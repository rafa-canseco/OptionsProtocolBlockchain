// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/OToken.sol";

contract OTokenTest is Test {
    OToken public oToken;

    address public weth = address(0x1111);
    address public usdc = address(0x2222);
    uint256 public strikePrice = 2000e8; // $2000 in 8 decimals
    uint256 public expiry = 1740124800; // some future 08:00 UTC timestamp
    address public controller = address(0xC0DE);

    function setUp() public {
        oToken = new OToken();
        oToken.init(weth, usdc, usdc, strikePrice, expiry, true, controller);
    }

    function test_initSetsParams() public view {
        assertEq(oToken.underlying(), weth);
        assertEq(oToken.strikeAsset(), usdc);
        assertEq(oToken.collateralAsset(), usdc);
        assertEq(oToken.strikePrice(), strikePrice);
        assertEq(oToken.expiry(), expiry);
        assertTrue(oToken.isPut());
        assertEq(oToken.controller(), controller);
    }

    function test_decimalsIs8() public view {
        assertEq(oToken.decimals(), 8);
    }

    function test_cannotInitTwice() public {
        vm.expectRevert(OToken.AlreadyInitialized.selector);
        oToken.init(weth, usdc, usdc, strikePrice, expiry, true, controller);
    }

    function test_controllerCanMint() public {
        vm.prank(controller);
        oToken.mintOtoken(address(0xBEEF), 100e8);
        assertEq(oToken.balanceOf(address(0xBEEF)), 100e8);
    }

    function test_controllerCanBurn() public {
        vm.prank(controller);
        oToken.mintOtoken(address(0xBEEF), 100e8);

        vm.prank(controller);
        oToken.burnOtoken(address(0xBEEF), 40e8);
        assertEq(oToken.balanceOf(address(0xBEEF)), 60e8);
    }

    function test_nonControllerCannotMint() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(OToken.OnlyController.selector);
        oToken.mintOtoken(address(0xBEEF), 100e8);
    }

    function test_nonControllerCannotBurn() public {
        vm.prank(controller);
        oToken.mintOtoken(address(0xBEEF), 100e8);

        vm.prank(address(0xBEEF));
        vm.expectRevert(OToken.OnlyController.selector);
        oToken.burnOtoken(address(0xBEEF), 50e8);
    }

    function test_transferWorks() public {
        vm.prank(controller);
        oToken.mintOtoken(address(0xBEEF), 100e8);

        vm.prank(address(0xBEEF));
        oToken.transfer(address(0xCAFE), 30e8);

        assertEq(oToken.balanceOf(address(0xBEEF)), 70e8);
        assertEq(oToken.balanceOf(address(0xCAFE)), 30e8);
    }

    function test_totalSupplyTracked() public {
        vm.prank(controller);
        oToken.mintOtoken(address(0xBEEF), 100e8);
        assertEq(oToken.totalSupply(), 100e8);

        vm.prank(controller);
        oToken.burnOtoken(address(0xBEEF), 25e8);
        assertEq(oToken.totalSupply(), 75e8);
    }

    function test_initAsCall() public {
        OToken callToken = new OToken();
        callToken.init(weth, usdc, weth, strikePrice, expiry, false, controller);
        assertFalse(callToken.isPut());
        assertEq(callToken.collateralAsset(), weth);
    }

    function test_nameAndSymbolSetAfterInit() public view {
        assertEq(oToken.name(), "oToken 2000 Put");
        assertEq(oToken.symbol(), "o2000P");
    }

    function test_callNameAndSymbol() public {
        OToken callToken = new OToken();
        callToken.init(weth, usdc, weth, strikePrice, expiry, false, controller);
        assertEq(callToken.name(), "oToken 2000 Call");
        assertEq(callToken.symbol(), "o2000C");
    }

    function test_nameEmptyBeforeInit() public {
        OToken freshToken = new OToken();
        assertEq(freshToken.name(), "");
        assertEq(freshToken.symbol(), "");
    }

    function test_nonCreatorCannotInit() public {
        OToken freshToken = new OToken();

        vm.prank(address(0xBEEF));
        vm.expectRevert(OToken.OnlyCreator.selector);
        freshToken.init(weth, usdc, usdc, strikePrice, expiry, true, controller);
    }
}
