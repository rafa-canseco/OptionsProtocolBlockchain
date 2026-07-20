// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

contract ScheduleB1N352Policy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        PolicyConfig memory config = _loadPolicyConfig();
        _scheduleOperations(manager, _policyOperations(config), _phaseSchedulerKey(), _isPolicyPhaseFinalized(config));
    }
}

contract RestartB1N352Policy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        PolicyConfig memory config = _loadPolicyConfig();
        _restartOperations(
            manager,
            _policyOperations(config),
            _approvedAddress("FUND_PHASE_SCHEDULER"),
            _phaseSchedulerKey(),
            _isPolicyPhaseFinalized(config)
        );
    }
}

contract CancelB1N352Policy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        _cancelOperations(
            manager,
            _policyOperations(_loadPolicyConfig()),
            _approvedAddress("FUND_PHASE_SCHEDULER"),
            vm.envUint("PRIVATE_KEY")
        );
    }
}

contract ExecuteB1N352Policy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        PolicyConfig memory config = _loadPolicyConfig();
        _executeOperations(manager, _policyOperations(config), _phaseSchedulerKey(), _isPolicyPhaseFinalized(config));
    }
}
