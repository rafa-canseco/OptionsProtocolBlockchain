// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice BatchSettler-owner phase for the eight fresh child adapters.
/// @dev It changes only fresh-adapter authorization entries and rechecks the standalone proxy baseline.
contract OnboardMetaWheelChildrenBaseSepolia is DeployMetaWheelBaseSepolia {
    function run() external override returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = _loadBoundManifest(config);
        address[] memory cspLanes = vm.parseJsonAddressArray(manifest, ".cspLanes");
        address[] memory cspAdapters = vm.parseJsonAddressArray(manifest, ".cspAdapters");
        address[] memory coveredCallLanes = vm.parseJsonAddressArray(manifest, ".coveredCallLanes");
        address[] memory coveredCallAdapters = vm.parseJsonAddressArray(manifest, ".coveredCallAdapters");
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        deployed.strategy = vm.parseJsonAddress(manifest, ".strategy");
        deployed.coordinator = vm.parseJsonAddress(manifest, ".coordinator");
        _requireFinalRoles(FundAccessManager(deployed.accessManager), config.finalRoles);
        require(
            cspLanes.length == CSP_LANE_COUNT && cspAdapters.length == CSP_LANE_COUNT
                && coveredCallLanes.length == COVERED_CALL_LANE_COUNT
                && coveredCallAdapters.length == COVERED_CALL_LANE_COUNT,
            "B1N419: adapters"
        );
        FundTypes.StrategyConfig memory strategyConfig =
            StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator);
        require(strategyConfig.interfaceVersion == 1 && !strategyConfig.active, "B1N419: strategy phase order");
        require(
            WheelCoordinatorAdapter(deployed.coordinator).registeredLaneCount()
                == CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT,
            "B1N419: managed lane setup incomplete"
        );

        BatchSettler settler = BatchSettler(AddressBook(config.assets.addressBook).batchSettler());
        address owner = vm.envAddress("B1N419_BROADCASTER");
        require(owner == settler.owner(), "B1N419: settler owner");
        _requireStandaloneBaseline(config.standalone);
        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(deployed.coordinator);
        require(coordinator.allocationsPaused(), "B1N419: coordinator not paused for onboarding");
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            require(
                WheelCspChildLane(cspLanes[i]).adapter() == cspAdapters[i]
                    && WheelCspChildLane(cspLanes[i]).allocationsPaused(),
                "B1N419: CSP lane adapter"
            );
            require(
                WheelCoveredCallChildLane(coveredCallLanes[i]).adapter() == coveredCallAdapters[i]
                    && WheelCoveredCallChildLane(coveredCallLanes[i]).allocationsPaused(),
                "B1N419: CC lane adapter"
            );
            (address registeredCsp, WheelTypes.LaneKind cspKind, bool cspActive) = coordinator.registeredLaneAt(i);
            (address registeredCc, WheelTypes.LaneKind ccKind, bool ccActive) =
                coordinator.registeredLaneAt(CSP_LANE_COUNT + i);
            require(
                registeredCsp == cspLanes[i] && cspKind == WheelTypes.LaneKind.Csp && cspActive,
                "B1N419: CSP lane order"
            );
            require(
                registeredCc == coveredCallLanes[i] && ccKind == WheelTypes.LaneKind.CoveredCall && ccActive,
                "B1N419: CC lane order"
            );
            _requireFreshAdapter(config, cspAdapters[i]);
            _requireFreshAdapter(config, coveredCallAdapters[i]);
            for (uint256 j; j < i; ++j) {
                require(
                    cspAdapters[i] != cspAdapters[j] && cspAdapters[i] != coveredCallAdapters[j]
                        && coveredCallAdapters[i] != cspAdapters[j] && coveredCallAdapters[i] != coveredCallAdapters[j],
                    "B1N419: duplicate adapter"
                );
            }
            require(cspAdapters[i] != coveredCallAdapters[i], "B1N419: duplicate adapter");
        }

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

    function _requireFreshAdapter(DeployConfig memory config, address adapter) private view {
        require(
            adapter != address(0) && adapter.code.length != 0 && adapter != config.standalone.cspVaultProxy
                && adapter != config.standalone.cspAdapterProxy && adapter != config.standalone.coveredCallVaultProxy
                && adapter != config.standalone.coveredCallAdapterProxy
                && adapter != config.standalone.cspVaultImplementation
                && adapter != config.standalone.cspAdapterImplementation
                && adapter != config.standalone.coveredCallVaultImplementation
                && adapter != config.standalone.coveredCallAdapterImplementation,
            "B1N419: standalone adapter excluded"
        );
    }
}
