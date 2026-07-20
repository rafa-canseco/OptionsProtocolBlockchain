// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CspFundValuator} from "../../src/fund/CspFundValuator.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {IStrategyAssetEscrow} from "../../src/fund/interfaces/IStrategyAssetEscrow.sol";
import {B1N352Base} from "./B1N352Base.sol";

abstract contract B1N352Operations is B1N352Base {
    struct Operation {
        address target;
        bytes data;
        bytes32 label;
    }

    struct PolicyConfig {
        address accounting;
        address flowManager;
        address strategyManager;
        address adapter;
        address valuator;
        address inKindEscrow;
        address emergencyEscrow;
        address[] reporters;
        uint16 reporterThreshold;
        uint64 reporterSetVersion;
        uint16 maxExitFeeBps;
        uint16 maxWindowOutflowBps;
        uint16 minimumIdleBps;
        uint16 maxAllocationBps;
        uint16 maxLossBps;
        uint32 cooldown;
        uint64 adapterInterfaceVersion;
        uint256 absoluteCap;
    }

    function _accessOperations(address manager_, address adapter, address inKindEscrow, address emergencyEscrow)
        internal
        pure
        returns (Operation[] memory operations)
    {
        operations = new Operation[](8);
        AccessManager manager = AccessManager(manager_);

        operations[0] = Operation({
            target: manager_,
            data: abi.encodeCall(manager.labelRole, (FundConstants.ADAPTER_UPGRADER_ROLE, "ADAPTER_UPGRADER")),
            label: keccak256("LABEL_ADAPTER_UPGRADER_ROLE")
        });
        operations[1] = _targetRoleOperation(
            manager,
            adapter,
            FundAccessPolicy.UPGRADE_TO_AND_CALL_SELECTOR,
            FundConstants.ADAPTER_UPGRADER_ROLE,
            "ADAPTER_UPGRADE_ROLE"
        );
        operations[2] = _targetRoleOperation(
            manager,
            adapter,
            ICspFundAdapter.setAdapterConfig.selector,
            FundConstants.CURATOR_ROLE,
            "ADAPTER_CURATOR_ROLE"
        );
        operations[3] = _targetAdminDelayOperation(manager, adapter, "ADAPTER_ADMIN_DELAY");
        operations[4] = _targetRoleOperation(
            manager,
            inKindEscrow,
            IStrategyAssetEscrow.releaseToFund.selector,
            FundConstants.CURATOR_ROLE,
            "IN_KIND_ESCROW_CURATOR_ROLE"
        );
        operations[5] = _targetAdminDelayOperation(manager, inKindEscrow, "IN_KIND_ESCROW_ADMIN_DELAY");
        operations[6] = _targetRoleOperation(
            manager,
            emergencyEscrow,
            IStrategyAssetEscrow.releaseToFund.selector,
            FundConstants.CURATOR_ROLE,
            "EMERGENCY_ESCROW_CURATOR_ROLE"
        );
        operations[7] = _targetAdminDelayOperation(manager, emergencyEscrow, "EMERGENCY_ESCROW_ADMIN_DELAY");
    }

    function _loadPolicyConfig() internal view returns (PolicyConfig memory config) {
        config.accounting = vm.envAddress("FUND_ACCOUNTING_PROXY");
        config.flowManager = vm.envAddress("FUND_FLOW_MANAGER_PROXY");
        config.strategyManager = vm.envAddress("FUND_STRATEGY_MANAGER_PROXY");
        config.adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        config.valuator = vm.envAddress("FUND_CSP_VALUATOR");
        config.inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        config.emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        config.reporters = vm.envAddress("FUND_NAV_REPORTERS", ",");
        config.reporterThreshold = _envUint16("FUND_NAV_REPORTER_THRESHOLD");
        config.reporterSetVersion = _envUint64("FUND_NAV_REPORTER_SET_VERSION");
        config.maxExitFeeBps = _envUint16("FUND_MAX_EXIT_FEE_BPS");
        config.maxWindowOutflowBps = _envUint16("FUND_MAX_WINDOW_OUTFLOW_BPS");
        config.minimumIdleBps = _envUint16("FUND_MINIMUM_IDLE_BPS");
        config.maxAllocationBps = _envUint16("FUND_STRATEGY_MAX_ALLOCATION_BPS");
        config.maxLossBps = _envUint16("FUND_STRATEGY_MAX_LOSS_BPS");
        config.cooldown = _envUint32("FUND_STRATEGY_COOLDOWN_SECONDS");
        config.adapterInterfaceVersion = _envUint64("FUND_CSP_ADAPTER_INTERFACE_VERSION");
        config.absoluteCap = vm.envUint("FUND_STRATEGY_ABSOLUTE_CAP");
    }

    function _policyOperations(PolicyConfig memory config) internal pure returns (Operation[] memory operations) {
        operations = new Operation[](7);
        FundAccounting accounting = FundAccounting(config.accounting);
        FundFlowManager flowManager = FundFlowManager(config.flowManager);
        StrategyManager strategyManager = StrategyManager(config.strategyManager);

        operations[0] = Operation({
            target: config.accounting,
            data: abi.encodeCall(
                accounting.setReporterSet, (config.reporters, config.reporterThreshold, config.reporterSetVersion)
            ),
            label: keccak256("SET_REPORTER_SET")
        });
        operations[1] = Operation({
            target: config.accounting,
            data: abi.encodeCall(
                accounting.setComponent, (FundConstants.IDLE_COMPONENT_ID, address(0), uint64(1), true)
            ),
            label: keccak256("SET_IDLE_COMPONENT")
        });
        operations[2] = Operation({
            target: config.accounting,
            data: abi.encodeCall(
                accounting.setComponent,
                (
                    keccak256(abi.encodePacked("STRATEGY", config.adapter)),
                    config.valuator,
                    config.adapterInterfaceVersion,
                    true
                )
            ),
            label: keccak256("SET_CSP_COMPONENT")
        });
        operations[3] = Operation({
            target: config.flowManager,
            data: abi.encodeCall(flowManager.setExitPolicy, (config.maxExitFeeBps, config.maxWindowOutflowBps)),
            label: keccak256("SET_EXIT_POLICY")
        });
        operations[4] = Operation({
            target: config.flowManager,
            data: abi.encodeCall(flowManager.setStrategyExitEscrows, (config.inKindEscrow, config.emergencyEscrow)),
            label: keccak256("SET_STRATEGY_EXIT_ESCROWS")
        });
        operations[5] = Operation({
            target: config.strategyManager,
            data: abi.encodeCall(strategyManager.setMinimumIdleBps, (config.minimumIdleBps)),
            label: keccak256("SET_MINIMUM_IDLE")
        });
        operations[6] = Operation({
            target: config.strategyManager,
            data: abi.encodeCall(
                strategyManager.setStrategyConfig,
                (
                    config.adapter,
                    FundTypes.StrategyConfig({
                        active: false,
                        maxAllocationBps: config.maxAllocationBps,
                        maxLossBps: config.maxLossBps,
                        cooldown: config.cooldown,
                        interfaceVersion: config.adapterInterfaceVersion,
                        valuator: config.valuator,
                        absoluteCap: config.absoluteCap
                    })
                )
            ),
            label: keccak256("SET_INACTIVE_CSP_STRATEGY")
        });
    }

    function _activationOperation(address strategyManager_, address adapter)
        internal
        view
        returns (Operation memory operation)
    {
        StrategyManager strategyManager = StrategyManager(strategyManager_);
        FundTypes.StrategyConfig memory config = strategyManager.strategyConfig(adapter);
        require(config.interfaceVersion != 0, "B1N352: activation state");
        operation = Operation({
            target: strategyManager_,
            data: abi.encodeCall(strategyManager.resumeAllocation, (adapter)),
            label: keccak256("ACTIVATE_CSP_STRATEGY")
        });
    }

    function _verifyDeployedPolicy(
        DeployConfig memory deployConfig,
        PolicyConfig memory policyConfig,
        bool expectedActive
    ) internal view {
        _verifyAccountingPolicy(deployConfig, policyConfig);
        _verifyFlowPolicy(policyConfig);
        _verifyStrategyPolicy(policyConfig, expectedActive);
        _verifyAdapterPolicy(deployConfig, policyConfig.adapter);
        _verifyValuatorPolicy(deployConfig, policyConfig.valuator);
    }

    function _verifyAccountingPolicy(DeployConfig memory deployConfig, PolicyConfig memory policyConfig) private view {
        FundAccounting accounting = FundAccounting(policyConfig.accounting);
        require(accounting.reporterSetVersion() == policyConfig.reporterSetVersion, "B1N352: reporter version");
        require(accounting.reporterThreshold() == policyConfig.reporterThreshold, "B1N352: reporter threshold");
        require(accounting.activeReporterCount() == policyConfig.reporters.length, "B1N352: reporter count");
        for (uint256 i; i < policyConfig.reporters.length; ++i) {
            require(accounting.activeReporterAt(i) == policyConfig.reporters[i], "B1N352: reporter order");
            require(accounting.isReporter(policyConfig.reporters[i]), "B1N352: reporter inactive");
        }

        bytes32 cspComponentId = keccak256(abi.encodePacked("STRATEGY", policyConfig.adapter));
        require(accounting.activeComponentCount() == 2, "B1N352: component count");
        require(accounting.activeComponentAt(0) == FundConstants.IDLE_COMPONENT_ID, "B1N352: idle component id");
        require(accounting.activeComponentAt(1) == cspComponentId, "B1N352: CSP component id");
        FundAccounting.ComponentState memory idle = accounting.componentState(FundConstants.IDLE_COMPONENT_ID);
        require(idle.valuator == address(0) && idle.interfaceVersion == 1 && idle.active, "B1N352: idle component");
        FundAccounting.ComponentState memory csp = accounting.componentState(cspComponentId);
        require(
            csp.valuator == policyConfig.valuator && csp.interfaceVersion == policyConfig.adapterInterfaceVersion
                && csp.active,
            "B1N352: CSP component"
        );

        (uint64 activationDelay, uint64 maxSnapshotAge, uint64 maxWindowLength) = accounting.navPolicy();
        require(activationDelay == deployConfig.navActivationDelay, "B1N352: NAV activation delay");
        require(maxSnapshotAge == deployConfig.maxSnapshotAge, "B1N352: NAV snapshot age");
        require(maxWindowLength == deployConfig.maxNavWindowLength, "B1N352: NAV window length");
        require(
            keccak256(abi.encode(accounting.feeConfig())) == keccak256(abi.encode(deployConfig.feeConfig)),
            "B1N352: fee config"
        );
    }

    function _verifyFlowPolicy(PolicyConfig memory policyConfig) private view {
        FundFlowManager flowManager = FundFlowManager(policyConfig.flowManager);
        (uint16 maxExitFeeBps, uint16 maxWindowOutflowBps) = flowManager.exitPolicy();
        require(maxExitFeeBps == policyConfig.maxExitFeeBps, "B1N352: exit fee");
        require(maxWindowOutflowBps == policyConfig.maxWindowOutflowBps, "B1N352: exit outflow");
        (address inKindEscrow, address emergencyEscrow) = flowManager.strategyExitEscrows();
        require(inKindEscrow == policyConfig.inKindEscrow, "B1N352: in-kind escrow policy");
        require(emergencyEscrow == policyConfig.emergencyEscrow, "B1N352: emergency escrow policy");
    }

    function _verifyStrategyPolicy(PolicyConfig memory policyConfig, bool expectedActive) private view {
        StrategyManager strategyManager = StrategyManager(policyConfig.strategyManager);
        require(strategyManager.activeAdapterCount() == 1, "B1N352: registered adapter count");
        require(strategyManager.activeAdapterAt(0) == policyConfig.adapter, "B1N352: registered adapter");
        require(strategyManager.minimumIdleBps() == policyConfig.minimumIdleBps, "B1N352: minimum idle");
        FundTypes.StrategyConfig memory expected = FundTypes.StrategyConfig({
            active: expectedActive,
            maxAllocationBps: policyConfig.maxAllocationBps,
            maxLossBps: policyConfig.maxLossBps,
            cooldown: policyConfig.cooldown,
            interfaceVersion: policyConfig.adapterInterfaceVersion,
            valuator: policyConfig.valuator,
            absoluteCap: policyConfig.absoluteCap
        });
        require(
            keccak256(abi.encode(strategyManager.strategyConfig(policyConfig.adapter)))
                == keccak256(abi.encode(expected)),
            "B1N352: strategy config"
        );
    }

    function _verifyAdapterPolicy(DeployConfig memory deployConfig, address adapter_) private view {
        ICspFundAdapter.AdapterConfig memory actual = CspFundAdapter(adapter_).adapterConfig();
        ICspFundAdapter.AdapterConfig memory expected = ICspFundAdapter.AdapterConfig({
            riskConfig: deployConfig.adapterRiskConfig,
            swapRouter: deployConfig.adapterSwapRouter,
            swapFeeTier: deployConfig.adapterSwapFeeTier
        });
        require(keccak256(abi.encode(actual)) == keccak256(abi.encode(expected)), "B1N352: adapter config");
    }

    function _verifyValuatorPolicy(DeployConfig memory deployConfig, address valuator_) private view {
        CspFundValuator valuator = CspFundValuator(valuator_);
        require(valuator.spotFeed() == deployConfig.spotFeed, "B1N352: valuator feed");
        require(valuator.spotFeedDecimals() == deployConfig.spotFeedDecimals, "B1N352: valuator decimals");
        require(valuator.maxSpotStaleness() == deployConfig.maxSpotStaleness, "B1N352: valuator staleness");
        require(
            valuator.maxObservationWindow() == deployConfig.maxObservationWindow, "B1N352: valuator observation window"
        );
        require(valuator.observationQuorum() == deployConfig.observationQuorum, "B1N352: valuator quorum");
        require(valuator.liabilityBufferBps() == deployConfig.liabilityBufferBps, "B1N352: valuator liability buffer");
        require(
            valuator.approvedObserverCount() == deployConfig.approvedObservers.length, "B1N352: valuator observer count"
        );
        for (uint256 i; i < deployConfig.approvedObservers.length; ++i) {
            require(
                valuator.approvedObserverAt(i) == deployConfig.approvedObservers[i], "B1N352: valuator observer order"
            );
            require(valuator.isApprovedObserver(deployConfig.approvedObservers[i]), "B1N352: valuator observer");
        }
    }

    function _isAccessPhaseFinalized(
        FundAccessManager manager,
        address adapter,
        address inKindEscrow,
        address emergencyEscrow
    ) internal view returns (bool) {
        return manager.configuredSelectorCount(adapter) == 2
            && manager.getTargetFunctionRole(adapter, FundAccessPolicy.UPGRADE_TO_AND_CALL_SELECTOR)
                == FundConstants.ADAPTER_UPGRADER_ROLE
            && manager.getTargetFunctionRole(adapter, ICspFundAdapter.setAdapterConfig.selector)
                == FundConstants.CURATOR_ROLE && _isTargetAdminDelayConfigured(manager, adapter)
            && manager.configuredSelectorCount(inKindEscrow) == 1
            && manager.getTargetFunctionRole(inKindEscrow, IStrategyAssetEscrow.releaseToFund.selector)
                == FundConstants.CURATOR_ROLE && _isTargetAdminDelayConfigured(manager, inKindEscrow)
            && manager.configuredSelectorCount(emergencyEscrow) == 1
            && manager.getTargetFunctionRole(emergencyEscrow, IStrategyAssetEscrow.releaseToFund.selector)
                == FundConstants.CURATOR_ROLE && _isTargetAdminDelayConfigured(manager, emergencyEscrow);
    }

    function _isPolicyPhaseFinalized(PolicyConfig memory config) internal view returns (bool) {
        FundAccounting accounting = FundAccounting(config.accounting);
        if (
            accounting.reporterSetVersion() != config.reporterSetVersion
                || accounting.reporterThreshold() != config.reporterThreshold
                || accounting.activeReporterCount() != config.reporters.length
        ) return false;
        for (uint256 i; i < config.reporters.length; ++i) {
            if (accounting.activeReporterAt(i) != config.reporters[i] || !accounting.isReporter(config.reporters[i])) {
                return false;
            }
        }

        bytes32 cspComponentId = keccak256(abi.encodePacked("STRATEGY", config.adapter));
        if (
            accounting.activeComponentCount() != 2 || accounting.activeComponentAt(0) != FundConstants.IDLE_COMPONENT_ID
                || accounting.activeComponentAt(1) != cspComponentId
        ) return false;
        FundAccounting.ComponentState memory idle = accounting.componentState(FundConstants.IDLE_COMPONENT_ID);
        FundAccounting.ComponentState memory csp = accounting.componentState(cspComponentId);
        if (
            idle.valuator != address(0) || idle.interfaceVersion != 1 || !idle.active || csp.valuator != config.valuator
                || csp.interfaceVersion != config.adapterInterfaceVersion || !csp.active
        ) return false;

        FundFlowManager flowManager = FundFlowManager(config.flowManager);
        (uint16 maxExitFeeBps, uint16 maxWindowOutflowBps) = flowManager.exitPolicy();
        (address inKindEscrow, address emergencyEscrow) = flowManager.strategyExitEscrows();
        if (
            maxExitFeeBps != config.maxExitFeeBps || maxWindowOutflowBps != config.maxWindowOutflowBps
                || inKindEscrow != config.inKindEscrow || emergencyEscrow != config.emergencyEscrow
        ) return false;

        StrategyManager strategyManager = StrategyManager(config.strategyManager);
        FundTypes.StrategyConfig memory strategy = strategyManager.strategyConfig(config.adapter);
        return strategyManager.activeAdapterCount() == 1 && strategyManager.activeAdapterAt(0) == config.adapter
            && strategyManager.minimumIdleBps() == config.minimumIdleBps
            && strategy.maxAllocationBps <= config.maxAllocationBps && strategy.maxLossBps == config.maxLossBps
            && strategy.cooldown == config.cooldown && strategy.interfaceVersion == config.adapterInterfaceVersion
            && strategy.valuator == config.valuator && strategy.absoluteCap <= config.absoluteCap;
    }

    function _isActivationPhaseFinalized(address strategyManager, address adapter) internal view returns (bool) {
        return StrategyManager(strategyManager).strategyConfig(adapter).active;
    }

    function _scheduleOperations(
        AccessManager manager,
        Operation[] memory operations,
        uint256 callerKey,
        bool phaseFinalized
    ) internal {
        require(operations.length != 0, "B1N352: empty phase");
        address caller = vm.addr(callerKey);
        bytes[] memory calls = new bytes[](operations.length);
        uint256 scheduledCount;
        uint256 seenCount;
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(caller, operations[i].target, operations[i].data);
            uint48 readyAt = manager.getSchedule(operationId);
            if (manager.getNonce(operationId) != 0) ++seenCount;
            if (readyAt != 0) {
                ++scheduledCount;
                _logScheduledOperation(operations[i], operationId, manager.getNonce(operationId), readyAt);
            }
            calls[i] = abi.encodeCall(manager.schedule, (operations[i].target, operations[i].data, uint48(0)));
        }
        if (phaseFinalized) {
            require(scheduledCount == 0, "B1N352: finalized phase still scheduled");
            console2.log("PHASE_ALREADY_FINALIZED");
            return;
        }
        require(scheduledCount == 0 || scheduledCount == operations.length, "B1N352: partial phase schedule");
        if (scheduledCount == operations.length) return;
        require(seenCount == 0, "B1N352: explicit phase restart required");

        vm.startBroadcast(callerKey);
        bytes[] memory results = manager.multicall(calls);
        vm.stopBroadcast();

        for (uint256 i; i < operations.length; ++i) {
            (bytes32 operationId, uint32 nonce) = abi.decode(results[i], (bytes32, uint32));
            _logScheduledOperation(operations[i], operationId, nonce, manager.getSchedule(operationId));
        }
    }

    function _restartOperations(
        AccessManager manager,
        Operation[] memory operations,
        address scheduledCaller,
        uint256 restartCallerKey,
        bool phaseFinalized
    ) internal {
        require(operations.length != 0, "B1N352: empty phase");
        require(scheduledCaller != address(0), "B1N352: zero phase scheduler");
        require(vm.addr(restartCallerKey) == scheduledCaller, "B1N352: restart caller differs");
        require(!phaseFinalized, "B1N352: phase already finalized");

        uint256 liveCount;
        uint256 seenCount;
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(scheduledCaller, operations[i].target, operations[i].data);
            if (manager.getNonce(operationId) != 0) ++seenCount;
            if (manager.getSchedule(operationId) != 0) ++liveCount;
        }
        require(seenCount == operations.length, "B1N352: inconsistent phase nonce history");

        bytes[] memory calls = new bytes[](liveCount + operations.length);
        uint256 cursor;
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(scheduledCaller, operations[i].target, operations[i].data);
            if (manager.getSchedule(operationId) == 0) continue;
            calls[cursor++] =
                abi.encodeCall(manager.cancel, (scheduledCaller, operations[i].target, operations[i].data));
        }
        for (uint256 i; i < operations.length; ++i) {
            calls[cursor++] = abi.encodeCall(manager.schedule, (operations[i].target, operations[i].data, uint48(0)));
        }

        vm.startBroadcast(restartCallerKey);
        bytes[] memory results = manager.multicall(calls);
        vm.stopBroadcast();

        address restartCaller = vm.addr(restartCallerKey);
        for (uint256 i; i < operations.length; ++i) {
            (bytes32 operationId, uint32 nonce) = abi.decode(results[liveCount + i], (bytes32, uint32));
            require(
                operationId == manager.hashOperation(restartCaller, operations[i].target, operations[i].data),
                "B1N352: restarted operation id"
            );
            _logScheduledOperation(operations[i], operationId, nonce, manager.getSchedule(operationId));
        }
        console2.log("PHASE_ATOMICALLY_RESTARTED");
    }

    function _executeOperations(
        AccessManager manager,
        Operation[] memory operations,
        uint256 callerKey,
        bool phaseFinalized
    ) internal {
        require(operations.length != 0, "B1N352: empty phase");
        address caller = vm.addr(callerKey);
        bytes[] memory calls = new bytes[](operations.length);
        uint256 scheduledCount;
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(caller, operations[i].target, operations[i].data);
            uint48 readyAt = manager.getSchedule(operationId);
            if (readyAt != 0) ++scheduledCount;
            calls[i] = abi.encodeCall(manager.execute, (operations[i].target, operations[i].data));
        }
        if (phaseFinalized) {
            require(scheduledCount == 0, "B1N352: finalized phase still scheduled");
            console2.log("PHASE_ALREADY_FINALIZED");
            return;
        }
        require(scheduledCount == operations.length, "B1N352: phase operation not scheduled");
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(caller, operations[i].target, operations[i].data);
            require(manager.getSchedule(operationId) <= block.timestamp, "B1N352: phase operation not ready");
        }

        vm.startBroadcast(callerKey);
        manager.multicall(calls);
        vm.stopBroadcast();

        for (uint256 i; i < operations.length; ++i) {
            console2.log("EXECUTED_OPERATION_LABEL");
            console2.logBytes32(operations[i].label);
            console2.log("EXECUTED_OPERATION_TARGET", operations[i].target);
        }
    }

    function _cancelOperations(
        AccessManager manager,
        Operation[] memory operations,
        address scheduledCaller,
        uint256 cancelerKey
    ) internal {
        require(operations.length != 0, "B1N352: empty phase");
        require(scheduledCaller != address(0), "B1N352: zero phase scheduler");
        uint256 scheduledCount;
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(scheduledCaller, operations[i].target, operations[i].data);
            if (manager.getSchedule(operationId) != 0) ++scheduledCount;
        }
        if (scheduledCount == 0) {
            console2.log("PHASE_HAS_NO_LIVE_SCHEDULES");
            return;
        }

        bytes[] memory calls = new bytes[](scheduledCount);
        uint256 cursor;
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(scheduledCaller, operations[i].target, operations[i].data);
            if (manager.getSchedule(operationId) == 0) continue;
            calls[cursor++] =
                abi.encodeCall(manager.cancel, (scheduledCaller, operations[i].target, operations[i].data));
        }

        vm.startBroadcast(cancelerKey);
        manager.multicall(calls);
        vm.stopBroadcast();

        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(scheduledCaller, operations[i].target, operations[i].data);
            require(manager.getSchedule(operationId) == 0, "B1N352: phase cancellation incomplete");
        }
        console2.log("PHASE_LIVE_SCHEDULES_CANCELED", scheduledCount);
    }

    function _phaseSchedulerKey() internal view returns (uint256 callerKey) {
        callerKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(callerKey) == vm.envAddress("FUND_PHASE_SCHEDULER"), "B1N352: phase scheduler key");
    }

    function _isTargetAdminDelayConfigured(FundAccessManager manager, address target) private view returns (bool) {
        (uint32 currentDelay, uint32 pendingDelay, uint48 effect) = manager.getTargetAdminDelayFull(target);
        if (currentDelay == FundConstants.CORE_UPGRADE_DELAY) {
            return pendingDelay == 0 && effect == 0;
        }
        return pendingDelay == FundConstants.CORE_UPGRADE_DELAY && effect > block.timestamp;
    }

    function _logScheduledOperation(Operation memory operation, bytes32 operationId, uint32 nonce, uint48 readyAt)
        private
        pure
    {
        console2.log("SCHEDULED_OPERATION_LABEL");
        console2.logBytes32(operation.label);
        console2.log("SCHEDULED_OPERATION_TARGET", operation.target);
        console2.log("SCHEDULED_OPERATION_ID");
        console2.logBytes32(operationId);
        console2.log("SCHEDULED_OPERATION_NONCE", nonce);
        console2.log("SCHEDULED_OPERATION_READY_AT", readyAt);
    }

    function _targetRoleOperation(
        AccessManager manager,
        address target,
        bytes4 selector,
        uint64 role,
        string memory label
    ) private pure returns (Operation memory operation) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        operation = Operation({
            target: address(manager),
            data: abi.encodeCall(manager.setTargetFunctionRole, (target, selectors, role)),
            label: keccak256(bytes(label))
        });
    }

    function _targetAdminDelayOperation(AccessManager manager, address target, string memory label)
        private
        pure
        returns (Operation memory operation)
    {
        operation = Operation({
            target: address(manager),
            data: abi.encodeCall(manager.setTargetAdminDelay, (target, FundConstants.CORE_UPGRADE_DELAY)),
            label: keccak256(bytes(label))
        });
    }
}
