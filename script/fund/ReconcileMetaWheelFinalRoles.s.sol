// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice Read-only gate proving bootstrap authority is gone before later phases.
contract ReconcileMetaWheelFinalRoles is DeployMetaWheelBaseSepolia {
    function run() external view override returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = vm.readFile(vm.envString("B1N419_MANIFEST_PATH"));
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        deployed.vault = vm.parseJsonAddress(manifest, ".vault");
        deployed.strategy = vm.parseJsonAddress(manifest, ".strategy");
        deployed.coordinator = vm.parseJsonAddress(manifest, ".coordinator");
        _requireFinalRoles(FundAccessManager(deployed.accessManager), config.finalRoles);
        require(FundVault(deployed.vault).depositsPaused(), "B1N419: deposits open");
        require(FundVault(deployed.vault).redemptionsPaused(), "B1N419: redemptions open");
        require(
            StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator).interfaceVersion == 0,
            "B1N419: configured before rotation gate"
        );

        BatchSettler settler = BatchSettler(AddressBook(config.assets.addressBook).batchSettler());
        address[] memory cspAdapters = vm.parseJsonAddressArray(manifest, ".cspAdapters");
        address[] memory coveredCallAdapters = vm.parseJsonAddressArray(manifest, ".coveredCallAdapters");
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            require(!settler.authorizedPhysicalDeliveryVault(cspAdapters[i]), "B1N419: CSP onboarded before role gate");
            require(
                !settler.authorizedPhysicalDeliveryVault(coveredCallAdapters[i]),
                "B1N419: CC onboarded before role gate"
            );
        }
        _requireStandaloneBaseline(config.standalone);
    }
}
