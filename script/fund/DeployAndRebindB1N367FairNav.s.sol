// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {B1N367Base} from "./B1N367Base.sol";

/// @notice Deploys only the B1N-367 fair-NAV valuator. It never upgrades or reconfigures the CSP adapter.
contract DeployB1N367FairNavValuator is B1N367Base {
    function run() external returns (address deployed) {
        _requireApprovedBaseSepolia();
        FairNavConfig memory config = _loadFairNavConfig();
        _requireApprovedPolicy(config);
        uint256 deployerKey = _phaseSchedulerKey(config);

        vm.startBroadcast(deployerKey);
        deployed = address(
            new CspFundValuatorV2(
                config.spotFeed,
                config.spotFeedDecimals,
                config.maxSpotStaleness,
                config.maxObservationWindow,
                config.observationQuorum,
                config.approvedObservers
            )
        );
        vm.stopBroadcast();

        _requireFairPolicy(CspFundValuatorV2(deployed), config);
        console2.log("FUND_CSP_FAIR_NAV_VALUATOR", deployed);
    }

    function _requireApprovedPolicy(FairNavConfig memory config) private pure {
        require(config.spotFeedDecimals == 8, "B1N367: decimals");
        require(config.maxSpotStaleness == 1 hours, "B1N367: staleness");
        require(config.maxObservationWindow == 120, "B1N367: window");
        require(config.observationQuorum == 2, "B1N367: quorum");
        require(config.approvedObservers.length == 2, "B1N367: observers");
    }

    function _requireFairPolicy(CspFundValuatorV2 valuator, FairNavConfig memory config) private view {
        require(valuator.interfaceVersion() == 1, "B1N367: interface");
        require(valuator.valuationPolicyVersion() == 2, "B1N367: policy");
        require(valuator.requiredModelVersion() == 1, "B1N367: model");
        require(valuator.maxObservationDivergenceBps() == 500, "B1N367: divergence");
        require(valuator.observationQuorum() == config.observationQuorum, "B1N367: quorum");
        require(valuator.approvedObserverCount() == config.approvedObservers.length, "B1N367: observers");
        for (uint256 i; i < config.approvedObservers.length; ++i) {
            require(valuator.approvedObserverAt(i) == config.approvedObservers[i], "B1N367: observer order");
        }
    }
}

/// @notice Atomically rebinds the accounting component and existing strategy to a deployed fair-NAV valuator.
/// @dev Base Sepolia's B1N-352 v2 authority grants CURATOR_ROLE with zero execution delay. Deposits and allocation
///      state are preserved; the coordinated reporter must immediately replace the previously committed NAV.
contract RebindB1N367FairNavValuator is B1N367Base {
    function run() external {
        _requireApprovedBaseSepolia();
        FairNavConfig memory policy = _loadFairNavConfig();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        address valuatorAddress = vm.envAddress("FUND_CSP_VALUATOR");
        address priorValuator = vm.envAddress("FUND_CSP_PREVIOUS_VALUATOR");
        FundAccounting accounting = FundAccounting(vm.envAddress("FUND_ACCOUNTING_PROXY"));
        StrategyManager strategyManager = StrategyManager(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"));
        FundVault vault = FundVault(vm.envAddress("FUND_VAULT_PROXY"));
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));

        _requireFairPolicy(CspFundValuatorV2(valuatorAddress), policy);
        bytes32 componentId = keccak256(abi.encodePacked("STRATEGY", adapter));
        FundTypes.StrategyConfig memory prior = strategyManager.strategyConfig(adapter);
        FundAccounting.ComponentState memory component = accounting.componentState(componentId);
        require(prior.interfaceVersion == 1 && component.interfaceVersion == 1, "B1N367: interface");
        require(
            (prior.valuator == priorValuator && component.valuator == priorValuator)
                || (prior.valuator == valuatorAddress && component.valuator == valuatorAddress),
            "B1N367: unexpected prior valuator"
        );
        bool finalized = component.active && prior.valuator == valuatorAddress && component.valuator == valuatorAddress;
        if (finalized) {
            console2.log("PHASE_ALREADY_FINALIZED");
            return;
        }

        bool depositsPausedBefore = vault.depositsPaused();
        uint64 allocationPauseNonceBefore = strategyManager.allocationPauseNonce(adapter);
        uint256 callerKey = _phaseSchedulerKey(policy);
        (bool isCurator, uint32 executionDelay) = manager.hasRole(FundConstants.CURATOR_ROLE, vm.addr(callerKey));
        require(isCurator && executionDelay == 0, "B1N367: immediate curator unavailable");

        FundTypes.StrategyConfig memory replacement = prior;
        replacement.valuator = valuatorAddress;
        bytes memory componentCall =
            abi.encodeCall(accounting.setComponent, (componentId, valuatorAddress, uint64(1), true));
        bytes memory strategyCall = abi.encodeCall(strategyManager.setStrategyConfig, (adapter, replacement));
        require(manager.getSchedule(manager.hashOperation(vm.addr(callerKey), address(accounting), componentCall)) == 0);
        require(
            manager.getSchedule(manager.hashOperation(vm.addr(callerKey), address(strategyManager), strategyCall)) == 0
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(manager.execute, (address(accounting), componentCall));
        calls[1] = abi.encodeCall(manager.execute, (address(strategyManager), strategyCall));
        vm.startBroadcast(callerKey);
        manager.multicall(calls);
        vm.stopBroadcast();

        component = accounting.componentState(componentId);
        FundTypes.StrategyConfig memory afterConfig = strategyManager.strategyConfig(adapter);
        require(component.active && component.valuator == valuatorAddress, "B1N367: component rebind");
        require(keccak256(abi.encode(afterConfig)) == keccak256(abi.encode(replacement)), "B1N367: strategy rebind");
        require(afterConfig.active == prior.active, "B1N367: strategy active changed");
        require(vault.depositsPaused() == depositsPausedBefore, "B1N367: deposit state changed");
        require(
            strategyManager.allocationPauseNonce(adapter) == allocationPauseNonceBefore,
            "B1N367: allocation pause changed"
        );
    }

    function _requireFairPolicy(CspFundValuatorV2 valuator, FairNavConfig memory config) private view {
        require(address(valuator).code.length != 0, "B1N367: valuator code");
        require(valuator.interfaceVersion() == 1, "B1N367: interface");
        require(valuator.valuationPolicyVersion() == 2, "B1N367: policy");
        require(valuator.requiredModelVersion() == 1, "B1N367: model");
        require(valuator.maxObservationDivergenceBps() == 500, "B1N367: divergence");
        require(valuator.observationQuorum() == config.observationQuorum, "B1N367: quorum");
        require(valuator.spotFeed() == config.spotFeed, "B1N367: spot feed");
        require(valuator.spotFeedDecimals() == config.spotFeedDecimals, "B1N367: spot decimals");
        require(valuator.maxSpotStaleness() == config.maxSpotStaleness, "B1N367: spot staleness");
        require(valuator.maxObservationWindow() == config.maxObservationWindow, "B1N367: observation window");
        require(valuator.approvedObserverCount() == config.approvedObservers.length, "B1N367: observers");
        for (uint256 i; i < config.approvedObservers.length; ++i) {
            require(valuator.approvedObserverAt(i) == config.approvedObservers[i], "B1N367: observer order");
        }
    }
}
