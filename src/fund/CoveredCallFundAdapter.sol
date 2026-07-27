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
import {CoveredCallFundAdapterStorage} from "./storage/CoveredCallFundAdapterStorage.sol";
import {ICoveredCallFundAdapter} from "./interfaces/ICoveredCallFundAdapter.sol";
import {CoveredCallFundAdapterOperations} from "./libraries/CoveredCallFundAdapterOperations.sol";

interface IFundTotalAssets {
    function totalAssets() external view returns (uint256);
}

/// @notice WETH-accounted ETH covered-call strategy boundary for one tokenized fund.
/// @dev USDC premium and called-away proceeds remain transient until normalized back to WETH.
contract CoveredCallFundAdapter is FundUpgradeable, CoveredCallFundAdapterStorage, ICoveredCallFundAdapter {
    using SafeERC20 for IERC20;

    bytes32 private constant INITIAL_COVERED_CALL_POSITIONS_HASH = keccak256("b1nary Covered Call Positions");

    struct InitializeParams {
        address fund;
        address strategyManager;
        address addressBook;
        address accountingAsset;
        address usdc;
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
                || params.accountingAsset == address(0) || params.usdc == address(0) || params.swapRouter == address(0)
                || params.fund.code.length == 0 || params.strategyManager.code.length == 0
                || params.addressBook.code.length == 0 || params.swapRouter.code.length == 0
        ) revert InvalidAddress();
        if (
            IERC20Metadata(params.accountingAsset).decimals() != 18 || IERC20Metadata(params.usdc).decimals() != 6
                || params.accountingAsset == params.usdc || !_isValidFeeTier(params.swapFeeTier)
        ) revert InvalidRiskConfig();
        _validateRiskConfig(params.riskConfig);
        __FundUpgradeable_init(params.authority);

        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        $.fund = params.fund;
        $.strategyManager = params.strategyManager;
        $.addressBook = params.addressBook;
        $.accountingAsset = params.accountingAsset;
        $.usdc = params.usdc;
        $.swapRouter = params.swapRouter;
        $.swapFeeTier = params.swapFeeTier;
        $.positionsHash = INITIAL_COVERED_CALL_POSITIONS_HASH;
        $.riskConfig = params.riskConfig;
    }

    modifier onlyStrategyManager() {
        _checkStrategyManager();
        _;
    }

    function _checkStrategyManager() private view {
        if (msg.sender != _getCoveredCallFundAdapterStorage().strategyManager) revert OnlyStrategyManager();
    }

    function fund() external view returns (address) {
        return _getCoveredCallFundAdapterStorage().fund;
    }

    function strategyManager() external view returns (address) {
        return _getCoveredCallFundAdapterStorage().strategyManager;
    }

    function addressBook() external view returns (address) {
        return _getCoveredCallFundAdapterStorage().addressBook;
    }

    function accountingAsset() external view returns (address) {
        return _getCoveredCallFundAdapterStorage().accountingAsset;
    }

    function weth() external view returns (address) {
        return _getCoveredCallFundAdapterStorage().accountingAsset;
    }

    function usdc() external view returns (address) {
        return _getCoveredCallFundAdapterStorage().usdc;
    }

    function adapterState() external view returns (AdapterState memory state) {
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        state = AdapterState({
            stateNonce: $.stateNonce,
            positionsHash: $.positionsHash,
            positionCount: $.positionCount,
            activePositionCount: $.activePositionCount,
            activeCollateral: $.activeCollateral,
            accountedWeth: $.accountedWeth,
            accountedUsdc: $.accountedUsdc
        });
    }

    function adapterConfig() external view returns (AdapterConfig memory config) {
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        config = AdapterConfig({riskConfig: $.riskConfig, swapRouter: $.swapRouter, swapFeeTier: $.swapFeeTier});
    }

    function position(uint256 positionId) external view returns (Position memory) {
        return _getCoveredCallFundAdapterStorage().positions[positionId];
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function positionStateHash() public view returns (bytes32) {
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.fund,
                $.stateNonce,
                $.positionsHash,
                $.activePositionCount,
                $.activeCollateral,
                $.accountedWeth,
                $.accountedUsdc,
                IERC20($.accountingAsset).balanceOf(address(this)),
                IERC20($.usdc).balanceOf(address(this))
            )
        );
    }

    function freeAssets(address asset) external view returns (uint256) {
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        if (asset == $.accountingAsset) return Math.min($.accountedWeth, IERC20(asset).balanceOf(address(this)));
        if (asset == $.usdc) return Math.min($.accountedUsdc, IERC20(asset).balanceOf(address(this)));
        return 0;
    }

    function isOnboarded() public view returns (bool) {
        return CoveredCallFundAdapterOperations.isOnboarded(_getCoveredCallFundAdapterStorage());
    }

    function setAdapterConfig(RiskConfig calldata riskConfig_, address swapRouter_, uint24 swapFeeTier_)
        external
        restricted
    {
        _validateRiskConfig(riskConfig_);
        if (swapRouter_ == address(0) || swapRouter_.code.length == 0 || !_isValidFeeTier(swapFeeTier_)) {
            revert InvalidAddress();
        }
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        $.riskConfig = riskConfig_;
        $.swapRouter = swapRouter_;
        $.swapFeeTier = swapFeeTier_;
        emit AdapterConfigUpdated(riskConfig_, swapRouter_, swapFeeTier_);
    }

    function allocate(address asset, uint256 amount, bytes calldata data) external onlyStrategyManager {
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        if (!isOnboarded()) revert AdapterNotOnboarded();
        if (asset != $.accountingAsset || amount == 0) revert InvalidAmount();
        _requireNoDeficit($);

        OpenPositionData memory openData = abi.decode(data, (OpenPositionData));
        if (openData.collateral != amount || openData.optionAmount == 0) revert InvalidAmount();
        if (
            $.activePositionCount >= $.riskConfig.maxOpenPositions || $.accountedUsdc != 0
                || $.activeCollateral + amount
                    > Math.mulDiv(
                        IFundTotalAssets($.fund).totalAssets(), $.riskConfig.maxUtilizationBps, FundConstants.BPS
                    )
        ) revert InvalidRiskConfig();
        _validateCall($, openData);

        IERC20 wethToken = IERC20($.accountingAsset);
        IERC20 usdcToken = IERC20($.usdc);
        AddressBook book = AddressBook($.addressBook);
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        MarginPool pool = MarginPool(book.marginPool());
        uint256 expectedVaultId = controller.vaultCount(address(this)) + 1;
        uint256 wethBefore = wethToken.balanceOf(address(this));
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 poolBefore = pool.getStoredBalance($.accountingAsset);

        $.accountedWeth += amount;
        wethToken.forceApprove(address(pool), openData.collateral);
        uint256 protocolVaultId =
            settler.executeOrder(openData.quote, openData.signature, openData.optionAmount, openData.collateral);
        wethToken.forceApprove(address(pool), 0);

        uint256 wethAfter = wethToken.balanceOf(address(this));
        uint256 usdcAfter = usdcToken.balanceOf(address(this));
        uint256 poolAfter = pool.getStoredBalance($.accountingAsset);
        if (
            protocolVaultId != expectedVaultId || poolAfter < poolBefore
                || poolAfter - poolBefore != openData.collateral || wethBefore < wethAfter
                || wethBefore - wethAfter != openData.collateral || usdcAfter < usdcBefore
        ) revert LedgerMismatch(0);
        uint256 premiumEarned = usdcAfter - usdcBefore;
        _validatePremium($, openData.collateral, premiumEarned);
        $.accountedWeth -= openData.collateral;
        $.accountedUsdc += premiumEarned;
        $.activeCollateral += openData.collateral;

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
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        if (targetValue == 0) revert InvalidAmount();
        _requireNoDeficit($);
        DeallocateData memory deallocation = abi.decode(data, (DeallocateData));

        if (deallocation.action == DeallocateAction.ReturnIdle) {
            if ($.activePositionCount != 0) revert InvalidRiskConfig();
            if ($.accountedUsdc != 0) revert UnresolvedUsdc($.accountedUsdc);
            if (targetValue > $.accountedWeth) revert InvalidAmount();
            _checkpointGlobal($, keccak256(abi.encode("RETURN_IDLE", targetValue)));
        } else if (deallocation.action == DeallocateAction.Settle) {
            CoveredCallFundAdapterOperations.settlePosition($, deallocation.positionId);
        } else if (deallocation.action == DeallocateAction.NormalizeUsdc) {
            if ($.activePositionCount != 0) revert InvalidRiskConfig();
            CoveredCallFundAdapterOperations.normalizeUsdc($, deallocation.amount, deallocation.minAmountOut);
        } else {
            revert InvalidAmount();
        }

        if ($.activePositionCount == 0 && $.accountedUsdc == 0) {
            uint256 available = Math.min($.accountedWeth, IERC20($.accountingAsset).balanceOf(address(this)));
            accountingAssetsOut = Math.min(targetValue, available);
        }
        if (accountingAssetsOut < minAccountingAssetsOut) {
            revert SlippageExceeded(minAccountingAssetsOut, accountingAssetsOut);
        }
        if (accountingAssetsOut != 0) {
            $.accountedWeth -= accountingAssetsOut;
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
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        if ($.activePositionCount != 0) revert InvalidRiskConfig();
        if ($.accountedUsdc != 0) revert UnresolvedUsdc($.accountedUsdc);
        _requireNoDeficit($);

        assets = new address[](1);
        amounts = new uint256[](1);
        assets[0] = $.accountingAsset;
        amounts[0] = Math.mulDiv($.accountedWeth, fractionWad, FundConstants.WAD);
        $.accountedWeth -= amounts[0];
        _checkpointGlobal($, keccak256(abi.encode("WETH_ONLY_IN_KIND", fractionWad, escrow, amounts[0])));
        if (amounts[0] != 0) IERC20(assets[0]).safeTransfer(escrow, amounts[0]);
        emit RawAssetsRecovered(escrow, assets, amounts, false);
    }

    function emergencyExit(address escrow, bytes calldata)
        external
        onlyStrategyManager
        returns (address[] memory assets, uint256[] memory amounts)
    {
        if (escrow == address(0)) revert InvalidAddress();
        CoveredCallFundAdapterStorageLayout storage $ = _getCoveredCallFundAdapterStorage();
        if ($.activePositionCount != 0) revert InvalidRiskConfig();
        _requireNoDeficit($);

        assets = new address[](2);
        amounts = new uint256[](2);
        assets[0] = $.accountingAsset;
        assets[1] = $.usdc;
        amounts[0] = $.accountedWeth;
        amounts[1] = $.accountedUsdc;
        $.accountedWeth = 0;
        $.accountedUsdc = 0;
        _checkpointGlobal($, keccak256(abi.encode("EMERGENCY_RECOVERY", escrow, amounts)));
        if (amounts[0] != 0) IERC20(assets[0]).safeTransfer(escrow, amounts[0]);
        if (amounts[1] != 0) IERC20(assets[1]).safeTransfer(escrow, amounts[1]);
        emit RawAssetsRecovered(escrow, assets, amounts, true);
    }

    function _validateCall(CoveredCallFundAdapterStorageLayout storage $, OpenPositionData memory openData)
        private
        view
    {
        OToken oToken = OToken(openData.quote.oToken);
        RiskConfig storage config = $.riskConfig;
        if (
            openData.quote.oToken == address(0) || oToken.isPut() || oToken.underlying() != $.accountingAsset
                || oToken.strikeAsset() != $.usdc || oToken.collateralAsset() != $.accountingAsset
        ) revert InvalidSeries(openData.quote.oToken);
        uint256 expiryDelay = oToken.expiry() > block.timestamp ? oToken.expiry() - block.timestamp : 0;
        if (
            expiryDelay < config.minExpiryDelay || expiryDelay > config.maxExpiryDelay
                || oToken.strikePrice() < config.minStrike || oToken.strikePrice() > config.maxStrike
                || openData.collateral > config.maxCollateralPerPosition
        ) revert InvalidRiskConfig();
        uint256 requiredCollateral = openData.optionAmount * 1e10;
        if (openData.collateral != requiredCollateral) revert InvalidAmount();
    }

    function _validatePremium(CoveredCallFundAdapterStorageLayout storage $, uint256 collateral, uint256 premiumEarned)
        private
        view
    {
        uint256 spotPrice = Oracle(AddressBook($.addressBook).oracle()).getPrice($.accountingAsset);
        uint256 collateralValueUsdc = Math.mulDiv(collateral, spotPrice, 1e20);
        if (
            premiumEarned == 0
                || premiumEarned * FundConstants.BPS < collateralValueUsdc * uint256($.riskConfig.minPremiumBps)
        ) revert InvalidRiskConfig();
    }

    function _validateOpenLedger(
        CoveredCallFundAdapterStorageLayout storage $,
        uint256 positionId,
        Position storage opened
    ) private view {
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

    function _requireNoDeficit(CoveredCallFundAdapterStorageLayout storage $) private view {
        uint256 rawWeth = IERC20($.accountingAsset).balanceOf(address(this));
        uint256 rawUsdc = IERC20($.usdc).balanceOf(address(this));
        if (rawWeth < $.accountedWeth) {
            revert AccountingDeficit($.accountingAsset, $.accountedWeth, rawWeth);
        }
        if (rawUsdc < $.accountedUsdc) revert AccountingDeficit($.usdc, $.accountedUsdc, rawUsdc);
    }

    function _checkpointPosition(
        CoveredCallFundAdapterStorageLayout storage $,
        uint256 positionId,
        Position storage current
    ) private {
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
                current.calledAwayUsdc,
                current.fallbackWethRecovered,
                current.mmWethPayout,
                current.lifecycle
            )
        );
        $.positionsHash = keccak256(abi.encode($.positionsHash, nextNonce, positionId, current.lifecycleHash));
    }

    function _checkpointGlobal(CoveredCallFundAdapterStorageLayout storage $, bytes32 operationHash) private {
        uint64 nextNonce = ++$.stateNonce;
        $.positionsHash = keccak256(abi.encode($.positionsHash, nextNonce, operationHash));
    }

    function _validateRiskConfig(RiskConfig memory config) private pure {
        if (
            config.minExpiryDelay == 0 || config.maxExpiryDelay < config.minExpiryDelay
                || config.settlementDefaultDelay == 0 || config.minPremiumBps > FundConstants.BPS
                || config.maxSwapSlippageBps > FundConstants.BPS || config.maxOpenPositions == 0
                || config.maxUtilizationBps == 0 || config.maxUtilizationBps > FundConstants.BPS
                || config.maxStrike < config.minStrike || config.maxCollateralPerPosition == 0
                || config.maxUsdcPerSwap == 0
        ) revert InvalidRiskConfig();
    }

    function _isValidFeeTier(uint24 feeTier) private pure returns (bool) {
        return feeTier == 100 || feeTier == 500 || feeTier == 3000 || feeTier == 10_000;
    }
}
