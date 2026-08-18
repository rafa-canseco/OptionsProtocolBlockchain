// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

contract ScheduleB1N352Activation is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        require(ICspFundAdapter(adapter).isOnboarded(), "B1N352: adapter not onboarded");
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        Operation[] memory operations = new Operation[](1);
        address strategyManager = vm.envAddress("FUND_STRATEGY_MANAGER_PROXY");
        operations[0] = _activationOperation(strategyManager, adapter);
        console2.log(
            "FUND_SCHEDULED_ALLOCATION_PAUSE_NONCE", StrategyManager(strategyManager).allocationPauseNonce(adapter)
        );
        _scheduleOperations(
            manager, operations, _phaseSchedulerKey(), _isActivationPhaseFinalized(strategyManager, adapter)
        );
    }
}

contract RestartB1N352Activation is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        require(ICspFundAdapter(adapter).isOnboarded(), "B1N352: adapter not onboarded");
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        address strategyManager = vm.envAddress("FUND_STRATEGY_MANAGER_PROXY");
        uint64 priorPauseNonce = _envUint64("FUND_SCHEDULED_ALLOCATION_PAUSE_NONCE");
        uint64 currentPauseNonce = StrategyManager(strategyManager).allocationPauseNonce(adapter);
        Operation memory priorOperation = _activationOperationAtPauseNonce(strategyManager, adapter, priorPauseNonce);
        Operation memory replacementOperation =
            _activationOperationAtPauseNonce(strategyManager, adapter, currentPauseNonce);
        if (priorPauseNonce == currentPauseNonce) {
            Operation[] memory operations = new Operation[](1);
            operations[0] = priorOperation;
            _restartOperations(
                manager,
                operations,
                _approvedAddress("FUND_PHASE_SCHEDULER"),
                _phaseSchedulerKey(),
                _isActivationPhaseFinalized(strategyManager, adapter)
            );
        } else {
            _replaceOperation(
                manager,
                priorOperation,
                replacementOperation,
                _approvedAddress("FUND_PHASE_SCHEDULER"),
                _phaseSchedulerKey(),
                _isActivationPhaseFinalized(strategyManager, adapter)
            );
            console2.log("FUND_SCHEDULED_ALLOCATION_PAUSE_NONCE", currentPauseNonce);
        }
    }
}

contract CancelB1N352Activation is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        Operation[] memory operations = new Operation[](1);
        operations[0] = _activationOperationAtPauseNonce(
            vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"), adapter, _envUint64("FUND_SCHEDULED_ALLOCATION_PAUSE_NONCE")
        );
        _cancelOperations(manager, operations, _approvedAddress("FUND_PHASE_SCHEDULER"), vm.envUint("PRIVATE_KEY"));
    }
}

contract ExecuteB1N352Activation is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        require(ICspFundAdapter(adapter).isOnboarded(), "B1N352: adapter not onboarded");
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        Operation[] memory operations = new Operation[](1);
        address strategyManager = vm.envAddress("FUND_STRATEGY_MANAGER_PROXY");
        uint64 scheduledPauseNonce = _envUint64("FUND_SCHEDULED_ALLOCATION_PAUSE_NONCE");
        bool phaseFinalized = _isActivationPhaseFinalized(strategyManager, adapter);
        if (!phaseFinalized) {
            require(
                StrategyManager(strategyManager).allocationPauseNonce(adapter) == scheduledPauseNonce,
                "B1N352: stale activation schedule"
            );
        }
        operations[0] = _activationOperationAtPauseNonce(strategyManager, adapter, scheduledPauseNonce);
        _executeOperations(manager, operations, _phaseSchedulerKey(), phaseFinalized);
    }
}
