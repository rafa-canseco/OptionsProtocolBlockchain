// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressBook} from "../../core/AddressBook.sol";
import {BatchSettler} from "../../core/BatchSettler.sol";
import {Controller} from "../../core/Controller.sol";
import {OToken} from "../../core/OToken.sol";
import {Oracle} from "../../core/Oracle.sol";
import {ISwapRouter} from "../../interfaces/ISwapRouter.sol";
import {FundConstants} from "../FundConstants.sol";
import {ICoveredCallFundAdapter} from "../interfaces/ICoveredCallFundAdapter.sol";
import {CoveredCallFundAdapterStorage} from "../storage/CoveredCallFundAdapterStorage.sol";

/// @notice Linked execution module for covered-call onboarding and bounded USDC normalization.
/// @dev Solidity library calls use DELEGATECALL, so accounting mutations remain in the adapter namespace.
library CoveredCallFundAdapterOperations {
    using SafeERC20 for IERC20;

    bytes4 private constant ADDRESS_BOOK_SELECTOR = bytes4(keccak256("addressBook()"));
    bytes4 private constant CUSTODIED_REDEMPTION_ONLY_SELECTOR = bytes4(keccak256("custodiedRedemptionOnly()"));
    bytes4 private constant AUTHORIZED_PHYSICAL_VAULT_SELECTOR =
        bytes4(keccak256("authorizedPhysicalDeliveryVault(address)"));
    bytes4 private constant SWAP_ROUTER_SELECTOR = bytes4(keccak256("swapRouter()"));
    bytes4 private constant SWAP_FEE_TIER_SELECTOR = bytes4(keccak256("swapFeeTier()"));
    bytes4 private constant ASSET_SWAP_FEE_TIER_SELECTOR = bytes4(keccak256("assetSwapFeeTier(address)"));
    bytes4 private constant PRICE_FEED_SELECTOR = bytes4(keccak256("priceFeed(address)"));
    bytes4 private constant WHITELISTED_UNDERLYING_SELECTOR = bytes4(keccak256("isWhitelistedUnderlying(address)"));
    bytes4 private constant WHITELISTED_COLLATERAL_SELECTOR = bytes4(keccak256("isWhitelistedCollateral(address)"));
    bytes4 private constant WHITELISTED_PRODUCT_SELECTOR =
        bytes4(keccak256("isProductWhitelisted(address,address,address,bool)"));

    event PositionTransitioned(
        uint256 indexed positionId,
        uint256 indexed protocolVaultId,
        ICoveredCallFundAdapter.Lifecycle lifecycle,
        uint256 wethDelta,
        uint256 usdcDelta,
        uint256 mmWethPayout,
        bytes32 lifecycleHash
    );
    event UsdcNormalized(uint256 usdcIn, uint256 wethOut);
    event UnaccountedAssetIsolated(address indexed asset, uint256 amount);

    error InvalidAmount();
    error InvalidLifecycle(uint256 positionId, ICoveredCallFundAdapter.Lifecycle lifecycle);
    error InvalidPosition(uint256 positionId);
    error LedgerMismatch(uint256 positionId);
    error SettlementNotReady(uint256 positionId);
    error SlippageExceeded(uint256 minimum, uint256 actual);

    function isOnboarded(CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $)
        public
        view
        returns (bool)
    {
        AddressBook book = AddressBook($.addressBook);
        address controllerAddress = book.controller();
        address settlerAddress = book.batchSettler();
        address poolAddress = book.marginPool();
        address factoryAddress = book.oTokenFactory();
        address oracleAddress = book.oracle();
        address whitelistAddress = book.whitelist();
        if (
            controllerAddress == address(0) || settlerAddress == address(0) || poolAddress == address(0)
                || factoryAddress == address(0) || oracleAddress == address(0) || whitelistAddress == address(0)
                || controllerAddress.code.length == 0 || settlerAddress.code.length == 0 || poolAddress.code.length == 0
                || factoryAddress.code.length == 0 || oracleAddress.code.length == 0
                || whitelistAddress.code.length == 0 || $.swapRouter.code.length == 0
        ) return false;
        if (!_returnsAddress(controllerAddress, ADDRESS_BOOK_SELECTOR, "", $.addressBook)) return false;
        if (!_returnsAddress(settlerAddress, ADDRESS_BOOK_SELECTOR, "", $.addressBook)) return false;
        if (!_returnsAddress(poolAddress, ADDRESS_BOOK_SELECTOR, "", $.addressBook)) return false;
        if (!_returnsAddress(factoryAddress, ADDRESS_BOOK_SELECTOR, "", $.addressBook)) return false;
        if (!_returnsAddress(oracleAddress, ADDRESS_BOOK_SELECTOR, "", $.addressBook)) return false;
        if (!_returnsAddress(whitelistAddress, ADDRESS_BOOK_SELECTOR, "", $.addressBook)) return false;
        if (!_returnsBool(controllerAddress, CUSTODIED_REDEMPTION_ONLY_SELECTOR, "")) return false;
        if (!_returnsBool(settlerAddress, AUTHORIZED_PHYSICAL_VAULT_SELECTOR, abi.encode(address(this)))) return false;
        if (!_returnsNonzeroAddress(settlerAddress, SWAP_ROUTER_SELECTOR, "")) return false;
        if (
            !_returnsNonzeroWord(settlerAddress, SWAP_FEE_TIER_SELECTOR, "")
                && !_returnsNonzeroWord(settlerAddress, ASSET_SWAP_FEE_TIER_SELECTOR, abi.encode($.accountingAsset))
        ) return false;
        if (!_returnsNonzeroAddress(oracleAddress, PRICE_FEED_SELECTOR, abi.encode($.accountingAsset))) return false;
        if (!_returnsBool(whitelistAddress, WHITELISTED_UNDERLYING_SELECTOR, abi.encode($.accountingAsset))) {
            return false;
        }
        if (!_returnsBool(whitelistAddress, WHITELISTED_COLLATERAL_SELECTOR, abi.encode($.accountingAsset))) {
            return false;
        }
        return _returnsBool(
            whitelistAddress,
            WHITELISTED_PRODUCT_SELECTOR,
            abi.encode($.accountingAsset, $.usdc, $.accountingAsset, false)
        );
    }

    function normalizeUsdc(
        CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $,
        uint256 usdcAmount,
        uint256 callerMinimumWethOut
    ) public returns (uint256 wethOut) {
        if (usdcAmount == 0 || usdcAmount > $.accountedUsdc || usdcAmount > $.riskConfig.maxUsdcPerSwap) {
            revert InvalidAmount();
        }

        uint256 spotPrice = Oracle(AddressBook($.addressBook).oracle()).getPrice($.accountingAsset);
        uint256 expectedWeth = Math.mulDiv(usdcAmount, 1e20, spotPrice);
        uint256 policyMinimum =
            Math.mulDiv(expectedWeth, FundConstants.BPS - $.riskConfig.maxSwapSlippageBps, FundConstants.BPS);
        if (callerMinimumWethOut < policyMinimum) {
            revert SlippageExceeded(policyMinimum, callerMinimumWethOut);
        }

        IERC20 usdcToken = IERC20($.usdc);
        IERC20 wethToken = IERC20($.accountingAsset);
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 wethBefore = wethToken.balanceOf(address(this));
        usdcToken.forceApprove($.swapRouter, usdcAmount);
        uint256 amountOut = ISwapRouter($.swapRouter)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: $.usdc,
                    tokenOut: $.accountingAsset,
                    fee: $.swapFeeTier,
                    recipient: address(this),
                    amountIn: usdcAmount,
                    amountOutMinimum: callerMinimumWethOut,
                    sqrtPriceLimitX96: 0
                })
            );
        usdcToken.forceApprove($.swapRouter, 0);

        uint256 observedUsdc = usdcBefore - usdcToken.balanceOf(address(this));
        uint256 observedWeth = wethToken.balanceOf(address(this)) - wethBefore;
        if (observedUsdc != usdcAmount || observedWeth != amountOut || observedWeth < callerMinimumWethOut) {
            revert SlippageExceeded(callerMinimumWethOut, observedWeth);
        }

        $.accountedUsdc -= observedUsdc;
        $.accountedWeth += observedWeth;
        uint64 nextNonce = ++$.stateNonce;
        $.positionsHash = keccak256(
            abi.encode($.positionsHash, nextNonce, keccak256(abi.encode("NORMALIZE_USDC", observedUsdc, observedWeth)))
        );
        emit UsdcNormalized(observedUsdc, observedWeth);
        return observedWeth;
    }

    function settlePosition(
        CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $,
        uint256 positionId
    ) public {
        ICoveredCallFundAdapter.Position storage current = $.positions[positionId];
        if (current.protocolVaultId == 0) revert InvalidPosition(positionId);
        if (current.lifecycle == ICoveredCallFundAdapter.Lifecycle.Open) {
            _prepareSettlement($, positionId, current);
            return;
        }
        if (current.lifecycle == ICoveredCallFundAdapter.Lifecycle.AwaitingPhysicalDelivery) {
            _completePhysicalOrFallback($, positionId, current);
            return;
        }
        revert InvalidLifecycle(positionId, current.lifecycle);
    }

    function _prepareSettlement(
        CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICoveredCallFundAdapter.Position storage current
    ) private {
        OToken oToken = OToken(current.oToken);
        if (block.timestamp < oToken.expiry()) revert SettlementNotReady(positionId);
        AddressBook book = AddressBook($.addressBook);
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        uint256 wethBefore = IERC20($.accountingAsset).balanceOf(address(this));
        controller.settleVault(address(this), current.protocolVaultId);
        uint256 wethAfter = IERC20($.accountingAsset).balanceOf(address(this));
        if (wethAfter < wethBefore) revert LedgerMismatch(positionId);
        uint256 collateralReturned = wethAfter - wethBefore;
        if (collateralReturned > current.collateral) revert LedgerMismatch(positionId);
        current.collateralReturned = collateralReturned;

        (uint256 expiryPrice, bool isSet) = Oracle(book.oracle()).getExpiryPrice($.accountingAsset, oToken.expiry());
        if (!isSet) revert SettlementNotReady(positionId);
        if (expiryPrice <= oToken.strikePrice()) {
            if (collateralReturned != current.collateral) revert LedgerMismatch(positionId);
            $.accountedWeth += collateralReturned;
            uint256 payout = settler.settleReservedPhysicalDelivery(current.protocolVaultId, current.marketMaker, 0);
            if (payout != 0) revert LedgerMismatch(positionId);
            current.lifecycle = ICoveredCallFundAdapter.Lifecycle.SettledOtm;
            _closeActivePosition($, current);
            _validateTerminalLedger($, positionId, current);
            _checkpointPosition($, positionId, current);
            emit PositionTransitioned(
                positionId, current.protocolVaultId, current.lifecycle, collateralReturned, 0, 0, current.lifecycleHash
            );
            return;
        }

        if (collateralReturned != 0) revert LedgerMismatch(positionId);
        settler.releasePhysicalDelivery(current.protocolVaultId);
        current.usdcBalanceBeforeDelivery = IERC20($.usdc).balanceOf(address(this));
        current.fallbackEligibleAt = uint64(block.timestamp + $.riskConfig.settlementDefaultDelay);
        current.lifecycle = ICoveredCallFundAdapter.Lifecycle.AwaitingPhysicalDelivery;
        _checkpointPosition($, positionId, current);
        emit PositionTransitioned(
            positionId, current.protocolVaultId, current.lifecycle, 0, 0, 0, current.lifecycleHash
        );
    }

    function _completePhysicalOrFallback(
        CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICoveredCallFundAdapter.Position storage current
    ) private {
        AddressBook book = AddressBook($.addressBook);
        BatchSettler settler = BatchSettler(book.batchSettler());
        uint256 remainingLedger = settler.vaultOTokenBalance(address(this), current.protocolVaultId);
        if (remainingLedger == 0) {
            if (settler.physicalDeliveryReservedVault(address(this), current.protocolVaultId)) {
                revert LedgerMismatch(positionId);
            }
            uint256 expectedUsdc = Math.mulDiv(current.optionAmount, OToken(current.oToken).strikePrice(), 1e10);
            uint256 usdcBalance = IERC20($.usdc).balanceOf(address(this));
            if (usdcBalance < current.usdcBalanceBeforeDelivery) revert LedgerMismatch(positionId);
            uint256 deliveredUsdc = usdcBalance - current.usdcBalanceBeforeDelivery;
            if (deliveredUsdc < expectedUsdc) revert LedgerMismatch(positionId);
            $.accountedUsdc += expectedUsdc;
            current.calledAwayUsdc = expectedUsdc;
            current.lifecycle = ICoveredCallFundAdapter.Lifecycle.CalledAway;
            _closeActivePosition($, current);
            _validateTerminalLedger($, positionId, current);
            _checkpointPosition($, positionId, current);
            if (deliveredUsdc > expectedUsdc) {
                emit UnaccountedAssetIsolated($.usdc, deliveredUsdc - expectedUsdc);
            }
            emit PositionTransitioned(
                positionId, current.protocolVaultId, current.lifecycle, 0, expectedUsdc, 0, current.lifecycleHash
            );
            return;
        }

        if (block.timestamp < current.fallbackEligibleAt) revert SettlementNotReady(positionId);
        if (!settler.physicalDeliveryReservedVault(address(this), current.protocolVaultId)) {
            settler.reservePhysicalDelivery(current.protocolVaultId);
        }
        OToken oToken = OToken(current.oToken);
        (uint256 expiryPrice, bool isSet) = Oracle(book.oracle()).getExpiryPrice($.accountingAsset, oToken.expiry());
        if (!isSet || expiryPrice <= oToken.strikePrice()) revert SettlementNotReady(positionId);

        uint256 wethBefore = IERC20($.accountingAsset).balanceOf(address(this));
        uint256 payout =
            settler.settleReservedPhysicalDelivery(current.protocolVaultId, address(this), current.collateral);
        uint256 observedPayout = IERC20($.accountingAsset).balanceOf(address(this)) - wethBefore;
        uint256 mmWethPayout =
            Math.mulDiv(current.collateral, expiryPrice - oToken.strikePrice(), expiryPrice, Math.Rounding.Ceil);
        if (payout != current.collateral || observedPayout != payout || mmWethPayout > payout) {
            revert LedgerMismatch(positionId);
        }
        $.accountedWeth += payout;
        if (mmWethPayout != 0) {
            $.accountedWeth -= mmWethPayout;
            IERC20($.accountingAsset).safeTransfer(current.marketMaker, mmWethPayout);
        }
        current.fallbackWethRecovered = payout - mmWethPayout;
        current.mmWethPayout = mmWethPayout;
        current.lifecycle = ICoveredCallFundAdapter.Lifecycle.CashFallback;
        _closeActivePosition($, current);
        _validateTerminalLedger($, positionId, current);
        _checkpointPosition($, positionId, current);
        emit PositionTransitioned(
            positionId,
            current.protocolVaultId,
            current.lifecycle,
            current.fallbackWethRecovered,
            0,
            mmWethPayout,
            current.lifecycleHash
        );
    }

    function _closeActivePosition(
        CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $,
        ICoveredCallFundAdapter.Position storage current
    ) private {
        if ($.activePositionCount == 0 || $.activeCollateral < current.collateral) {
            revert LedgerMismatch(current.protocolVaultId);
        }
        --$.activePositionCount;
        $.activeCollateral -= current.collateral;
    }

    function _validateTerminalLedger(
        CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICoveredCallFundAdapter.Position storage current
    ) private view {
        AddressBook book = AddressBook($.addressBook);
        BatchSettler settler = BatchSettler(book.batchSettler());
        if (
            !Controller(book.controller()).vaultSettled(address(this), current.protocolVaultId)
                || settler.vaultOTokenBalance(address(this), current.protocolVaultId) != 0
                || settler.physicalDeliveryReservedVault(address(this), current.protocolVaultId)
        ) revert LedgerMismatch(positionId);
    }

    function _checkpointPosition(
        CoveredCallFundAdapterStorage.CoveredCallFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICoveredCallFundAdapter.Position storage current
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

    function _returnsAddress(address target, bytes4 selector, bytes memory args, address expected)
        private
        view
        returns (bool)
    {
        (bool success, bytes memory result) = target.staticcall(abi.encodePacked(selector, args));
        if (!success || result.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(result, 0x20))
        }
        return address(uint160(word)) == expected;
    }

    function _returnsNonzeroAddress(address target, bytes4 selector, bytes memory args) private view returns (bool) {
        (bool success, bytes memory result) = target.staticcall(abi.encodePacked(selector, args));
        if (!success || result.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(result, 0x20))
        }
        return address(uint160(word)) != address(0);
    }

    function _returnsBool(address target, bytes4 selector, bytes memory args) private view returns (bool) {
        (bool success, bytes memory result) = target.staticcall(abi.encodePacked(selector, args));
        if (!success || result.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(result, 0x20))
        }
        return word == 1;
    }

    function _returnsNonzeroWord(address target, bytes4 selector, bytes memory args) private view returns (bool) {
        (bool success, bytes memory result) = target.staticcall(abi.encodePacked(selector, args));
        if (!success || result.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(result, 0x20))
        }
        return word != 0;
    }
}
