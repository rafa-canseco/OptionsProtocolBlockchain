// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/AddressBook.sol";
import "../src/core/OToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract OTokenFactoryTest is Test {
    AddressBook public addressBook;
    OTokenFactory public factory;

    address public controller = address(0xC0DE);
    address public weth = address(0x1111);
    address public usdc = address(0x2222);
    uint256 public strikePrice = 2000e8;
    // A valid 08:00 UTC timestamp in the future
    uint256 public expiry;

    function setUp() public {
        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );
        addressBook.setController(controller);

        factory = OTokenFactory(
            address(
                new ERC1967Proxy(
                    address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
                )
            )
        );

        // Set expiry to next day at 08:00 UTC
        // Round up to next 08:00 UTC
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }

    function test_createOTokenPut() public {
        address oToken = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);

        assertTrue(oToken != address(0));
        assertTrue(factory.isOToken(oToken));
        assertEq(factory.getOTokensLength(), 1);
        assertEq(factory.oTokens(0), oToken);

        OToken token = OToken(oToken);
        assertEq(token.underlying(), weth);
        assertEq(token.strikeAsset(), usdc);
        assertEq(token.collateralAsset(), usdc);
        assertEq(token.strikePrice(), strikePrice);
        assertEq(token.expiry(), expiry);
        assertTrue(token.isPut());
        assertEq(token.controller(), controller);
    }

    function test_createOTokenCall() public {
        address oToken = factory.createOToken(weth, usdc, weth, strikePrice, expiry, false);

        OToken token = OToken(oToken);
        assertFalse(token.isPut());
        assertEq(token.collateralAsset(), weth);
    }

    function test_cannotCreateDuplicate() public {
        factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);

        vm.expectRevert(OTokenFactory.OTokenAlreadyExists.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
    }

    function test_differentStrikeCreatesDifferentToken() public {
        address oToken1 = factory.createOToken(weth, usdc, usdc, 2000e8, expiry, true);
        address oToken2 = factory.createOToken(weth, usdc, usdc, 1900e8, expiry, true);

        assertTrue(oToken1 != oToken2);
        assertEq(factory.getOTokensLength(), 2);
    }

    function test_differentExpiryCreatesDifferentToken() public {
        address oToken1 = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
        address oToken2 = factory.createOToken(weth, usdc, usdc, strikePrice, expiry + 7 days, true);

        assertTrue(oToken1 != oToken2);
    }

    function test_putAndCallAreDifferentTokens() public {
        address put = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
        address call = factory.createOToken(weth, usdc, weth, strikePrice, expiry, false);

        assertTrue(put != call);
    }

    function test_revertExpiredExpiry() public {
        // Warp to a realistic timestamp first
        vm.warp(1700000000);
        // Use an expiry that's in the past but still valid 08:00 UTC format
        uint256 pastExpiry = ((block.timestamp / 1 days) - 1) * 1 days + 8 hours;
        vm.expectRevert(OTokenFactory.InvalidExpiry.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, pastExpiry, true);
    }

    function test_revertNon0800Expiry() public {
        // Use a timestamp that's not at 08:00 UTC
        uint256 badExpiry = expiry + 1 hours;
        vm.expectRevert(OTokenFactory.InvalidExpiry.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, badExpiry, true);
    }

    function test_getTargetAddress() public {
        address predicted = factory.getTargetOTokenAddress(weth, usdc, usdc, strikePrice, expiry, true);
        address actual = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);

        assertEq(predicted, actual);
    }

    function test_controllerMintOnCreatedToken() public {
        address oTokenAddr = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
        OToken token = OToken(oTokenAddr);

        vm.prank(controller);
        token.mintOtoken(address(0xBEEF), 1e8);
        assertEq(token.balanceOf(address(0xBEEF)), 1e8);
    }
}
