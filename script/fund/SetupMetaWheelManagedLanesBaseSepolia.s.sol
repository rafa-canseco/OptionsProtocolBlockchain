// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice Post-configuration lane bootstrap through StrategyManager's classified managed-operation wrappers.
/// @dev Run registerLanes() as final curator, then pauseCoordinator() as final guardian. No activation occurs.
contract SetupMetaWheelManagedLanesBaseSepolia is DeployMetaWheelBaseSepolia {
    error UseExplicitManagedLaneSetupEntryPoint();

    function run() external pure override returns (DeploymentAddresses memory) {
        revert UseExplicitManagedLaneSetupEntryPoint();
    }

    function registerLanes() external returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = _loadBoundManifest(config);
        deployed = _loadManagedSetupAddresses(manifest);
        uint256 registeredBefore = WheelCoordinatorAdapter(deployed.coordinator).registeredLaneCount();
        require(registeredBefore <= CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT, "B1N419: excess registered lanes");
        _requireManagedSetupPrerequisites(config, deployed, registeredBefore, false);

        address curator = vm.envAddress("B1N419_BROADCASTER");
        require(curator == config.finalRoles.curator, "B1N419: curator broadcaster");
        StrategyManager strategy = StrategyManager(deployed.strategy);
        uint64 beforePositionNonce = strategy.positionNonce(deployed.coordinator);

        vm.startBroadcast(curator);
        for (uint256 i = registeredBefore; i < CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT; ++i) {
            bool isCsp = i < CSP_LANE_COUNT;
            uint256 laneIndex = isCsp ? i : i - CSP_LANE_COUNT;
            address lane = isCsp ? deployed.cspLanes[laneIndex] : deployed.coveredCallLanes[laneIndex];
            WheelTypes.LaneKind kind = isCsp ? WheelTypes.LaneKind.Csp : WheelTypes.LaneKind.CoveredCall;
            strategy.executeAdapterConfigurationOperation(
                deployed.coordinator, _managedData(WheelTypes.ManagedOperation.RegisterLane, abi.encode(lane, kind))
            );
        }
        vm.stopBroadcast();

        _requireManagedSetupPrerequisites(config, deployed, CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT, false);
        require(
            strategy.positionNonce(deployed.coordinator)
                == beforePositionNonce + uint64(CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT - registeredBefore),
            "B1N419: managed registration nonce"
        );
    }

    function pauseCoordinator() external returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = _loadBoundManifest(config);
        deployed = _loadManagedSetupAddresses(manifest);
        _requireManagedSetupPrerequisites(config, deployed, CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT, false);

        address guardian = vm.envAddress("B1N419_BROADCASTER");
        require(guardian == config.finalRoles.guardian, "B1N419: guardian broadcaster");
        StrategyManager strategy = StrategyManager(deployed.strategy);
        uint64 beforePositionNonce = strategy.positionNonce(deployed.coordinator);
        uint64 beforeCoordinatorNonce = WheelCoordinatorAdapter(deployed.coordinator).summary().stateNonce;
        vm.startBroadcast(guardian);
        strategy.executeAdapterGuardianOperation(
            deployed.coordinator, _managedData(WheelTypes.ManagedOperation.PauseAllocations, "")
        );
        vm.stopBroadcast();

        _requireManagedSetupPrerequisites(config, deployed, CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT, true);
        require(strategy.positionNonce(deployed.coordinator) == beforePositionNonce + 1, "B1N419: managed pause nonce");
        require(
            WheelCoordinatorAdapter(deployed.coordinator).summary().stateNonce == beforeCoordinatorNonce,
            "B1N419: coordinator pause changed position state"
        );
    }

    function reconcileManagedSetup() external returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = _loadBoundManifest(config);
        deployed = _loadManagedSetupAddresses(manifest);
        _requireManagedSetupPrerequisites(config, deployed, CSP_LANE_COUNT + COVERED_CALL_LANE_COUNT, true);
    }

    function _loadManagedSetupAddresses(string memory manifest)
        private
        view
        returns (DeploymentAddresses memory deployed)
    {
        deployed.vault = vm.parseJsonAddress(manifest, ".vault");
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        deployed.strategy = vm.parseJsonAddress(manifest, ".strategy");
        deployed.coordinator = vm.parseJsonAddress(manifest, ".coordinator");
        deployed.metaWheelValuator = vm.parseJsonAddress(manifest, ".metaWheelValuator");
        deployed.cspLanes = _fixed(vm.parseJsonAddressArray(manifest, ".cspLanes"));
        deployed.cspAdapters = _fixed(vm.parseJsonAddressArray(manifest, ".cspAdapters"));
        deployed.coveredCallLanes = _fixed(vm.parseJsonAddressArray(manifest, ".coveredCallLanes"));
        deployed.coveredCallAdapters = _fixed(vm.parseJsonAddressArray(manifest, ".coveredCallAdapters"));
    }

    function _requireManagedSetupPrerequisites(
        DeployConfig memory config,
        DeploymentAddresses memory deployed,
        uint256 expectedLaneCount,
        bool expectCoordinatorPaused
    ) private view {
        _requireFinalRoles(FundAccessManager(deployed.accessManager), config.finalRoles);
        require(FundVault(deployed.vault).depositsPaused(), "B1N419: deposits open");
        require(FundVault(deployed.vault).redemptionsPaused(), "B1N419: redemptions open");
        FundTypes.StrategyConfig memory strategyConfig =
            StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator);
        require(strategyConfig.interfaceVersion == 1, "B1N419: coordinator not configured");
        require(!strategyConfig.active, "B1N419: coordinator active");
        require(strategyConfig.valuator == deployed.metaWheelValuator, "B1N419: coordinator valuator");

        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(deployed.coordinator);
        require(coordinator.registeredLaneCount() == expectedLaneCount, "B1N419: unexpected lane count");
        require(coordinator.allocationsPaused() == expectCoordinatorPaused, "B1N419: coordinator managed pause state");
        for (uint256 i; i < expectedLaneCount; ++i) {
            (address lane, WheelTypes.LaneKind kind, bool active) = coordinator.registeredLaneAt(i);
            if (i < CSP_LANE_COUNT) {
                require(
                    lane == deployed.cspLanes[i] && kind == WheelTypes.LaneKind.Csp && active, "B1N419: CSP lane setup"
                );
            } else {
                uint256 laneIndex = i - CSP_LANE_COUNT;
                require(
                    lane == deployed.coveredCallLanes[laneIndex] && kind == WheelTypes.LaneKind.CoveredCall && active,
                    "B1N419: CC lane setup"
                );
            }
        }

        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            require(
                WheelCspChildLane(deployed.cspLanes[i]).allocationsPaused(), "B1N419: CSP child unexpectedly resumed"
            );
            require(
                WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).allocationsPaused(),
                "B1N419: CC child unexpectedly resumed"
            );
        }

        BatchSettler settler = BatchSettler(config.assets.batchSettler);
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            require(!settler.authorizedPhysicalDeliveryVault(deployed.cspAdapters[i]), "B1N419: CSP onboarded early");
            require(
                !settler.authorizedPhysicalDeliveryVault(deployed.coveredCallAdapters[i]), "B1N419: CC onboarded early"
            );
        }
        _requireStandaloneBaseline(config.standalone);
    }

    function _managedData(WheelTypes.ManagedOperation operation, bytes memory arguments)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(operation, arguments);
    }

    function _fixed(address[] memory values) private pure returns (address[4] memory fixedValues) {
        require(values.length == 4, "B1N419: four lanes required");
        for (uint256 i; i < values.length; ++i) {
            fixedValues[i] = values[i];
        }
    }
}
