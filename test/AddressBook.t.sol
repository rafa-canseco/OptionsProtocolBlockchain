// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/AddressBook.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AddressBookTest is Test {
    AddressBook public addressBook;
    address public owner = address(this);
    address public notOwner = address(0xBEEF);

    function setUp() public {
        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (owner))))
        );
    }

    function test_ownerIsDeployer() public view {
        assertEq(addressBook.owner(), owner);
    }

    function test_setController() public {
        address controller = address(0x1);
        addressBook.setController(controller);
        assertEq(addressBook.controller(), controller);
    }

    function test_setMarginPool() public {
        address pool = address(0x2);
        addressBook.setMarginPool(pool);
        assertEq(addressBook.marginPool(), pool);
    }

    function test_setOTokenFactory() public {
        address factory = address(0x3);
        addressBook.setOTokenFactory(factory);
        assertEq(addressBook.oTokenFactory(), factory);
    }

    function test_setOracle() public {
        address oracle = address(0x4);
        addressBook.setOracle(oracle);
        assertEq(addressBook.oracle(), oracle);
    }

    function test_setWhitelist() public {
        address whitelist = address(0x5);
        addressBook.setWhitelist(whitelist);
        assertEq(addressBook.whitelist(), whitelist);
    }

    function test_setBatchSettler() public {
        address settler = address(0x6);
        addressBook.setBatchSettler(settler);
        assertEq(addressBook.batchSettler(), settler);
    }

    function test_revertNonOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(AddressBook.OnlyOwner.selector);
        addressBook.setController(address(0x1));
    }

    event ControllerUpdated(address indexed oldAddress, address indexed newAddress);

    function test_emitsEvent() public {
        address controller = address(0x1);
        vm.expectEmit(true, true, false, false);
        emit ControllerUpdated(address(0), controller);
        addressBook.setController(controller);
    }
}
