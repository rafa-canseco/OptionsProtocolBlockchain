// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

contract ScheduleB1N352Policy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        _scheduleOperations(manager, _policyOperations(_loadPolicyConfig()), vm.envUint("PRIVATE_KEY"));
    }
}

contract ExecuteB1N352Policy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        _executeOperations(manager, _policyOperations(_loadPolicyConfig()), vm.envUint("PRIVATE_KEY"));
    }
}
