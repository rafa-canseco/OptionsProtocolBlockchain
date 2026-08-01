// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice BatchSettler-owner phase for the eight fresh child adapters.
/// @dev It changes only fresh-adapter authorization entries and rechecks the standalone proxy baseline.
contract OnboardMetaWheelChildrenBaseSepolia is DeployMetaWheelBaseSepolia {
    function run() external override returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = vm.readFile(vm.envString("B1N419_MANIFEST_PATH"));
        address[] memory cspAdapters = vm.parseJsonAddressArray(manifest, ".cspAdapters");
        address[] memory coveredCallAdapters = vm.parseJsonAddressArray(manifest, ".coveredCallAdapters");
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        _requireFinalRoles(FundAccessManager(deployed.accessManager), config.finalRoles);
        require(
            cspAdapters.length == CSP_LANE_COUNT && coveredCallAdapters.length == COVERED_CALL_LANE_COUNT,
            "B1N419: adapters"
        );

        BatchSettler settler = BatchSettler(AddressBook(config.assets.addressBook).batchSettler());
        address owner = vm.envAddress("B1N419_BROADCASTER");
        require(owner == settler.owner(), "B1N419: settler owner");
        _requireStandaloneBaseline(config.standalone);

        vm.startBroadcast(owner);
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            if (!settler.authorizedPhysicalDeliveryVault(cspAdapters[i])) {
                settler.setPhysicalDeliveryVault(cspAdapters[i], true);
            }
            if (!settler.authorizedPhysicalDeliveryVault(coveredCallAdapters[i])) {
                settler.setPhysicalDeliveryVault(coveredCallAdapters[i], true);
            }
        }
        vm.stopBroadcast();

        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            require(settler.authorizedPhysicalDeliveryVault(cspAdapters[i]), "B1N419: CSP onboarding");
            require(settler.authorizedPhysicalDeliveryVault(coveredCallAdapters[i]), "B1N419: CC onboarding");
        }
        _requireStandaloneBaseline(config.standalone);
    }
}
