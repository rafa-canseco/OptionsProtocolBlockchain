// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
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
        config.reporterThreshold = uint16(vm.envUint("FUND_NAV_REPORTER_THRESHOLD"));
        config.reporterSetVersion = uint64(vm.envUint("FUND_NAV_REPORTER_SET_VERSION"));
        config.maxExitFeeBps = uint16(vm.envUint("FUND_MAX_EXIT_FEE_BPS"));
        config.maxWindowOutflowBps = uint16(vm.envUint("FUND_MAX_WINDOW_OUTFLOW_BPS"));
        config.minimumIdleBps = uint16(vm.envUint("FUND_MINIMUM_IDLE_BPS"));
        config.maxAllocationBps = uint16(vm.envUint("FUND_STRATEGY_MAX_ALLOCATION_BPS"));
        config.maxLossBps = uint16(vm.envUint("FUND_STRATEGY_MAX_LOSS_BPS"));
        config.cooldown = uint32(vm.envUint("FUND_STRATEGY_COOLDOWN_SECONDS"));
        config.adapterInterfaceVersion = uint64(vm.envUint("FUND_CSP_ADAPTER_INTERFACE_VERSION"));
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
        require(config.interfaceVersion != 0 && !config.active, "B1N352: activation state");
        config.active = true;
        operation = Operation({
            target: strategyManager_,
            data: abi.encodeCall(strategyManager.setStrategyConfig, (adapter, config)),
            label: keccak256("ACTIVATE_CSP_STRATEGY")
        });
    }

    function _scheduleOperations(AccessManager manager, Operation[] memory operations, uint256 callerKey) internal {
        vm.startBroadcast(callerKey);
        for (uint256 i; i < operations.length; ++i) {
            (bytes32 operationId, uint32 nonce) = manager.schedule(operations[i].target, operations[i].data, 0);
            console2.log("SCHEDULED_OPERATION_LABEL");
            console2.logBytes32(operations[i].label);
            console2.log("SCHEDULED_OPERATION_TARGET", operations[i].target);
            console2.log("SCHEDULED_OPERATION_ID");
            console2.logBytes32(operationId);
            console2.log("SCHEDULED_OPERATION_NONCE", nonce);
        }
        vm.stopBroadcast();
    }

    function _executeOperations(AccessManager manager, Operation[] memory operations, uint256 callerKey) internal {
        vm.startBroadcast(callerKey);
        for (uint256 i; i < operations.length; ++i) {
            manager.execute(operations[i].target, operations[i].data);
            console2.log("EXECUTED_OPERATION_LABEL");
            console2.logBytes32(operations[i].label);
            console2.log("EXECUTED_OPERATION_TARGET", operations[i].target);
        }
        vm.stopBroadcast();
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
