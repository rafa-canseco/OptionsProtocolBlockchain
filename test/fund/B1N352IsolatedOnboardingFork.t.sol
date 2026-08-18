// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";

/// @notice Rehearses Fund adapter onboarding on the isolated B1N-336 Base Sepolia core stack.
contract B1N352IsolatedOnboardingForkTest is Test {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant BASELINE_BLOCK = 44_454_953;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private constant OWNER = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant ADDRESS_BOOK = 0x033d9d37Baf83dBc71935239b6fA22a6905dbaa0;
    address private constant CONTROLLER_PROXY = 0xD52EFbBaA1b02BA65A7f0A1604A5dFb4C4dB1572;
    address private constant SETTLER_PROXY = 0xb94D6270B336dca566C2077d50c2C50F06398cB8;
    address private constant SETTLER_IMPLEMENTATION = 0x040219e594de2862D1480a6A3c1d45c5c032aCE6;
    bytes32 private constant SETTLER_IMPLEMENTATION_CODEHASH =
        0x5614f407be81f95e601647ed2777d2762ff5e26d64a329b525d7fab9f21c207d;
    address private constant ADAPTER = address(0xB1A352);

    function test_ownerOnboardsWithoutChangingPinnedCoreState() public {
        if (!_isPinnedFork()) return;
        BatchSettler settler = BatchSettler(SETTLER_PROXY);
        assertTrue(Controller(CONTROLLER_PROXY).custodiedRedemptionOnly());
        assertEq(AddressBook(ADDRESS_BOOK).batchSettler(), SETTLER_PROXY);
        assertEq(_implementationOf(SETTLER_PROXY), SETTLER_IMPLEMENTATION);
        assertEq(SETTLER_IMPLEMENTATION.codehash, SETTLER_IMPLEMENTATION_CODEHASH);
        assertEq(settler.owner(), OWNER);
        assertEq(settler.pendingOwner(), address(0));
        assertFalse(settler.authorizedPhysicalDeliveryVault(ADAPTER));

        vm.prank(OWNER);
        settler.setPhysicalDeliveryVault(ADAPTER, true);

        assertTrue(settler.authorizedPhysicalDeliveryVault(ADAPTER));
        assertEq(_implementationOf(SETTLER_PROXY), SETTLER_IMPLEMENTATION);
        assertEq(settler.owner(), OWNER);
        assertEq(settler.pendingOwner(), address(0));
    }

    function test_nonOwnerCannotOnboard() public {
        if (!_isPinnedFork()) return;
        vm.prank(address(0xBAD));
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        BatchSettler(SETTLER_PROXY).setPhysicalDeliveryVault(ADAPTER, true);
    }

    function _isPinnedFork() private view returns (bool) {
        return block.chainid == BASE_SEPOLIA_CHAIN_ID && block.number == BASELINE_BLOCK;
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
