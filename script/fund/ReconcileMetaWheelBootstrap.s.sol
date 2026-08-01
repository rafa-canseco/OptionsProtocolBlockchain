// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice Read-only reconciliation for the paused, unconfigured bootstrap phase.
contract ReconcileMetaWheelBootstrap is DeployMetaWheelBaseSepolia {
    function run() external view override returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = vm.readFile(vm.envString("B1N419_MANIFEST_PATH"));
        deployed = _deploymentFromManifest(manifest);
        _reconcileBootstrap(config, deployed);
        _reconcileImplementations(deployed);
        _reconcileCodehashes(manifest, deployed);
        _reconcileRoles(FundAccessManager(deployed.accessManager), config.fund.roles);
        _reconcileLanes(deployed);
        _reconcileFees(deployed.accounting, config.fund.feeRecipient);
    }

    function _deploymentFromManifest(string memory manifest)
        private
        pure
        returns (DeploymentAddresses memory deployed)
    {
        deployed.deploymentId = vm.parseJsonBytes32(manifest, ".deploymentId");
        deployed.factory = vm.parseJsonAddress(manifest, ".factory");
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        deployed.vault = vm.parseJsonAddress(manifest, ".vault");
        deployed.share = vm.parseJsonAddress(manifest, ".share");
        deployed.accounting = vm.parseJsonAddress(manifest, ".accounting");
        deployed.flow = vm.parseJsonAddress(manifest, ".flow");
        deployed.strategy = vm.parseJsonAddress(manifest, ".strategy");
        deployed.claimEscrow = vm.parseJsonAddress(manifest, ".claimEscrow");
        deployed.inKindEscrow = vm.parseJsonAddress(manifest, ".inKindEscrow");
        deployed.emergencyEscrow = vm.parseJsonAddress(manifest, ".emergencyEscrow");
        deployed.coordinator = vm.parseJsonAddress(manifest, ".coordinator");
        deployed.metaWheelValuator = vm.parseJsonAddress(manifest, ".metaWheelValuator");
        deployed.cspValuator = vm.parseJsonAddress(manifest, ".cspValuator");
        deployed.coveredCallValuator = vm.parseJsonAddress(manifest, ".coveredCallValuator");
        deployed.vaultImplementation = vm.parseJsonAddress(manifest, ".vaultImplementation");
        deployed.shareImplementation = vm.parseJsonAddress(manifest, ".shareImplementation");
        deployed.accountingImplementation = vm.parseJsonAddress(manifest, ".accountingImplementation");
        deployed.flowImplementation = vm.parseJsonAddress(manifest, ".flowImplementation");
        deployed.strategyImplementation = vm.parseJsonAddress(manifest, ".strategyImplementation");
        deployed.coordinatorImplementation = vm.parseJsonAddress(manifest, ".coordinatorImplementation");
        deployed.cspAdapterImplementation = vm.parseJsonAddress(manifest, ".cspAdapterImplementation");
        deployed.cspLaneImplementation = vm.parseJsonAddress(manifest, ".cspLaneImplementation");
        deployed.coveredCallAdapterImplementation = vm.parseJsonAddress(manifest, ".coveredCallAdapterImplementation");
        deployed.coveredCallLaneImplementation = vm.parseJsonAddress(manifest, ".coveredCallLaneImplementation");
        deployed.cspLanes = _fixed(vm.parseJsonAddressArray(manifest, ".cspLanes"));
        deployed.cspAdapters = _fixed(vm.parseJsonAddressArray(manifest, ".cspAdapters"));
        deployed.coveredCallLanes = _fixed(vm.parseJsonAddressArray(manifest, ".coveredCallLanes"));
        deployed.coveredCallAdapters = _fixed(vm.parseJsonAddressArray(manifest, ".coveredCallAdapters"));
    }

    function _reconcileImplementations(DeploymentAddresses memory deployed) private view {
        require(_implementationOf(deployed.vault) == deployed.vaultImplementation, "B1N419: vault impl");
        require(_implementationOf(deployed.share) == deployed.shareImplementation, "B1N419: share impl");
        require(_implementationOf(deployed.accounting) == deployed.accountingImplementation, "B1N419: accounting impl");
        require(_implementationOf(deployed.flow) == deployed.flowImplementation, "B1N419: flow impl");
        require(_implementationOf(deployed.strategy) == deployed.strategyImplementation, "B1N419: strategy impl");
        require(
            _implementationOf(deployed.coordinator) == deployed.coordinatorImplementation, "B1N419: coordinator impl"
        );
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            require(_implementationOf(deployed.cspLanes[i]) == deployed.cspLaneImplementation, "B1N419: CSP lane impl");
            require(
                _implementationOf(deployed.cspAdapters[i]) == deployed.cspAdapterImplementation,
                "B1N419: CSP adapter impl"
            );
            require(
                _implementationOf(deployed.coveredCallLanes[i]) == deployed.coveredCallLaneImplementation,
                "B1N419: CC lane impl"
            );
            require(
                _implementationOf(deployed.coveredCallAdapters[i]) == deployed.coveredCallAdapterImplementation,
                "B1N419: CC adapter impl"
            );
        }
    }

    function _reconcileCodehashes(string memory manifest, DeploymentAddresses memory deployed) private view {
        require(
            deployed.vaultImplementation.codehash == vm.parseJsonBytes32(manifest, ".vaultImplementationCodehash"),
            "B1N419: vault codehash"
        );
        require(
            deployed.shareImplementation.codehash == vm.parseJsonBytes32(manifest, ".shareImplementationCodehash"),
            "B1N419: share codehash"
        );
        require(
            deployed.accountingImplementation.codehash
                == vm.parseJsonBytes32(manifest, ".accountingImplementationCodehash"),
            "B1N419: accounting codehash"
        );
        require(
            deployed.flowImplementation.codehash == vm.parseJsonBytes32(manifest, ".flowImplementationCodehash"),
            "B1N419: flow codehash"
        );
        require(
            deployed.strategyImplementation.codehash
                == vm.parseJsonBytes32(manifest, ".strategyImplementationCodehash"),
            "B1N419: strategy codehash"
        );
        require(
            deployed.coordinatorImplementation.codehash
                == vm.parseJsonBytes32(manifest, ".coordinatorImplementationCodehash"),
            "B1N419: coordinator codehash"
        );
        require(
            deployed.cspAdapterImplementation.codehash
                == vm.parseJsonBytes32(manifest, ".cspAdapterImplementationCodehash"),
            "B1N419: CSP adapter codehash"
        );
        require(
            deployed.cspLaneImplementation.codehash == vm.parseJsonBytes32(manifest, ".cspLaneImplementationCodehash"),
            "B1N419: CSP lane codehash"
        );
        require(
            deployed.coveredCallAdapterImplementation.codehash
                == vm.parseJsonBytes32(manifest, ".coveredCallAdapterImplementationCodehash"),
            "B1N419: CC adapter codehash"
        );
        require(
            deployed.coveredCallLaneImplementation.codehash
                == vm.parseJsonBytes32(manifest, ".coveredCallLaneImplementationCodehash"),
            "B1N419: CC lane codehash"
        );
    }

    function _reconcileRoles(FundAccessManager manager, FundFactory.RoleAccounts memory roles) private view {
        _requireSingleImmediateRole(manager, manager.ADMIN_ROLE(), roles.admin);
        _requireSingleImmediateRole(manager, FundConstants.UPGRADER_ROLE, roles.upgrader);
        _requireSingleImmediateRole(manager, FundConstants.ADAPTER_UPGRADER_ROLE, roles.upgrader);
        _requireSingleImmediateRole(manager, FundConstants.ACCOUNTING_ROLE, roles.accounting);
        _requireSingleImmediateRole(manager, FundConstants.ALLOCATOR_ROLE, roles.allocator);
        _requireSingleImmediateRole(manager, FundConstants.PROCESSOR_ROLE, roles.processor);
        _requireSingleImmediateRole(manager, FundConstants.CURATOR_ROLE, roles.curator);
        _requireSingleImmediateRole(manager, FundConstants.GUARDIAN_ROLE, roles.guardian);
    }

    function _reconcileLanes(DeploymentAddresses memory deployed) private view {
        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(deployed.coordinator);
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            (address cspLane, WheelTypes.LaneKind cspKind, bool cspActive) = coordinator.registeredLaneAt(i);
            require(
                cspLane == deployed.cspLanes[i] && cspKind == WheelTypes.LaneKind.Csp && cspActive, "B1N419: CSP lane"
            );
            require(WheelCspChildLane(cspLane).adapter() == deployed.cspAdapters[i], "B1N419: CSP adapter");
            require(!ICspFundAdapter(deployed.cspAdapters[i]).isOnboarded(), "B1N419: CSP onboarded early");

            (address callLane, WheelTypes.LaneKind callKind, bool callActive) =
                coordinator.registeredLaneAt(CSP_LANE_COUNT + i);
            require(
                callLane == deployed.coveredCallLanes[i] && callKind == WheelTypes.LaneKind.CoveredCall && callActive,
                "B1N419: CC lane"
            );
            require(
                WheelCoveredCallChildLane(callLane).adapter() == deployed.coveredCallAdapters[i], "B1N419: CC adapter"
            );
            require(
                !ICoveredCallFundAdapter(deployed.coveredCallAdapters[i]).isOnboarded(), "B1N419: CC onboarded early"
            );
        }
    }

    function _reconcileFees(address accounting, address recipient) private view {
        FundTypes.FeeConfig memory fees = FundAccounting(accounting).feeConfig();
        require(fees.managementFeeWad == MANAGEMENT_FEE_WAD, "B1N419: management fee");
        require(fees.performanceFeeBps == PERFORMANCE_FEE_BPS, "B1N419: performance fee");
        require(fees.feeRecipient == recipient, "B1N419: fee recipient");
    }

    function _fixed(address[] memory values) private pure returns (address[4] memory fixedValues) {
        require(values.length == 4, "B1N419: manifest lane count");
        for (uint256 i; i < values.length; ++i) {
            fixedValues[i] = values[i];
        }
    }
}
