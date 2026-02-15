// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/core/Whitelist.sol";
import "../src/core/AddressBook.sol";

contract WhitelistTest is Test {
    AddressBook public addressBook;
    Whitelist public whitelist;

    address public weth = address(0x1111);
    address public usdc = address(0x2222);
    address public factory = address(0xFAC0);

    function setUp() public {
        addressBook = new AddressBook();
        addressBook.setOTokenFactory(factory);
        whitelist = new Whitelist(address(addressBook));
    }

    function test_whitelistCollateral() public {
        assertFalse(whitelist.isWhitelistedCollateral(usdc));
        whitelist.whitelistCollateral(usdc);
        assertTrue(whitelist.isWhitelistedCollateral(usdc));
    }

    function test_whitelistUnderlying() public {
        assertFalse(whitelist.isWhitelistedUnderlying(weth));
        whitelist.whitelistUnderlying(weth);
        assertTrue(whitelist.isWhitelistedUnderlying(weth));
    }

    function test_whitelistProduct() public {
        // CSP: underlying=WETH, strike=USDC, collateral=USDC, isPut=true
        whitelist.whitelistProduct(weth, usdc, usdc, true);
        assertTrue(whitelist.isProductWhitelisted(weth, usdc, usdc, true));
    }

    function test_productNotWhitelistedByDefault() public view {
        assertFalse(whitelist.isProductWhitelisted(weth, usdc, usdc, true));
    }

    function test_differentProductsAreIndependent() public {
        // Whitelist CSP but not CC
        whitelist.whitelistProduct(weth, usdc, usdc, true);

        assertTrue(whitelist.isProductWhitelisted(weth, usdc, usdc, true));
        assertFalse(whitelist.isProductWhitelisted(weth, usdc, weth, false));
    }

    function test_ownerCanWhitelistOToken() public {
        address oToken = address(0xAAAA);
        whitelist.whitelistOToken(oToken);
        assertTrue(whitelist.isWhitelistedOToken(oToken));
    }

    function test_factoryCannotWhitelistOToken() public {
        vm.prank(factory);
        vm.expectRevert(Whitelist.OnlyOwner.selector);
        whitelist.whitelistOToken(address(0xAAAA));
    }

    function test_randomCannotWhitelistOToken() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Whitelist.OnlyOwner.selector);
        whitelist.whitelistOToken(address(0xAAAA));
    }

    function test_onlyOwnerCanWhitelistCollateral() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Whitelist.OnlyOwner.selector);
        whitelist.whitelistCollateral(usdc);
    }

    function test_onlyOwnerCanWhitelistProduct() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Whitelist.OnlyOwner.selector);
        whitelist.whitelistProduct(weth, usdc, usdc, true);
    }
}
