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
import {ICspFundAdapter} from "../interfaces/ICspFundAdapter.sol";
import {CspFundAdapterStorage} from "../storage/CspFundAdapterStorage.sol";

/// @notice Linked execution module for bounded CSP asset conversions.
/// @dev Solidity library calls use DELEGATECALL, so accounting mutations remain in the adapter namespace.
library CspFundAdapterOperations {
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
        ICspFundAdapter.Lifecycle lifecycle,
        uint256 collateralDelta,
        uint256 payment,
        uint256 wethDelta,
        bytes32 lifecycleHash
    );
    event AssignedWethSwapped(uint256 wethIn, uint256 usdcOut);
    event UnaccountedAssetIsolated(address indexed asset, uint256 amount);

    error InvalidAmount();
    error InvalidLifecycle(uint256 positionId, ICspFundAdapter.Lifecycle lifecycle);
    error InvalidPosition(uint256 positionId);
    error LedgerMismatch(uint256 positionId);
    error SettlementNotReady(uint256 positionId);
    error SlippageExceeded(uint256 minimum, uint256 actual);

    function isOnboarded(CspFundAdapterStorage.CspFundAdapterStorageLayout storage $) public view returns (bool) {
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
                && !_returnsNonzeroWord(settlerAddress, ASSET_SWAP_FEE_TIER_SELECTOR, abi.encode($.weth))
        ) return false;
        if (!_returnsNonzeroAddress(oracleAddress, PRICE_FEED_SELECTOR, abi.encode($.weth))) return false;
        if (!_returnsBool(whitelistAddress, WHITELISTED_UNDERLYING_SELECTOR, abi.encode($.weth))) return false;
        if (!_returnsBool(whitelistAddress, WHITELISTED_COLLATERAL_SELECTOR, abi.encode($.accountingAsset))) {
            return false;
        }
        return _returnsBool(
            whitelistAddress,
            WHITELISTED_PRODUCT_SELECTOR,
            abi.encode($.weth, $.accountingAsset, $.accountingAsset, true)
        );
    }

    function settlePosition(CspFundAdapterStorage.CspFundAdapterStorageLayout storage $, uint256 positionId) public {
        ICspFundAdapter.Position storage current = $.positions[positionId];
        if (current.protocolVaultId == 0) revert InvalidPosition(positionId);
        if (current.lifecycle == ICspFundAdapter.Lifecycle.Open) {
            _prepareSettlement($, positionId, current);
            return;
        }
        if (current.lifecycle == ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery) {
            _completePhysicalOrFallback($, positionId, current);
            return;
        }
        revert InvalidLifecycle(positionId, current.lifecycle);
    }

    function checkpointPosition(
        CspFundAdapterStorage.CspFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICspFundAdapter.Position storage current
    ) public {
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

    function _prepareSettlement(
        CspFundAdapterStorage.CspFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICspFundAdapter.Position storage current
    ) private {
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
            current.lifecycle = ICspFundAdapter.Lifecycle.SettledOtm;
            _closeActivePosition($, current);
            _validateTerminalLedger($, positionId, current);
            checkpointPosition($, positionId, current);
            emit PositionTransitioned(
                positionId, current.protocolVaultId, current.lifecycle, collateralReturned, 0, 0, current.lifecycleHash
            );
            return;
        }

        settler.releasePhysicalDelivery(current.protocolVaultId);
        current.wethBalanceBeforeDelivery = IERC20($.weth).balanceOf(address(this));
        current.fallbackEligibleAt = uint64(block.timestamp + $.riskConfig.settlementDefaultDelay);
        current.lifecycle = ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery;
        checkpointPosition($, positionId, current);
        emit PositionTransitioned(
            positionId, current.protocolVaultId, current.lifecycle, collateralReturned, 0, 0, current.lifecycleHash
        );
    }

    function _completePhysicalOrFallback(
        CspFundAdapterStorage.CspFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICspFundAdapter.Position storage current
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
            current.lifecycle = ICspFundAdapter.Lifecycle.Assigned;
            _closeActivePosition($, current);
            checkpointPosition($, positionId, current);
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
        current.lifecycle = ICspFundAdapter.Lifecycle.CashFallback;
        _closeActivePosition($, current);
        _validateTerminalLedger($, positionId, current);
        checkpointPosition($, positionId, current);
        emit PositionTransitioned(
            positionId, current.protocolVaultId, current.lifecycle, payout, mmCashPayout, 0, current.lifecycleHash
        );
    }

    function _putCashPayouts(
        CspFundAdapterStorage.CspFundAdapterStorageLayout storage $,
        ICspFundAdapter.Position storage current
    ) private view returns (uint256 redemptionPayout, uint256 mmCashPayout) {
        OToken oToken = OToken(current.oToken);
        (uint256 expiryPrice, bool isSet) =
            Oracle(AddressBook($.addressBook).oracle()).getExpiryPrice($.weth, oToken.expiry());
        if (!isSet || expiryPrice >= oToken.strikePrice()) revert SettlementNotReady(current.protocolVaultId);
        redemptionPayout = Math.mulDiv(current.optionAmount, oToken.strikePrice(), 1e10);
        mmCashPayout = Math.mulDiv(current.optionAmount, oToken.strikePrice() - expiryPrice, 1e10);
    }

    function _validateTerminalLedger(
        CspFundAdapterStorage.CspFundAdapterStorageLayout storage $,
        uint256 positionId,
        ICspFundAdapter.Position storage current
    ) private view {
        AddressBook book = AddressBook($.addressBook);
        BatchSettler settler = BatchSettler(book.batchSettler());
        if (
            !Controller(book.controller()).vaultSettled(address(this), current.protocolVaultId)
                || settler.vaultOTokenBalance(address(this), current.protocolVaultId) != 0
                || settler.physicalDeliveryReservedVault(address(this), current.protocolVaultId)
        ) revert LedgerMismatch(positionId);
    }

    function _closeActivePosition(
        CspFundAdapterStorage.CspFundAdapterStorageLayout storage $,
        ICspFundAdapter.Position storage current
    ) private {
        if ($.activePositionCount == 0) {
            revert LedgerMismatch(current.protocolVaultId);
        }
        --$.activePositionCount;
        $.releasablePrincipal += current.collateral;
    }

    function swapAssignedWeth(
        CspFundAdapterStorage.CspFundAdapterStorageLayout storage $,
        uint256 minAccountingAssetsOut,
        ICspFundAdapter.DeallocateData memory deallocation
    ) public {
        uint256 wethAmount = deallocation.amount;
        if (
            wethAmount == 0 || wethAmount > $.accountedWeth || wethAmount > $.riskConfig.maxWethPerSwap
                || deallocation.minAmountOut < minAccountingAssetsOut
        ) revert InvalidAmount();

        uint256 spotPrice = Oracle(AddressBook($.addressBook).oracle()).getPrice($.weth);
        uint256 expectedUsdc = Math.mulDiv(wethAmount, spotPrice, 1e20);
        uint256 policyMinimum =
            Math.mulDiv(expectedUsdc, FundConstants.BPS - $.riskConfig.maxSwapSlippageBps, FundConstants.BPS);
        if (deallocation.minAmountOut < policyMinimum) {
            revert SlippageExceeded(policyMinimum, deallocation.minAmountOut);
        }

        IERC20 wethToken = IERC20($.weth);
        IERC20 usdc = IERC20($.accountingAsset);
        uint256 wethBefore = wethToken.balanceOf(address(this));
        uint256 usdcBefore = usdc.balanceOf(address(this));
        wethToken.forceApprove($.swapRouter, wethAmount);
        uint256 amountOut = ISwapRouter($.swapRouter)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: $.weth,
                    tokenOut: $.accountingAsset,
                    fee: $.swapFeeTier,
                    recipient: address(this),
                    amountIn: wethAmount,
                    amountOutMinimum: deallocation.minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
        wethToken.forceApprove($.swapRouter, 0);
        uint256 observedWeth = wethBefore - wethToken.balanceOf(address(this));
        uint256 observedUsdc = usdc.balanceOf(address(this)) - usdcBefore;
        if (observedWeth != wethAmount || observedUsdc != amountOut || amountOut < deallocation.minAmountOut) {
            revert SlippageExceeded(deallocation.minAmountOut, observedUsdc);
        }
        $.accountedWeth -= observedWeth;
        $.accountedUsdc += observedUsdc;
        uint64 nextNonce = ++$.stateNonce;
        $.positionsHash = keccak256(
            abi.encode(
                $.positionsHash, nextNonce, keccak256(abi.encode("SWAP_ASSIGNED_WETH", observedWeth, observedUsdc))
            )
        );
        emit AssignedWethSwapped(observedWeth, observedUsdc);
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
