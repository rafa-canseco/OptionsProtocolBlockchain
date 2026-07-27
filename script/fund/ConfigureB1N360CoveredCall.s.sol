// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {B1N360Operations} from "./B1N360Operations.sol";

contract ConfigureB1N360Access is B1N360Operations {
    function run() external {
        _requireBaseSepolia();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        address adapter = vm.envAddress("FUND_CC_ADAPTER_PROXY");
        address inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        address emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        _executeImmediateManagerOperations(
            manager,
            _accessOperations(address(manager), adapter, inKindEscrow, emergencyEscrow),
            _phaseSchedulerKey(),
            _isAccessPhaseFinalized(manager, adapter, inKindEscrow, emergencyEscrow)
        );
        require(_isAccessPhaseFinalized(manager, adapter, inKindEscrow, emergencyEscrow), "B1N360: access incomplete");
    }
}

contract ConfigureB1N360Policy is B1N360Operations {
    function run() external {
        _requireBaseSepolia();
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        PolicyConfig memory config = _loadPolicyConfig();
        _executeImmediateOperations(
            manager, _policyOperations(config), _phaseSchedulerKey(), _isPolicyPhaseFinalized(config)
        );
        require(_isPolicyPhaseFinalized(config), "B1N360: policy incomplete");
        _verifyDeployedPolicy(_loadDeployConfig(), config);
    }
}
