// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Whitelist.sol";
import "../src/core/AddressBook.sol";
import "../src/core/OToken.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract OTokenFactoryTest is Test {
    AddressBook public addressBook;
    OTokenFactory public factory;
    Whitelist public whitelist;

    address public controller = address(0xC0DE);
    address public operator = address(0x0BE);
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
        addressBook.setOTokenFactory(address(factory));

        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()),
                    abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
                )
            )
        );
        addressBook.setWhitelist(address(whitelist));

        factory.setOperator(operator);

        // Set expiry to next day at 08:00 UTC
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }

    function test_createOTokenPut() public {
        vm.prank(operator);
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
        vm.prank(operator);
        address oToken = factory.createOToken(weth, usdc, weth, strikePrice, expiry, false);

        OToken token = OToken(oToken);
        assertFalse(token.isPut());
        assertEq(token.collateralAsset(), weth);
    }

    function test_createOTokenAutoWhitelists() public {
        vm.prank(operator);
        address oToken = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);

        assertTrue(whitelist.isWhitelistedOToken(oToken));
    }

    function test_cannotCreateDuplicate() public {
        vm.prank(operator);
        factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);

        vm.prank(operator);
        vm.expectRevert(OTokenFactory.OTokenAlreadyExists.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
    }

    function test_differentStrikeCreatesDifferentToken() public {
        vm.prank(operator);
        address oToken1 = factory.createOToken(weth, usdc, usdc, 2000e8, expiry, true);
        vm.prank(operator);
        address oToken2 = factory.createOToken(weth, usdc, usdc, 1900e8, expiry, true);

        assertTrue(oToken1 != oToken2);
        assertEq(factory.getOTokensLength(), 2);
    }

    function test_differentExpiryCreatesDifferentToken() public {
        vm.prank(operator);
        address oToken1 = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
        vm.prank(operator);
        address oToken2 = factory.createOToken(weth, usdc, usdc, strikePrice, expiry + 7 days, true);

        assertTrue(oToken1 != oToken2);
    }

    function test_putAndCallAreDifferentTokens() public {
        vm.prank(operator);
        address put = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
        vm.prank(operator);
        address call = factory.createOToken(weth, usdc, weth, strikePrice, expiry, false);

        assertTrue(put != call);
    }

    function test_revertExpiredExpiry() public {
        vm.warp(1700000000);
        uint256 pastExpiry = ((block.timestamp / 1 days) - 1) * 1 days + 8 hours;
        vm.prank(operator);
        vm.expectRevert(OTokenFactory.InvalidExpiry.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, pastExpiry, true);
    }

    function test_revertNon0800Expiry() public {
        uint256 badExpiry = expiry + 1 hours;
        vm.prank(operator);
        vm.expectRevert(OTokenFactory.InvalidExpiry.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, badExpiry, true);
    }

    function test_getTargetAddress() public {
        address predicted = factory.getTargetOTokenAddress(weth, usdc, usdc, strikePrice, expiry, true);
        vm.prank(operator);
        address actual = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);

        assertEq(predicted, actual);
    }

    function test_controllerMintOnCreatedToken() public {
        vm.prank(operator);
        address oTokenAddr = factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
        OToken token = OToken(oTokenAddr);

        vm.prank(controller);
        token.mintOtoken(address(0xBEEF), 1e8);
        assertEq(token.balanceOf(address(0xBEEF)), 1e8);
    }

    function test_onlyOperatorCanCreate() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(OTokenFactory.Unauthorized.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
    }

    function test_randomCannotCreate() public {
        vm.expectRevert(OTokenFactory.Unauthorized.selector);
        factory.createOToken(weth, usdc, usdc, strikePrice, expiry, true);
    }

    function test_setOperator() public {
        address newOp = address(0x1234);
        factory.setOperator(newOp);
        assertEq(factory.operator(), newOp);
    }

    function test_onlyOwnerCanSetOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(OTokenFactory.Unauthorized.selector);
        factory.setOperator(address(0x1234));
    }

    function test_cannotSetZeroOperator() public {
        vm.expectRevert(OTokenFactory.InvalidAddress.selector);
        factory.setOperator(address(0));
    }
}
