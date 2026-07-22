// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ControllerStorageHarnessV1, ControllerStorageHarnessV2} from "./harness/ControllerUpgradeStorageHarnesses.sol";

contract ControllerUpgradeStorageSpecTest is Test {
    string private constant HARNESS_PATH = "test/fund/harness/ControllerUpgradeStorageHarnesses.sol:";

    function test_controllerCustodialFlagIsStorageCompatible() public {
        Options memory options;
        options.referenceContract = string.concat(HARNESS_PATH, "ControllerStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "ControllerStorageHarnessV2"), options);
    }

    function test_upgradePreservesPackedAndMappedState() public {
        address proxy = Upgrades.deployUUPSProxy(
            string.concat(HARNESS_PATH, "ControllerStorageHarnessV1"),
            abi.encodeWithSignature("initialize(address)", address(this))
        );
        ControllerStorageHarnessV1 legacy = ControllerStorageHarnessV1(proxy);
        address book = address(0xB00C);
        address pauser = address(0xA115E);
        address pendingOwner = address(0x0A11);
        address vaultOwner = address(0xA11CE);
        legacy.setBaselineState(book, pauser, pendingOwner, vaultOwner, 7, true, false);

        Options memory options;
        options.referenceContract = string.concat(HARNESS_PATH, "ControllerStorageHarnessV1");
        Upgrades.upgradeProxy(proxy, string.concat(HARNESS_PATH, "ControllerStorageHarnessV2"), bytes(""), options);

        ControllerStorageHarnessV2 upgraded = ControllerStorageHarnessV2(proxy);
        assertEq(address(upgraded.addressBook()), book);
        assertEq(upgraded.owner(), address(this));
        assertEq(upgraded.partialPauser(), pauser);
        assertEq(upgraded.pendingOwner(), pendingOwner);
        assertEq(upgraded.vaultCount(vaultOwner), 7);
        assertTrue(upgraded.systemPartiallyPaused());
        assertFalse(upgraded.systemFullyPaused());
        assertFalse(upgraded.custodiedRedemptionOnly());

        upgraded.setCustodiedRedemptionOnly(true);
        assertTrue(upgraded.custodiedRedemptionOnly());
        assertEq(upgraded.pendingOwner(), pendingOwner);
    }
}
