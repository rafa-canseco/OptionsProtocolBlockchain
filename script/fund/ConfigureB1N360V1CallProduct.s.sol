// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {Whitelist} from "../../src/core/Whitelist.sol";
import {B1N360Base} from "./B1N360Base.sol";

abstract contract B1N360V1CallProductBase is B1N360Base {
    function _loadTargets() internal view returns (Whitelist whitelist, address weth, address usdc) {
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        _requireExpectedV1Baseline(addressBook_);
        AddressBook book = AddressBook(addressBook_);
        whitelist = Whitelist(book.whitelist());
        weth = _approvedAddress("FUND_ACCOUNTING_ASSET");
        usdc = _approvedAddress("FUND_USDC");
        require(IERC20Metadata(weth).decimals() == 18, "B1N360: WETH decimals");
        require(IERC20Metadata(usdc).decimals() == 6, "B1N360: USDC decimals");
        require(Oracle(book.oracle()).priceFeed(weth).code.length != 0, "B1N360: WETH feed");
        require(whitelist.isWhitelistedUnderlying(weth), "B1N360: WETH underlying");
    }
}

/// @notice Prints the exact two idempotent V1 configuration calls required by the covered-call product.
contract PrepareB1N360V1CallProduct is B1N360V1CallProductBase {
    function run() external view {
        _requireBaseSepolia();
        (Whitelist whitelist, address weth, address usdc) = _loadTargets();
        bool collateralReady = whitelist.isWhitelistedCollateral(weth);
        bool productReady = whitelist.isProductWhitelisted(weth, usdc, weth, false);
        console2.log("V1_WHITELIST_OWNER", whitelist.owner());
        console2.log("WETH_COLLATERAL_READY", collateralReady);
        console2.log("COVERED_CALL_PRODUCT_READY", productReady);
        if (!collateralReady) {
            console2.log("WHITELIST_COLLATERAL_CALLDATA");
            console2.logBytes(abi.encodeCall(whitelist.whitelistCollateral, (weth)));
        }
        if (!productReady) {
            console2.log("WHITELIST_PRODUCT_CALLDATA");
            console2.logBytes(abi.encodeCall(whitelist.whitelistProduct, (weth, usdc, weth, false)));
        }
    }
}

/// @notice Adds only the WETH-collateral and WETH/USDC call product entries; no V1 proxy is upgraded.
contract ConfigureB1N360V1CallProduct is B1N360V1CallProductBase {
    function run() external {
        _requireBaseSepolia();
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        (Whitelist whitelist, address weth, address usdc) = _loadTargets();
        address implementationBefore = _implementationOf(address(whitelist));
        uint256 broadcasterKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(broadcasterKey) == whitelist.owner(), "B1N360: whitelist owner key");

        bool collateralReady = whitelist.isWhitelistedCollateral(weth);
        bool productReady = whitelist.isProductWhitelisted(weth, usdc, weth, false);
        if (!collateralReady || !productReady) {
            vm.startBroadcast(broadcasterKey);
            if (!collateralReady) whitelist.whitelistCollateral(weth);
            if (!productReady) whitelist.whitelistProduct(weth, usdc, weth, false);
            vm.stopBroadcast();
        }

        require(_implementationOf(address(whitelist)) == implementationBefore, "B1N360: whitelist impl changed");
        _validateV1(addressBook_, weth, usdc);
        _requireExpectedV1Baseline(addressBook_);
        console2.log("WETH_COLLATERAL_READY", true);
        console2.log("COVERED_CALL_PRODUCT_READY", true);
    }
}
