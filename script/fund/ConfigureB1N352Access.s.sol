// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

contract ScheduleB1N352Access is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        Operation[] memory operations = _accessOperations(
            address(manager),
            vm.envAddress("FUND_CSP_ADAPTER_PROXY"),
            vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW"),
            vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW")
        );
        _scheduleOperations(manager, operations, vm.envUint("PRIVATE_KEY"));
    }
}

contract ExecuteB1N352Access is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        Operation[] memory operations = _accessOperations(
            address(manager),
            vm.envAddress("FUND_CSP_ADAPTER_PROXY"),
            vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW"),
            vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW")
        );
        _executeOperations(manager, operations, vm.envUint("PRIVATE_KEY"));
    }
}
