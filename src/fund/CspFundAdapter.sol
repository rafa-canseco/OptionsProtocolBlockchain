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

    function deallocationInterfaceVersion() external pure returns (uint64) {
        return 2;
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
                $.releasablePrincipal,
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
        if ($.activePositionCount >= $.riskConfig.maxOpenPositions) revert InvalidRiskConfig();
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
        CspFundAdapterOperations.checkpointPosition($, positionId, opened);

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
        returns (uint256 accountingAssetsOut, uint256 principalReleased)
    {
        CspFundAdapterStorageLayout storage $ = _getCspFundAdapterStorage();
        if (targetValue == 0) revert InvalidAmount();
        _requireNoDeficit($);
        DeallocateData memory deallocation = abi.decode(data, (DeallocateData));

        bool returnAll;
        bool principalReleaseEligible;
        if (deallocation.action == DeallocateAction.ReturnIdle) {
            if (targetValue > $.accountedUsdc) revert InvalidAmount();
            _checkpointGlobal($, keccak256(abi.encode("RETURN_IDLE", targetValue)));
            principalReleaseEligible = $.accountedWeth == 0;
        } else if (deallocation.action == DeallocateAction.Settle) {
            CspFundAdapterOperations.settlePosition($, deallocation.positionId);
            principalReleaseEligible = $.accountedWeth == 0;
        } else if (deallocation.action == DeallocateAction.SwapAssignedWeth) {
            CspFundAdapterOperations.swapAssignedWeth($, minAccountingAssetsOut, deallocation);
            returnAll = true;
            principalReleaseEligible = true;
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
            if (principalReleaseEligible) {
                principalReleased = _consumeReleasablePrincipal($, targetValue);
            }
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
        $.releasablePrincipal -= Math.mulDiv($.releasablePrincipal, fractionWad, FundConstants.WAD);
        _checkpointGlobal($, keccak256(abi.encode("RAW_RECOVERY", fractionWad, escrow, amounts, emergency)));
        if (amounts[0] != 0) IERC20(assets[0]).safeTransfer(escrow, amounts[0]);
        if (amounts[1] != 0) IERC20(assets[1]).safeTransfer(escrow, amounts[1]);
        emit RawAssetsRecovered(escrow, assets, amounts, emergency);
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

    function _requireNoDeficit(CspFundAdapterStorageLayout storage $) private view {
        uint256 rawUsdc = IERC20($.accountingAsset).balanceOf(address(this));
        uint256 rawWeth = IERC20($.weth).balanceOf(address(this));
        if (rawUsdc < $.accountedUsdc) revert AccountingDeficit($.accountingAsset, $.accountedUsdc, rawUsdc);
        if (rawWeth < $.accountedWeth) revert AccountingDeficit($.weth, $.accountedWeth, rawWeth);
    }

    function _consumeReleasablePrincipal(CspFundAdapterStorageLayout storage $, uint256 targetValue)
        private
        returns (uint256 principalReleased)
    {
        principalReleased = Math.min($.releasablePrincipal, targetValue);
        $.releasablePrincipal -= principalReleased;
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
