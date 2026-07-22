// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {Controller} from "../../src/core/Controller.sol";

/// @notice Rehearses the approved Controller upgrade and rollback at the pinned Base Sepolia baseline block.
/// @dev Run with:
/// forge test --match-contract B1N352ControllerUpgradeForkTest \
///   --fork-url $BASE_SEPOLIA_RPC_URL --fork-block-number 44454953 -vv
contract B1N352ControllerUpgradeForkTest is Test {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant BASELINE_BLOCK = 44_454_953;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private constant CONTROLLER_PROXY = 0xB64a532B71E711B5F45B906D9Fc09c184EC54CA0;
    address private constant PREVIOUS_IMPLEMENTATION = 0x147fb733DCE6686E4E39AA55C0B87D22c90E3a2F;
    bytes32 private constant PREVIOUS_IMPLEMENTATION_CODEHASH =
        0xd899acfd13155fe5395f3de05ba14c89d182dffe8b87ba531612deba69614d20;
    address private constant CANDIDATE_IMPLEMENTATION = 0x5cfB9ca0437D4a5b3735bba0d9E2490a05F532bc;
    bytes32 private constant CANDIDATE_IMPLEMENTATION_CODEHASH =
        0xd112e28c04dac654210602e73e2278e9f6ec8b847ac7f0cdac251787f51f42bf;
    address private constant OWNER = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant ADDRESS_BOOK = 0x9e8cd9a79d667f4154e123604bF62d35a3d9673C;

    struct Snapshot {
        address owner;
        address pendingOwner;
        address addressBook;
        address partialPauser;
        bool systemPartiallyPaused;
        bool systemFullyPaused;
    }

    function test_upgradeAndAtomicCustodialInitializationPreserveState() public {
        if (!_isPinnedFork()) return;
        Controller controller = Controller(CONTROLLER_PROXY);
        Snapshot memory beforeSnapshot = _snapshot(controller);
        _requireLegacyBaseline(controller, beforeSnapshot);

        vm.prank(OWNER);
        controller.upgradeToAndCall(
            CANDIDATE_IMPLEMENTATION, abi.encodeCall(Controller.setCustodiedRedemptionOnly, (true))
        );

        assertEq(_implementationOf(CONTROLLER_PROXY), CANDIDATE_IMPLEMENTATION);
        assertTrue(controller.custodiedRedemptionOnly());
        _assertSnapshot(_snapshot(controller), beforeSnapshot);
        assertEq(AddressBook(ADDRESS_BOOK).controller(), CONTROLLER_PROXY);
    }

    function test_nonOwnerCannotUpgrade() public {
        if (!_isPinnedFork()) return;
        vm.prank(address(0xBAD));
        vm.expectRevert(Controller.OnlyOwner.selector);
        Controller(CONTROLLER_PROXY)
            .upgradeToAndCall(CANDIDATE_IMPLEMENTATION, abi.encodeCall(Controller.setCustodiedRedemptionOnly, (true)));
    }

    function test_rollbackRestoresImplementationAndPreservesState() public {
        if (!_isPinnedFork()) return;
        Controller controller = Controller(CONTROLLER_PROXY);
        Snapshot memory beforeSnapshot = _snapshot(controller);
        _requireLegacyBaseline(controller, beforeSnapshot);

        vm.startPrank(OWNER);
        controller.upgradeToAndCall(
            CANDIDATE_IMPLEMENTATION, abi.encodeCall(Controller.setCustodiedRedemptionOnly, (true))
        );
        controller.upgradeToAndCall(PREVIOUS_IMPLEMENTATION, "");
        vm.stopPrank();

        assertEq(_implementationOf(CONTROLLER_PROXY), PREVIOUS_IMPLEMENTATION);
        (bool success,) = CONTROLLER_PROXY.staticcall(abi.encodeWithSignature("custodiedRedemptionOnly()"));
        assertFalse(success);
        _assertSnapshot(_snapshot(controller), beforeSnapshot);
        assertEq(AddressBook(ADDRESS_BOOK).controller(), CONTROLLER_PROXY);
    }

    function _isPinnedFork() private view returns (bool) {
        return block.chainid == BASE_SEPOLIA_CHAIN_ID && block.number == BASELINE_BLOCK;
    }

    function _requireLegacyBaseline(Controller controller, Snapshot memory snapshot) private view {
        assertEq(_implementationOf(CONTROLLER_PROXY), PREVIOUS_IMPLEMENTATION);
        assertEq(PREVIOUS_IMPLEMENTATION.codehash, PREVIOUS_IMPLEMENTATION_CODEHASH);
        assertEq(CANDIDATE_IMPLEMENTATION.codehash, CANDIDATE_IMPLEMENTATION_CODEHASH);
        assertEq(snapshot.owner, OWNER);
        assertEq(snapshot.pendingOwner, address(0));
        assertEq(snapshot.addressBook, ADDRESS_BOOK);
        assertEq(snapshot.partialPauser, OWNER);
        assertFalse(snapshot.systemPartiallyPaused);
        assertFalse(snapshot.systemFullyPaused);
        assertEq(AddressBook(ADDRESS_BOOK).controller(), CONTROLLER_PROXY);

        (bool success,) = address(controller).staticcall(abi.encodeWithSignature("custodiedRedemptionOnly()"));
        assertFalse(success);
    }

    function _snapshot(Controller controller) private view returns (Snapshot memory snapshot) {
        snapshot = Snapshot({
            owner: controller.owner(),
            pendingOwner: controller.pendingOwner(),
            addressBook: address(controller.addressBook()),
            partialPauser: controller.partialPauser(),
            systemPartiallyPaused: controller.systemPartiallyPaused(),
            systemFullyPaused: controller.systemFullyPaused()
        });
    }

    function _assertSnapshot(Snapshot memory actual, Snapshot memory expected) private pure {
        assertEq(actual.owner, expected.owner);
        assertEq(actual.pendingOwner, expected.pendingOwner);
        assertEq(actual.addressBook, expected.addressBook);
        assertEq(actual.partialPauser, expected.partialPauser);
        assertEq(actual.systemPartiallyPaused, expected.systemPartiallyPaused);
        assertEq(actual.systemFullyPaused, expected.systemFullyPaused);
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
