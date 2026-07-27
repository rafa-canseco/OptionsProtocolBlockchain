// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {B1N360Operations} from "./B1N360Operations.sol";

abstract contract B1N360FinalWorkerBase is B1N360Operations {
    function _workers() internal view returns (address scheduler, address allocator, address processor) {
        scheduler = _approvedAddress("FUND_PHASE_SCHEDULER");
        allocator = _approvedAddress("FUND_FINAL_ALLOCATOR");
        processor = _approvedAddress("FUND_FINAL_PROCESSOR");
        require(allocator != address(0) && processor != address(0), "B1N360: zero worker");
        require(allocator != scheduler && processor != scheduler, "B1N360: worker is scheduler");
    }
}

/// @notice Read-only handoff. B1N-362 should review this calldata only after NAV/keeper readiness.
contract PrepareB1N360WorkersAndActivation is B1N360FinalWorkerBase {
    function run() external view {
        _requireBaseSepolia();
        (address scheduler, address allocator, address processor) = _workers();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        StrategyManager strategyManager = StrategyManager(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"));
        address adapter = vm.envAddress("FUND_CC_ADAPTER_PROXY");
        uint64 pauseNonce = strategyManager.allocationPauseNonce(adapter);

        console2.log("FINAL_ALLOCATOR", allocator);
        console2.log("FINAL_PROCESSOR", processor);
        console2.log("ALLOCATION_PAUSE_NONCE", pauseNonce);
        console2.log("GRANT_ALLOCATOR_CALLDATA");
        console2.logBytes(abi.encodeCall(manager.grantRole, (FundConstants.ALLOCATOR_ROLE, allocator, uint32(0))));
        console2.log("GRANT_PROCESSOR_CALLDATA");
        console2.logBytes(abi.encodeCall(manager.grantRole, (FundConstants.PROCESSOR_ROLE, processor, uint32(0))));
        console2.log("REVOKE_SCHEDULER_ALLOCATOR_CALLDATA");
        console2.logBytes(abi.encodeCall(manager.revokeRole, (FundConstants.ALLOCATOR_ROLE, scheduler)));
        console2.log("REVOKE_SCHEDULER_PROCESSOR_CALLDATA");
        console2.logBytes(abi.encodeCall(manager.revokeRole, (FundConstants.PROCESSOR_ROLE, scheduler)));
        console2.log("RESUME_ALLOCATION_TARGET", address(strategyManager));
        console2.log("RESUME_ALLOCATION_CALLDATA");
        console2.logBytes(abi.encodeCall(strategyManager.resumeAllocation, (adapter, pauseNonce)));
    }
}

/// @notice Finalizes worker roles without activating the allocator. Safe to run before backend readiness.
contract FinalizeB1N360Workers is B1N360FinalWorkerBase {
    function run() external {
        _requireBaseSepolia();
        (address scheduler, address allocator, address processor) = _workers();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        uint256 broadcasterKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(broadcasterKey) == scheduler, "B1N360: scheduler key");

        vm.startBroadcast(broadcasterKey);
        manager.grantRole(FundConstants.ALLOCATOR_ROLE, allocator, 0);
        manager.grantRole(FundConstants.PROCESSOR_ROLE, processor, 0);
        manager.revokeRole(FundConstants.ALLOCATOR_ROLE, scheduler);
        manager.revokeRole(FundConstants.PROCESSOR_ROLE, scheduler);
        vm.stopBroadcast();

        (bool allocatorActive, uint32 allocatorDelay) = manager.hasRole(FundConstants.ALLOCATOR_ROLE, allocator);
        (bool processorActive, uint32 processorDelay) = manager.hasRole(FundConstants.PROCESSOR_ROLE, processor);
        (bool schedulerAllocator,) = manager.hasRole(FundConstants.ALLOCATOR_ROLE, scheduler);
        (bool schedulerProcessor,) = manager.hasRole(FundConstants.PROCESSOR_ROLE, scheduler);
        require(allocatorActive && allocatorDelay == 0, "B1N360: allocator role");
        require(processorActive && processorDelay == 0, "B1N360: processor role");
        require(!schedulerAllocator && !schedulerProcessor, "B1N360: scheduler worker role");
    }
}

/// @notice B1N-362 activation phase. Do not run until coherent NAV and worker readiness are proven.
contract ActivateB1N360CoveredCall is B1N360FinalWorkerBase {
    function run() external {
        _requireBaseSepolia();
        (, address allocator, address processor) = _workers();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        StrategyManager strategyManager = StrategyManager(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"));
        FundVault vault = FundVault(vm.envAddress("FUND_VAULT_PROXY"));
        address adapter = vm.envAddress("FUND_CC_ADAPTER_PROXY");
        bool depositsPausedBefore = vault.depositsPaused();
        uint256 allocatorKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(allocatorKey) == allocator, "B1N360: allocator key");
        (bool allocatorActive, uint32 allocatorDelay) = manager.hasRole(FundConstants.ALLOCATOR_ROLE, allocator);
        (bool processorActive, uint32 processorDelay) = manager.hasRole(FundConstants.PROCESSOR_ROLE, processor);
        require(allocatorActive && allocatorDelay == 0, "B1N360: allocator not ready");
        require(processorActive && processorDelay == 0, "B1N360: processor not ready");

        if (!strategyManager.strategyConfig(adapter).active) {
            vm.startBroadcast(allocatorKey);
            strategyManager.resumeAllocation(adapter, strategyManager.allocationPauseNonce(adapter));
            vm.stopBroadcast();
        }
        require(strategyManager.strategyConfig(adapter).active, "B1N360: activation failed");
        require(vault.depositsPaused() == depositsPausedBefore, "B1N360: activation changed deposits");
    }
}

/// @notice Explicit final gate. Run only after backend reconciliation confirms a currently active NAV.
contract OpenB1N360Deposits is B1N360FinalWorkerBase {
    function run() external {
        _requireBaseSepolia();
        FundVault vault = FundVault(vm.envAddress("FUND_VAULT_PROXY"));
        if (!vault.depositsPaused()) {
            console2.log("PHASE_ALREADY_FINALIZED");
            return;
        }
        StrategyManager strategyManager = StrategyManager(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"));
        address adapter = vm.envAddress("FUND_CC_ADAPTER_PROXY");
        _requireOpenDepositsReadiness(vault, strategyManager, adapter);

        Operation[] memory operations = new Operation[](1);
        operations[0] = _openDepositsOperation(address(vault));
        _executeImmediateOperations(
            FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER")), operations, _phaseSchedulerKey(), false
        );
        require(!vault.depositsPaused(), "B1N360: deposits still paused");
    }
}
