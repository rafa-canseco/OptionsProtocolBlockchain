// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

contract ScheduleB1N352Access is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        address inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        address emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        Operation[] memory operations = _accessOperations(address(manager), adapter, inKindEscrow, emergencyEscrow);
        _scheduleOperations(
            manager,
            operations,
            _phaseSchedulerKey(),
            _isAccessPhaseFinalized(manager, adapter, inKindEscrow, emergencyEscrow)
        );
    }
}

contract RestartB1N352Access is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        address inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        address emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        _restartOperations(
            manager,
            _accessOperations(address(manager), adapter, inKindEscrow, emergencyEscrow),
            _approvedAddress("FUND_PHASE_SCHEDULER"),
            _phaseSchedulerKey(),
            _isAccessPhaseFinalized(manager, adapter, inKindEscrow, emergencyEscrow)
        );
    }
}

contract CancelB1N352Access is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        _cancelOperations(
            manager,
            _accessOperations(
                address(manager),
                vm.envAddress("FUND_CSP_ADAPTER_PROXY"),
                vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW"),
                vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW")
            ),
            _approvedAddress("FUND_PHASE_SCHEDULER"),
            vm.envUint("PRIVATE_KEY")
        );
    }
}

contract ExecuteB1N352Access is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        address inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        address emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        Operation[] memory operations = _accessOperations(address(manager), adapter, inKindEscrow, emergencyEscrow);
        _executeOperations(
            manager,
            operations,
            _phaseSchedulerKey(),
            _isAccessPhaseFinalized(manager, adapter, inKindEscrow, emergencyEscrow)
        );
    }
}
