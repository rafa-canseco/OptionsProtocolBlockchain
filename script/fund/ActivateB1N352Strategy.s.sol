// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
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
        Operation[] memory operations = new Operation[](1);
        operations[0] = _activationOperation(strategyManager, adapter);
        _restartOperations(
            manager,
            operations,
            vm.envAddress("FUND_PHASE_SCHEDULER"),
            _phaseSchedulerKey(),
            _isActivationPhaseFinalized(strategyManager, adapter)
        );
    }
}

contract CancelB1N352Activation is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        Operation[] memory operations = new Operation[](1);
        operations[0] = _activationOperation(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"), adapter);
        _cancelOperations(manager, operations, vm.envAddress("FUND_PHASE_SCHEDULER"), vm.envUint("PRIVATE_KEY"));
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
        operations[0] = _activationOperation(strategyManager, adapter);
        _executeOperations(
            manager, operations, _phaseSchedulerKey(), _isActivationPhaseFinalized(strategyManager, adapter)
        );
    }
}
