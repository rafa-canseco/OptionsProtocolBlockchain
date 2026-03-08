// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Whitelist.sol";
import "../src/core/AddressBook.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract WhitelistTest is Test {
    AddressBook public addressBook;
    Whitelist public whitelist;

    address public weth = address(0x1111);
    address public usdc = address(0x2222);
    address public factory = address(0xFAC0);

    function setUp() public {
        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );
        addressBook.setOTokenFactory(factory);

        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()),
                    abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
                )
            )
        );
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

    function test_factoryCanWhitelistOToken() public {
        address oToken = address(0xAAAA);
        vm.prank(factory);
        whitelist.whitelistOToken(oToken);
        assertTrue(whitelist.isWhitelistedOToken(oToken));
    }

    function test_randomCannotWhitelistOToken() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Whitelist.OnlyOwnerOrFactory.selector);
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
