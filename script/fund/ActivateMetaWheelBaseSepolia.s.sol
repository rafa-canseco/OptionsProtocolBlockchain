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

/// @notice Two-phase activation that never opens a position or moves funds.
/// @dev Preparation is one curator transaction and deliberately invalidates NAV while the Fund remains paused.
///      ACCOUNTING must then submit a fresh signed NAV. Opening deposits/redemptions is a second curator transaction.
contract ActivateMetaWheelBaseSepolia is DeployMetaWheelBaseSepolia {
    string private constant PREPARE_APPROVAL = "APPROVED_BASE_SEPOLIA_ACTIVATION_PREPARE";
    string private constant OPEN_APPROVAL = "APPROVED_BASE_SEPOLIA_ACTIVATION_OPEN";

    error UseExplicitActivationEntryPoint();

    function run() external pure override returns (DeploymentAddresses memory) {
        revert UseExplicitActivationEntryPoint();
    }

    function prepareActivation() external returns (DeploymentAddresses memory deployed) {
        (DeployConfig memory config, string memory manifest, string memory approval) =
            _loadActivationInputs(PREPARE_APPROVAL);
        deployed = _loadActivationAddresses(manifest);
        _requireActivationState(config, manifest, approval, deployed, 0);

        address curator = vm.envAddress("B1N419_BROADCASTER");
        require(curator == config.finalRoles.curator, "B1N419: activation curator");
        StrategyManager strategy = StrategyManager(deployed.strategy);
        uint64 positionNonceBefore = strategy.positionNonce(deployed.coordinator);
        uint64 allocationPauseNonce = strategy.allocationPauseNonce(deployed.coordinator);
        WheelCoordinatorAdapter.Summary memory coordinatorBefore =
            WheelCoordinatorAdapter(deployed.coordinator).summary();

        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        bytes[] memory calls = new bytes[](10);
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            calls[2 * i] = abi.encodeCall(
                manager.execute, (deployed.cspLanes[i], abi.encodeCall(WheelCspChildLane.resumeAllocations, ()))
            );
            calls[2 * i + 1] = abi.encodeCall(
                manager.execute,
                (deployed.coveredCallLanes[i], abi.encodeCall(WheelCoveredCallChildLane.resumeAllocations, ()))
            );
        }
        calls[8] = abi.encodeCall(
            manager.execute,
            (
                deployed.strategy,
                abi.encodeCall(
                    strategy.executeAdapterConfigurationOperation,
                    (deployed.coordinator, abi.encode(WheelTypes.ManagedOperation.ResumeAllocations, bytes("")))
                )
            )
        );
        calls[9] = abi.encodeCall(
            manager.execute,
            (deployed.strategy, abi.encodeCall(strategy.resumeAllocation, (deployed.coordinator, allocationPauseNonce)))
        );

        vm.startBroadcast(curator);
        manager.multicall(calls);
        vm.stopBroadcast();

        require(strategy.positionNonce(deployed.coordinator) == positionNonceBefore + 1, "B1N419: resume nonce");
        require(
            keccak256(abi.encode(WheelCoordinatorAdapter(deployed.coordinator).summary()))
                == keccak256(abi.encode(coordinatorBefore)),
            "B1N419: preparation moved position state"
        );
        _requireActivationState(config, manifest, approval, deployed, 1);
    }

    function openFund() external returns (DeploymentAddresses memory deployed) {
        (DeployConfig memory config, string memory manifest, string memory approval) =
            _loadActivationInputs(OPEN_APPROVAL);
        deployed = _loadActivationAddresses(manifest);
        _requireActivationState(config, manifest, approval, deployed, 2);

        address curator = vm.envAddress("B1N419_BROADCASTER");
        require(curator == config.finalRoles.curator, "B1N419: activation curator");
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(manager.execute, (deployed.vault, abi.encodeCall(FundVault.resumeRedemptions, ())));
        calls[1] = abi.encodeCall(manager.execute, (deployed.vault, abi.encodeCall(FundVault.resumeDeposits, ())));
        vm.startBroadcast(curator);
        manager.multicall(calls);
        vm.stopBroadcast();

        _requireActivationState(config, manifest, approval, deployed, 3);
    }

    function reconcilePrepared() external returns (DeploymentAddresses memory deployed) {
        (DeployConfig memory config, string memory manifest, string memory approval) =
            _loadActivationInputs(PREPARE_APPROVAL);
        deployed = _loadActivationAddresses(manifest);
        _requireActivationState(config, manifest, approval, deployed, 1);
    }

    function reconcileActivated() external returns (DeploymentAddresses memory deployed) {
        (DeployConfig memory config, string memory manifest, string memory approval) =
            _loadActivationInputs(OPEN_APPROVAL);
        deployed = _loadActivationAddresses(manifest);
        _requireActivationState(config, manifest, approval, deployed, 3);
    }

    function _loadActivationInputs(string memory expectedApproval)
        private
        returns (DeployConfig memory config, string memory manifest, string memory approval)
    {
        config = _loadConfig();
        manifest = _loadBoundManifest(config);
        require(
            keccak256(bytes(vm.parseJsonString(manifest, ".status"))) == keccak256("CONFIRMED_CANONICAL_RECEIPTS")
                && keccak256(bytes(vm.parseJsonString(manifest, ".deploymentStatus"))) == keccak256("DEPLOYED")
                && vm.parseJsonBool(manifest, ".handoffReady"),
            "B1N419: canonical handoff required"
        );
        approval = vm.readFile(vm.envString("B1N419_ACTIVATION_APPROVAL_PATH"));
        require(
            sha256(bytes(approval)) == vm.envBytes32("B1N419_ACTIVATION_APPROVAL_SHA256")
                && keccak256(bytes(vm.parseJsonString(approval, ".approval"))) == keccak256(bytes(expectedApproval)),
            "B1N419: activation approval"
        );
    }

    /// @dev stage: 0 pre-prepare, 1 prepared/NAV invalid, 2 prepared/fresh NAV, 3 fully open.
    function _requireActivationState(
        DeployConfig memory config,
        string memory manifest,
        string memory approval,
        DeploymentAddresses memory deployed,
        uint8 stage
    ) private view {
        require(
            keccak256(bytes(vm.parseJsonString(approval, ".sourceCommit"))) == keccak256(bytes(config.sourceCommit))
                && vm.parseJsonBytes32(approval, ".deploymentId") == vm.parseJsonBytes32(manifest, ".deploymentId")
                && vm.parseJsonBytes32(approval, ".canonicalManifestSha256") == sha256(bytes(manifest))
                && vm.parseJsonBytes32(approval, ".readinessHash") == _readinessHash(manifest),
            "B1N419: activation artifact binding"
        );
        require(
            vm.parseJsonBool(approval, ".qa.twoCycleForkPassed") && vm.parseJsonBool(approval, ".qa.backendReady")
                && vm.parseJsonBool(approval, ".qa.frontendReady") && vm.parseJsonBool(approval, ".qa.marketMakerReady")
                && vm.parseJsonBool(approval, ".qa.standaloneRegressionPassed")
                && vm.parseJsonBool(approval, ".qa.noUnresolvedCriticalOrHigh"),
            "B1N419: activation QA incomplete"
        );
        _requireFinalRoles(FundAccessManager(deployed.accessManager), config.finalRoles);
        _requireStandaloneBaseline(config.standalone);

        FundVault vault = FundVault(deployed.vault);
        StrategyManager strategy = StrategyManager(deployed.strategy);
        bool prepared = stage != 0;
        bool opened = stage == 3;
        require(vault.executionLockOwner() == address(0), "B1N419: fund execution locked");
        require(vault.depositsPaused() != opened, "B1N419: deposit activation state");
        require(vault.redemptionsPaused() != opened, "B1N419: redemption activation state");
        require(strategy.strategyConfig(deployed.coordinator).active == prepared, "B1N419: strategy activation state");

        FundTypes.NavCommit memory nav = vault.activeNavWindow();
        if (stage == 1) {
            require(block.number > nav.validUntilBlock, "B1N419: preparation must invalidate NAV");
        } else if (stage >= 2) {
            require(
                nav.reportNonce != 0 && nav.reportHash != bytes32(0) && block.number >= nav.validAfterBlock
                    && block.number <= nav.validUntilBlock
                    && nav.reportNonce == vm.parseJsonUint(approval, ".nav.reportNonce")
                    && nav.reportHash == vm.parseJsonBytes32(approval, ".nav.reportHash")
                    && nav.positionsHash == vm.parseJsonBytes32(approval, ".nav.positionsHash")
                    && nav.positionsHash == strategy.positionsHash()
                    && nav.validAfterBlock == vm.parseJsonUint(approval, ".nav.validAfterBlock")
                    && nav.validUntilBlock == vm.parseJsonUint(approval, ".nav.validUntilBlock"),
                "B1N419: fresh NAV activation window"
            );
        }

        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(deployed.coordinator);
        require(coordinator.allocationsPaused() != prepared, "B1N419: coordinator pause state");
        WheelCoordinatorAdapter.Summary memory summary = coordinator.summary();
        require(
            summary.trancheCount == 0 && summary.assignmentLotCount == 0 && summary.pendingCspUsdc == 0
                && summary.reservedRedemptionUsdc == 0 && summary.reservedPrincipalUsdc == 0
                && summary.transitionWeth == 0 && summary.accountedUsdc == 0 && summary.accountedWeth == 0,
            "B1N419: activation must not move funds"
        );
        BatchSettler settler = BatchSettler(config.assets.batchSettler);
        require(coordinator.registeredLaneCount() == 8, "B1N419: activation lane count");
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            (address cspLane, WheelTypes.LaneKind cspKind, bool cspActive) = coordinator.registeredLaneAt(i);
            (address ccLane, WheelTypes.LaneKind ccKind, bool ccActive) =
                coordinator.registeredLaneAt(CSP_LANE_COUNT + i);
            require(
                cspLane == deployed.cspLanes[i] && cspKind == WheelTypes.LaneKind.Csp && cspActive
                    && WheelCspChildLane(cspLane).allocationsPaused() != prepared
                    && WheelCspChildLane(cspLane).laneState() == WheelTypes.LaneState.Idle
                    && WheelCspChildLane(cspLane).childShares() == 0
                    && settler.authorizedPhysicalDeliveryVault(deployed.cspAdapters[i]),
                "B1N419: CSP activation lane"
            );
            require(
                ccLane == deployed.coveredCallLanes[i] && ccKind == WheelTypes.LaneKind.CoveredCall && ccActive
                    && WheelCoveredCallChildLane(ccLane).allocationsPaused() != prepared
                    && WheelCoveredCallChildLane(ccLane).laneState() == WheelTypes.LaneState.Idle
                    && WheelCoveredCallChildLane(ccLane).childShares() == 0
                    && settler.authorizedPhysicalDeliveryVault(deployed.coveredCallAdapters[i]),
                "B1N419: CC activation lane"
            );
        }
    }

    function _readinessHash(string memory manifest) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                vm.parseJsonBool(manifest, ".readiness.canonicalReceiptsRecorded"),
                vm.parseJsonBool(manifest, ".readiness.exactSourceRuntimeBytecodeVerified"),
                vm.parseJsonBool(manifest, ".readiness.bootstrapReconciled"),
                vm.parseJsonBool(manifest, ".readiness.finalRolesReconciled"),
                vm.parseJsonBool(manifest, ".readiness.standaloneBaselinesUnchanged"),
                vm.parseJsonBool(manifest, ".readiness.backendHandoffReady"),
                vm.parseJsonBool(manifest, ".readiness.mainnetAuthorized")
            )
        );
    }

    function _loadActivationAddresses(string memory manifest)
        private
        view
        returns (DeploymentAddresses memory deployed)
    {
        deployed.vault = vm.parseJsonAddress(manifest, ".vault");
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        deployed.strategy = vm.parseJsonAddress(manifest, ".strategy");
        deployed.coordinator = vm.parseJsonAddress(manifest, ".coordinator");
        deployed.cspLanes = _fixedActivation(vm.parseJsonAddressArray(manifest, ".cspLanes"));
        deployed.cspAdapters = _fixedActivation(vm.parseJsonAddressArray(manifest, ".cspAdapters"));
        deployed.coveredCallLanes = _fixedActivation(vm.parseJsonAddressArray(manifest, ".coveredCallLanes"));
        deployed.coveredCallAdapters = _fixedActivation(vm.parseJsonAddressArray(manifest, ".coveredCallAdapters"));
    }

    function _fixedActivation(address[] memory values) private pure returns (address[4] memory fixedValues) {
        require(values.length == 4, "B1N419: activation requires four lanes");
        for (uint256 i; i < values.length; ++i) {
            fixedValues[i] = values[i];
        }
    }
}
