// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressBook} from "../../core/AddressBook.sol";
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

    event AssignedWethSwapped(uint256 wethIn, uint256 usdcOut);

    error InvalidAmount();
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
