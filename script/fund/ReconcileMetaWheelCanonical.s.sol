// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice Read-only final on-chain gate used before a manifest can become canonical.
/// @dev No transaction is broadcast and the unconfirmed manifest is never mutated by this contract.
contract ReconcileMetaWheelCanonical is DeployMetaWheelBaseSepolia {
    function run() external override returns (DeploymentAddresses memory deployed) {
        return _reconcileCanonical();
    }

    function reconcile() external returns (DeploymentAddresses memory deployed) {
        return _reconcileCanonical();
    }

    function _reconcileCanonical() private returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = _loadBoundManifest(config);

        require(
            keccak256(bytes(vm.parseJsonString(manifest, ".status")))
                == keccak256("UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS"),
            "B1N419: manifest already canonical"
        );
        require(
            keccak256(bytes(vm.parseJsonString(manifest, ".deploymentStatus"))) == keccak256("UNCONFIRMED"),
            "B1N419: deployment status"
        );
        require(!vm.parseJsonBool(manifest, ".handoffReady"), "B1N419: handoff already ready");
        require(
            keccak256(bytes(vm.parseJsonString(manifest, ".sourceCommit"))) == keccak256(bytes(config.sourceCommit)),
            "B1N419: manifest source"
        );

        _requireBoundary(config, manifest);
        deployed = _loadCanonicalAddresses(manifest);
        _requireFactoryDeployment(deployed, config.fund.implementationVersion);
        _requireCanonicalCore(config, deployed, manifest);
        _requireCanonicalWheel(config, deployed, manifest);
        _requireValuationIdentities(config, deployed);
        _requireFinalRoles(FundAccessManager(deployed.accessManager), config.finalRoles);
        _requireStandaloneBaseline(config.standalone);
        _requireV1Policy(config);
    }

    function _requireBoundary(DeployConfig memory config, string memory manifest) private view {
        require(
            vm.parseJsonAddress(manifest, ".v1Boundary.addressBook.proxy") == config.assets.addressBook,
            "B1N419: address book boundary"
        );
        require(
            vm.parseJsonAddress(manifest, ".v1Boundary.controller.proxy") == config.assets.controller
                && vm.parseJsonAddress(manifest, ".v1Boundary.controller.implementation")
                    == _implementationOf(config.assets.controller),
            "B1N419: controller boundary"
        );
        require(
            vm.parseJsonAddress(manifest, ".v1Boundary.batchSettler.proxy") == config.assets.batchSettler
                && vm.parseJsonAddress(manifest, ".v1Boundary.batchSettler.implementation")
                    == _implementationOf(config.assets.batchSettler),
            "B1N419: settler boundary"
        );
        require(
            vm.parseJsonAddress(manifest, ".v1Boundary.marginPool.proxy") == config.assets.marginPool
                && vm.parseJsonAddress(manifest, ".v1Boundary.oracle.proxy") == config.assets.oracle
                && vm.parseJsonAddress(manifest, ".v1Boundary.oTokenFactory.proxy") == config.assets.oTokenFactory
                && vm.parseJsonAddress(manifest, ".v1Boundary.whitelist.proxy") == config.assets.whitelist,
            "B1N419: protocol boundary"
        );
        string[7] memory keys = [
            string("addressBook"),
            string("controller"),
            string("batchSettler"),
            string("marginPool"),
            string("oracle"),
            string("oTokenFactory"),
            string("whitelist")
        ];
        for (uint256 i; i < keys.length; ++i) {
            require(
                vm.parseJsonBool(manifest, string.concat(".v1Boundary.", keys[i], ".unchanged")),
                "B1N419: V1 boundary changed"
            );
        }
    }

    function _loadCanonicalAddresses(string memory manifest)
        private
        view
        returns (DeploymentAddresses memory deployed)
    {
        deployed.deploymentId = vm.parseJsonBytes32(manifest, ".deploymentId");
        deployed.factory = vm.parseJsonAddress(manifest, ".factory");
        deployed.vault = vm.parseJsonAddress(manifest, ".contracts.fundVault.proxy");
        deployed.vaultImplementation = vm.parseJsonAddress(manifest, ".contracts.fundVault.implementation");
        deployed.share = vm.parseJsonAddress(manifest, ".contracts.fundShare.proxy");
        deployed.shareImplementation = vm.parseJsonAddress(manifest, ".contracts.fundShare.implementation");
        deployed.accounting = vm.parseJsonAddress(manifest, ".contracts.fundAccounting.proxy");
        deployed.accountingImplementation = vm.parseJsonAddress(manifest, ".contracts.fundAccounting.implementation");
        deployed.flow = vm.parseJsonAddress(manifest, ".contracts.fundFlowManager.proxy");
        deployed.flowImplementation = vm.parseJsonAddress(manifest, ".contracts.fundFlowManager.implementation");
        deployed.strategy = vm.parseJsonAddress(manifest, ".contracts.strategyManager.proxy");
        deployed.strategyImplementation = vm.parseJsonAddress(manifest, ".contracts.strategyManager.implementation");
        deployed.coordinator = vm.parseJsonAddress(manifest, ".contracts.wheelCoordinator.proxy");
        deployed.coordinatorImplementation = vm.parseJsonAddress(manifest, ".contracts.wheelCoordinator.implementation");
        deployed.claimEscrow = vm.parseJsonAddress(manifest, ".contracts.claimEscrow.address");
        deployed.accessManager = vm.parseJsonAddress(manifest, ".contracts.accessManager.address");
        deployed.metaWheelValuator = vm.parseJsonAddress(manifest, ".contracts.metaWheelValuator.address");
        deployed.navVerifier = vm.parseJsonAddress(manifest, ".contracts.navReportVerifier.address");
        deployed.cspValuator = vm.parseJsonAddress(manifest, ".cspValuator");
        deployed.coveredCallValuator = vm.parseJsonAddress(manifest, ".coveredCallValuator");
        deployed.cspLanes = _fixed(vm.parseJsonAddressArray(manifest, ".cspLanes"));
        deployed.cspAdapters = _fixed(vm.parseJsonAddressArray(manifest, ".cspAdapters"));
        deployed.coveredCallLanes = _fixed(vm.parseJsonAddressArray(manifest, ".coveredCallLanes"));
        deployed.coveredCallAdapters = _fixed(vm.parseJsonAddressArray(manifest, ".coveredCallAdapters"));
    }

    function _requireCanonicalCore(
        DeployConfig memory config,
        DeploymentAddresses memory deployed,
        string memory manifest
    ) private view {
        _requireProxyBaseline(
            deployed.vault,
            deployed.vaultImplementation,
            vm.parseJsonBytes32(manifest, ".contracts.fundVault.implementationCodehash"),
            "B1N419: vault implementation"
        );
        _requireProxyBaseline(
            deployed.share,
            deployed.shareImplementation,
            vm.parseJsonBytes32(manifest, ".contracts.fundShare.implementationCodehash"),
            "B1N419: share implementation"
        );
        _requireProxyBaseline(
            deployed.accounting,
            deployed.accountingImplementation,
            vm.parseJsonBytes32(manifest, ".contracts.fundAccounting.implementationCodehash"),
            "B1N419: accounting implementation"
        );
        _requireProxyBaseline(
            deployed.flow,
            deployed.flowImplementation,
            vm.parseJsonBytes32(manifest, ".contracts.fundFlowManager.implementationCodehash"),
            "B1N419: flow implementation"
        );
        _requireProxyBaseline(
            deployed.strategy,
            deployed.strategyImplementation,
            vm.parseJsonBytes32(manifest, ".contracts.strategyManager.implementationCodehash"),
            "B1N419: strategy implementation"
        );
        require(FundVault(deployed.vault).asset() == config.assets.usdc, "B1N419: accounting asset");
        require(FundVault(deployed.vault).depositsPaused(), "B1N419: deposits open");
        require(FundVault(deployed.vault).redemptionsPaused(), "B1N419: redemptions open");
        require(
            deployed.vault.codehash == vm.parseJsonBytes32(manifest, ".vaultProxyCodehash")
                && deployed.share.codehash == vm.parseJsonBytes32(manifest, ".shareProxyCodehash")
                && deployed.accounting.codehash == vm.parseJsonBytes32(manifest, ".accountingProxyCodehash")
                && deployed.flow.codehash == vm.parseJsonBytes32(manifest, ".flowProxyCodehash")
                && deployed.strategy.codehash == vm.parseJsonBytes32(manifest, ".strategyProxyCodehash"),
            "B1N419: core proxy codehash"
        );
        _requireCodehash(manifest, ".contracts.claimEscrow", deployed.claimEscrow);
        _requireCodehash(manifest, ".contracts.accessManager", deployed.accessManager);
        _requireCodehash(manifest, ".contracts.metaWheelValuator", deployed.metaWheelValuator);
        _requireCodehash(manifest, ".contracts.navReportVerifier", deployed.navVerifier);
    }

    function _requireCanonicalWheel(
        DeployConfig memory config,
        DeploymentAddresses memory deployed,
        string memory manifest
    ) private view {
        _requireProxyBaseline(
            deployed.coordinator,
            deployed.coordinatorImplementation,
            vm.parseJsonBytes32(manifest, ".contracts.wheelCoordinator.implementationCodehash"),
            "B1N419: coordinator implementation"
        );
        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(deployed.coordinator);
        require(coordinator.fund() == deployed.vault, "B1N419: coordinator fund");
        require(coordinator.registeredLaneCount() == 8, "B1N419: lane count");
        require(coordinator.allocationsPaused(), "B1N419: coordinator not paused at handoff");
        require(coordinator.policyHash() == config.wheel.policyHash, "B1N419: wheel policy");
        require(coordinator.floorBufferUsd8() == config.wheel.floorBufferUsd8, "B1N419: wheel floor");

        FundTypes.StrategyConfig memory strategyConfig =
            StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator);
        require(strategyConfig.interfaceVersion == 1, "B1N419: coordinator not configured");
        require(!strategyConfig.active, "B1N419: coordinator active");
        require(strategyConfig.valuator == deployed.metaWheelValuator, "B1N419: coordinator valuator");
        require(
            deployed.coordinator.codehash == vm.parseJsonBytes32(manifest, ".coordinatorProxyCodehash"),
            "B1N419: coordinator proxy codehash"
        );
        address cspAdapterImplementation = vm.parseJsonAddress(manifest, ".cspAdapterImplementation");
        address cspLaneImplementation = vm.parseJsonAddress(manifest, ".cspLaneImplementation");
        address coveredCallAdapterImplementation = vm.parseJsonAddress(manifest, ".coveredCallAdapterImplementation");
        address coveredCallLaneImplementation = vm.parseJsonAddress(manifest, ".coveredCallLaneImplementation");
        require(
            cspAdapterImplementation.codehash == vm.parseJsonBytes32(manifest, ".cspAdapterImplementationCodehash")
                && cspLaneImplementation.codehash == vm.parseJsonBytes32(manifest, ".cspLaneImplementationCodehash")
                && coveredCallAdapterImplementation.codehash
                    == vm.parseJsonBytes32(manifest, ".coveredCallAdapterImplementationCodehash")
                && coveredCallLaneImplementation.codehash
                    == vm.parseJsonBytes32(manifest, ".coveredCallLaneImplementationCodehash"),
            "B1N419: child implementation codehash"
        );
        address cspValuator = vm.parseJsonAddress(manifest, ".cspValuator");
        address coveredCallValuator = vm.parseJsonAddress(manifest, ".coveredCallValuator");
        require(
            cspValuator.codehash == vm.parseJsonBytes32(manifest, ".cspValuatorCodehash")
                && coveredCallValuator.codehash == vm.parseJsonBytes32(manifest, ".coveredCallValuatorCodehash"),
            "B1N419: child valuator codehash"
        );

        bytes32[] memory cspLaneCodehashes = vm.parseJsonBytes32Array(manifest, ".cspLaneCodehashes");
        bytes32[] memory cspAdapterCodehashes = vm.parseJsonBytes32Array(manifest, ".cspAdapterCodehashes");
        bytes32[] memory coveredCallLaneCodehashes = vm.parseJsonBytes32Array(manifest, ".coveredCallLaneCodehashes");
        bytes32[] memory coveredCallAdapterCodehashes =
            vm.parseJsonBytes32Array(manifest, ".coveredCallAdapterCodehashes");
        require(
            cspLaneCodehashes.length == 4 && cspAdapterCodehashes.length == 4 && coveredCallLaneCodehashes.length == 4
                && coveredCallAdapterCodehashes.length == 4,
            "B1N419: child codehash count"
        );

        BatchSettler settler = BatchSettler(config.assets.batchSettler);
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            (address cspLane, WheelTypes.LaneKind cspKind, bool cspActive) = coordinator.registeredLaneAt(i);
            (address coveredCallLane, WheelTypes.LaneKind coveredCallKind, bool coveredCallActive) =
                coordinator.registeredLaneAt(CSP_LANE_COUNT + i);
            require(
                cspLane == deployed.cspLanes[i] && cspKind == WheelTypes.LaneKind.Csp && cspActive,
                "B1N419: CSP lane order"
            );
            require(
                coveredCallLane == deployed.coveredCallLanes[i] && coveredCallKind == WheelTypes.LaneKind.CoveredCall
                    && coveredCallActive,
                "B1N419: CC lane order"
            );
            require(
                WheelCspChildLane(cspLane).coordinator() == deployed.coordinator
                    && WheelCspChildLane(cspLane).adapter() == deployed.cspAdapters[i]
                    && WheelCspChildLane(cspLane).allocationsPaused(),
                "B1N419: CSP binding"
            );
            require(
                WheelCoveredCallChildLane(coveredCallLane).coordinator() == deployed.coordinator
                    && WheelCoveredCallChildLane(coveredCallLane).adapter() == deployed.coveredCallAdapters[i]
                    && WheelCoveredCallChildLane(coveredCallLane).allocationsPaused(),
                "B1N419: CC binding"
            );
            require(
                cspLane.codehash == cspLaneCodehashes[i] && deployed.cspAdapters[i].codehash == cspAdapterCodehashes[i]
                    && coveredCallLane.codehash == coveredCallLaneCodehashes[i]
                    && deployed.coveredCallAdapters[i].codehash == coveredCallAdapterCodehashes[i],
                "B1N419: child proxy codehash"
            );
            require(settler.authorizedPhysicalDeliveryVault(deployed.cspAdapters[i]), "B1N419: CSP onboarding");
            require(settler.authorizedPhysicalDeliveryVault(deployed.coveredCallAdapters[i]), "B1N419: CC onboarding");
        }

        address[] memory libraries = vm.parseJsonAddressArray(manifest, ".linkedLibraries");
        bytes32[] memory codehashes = vm.parseJsonBytes32Array(manifest, ".linkedLibraryCodehashes");
        require(libraries.length == 5 && codehashes.length == 5, "B1N419: library count");
        for (uint256 i; i < libraries.length; ++i) {
            require(
                libraries[i] == config.linkedLibraries[i] && libraries[i].codehash == codehashes[i],
                "B1N419: library reconciliation"
            );
        }
    }

    function _requireCodehash(string memory manifest, string memory key, address deployed) private view {
        require(deployed.codehash == vm.parseJsonBytes32(manifest, string.concat(key, ".codehash")), "B1N419: codehash");
    }

    function _requireValuationIdentities(DeployConfig memory config, DeploymentAddresses memory deployed) private view {
        CspFundValuatorV2 cspValuator = CspFundValuatorV2(deployed.cspValuator);
        CoveredCallFundValuatorV2 coveredCallValuator = CoveredCallFundValuatorV2(deployed.coveredCallValuator);
        require(
            config.valuation.approvedObservers.length == 4 && cspValuator.approvedObserverCount() == 2
                && coveredCallValuator.approvedObserverCount() == 2
                && cspValuator.observationQuorum() == config.valuation.observationQuorum
                && coveredCallValuator.observationQuorum() == config.valuation.observationQuorum,
            "B1N419: observer set"
        );
        for (uint256 i; i < 2; ++i) {
            address expectedCsp = config.valuation.approvedObservers[i];
            address expectedCoveredCall = config.valuation.approvedObservers[i + 2];
            require(
                cspValuator.approvedObserverAt(i) == expectedCsp
                    && coveredCallValuator.approvedObserverAt(i) == expectedCoveredCall
                    && cspValuator.isApprovedObserver(expectedCsp)
                    && coveredCallValuator.isApprovedObserver(expectedCoveredCall)
                    && !cspValuator.isApprovedObserver(expectedCoveredCall)
                    && !coveredCallValuator.isApprovedObserver(expectedCsp),
                "B1N419: observer binding"
            );
        }

        FundAccounting accounting = FundAccounting(deployed.accounting);
        require(
            accounting.reporterSetVersion() == 1
                && accounting.reporterThreshold() == config.valuation.navReporterThreshold
                && accounting.activeReporterCount() == config.valuation.navReporters.length,
            "B1N419: reporter set"
        );
        for (uint256 i; i < config.valuation.navReporters.length; ++i) {
            address expected = config.valuation.navReporters[i];
            require(
                accounting.activeReporterAt(i) == expected && accounting.isReporter(expected),
                "B1N419: reporter binding"
            );
        }
    }

    function _fixed(address[] memory values) private pure returns (address[4] memory fixedValues) {
        require(values.length == 4, "B1N419: four lanes required");
        for (uint256 i; i < values.length; ++i) {
            fixedValues[i] = values[i];
        }
    }
}
