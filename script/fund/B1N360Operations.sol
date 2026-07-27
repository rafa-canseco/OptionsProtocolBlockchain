// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {IStrategyAssetEscrow} from "../../src/fund/interfaces/IStrategyAssetEscrow.sol";
import {B1N360Base} from "./B1N360Base.sol";

abstract contract B1N360Operations is B1N360Base {
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
        AccessManager manager = AccessManager(manager_);
        operations = new Operation[](5);
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
            ICoveredCallFundAdapter.setAdapterConfig.selector,
            FundConstants.CURATOR_ROLE,
            "ADAPTER_CURATOR_ROLE"
        );
        operations[3] = _targetRoleOperation(
            manager,
            inKindEscrow,
            IStrategyAssetEscrow.releaseToFund.selector,
            FundConstants.CURATOR_ROLE,
            "IN_KIND_ESCROW_CURATOR_ROLE"
        );
        operations[4] = _targetRoleOperation(
            manager,
            emergencyEscrow,
            IStrategyAssetEscrow.releaseToFund.selector,
            FundConstants.CURATOR_ROLE,
            "EMERGENCY_ESCROW_CURATOR_ROLE"
        );
    }

    function _loadPolicyConfig() internal view returns (PolicyConfig memory config) {
        config.accounting = vm.envAddress("FUND_ACCOUNTING_PROXY");
        config.flowManager = vm.envAddress("FUND_FLOW_MANAGER_PROXY");
        config.strategyManager = vm.envAddress("FUND_STRATEGY_MANAGER_PROXY");
        config.adapter = vm.envAddress("FUND_CC_ADAPTER_PROXY");
        config.valuator = vm.envAddress("FUND_CC_VALUATOR");
        config.inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        config.emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        config.reporters = _approvedAddressArray("FUND_NAV_REPORTERS");
        config.reporterThreshold = _approvedUint16("FUND_NAV_REPORTER_THRESHOLD");
        config.reporterSetVersion = _approvedUint64("FUND_NAV_REPORTER_SET_VERSION");
        config.maxExitFeeBps = _approvedUint16("FUND_MAX_EXIT_FEE_BPS");
        config.maxWindowOutflowBps = _approvedUint16("FUND_MAX_WINDOW_OUTFLOW_BPS");
        config.minimumIdleBps = _approvedUint16("FUND_MINIMUM_IDLE_BPS");
        config.maxAllocationBps = _approvedUint16("FUND_STRATEGY_MAX_ALLOCATION_BPS");
        config.maxLossBps = _approvedUint16("FUND_STRATEGY_MAX_LOSS_BPS");
        config.cooldown = _approvedUint32("FUND_STRATEGY_COOLDOWN_SECONDS");
        config.adapterInterfaceVersion = _approvedUint64("FUND_CC_ADAPTER_INTERFACE_VERSION");
        config.absoluteCap = _approvedUint("FUND_STRATEGY_ABSOLUTE_CAP");
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
            label: keccak256("SET_COVERED_CALL_COMPONENT")
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
            label: keccak256("SET_INACTIVE_COVERED_CALL_STRATEGY")
        });
    }

    function _executeImmediateManagerOperations(
        FundAccessManager manager,
        Operation[] memory operations,
        uint256 callerKey,
        bool phaseFinalized
    ) internal {
        require(operations.length != 0, "B1N360: empty access phase");
        if (phaseFinalized) {
            console2.log("ACCESS_PHASE_ALREADY_FINALIZED");
            return;
        }
        address caller = vm.addr(callerKey);
        (bool isAdmin, uint32 adminDelay) = manager.hasRole(manager.ADMIN_ROLE(), caller);
        require(isAdmin && adminDelay == 0, "B1N360: immediate admin unavailable");

        bytes[] memory calls = new bytes[](operations.length);
        for (uint256 i; i < operations.length; ++i) {
            require(operations[i].target == address(manager), "B1N360: non-manager access operation");
            calls[i] = operations[i].data;
        }
        vm.startBroadcast(callerKey);
        manager.multicall(calls);
        vm.stopBroadcast();
    }

    function _executeImmediateOperations(
        AccessManager manager,
        Operation[] memory operations,
        uint256 callerKey,
        bool phaseFinalized
    ) internal {
        require(operations.length != 0, "B1N360: empty policy phase");
        if (phaseFinalized) {
            console2.log("POLICY_PHASE_ALREADY_FINALIZED");
            return;
        }
        bytes[] memory calls = new bytes[](operations.length);
        for (uint256 i; i < operations.length; ++i) {
            calls[i] = abi.encodeCall(manager.execute, (operations[i].target, operations[i].data));
        }
        vm.startBroadcast(callerKey);
        manager.multicall(calls);
        vm.stopBroadcast();
    }

    function _verifyDeployedPolicy(DeployConfig memory deployConfig, PolicyConfig memory policyConfig) internal view {
        FundAccounting accounting = FundAccounting(policyConfig.accounting);
        require(accounting.reporterSetVersion() == policyConfig.reporterSetVersion, "B1N360: reporter version");
        require(accounting.reporterThreshold() == policyConfig.reporterThreshold, "B1N360: reporter threshold");
        require(accounting.activeReporterCount() == policyConfig.reporters.length, "B1N360: reporter count");
        for (uint256 i; i < policyConfig.reporters.length; ++i) {
            require(
                accounting.activeReporterAt(i) == policyConfig.reporters[i]
                    && accounting.isReporter(policyConfig.reporters[i]),
                "B1N360: reporter"
            );
        }
        bytes32 strategyComponentId = keccak256(abi.encodePacked("STRATEGY", policyConfig.adapter));
        require(accounting.activeComponentCount() == 2, "B1N360: component count");
        require(accounting.activeComponentAt(0) == FundConstants.IDLE_COMPONENT_ID, "B1N360: idle component");
        require(accounting.activeComponentAt(1) == strategyComponentId, "B1N360: strategy component");

        FundFlowManager flowManager = FundFlowManager(policyConfig.flowManager);
        (uint16 exitFee, uint16 outflow) = flowManager.exitPolicy();
        require(exitFee == policyConfig.maxExitFeeBps && outflow == policyConfig.maxWindowOutflowBps, "B1N360: exit");
        (address inKindEscrow, address emergencyEscrow) = flowManager.strategyExitEscrows();
        require(
            inKindEscrow == policyConfig.inKindEscrow && emergencyEscrow == policyConfig.emergencyEscrow,
            "B1N360: escrows"
        );

        StrategyManager strategyManager = StrategyManager(policyConfig.strategyManager);
        FundTypes.StrategyConfig memory strategy = strategyManager.strategyConfig(policyConfig.adapter);
        require(
            strategyManager.activeAdapterCount() == 1 && strategyManager.activeAdapterAt(0) == policyConfig.adapter,
            "B1N360: adapter registry"
        );
        require(!strategy.active, "B1N360: strategy active");
        require(
            strategy.maxAllocationBps == policyConfig.maxAllocationBps && strategy.maxLossBps == policyConfig.maxLossBps
                && strategy.cooldown == policyConfig.cooldown
                && strategy.interfaceVersion == policyConfig.adapterInterfaceVersion
                && strategy.valuator == policyConfig.valuator && strategy.absoluteCap == policyConfig.absoluteCap,
            "B1N360: strategy config"
        );
        require(strategyManager.minimumIdleBps() == policyConfig.minimumIdleBps, "B1N360: idle");

        CoveredCallFundAdapter.AdapterConfig memory actual =
            CoveredCallFundAdapter(policyConfig.adapter).adapterConfig();
        ICoveredCallFundAdapter.AdapterConfig memory expected = ICoveredCallFundAdapter.AdapterConfig({
            riskConfig: deployConfig.adapterRiskConfig,
            swapRouter: deployConfig.adapterSwapRouter,
            swapFeeTier: deployConfig.adapterSwapFeeTier
        });
        require(keccak256(abi.encode(actual)) == keccak256(abi.encode(expected)), "B1N360: adapter config");

        CoveredCallFundValuatorV2 valuator = CoveredCallFundValuatorV2(policyConfig.valuator);
        require(
            valuator.spotFeed() == deployConfig.spotFeed && valuator.spotFeedDecimals() == deployConfig.spotFeedDecimals
                && valuator.maxSpotStaleness() == deployConfig.maxSpotStaleness
                && valuator.maxObservationWindow() == deployConfig.maxObservationWindow
                && valuator.observationQuorum() == deployConfig.observationQuorum
                && valuator.liabilityBufferBps() == deployConfig.liabilityBufferBps
                && valuator.valuationPolicyVersion() == 2 && valuator.requiredModelVersion() == 1
                && valuator.maxObservationDivergenceBps() == 500,
            "B1N360: valuator config"
        );
        require(
            valuator.approvedObserverCount() == deployConfig.approvedObservers.length, "B1N360: valuator observer count"
        );
        for (uint256 i; i < deployConfig.approvedObservers.length; ++i) {
            require(
                valuator.approvedObserverAt(i) == deployConfig.approvedObservers[i]
                    && valuator.isApprovedObserver(deployConfig.approvedObservers[i]),
                "B1N360: valuator observer"
            );
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
            && manager.getTargetFunctionRole(adapter, ICoveredCallFundAdapter.setAdapterConfig.selector)
                == FundConstants.CURATOR_ROLE && manager.configuredSelectorCount(inKindEscrow) == 1
            && manager.getTargetFunctionRole(inKindEscrow, IStrategyAssetEscrow.releaseToFund.selector)
                == FundConstants.CURATOR_ROLE && manager.configuredSelectorCount(emergencyEscrow) == 1
            && manager.getTargetFunctionRole(emergencyEscrow, IStrategyAssetEscrow.releaseToFund.selector)
                == FundConstants.CURATOR_ROLE;
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

        bytes32 componentId = keccak256(abi.encodePacked("STRATEGY", config.adapter));
        FundAccounting.ComponentState memory idle = accounting.componentState(FundConstants.IDLE_COMPONENT_ID);
        FundAccounting.ComponentState memory coveredCall = accounting.componentState(componentId);
        if (
            accounting.activeComponentCount() != 2 || accounting.activeComponentAt(0) != FundConstants.IDLE_COMPONENT_ID
                || accounting.activeComponentAt(1) != componentId || !idle.active || idle.valuator != address(0)
                || idle.interfaceVersion != 1 || !coveredCall.active || coveredCall.valuator != config.valuator
                || coveredCall.interfaceVersion != config.adapterInterfaceVersion
        ) return false;

        FundFlowManager flowManager = FundFlowManager(config.flowManager);
        (uint16 exitFee, uint16 outflow) = flowManager.exitPolicy();
        (address inKindEscrow, address emergencyEscrow) = flowManager.strategyExitEscrows();
        if (
            exitFee != config.maxExitFeeBps || outflow != config.maxWindowOutflowBps
                || inKindEscrow != config.inKindEscrow || emergencyEscrow != config.emergencyEscrow
        ) return false;

        StrategyManager strategyManager = StrategyManager(config.strategyManager);
        FundTypes.StrategyConfig memory strategy = strategyManager.strategyConfig(config.adapter);
        return strategyManager.activeAdapterCount() == 1 && strategyManager.activeAdapterAt(0) == config.adapter
            && strategyManager.minimumIdleBps() == config.minimumIdleBps && !strategy.active
            && strategy.maxAllocationBps == config.maxAllocationBps && strategy.maxLossBps == config.maxLossBps
            && strategy.cooldown == config.cooldown && strategy.interfaceVersion == config.adapterInterfaceVersion
            && strategy.valuator == config.valuator && strategy.absoluteCap == config.absoluteCap;
    }

    function _requireOpenDepositsReadiness(FundVault vault, StrategyManager strategyManager, address adapter)
        internal
        view
    {
        require(vm.envBool("FUND_BACKEND_NAV_RECONCILED"), "B1N360: backend NAV not reconciled");
        require(ICoveredCallFundAdapter(adapter).isOnboarded(), "B1N360: adapter not onboarded");
        require(strategyManager.strategyConfig(adapter).active, "B1N360: strategy inactive");
        FundTypes.NavCommit memory nav = vault.activeNavWindow();
        require(
            nav.reportNonce != 0 && block.number >= nav.validAfterBlock && block.number <= nav.validUntilBlock,
            "B1N360: NAV not active"
        );
    }

    function _openDepositsOperation(address vaultAddress) internal pure returns (Operation memory operation) {
        FundVault vault = FundVault(vaultAddress);
        operation = Operation({
            target: vaultAddress,
            data: abi.encodeCall(vault.resumeDeposits, ()),
            label: keccak256("OPEN_B1N360_DEPOSITS")
        });
    }

    function _phaseSchedulerKey() internal view returns (uint256 callerKey) {
        callerKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(callerKey) == _approvedAddress("FUND_PHASE_SCHEDULER"), "B1N360: scheduler key");
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
}
