// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressBook} from "../core/AddressBook.sol";
import {BatchSettler} from "../core/BatchSettler.sol";
import {Controller} from "../core/Controller.sol";
import {MarginPool} from "../core/MarginPool.sol";
import {OToken} from "../core/OToken.sol";
import {Oracle} from "../core/Oracle.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {CspFundAdapterStorage} from "./storage/CspFundAdapterStorage.sol";
import {ICspFundAdapter} from "./interfaces/ICspFundAdapter.sol";
import {CspFundAdapterOperations} from "./libraries/CspFundAdapterOperations.sol";

/// @notice ETH/USDC cash-secured-put strategy boundary for one tokenized fund.
/// @dev The adapter owns only strategy state and strategy-held USDC/WETH. Authoritative NAV is external.
contract CspFundAdapter is FundUpgradeable, CspFundAdapterStorage, ICspFundAdapter {
    using SafeERC20 for IERC20;

    bytes32 private constant INITIAL_CSP_POSITIONS_HASH = keccak256("b1nary CSP Positions");

    struct InitializeParams {
        address fund;
        address strategyManager;
        address addressBook;
        address accountingAsset;
        address weth;
        address swapRouter;
        uint24 swapFeeTier;
        address authority;
        RiskConfig riskConfig;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitializeParams calldata params) external initializer {
        if (
            params.fund == address(0) || params.strategyManager == address(0) || params.addressBook == address(0)
                || params.accountingAsset == address(0) || params.weth == address(0) || params.swapRouter == address(0)
                || params.fund.code.length == 0 || params.strategyManager.code.length == 0
                || params.addressBook.code.length == 0 || params.swapRouter.code.length == 0
        ) revert InvalidAddress();
        if (
            IERC20Metadata(params.accountingAsset).decimals() != 6 || IERC20Metadata(params.weth).decimals() != 18
                || !_isValidFeeTier(params.swapFeeTier)
        ) revert InvalidRiskConfig();
        _validateRiskConfig(params.riskConfig);
        __FundUpgradeable_init(params.authority);

        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        $.fund = params.fund;
        $.strategyManager = params.strategyManager;
        $.addressBook = params.addressBook;
        $.accountingAsset = params.accountingAsset;
        $.weth = params.weth;
        $.swapRouter = params.swapRouter;
        $.swapFeeTier = params.swapFeeTier;
        $.positionsHash = INITIAL_CSP_POSITIONS_HASH;
        $.riskConfig = params.riskConfig;
    }

    modifier onlyStrategyManager() {
        _checkStrategyManager();
        _;
    }

    function _checkStrategyManager() private view {
        if (msg.sender != _getCspFundAdapterStorage().strategyManager) revert OnlyStrategyManager();
    }

    function fund() external view returns (address) {
        return _getCspFundAdapterStorage().fund;
    }

    function strategyManager() external view returns (address) {
        return _getCspFundAdapterStorage().strategyManager;
    }

    function addressBook() external view returns (address) {
        return _getCspFundAdapterStorage().addressBook;
    }

    function accountingAsset() external view returns (address) {
        return _getCspFundAdapterStorage().accountingAsset;
    }

    function weth() external view returns (address) {
        return _getCspFundAdapterStorage().weth;
    }

    function adapterState() external view returns (AdapterState memory state) {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        state = AdapterState({
            stateNonce: $.stateNonce,
            positionsHash: $.positionsHash,
            positionCount: $.positionCount,
            activePositionCount: $.activePositionCount,
            accountedUsdc: $.accountedUsdc,
            accountedWeth: $.accountedWeth
        });
    }

    function adapterConfig() external view returns (AdapterConfig memory config) {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        config = AdapterConfig({riskConfig: $.riskConfig, swapRouter: $.swapRouter, swapFeeTier: $.swapFeeTier});
    }

    function position(uint256 positionId) external view returns (Position memory) {
        return _getCspFundAdapterStorage().positions[positionId];
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function positionStateHash() public view returns (bytes32) {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.fund,
                $.stateNonce,
                $.positionsHash,
                $.activePositionCount,
                $.accountedUsdc,
                $.accountedWeth,
                IERC20($.accountingAsset).balanceOf(address(this)),
                IERC20($.weth).balanceOf(address(this))
            )
        );
    }

    function freeAssets(address asset) external view returns (uint256) {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        if (asset == $.accountingAsset) return Math.min($.accountedUsdc, IERC20(asset).balanceOf(address(this)));
        if (asset == $.weth) return Math.min($.accountedWeth, IERC20(asset).balanceOf(address(this)));
        return 0;
    }

    function isOnboarded() public view returns (bool) {
        return CspFundAdapterOperations.isOnboarded(_getCspFundAdapterStorage());
    }

    function setAdapterConfig(RiskConfig calldata riskConfig_, address swapRouter_, uint24 swapFeeTier_)
        external
        restricted
    {
        _validateRiskConfig(riskConfig_);
        if (swapRouter_ == address(0) || swapRouter_.code.length == 0 || !_isValidFeeTier(swapFeeTier_)) {
            revert InvalidAddress();
        }
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        $.riskConfig = riskConfig_;
        $.swapRouter = swapRouter_;
        $.swapFeeTier = swapFeeTier_;
        emit AdapterConfigUpdated(riskConfig_, swapRouter_, swapFeeTier_);
    }

    function allocate(address asset, uint256 amount, bytes calldata data) external onlyStrategyManager {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        if (!isOnboarded()) revert AdapterNotOnboarded();
        if (asset != $.accountingAsset || amount == 0) revert InvalidAmount();
        _requireNoDeficit($);

        OpenPositionData memory openData = abi.decode(data, (OpenPositionData));
        if (openData.collateral != amount || openData.optionAmount == 0) revert InvalidAmount();
        if ($.activePositionCount >= $.riskConfig.maxOpenPositions || $.accountedWeth != 0) {
            revert InvalidRiskConfig();
        }
        _validatePut($, openData);

        IERC20 usdc = IERC20($.accountingAsset);
        AddressBook book = AddressBook($.addressBook);
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        MarginPool pool = MarginPool(book.marginPool());
        uint256 expectedVaultId = controller.vaultCount(address(this)) + 1;
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 poolBefore = pool.getStoredBalance($.accountingAsset);

        $.accountedUsdc += amount;
        usdc.forceApprove(address(pool), openData.collateral);
        uint256 protocolVaultId =
            settler.executeOrder(openData.quote, openData.signature, openData.optionAmount, openData.collateral);
        usdc.forceApprove(address(pool), 0);

        uint256 usdcAfter = usdc.balanceOf(address(this));
        uint256 poolAfter = pool.getStoredBalance($.accountingAsset);
        if (
            protocolVaultId != expectedVaultId || poolAfter < poolBefore
                || poolAfter - poolBefore != openData.collateral || usdcAfter + openData.collateral < usdcBefore
        ) revert LedgerMismatch(0);
        uint256 premiumEarned = usdcAfter + openData.collateral - usdcBefore;
        if (premiumEarned * FundConstants.BPS < openData.collateral * uint256($.riskConfig.minPremiumBps)) {
            revert InvalidRiskConfig();
        }
        $.accountedUsdc = $.accountedUsdc - openData.collateral + premiumEarned;

        settler.reservePhysicalDelivery(protocolVaultId);
        address mm = settler.vaultMM(address(this), protocolVaultId);
        uint256 positionId = ++$.positionCount;
        Position storage opened = $.positions[positionId];
        opened.oToken = openData.quote.oToken;
        opened.marketMaker = mm;
        opened.protocolVaultId = protocolVaultId;
        opened.optionAmount = openData.optionAmount;
        opened.collateral = openData.collateral;
        opened.premiumEarned = premiumEarned;
        opened.openedAt = uint64(block.timestamp);
        opened.lifecycle = Lifecycle.Open;
        ++$.activePositionCount;
        _validateOpenLedger($, positionId, opened);
        _checkpointPosition($, positionId, opened);

        emit PositionOpened(
            positionId,
            protocolVaultId,
            opened.oToken,
            mm,
            opened.optionAmount,
            opened.collateral,
            premiumEarned,
            opened.lifecycleHash
        );
    }

    function deallocate(uint256 targetValue, uint256 minAccountingAssetsOut, bytes calldata data)
        external
        onlyStrategyManager
        returns (uint256 accountingAssetsOut)
    {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        if (targetValue == 0) revert InvalidAmount();
        _requireNoDeficit($);
        DeallocateData memory deallocation = abi.decode(data, (DeallocateData));

        bool returnAll;
        if (deallocation.action == DeallocateAction.ReturnIdle) {
            if (targetValue > $.accountedUsdc) revert InvalidAmount();
            _checkpointGlobal($, keccak256(abi.encode("RETURN_IDLE", targetValue)));
        } else if (deallocation.action == DeallocateAction.Settle) {
            _settlePosition($, deallocation.positionId);
        } else if (deallocation.action == DeallocateAction.SwapAssignedWeth) {
            CspFundAdapterOperations.swapAssignedWeth($, minAccountingAssetsOut, deallocation);
            returnAll = true;
        } else {
            revert InvalidAmount();
        }

        uint256 available = Math.min($.accountedUsdc, IERC20($.accountingAsset).balanceOf(address(this)));
        accountingAssetsOut = returnAll ? available : Math.min(targetValue, available);
        if (accountingAssetsOut < minAccountingAssetsOut) {
            revert SlippageExceeded(minAccountingAssetsOut, accountingAssetsOut);
        }
        if (accountingAssetsOut != 0) {
            $.accountedUsdc -= accountingAssetsOut;
            IERC20($.accountingAsset).safeTransfer($.fund, accountingAssetsOut);
            emit AccountingAssetsReturned(accountingAssetsOut);
        }
    }

    function deallocateInKind(uint256 fractionWad, address escrow, bytes calldata)
        external
        onlyStrategyManager
        returns (address[] memory assets, uint256[] memory amounts)
    {
        if (fractionWad == 0 || fractionWad > FundConstants.WAD || escrow == address(0)) {
            revert InvalidAmount();
        }
        if (_getCspFundAdapterStorage().activePositionCount != 0) revert InvalidRiskConfig();
        return _recoverRawAssets(fractionWad, escrow, false);
    }

    function emergencyExit(address escrow, bytes calldata)
        external
        onlyStrategyManager
        returns (address[] memory assets, uint256[] memory amounts)
    {
        if (escrow == address(0)) revert InvalidAddress();
        if (_getCspFundAdapterStorage().activePositionCount != 0) revert InvalidRiskConfig();
        return _recoverRawAssets(FundConstants.WAD, escrow, true);
    }

    function _recoverRawAssets(uint256 fractionWad, address escrow, bool emergency)
        private
        returns (address[] memory assets, uint256[] memory amounts)
    {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        _requireNoDeficit($);
        assets = new address[](2);
        amounts = new uint256[](2);
        assets[0] = $.accountingAsset;
        assets[1] = $.weth;
        amounts[0] = Math.mulDiv($.accountedUsdc, fractionWad, FundConstants.WAD);
        amounts[1] = Math.mulDiv($.accountedWeth, fractionWad, FundConstants.WAD);
        $.accountedUsdc -= amounts[0];
        $.accountedWeth -= amounts[1];
        _checkpointGlobal($, keccak256(abi.encode("RAW_RECOVERY", fractionWad, escrow, amounts, emergency)));
        if (amounts[0] != 0) IERC20(assets[0]).safeTransfer(escrow, amounts[0]);
        if (amounts[1] != 0) IERC20(assets[1]).safeTransfer(escrow, amounts[1]);
        emit RawAssetsRecovered(escrow, assets, amounts, emergency);
    }

    function _settlePosition(CspFundAdapterStorageLayout storage $, uint256 positionId) private {
        Position storage current = $.positions[positionId];
        if (current.protocolVaultId == 0) revert InvalidPosition(positionId);
        if (current.lifecycle == Lifecycle.Open) {
            _prepareSettlement($, positionId, current);
            return;
        }
        if (current.lifecycle == Lifecycle.AwaitingPhysicalDelivery) {
            _completePhysicalOrFallback($, positionId, current);
            return;
        }
        revert InvalidLifecycle(positionId, current.lifecycle);
    }

    function _prepareSettlement(CspFundAdapterStorageLayout storage $, uint256 positionId, Position storage current)
        private
    {
        OToken oToken = OToken(current.oToken);
        if (block.timestamp < oToken.expiry()) revert SettlementNotReady(positionId);
        AddressBook book = AddressBook($.addressBook);
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        uint256 usdcBefore = IERC20($.accountingAsset).balanceOf(address(this));
        controller.settleVault(address(this), current.protocolVaultId);
        uint256 collateralReturned = IERC20($.accountingAsset).balanceOf(address(this)) - usdcBefore;
        if (collateralReturned > current.collateral) revert LedgerMismatch(positionId);
        $.accountedUsdc += collateralReturned;
        current.collateralReturned = collateralReturned;

        (uint256 expiryPrice, bool isSet) = Oracle(book.oracle()).getExpiryPrice($.weth, oToken.expiry());
        if (!isSet) revert SettlementNotReady(positionId);
        if (expiryPrice >= oToken.strikePrice()) {
            uint256 payout = settler.settleReservedPhysicalDelivery(current.protocolVaultId, current.marketMaker, 0);
            if (payout != 0 || collateralReturned != current.collateral) revert LedgerMismatch(positionId);
            current.lifecycle = Lifecycle.SettledOtm;
            --$.activePositionCount;
            _validateTerminalLedger($, positionId, current);
            _checkpointPosition($, positionId, current);
            emit PositionTransitioned(
                positionId, current.protocolVaultId, current.lifecycle, collateralReturned, 0, 0, current.lifecycleHash
            );
            return;
        }

        settler.releasePhysicalDelivery(current.protocolVaultId);
        current.wethBalanceBeforeDelivery = IERC20($.weth).balanceOf(address(this));
        current.fallbackEligibleAt = uint64(block.timestamp + $.riskConfig.settlementDefaultDelay);
        current.lifecycle = Lifecycle.AwaitingPhysicalDelivery;
        _checkpointPosition($, positionId, current);
        emit PositionTransitioned(
            positionId, current.protocolVaultId, current.lifecycle, collateralReturned, 0, 0, current.lifecycleHash
        );
    }

    function _completePhysicalOrFallback(
        CspFundAdapterStorageLayout storage $,
        uint256 positionId,
        Position storage current
    ) private {
        AddressBook book = AddressBook($.addressBook);
        BatchSettler settler = BatchSettler(book.batchSettler());
        uint256 remainingLedger = settler.vaultOTokenBalance(address(this), current.protocolVaultId);
        if (remainingLedger == 0) {
            if (settler.physicalDeliveryReservedVault(address(this), current.protocolVaultId)) {
                revert LedgerMismatch(positionId);
            }
            uint256 expectedWeth = current.optionAmount * 1e10;
            uint256 wethBalance = IERC20($.weth).balanceOf(address(this));
            if (wethBalance < current.wethBalanceBeforeDelivery) revert LedgerMismatch(positionId);
            uint256 deliveredWeth = wethBalance - current.wethBalanceBeforeDelivery;
            if (deliveredWeth < expectedWeth) revert LedgerMismatch(positionId);
            $.accountedWeth += expectedWeth;
            current.assignedWeth = expectedWeth;
            current.lifecycle = Lifecycle.Assigned;
            --$.activePositionCount;
            _checkpointPosition($, positionId, current);
            if (deliveredWeth > expectedWeth) {
                emit UnaccountedAssetIsolated($.weth, deliveredWeth - expectedWeth);
            }
            emit PositionTransitioned(
                positionId, current.protocolVaultId, current.lifecycle, 0, 0, expectedWeth, current.lifecycleHash
            );
            return;
        }

        if (block.timestamp < current.fallbackEligibleAt) revert SettlementNotReady(positionId);
        if (!settler.physicalDeliveryReservedVault(address(this), current.protocolVaultId)) {
            settler.reservePhysicalDelivery(current.protocolVaultId);
        }
        (uint256 redemptionPayout, uint256 mmCashPayout) = _putCashPayouts($, current);
        uint256 usdcBefore = IERC20($.accountingAsset).balanceOf(address(this));
        uint256 payout =
            settler.settleReservedPhysicalDelivery(current.protocolVaultId, address(this), redemptionPayout);
        uint256 observedPayout = IERC20($.accountingAsset).balanceOf(address(this)) - usdcBefore;
        if (payout != redemptionPayout || observedPayout != redemptionPayout || mmCashPayout > payout) {
            revert LedgerMismatch(positionId);
        }
        $.accountedUsdc += payout;
        if (mmCashPayout != 0) {
            $.accountedUsdc -= mmCashPayout;
            IERC20($.accountingAsset).safeTransfer(current.marketMaker, mmCashPayout);
        }
        current.lifecycle = Lifecycle.CashFallback;
        --$.activePositionCount;
        _validateTerminalLedger($, positionId, current);
        _checkpointPosition($, positionId, current);
        emit PositionTransitioned(
            positionId, current.protocolVaultId, current.lifecycle, payout, mmCashPayout, 0, current.lifecycleHash
        );
    }

    function _putCashPayouts(CspFundAdapterStorageLayout storage $, Position storage current)
        private
        view
        returns (uint256 redemptionPayout, uint256 mmCashPayout)
    {
        OToken oToken = OToken(current.oToken);
        (uint256 expiryPrice, bool isSet) =
            Oracle(AddressBook($.addressBook).oracle()).getExpiryPrice($.weth, oToken.expiry());
        if (!isSet || expiryPrice >= oToken.strikePrice()) revert SettlementNotReady(current.protocolVaultId);
        redemptionPayout = Math.mulDiv(current.optionAmount, oToken.strikePrice(), 1e10);
        mmCashPayout = Math.mulDiv(current.optionAmount, oToken.strikePrice() - expiryPrice, 1e10);
    }

    function _validatePut(CspFundAdapterStorageLayout storage $, OpenPositionData memory openData) private view {
        OToken oToken = OToken(openData.quote.oToken);
        RiskConfig storage config = $.riskConfig;
        if (
            openData.quote.oToken == address(0) || !oToken.isPut() || oToken.underlying() != $.weth
                || oToken.strikeAsset() != $.accountingAsset || oToken.collateralAsset() != $.accountingAsset
        ) revert InvalidSeries(openData.quote.oToken);
        uint256 expiryDelay = oToken.expiry() > block.timestamp ? oToken.expiry() - block.timestamp : 0;
        if (
            expiryDelay < config.minExpiryDelay || expiryDelay > config.maxExpiryDelay
                || oToken.strikePrice() < config.minStrike || oToken.strikePrice() > config.maxStrike
                || openData.collateral > config.maxCollateralPerPosition
        ) revert InvalidRiskConfig();
        uint256 requiredCollateral = Math.mulDiv(openData.optionAmount, oToken.strikePrice(), 1e10, Math.Rounding.Ceil);
        if (openData.collateral != requiredCollateral) revert InvalidAmount();
    }

    function _validateOpenLedger(CspFundAdapterStorageLayout storage $, uint256 positionId, Position storage opened)
        private
        view
    {
        AddressBook book = AddressBook($.addressBook);
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        (address shortOtoken, address collateralAsset, uint256 shortAmount, uint256 collateralAmount) =
            controller.vaults(address(this), opened.protocolVaultId);
        if (
            shortOtoken != opened.oToken || shortAmount != opened.optionAmount || collateralAsset != $.accountingAsset
                || collateralAmount != opened.collateral
                || controller.vaultSettled(address(this), opened.protocolVaultId) || opened.marketMaker == address(0)
                || settler.vaultOTokenBalance(address(this), opened.protocolVaultId) != opened.optionAmount
                || !settler.physicalDeliveryReservedVault(address(this), opened.protocolVaultId)
                || settler.physicalDeliveryReservedAmount(address(this), opened.protocolVaultId) != opened.optionAmount
        ) revert LedgerMismatch(positionId);
    }

    function _validateTerminalLedger(
        CspFundAdapterStorageLayout storage $,
        uint256 positionId,
        Position storage current
    ) private view {
        AddressBook book = AddressBook($.addressBook);
        if (
            !Controller(book.controller()).vaultSettled(address(this), current.protocolVaultId)
                || BatchSettler(book.batchSettler()).vaultOTokenBalance(address(this), current.protocolVaultId) != 0
                || BatchSettler(book.batchSettler())
                    .physicalDeliveryReservedVault(address(this), current.protocolVaultId)
        ) revert LedgerMismatch(positionId);
    }

    function _requireNoDeficit(CspFundAdapterStorageLayout storage $) private view {
        uint256 rawUsdc = IERC20($.accountingAsset).balanceOf(address(this));
        uint256 rawWeth = IERC20($.weth).balanceOf(address(this));
        if (rawUsdc < $.accountedUsdc) revert AccountingDeficit($.accountingAsset, $.accountedUsdc, rawUsdc);
        if (rawWeth < $.accountedWeth) revert AccountingDeficit($.weth, $.accountedWeth, rawWeth);
    }

    function _checkpointPosition(CspFundAdapterStorageLayout storage $, uint256 positionId, Position storage current)
        private
    {
        uint64 nextNonce = ++$.stateNonce;
        current.lifecycleHash = keccak256(
            abi.encode(
                current.lifecycleHash,
                nextNonce,
                positionId,
                current.protocolVaultId,
                current.oToken,
                current.marketMaker,
                current.optionAmount,
                current.collateral,
                current.premiumEarned,
                current.collateralReturned,
                current.assignedWeth,
                current.lifecycle
            )
        );
        $.positionsHash = keccak256(abi.encode($.positionsHash, nextNonce, positionId, current.lifecycleHash));
    }

    function _checkpointGlobal(CspFundAdapterStorageLayout storage $, bytes32 operationHash) private {
        uint64 nextNonce = ++$.stateNonce;
        $.positionsHash = keccak256(abi.encode($.positionsHash, nextNonce, operationHash));
    }

    function _validateRiskConfig(RiskConfig memory config) private pure {
        if (
            config.minExpiryDelay == 0 || config.maxExpiryDelay < config.minExpiryDelay
                || config.settlementDefaultDelay == 0 || config.minPremiumBps > FundConstants.BPS
                || config.maxSwapSlippageBps > FundConstants.BPS || config.maxOpenPositions == 0
                || config.maxStrike < config.minStrike || config.maxCollateralPerPosition == 0
                || config.maxWethPerSwap == 0
        ) revert InvalidRiskConfig();
    }

    function _isValidFeeTier(uint24 feeTier) private pure returns (bool) {
        return feeTier == 100 || feeTier == 500 || feeTier == 3000 || feeTier == 10_000;
    }
}
