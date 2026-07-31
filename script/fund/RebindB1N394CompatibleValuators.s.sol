// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundAccountingStorage} from "../../src/fund/storage/FundAccountingStorage.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {B1N394Base} from "./B1N394Base.sol";

/// @notice Rebinds only the paused strategy valuators while retaining all component and strategy state.
contract RebindB1N394CompatibleValuators is B1N394Base {
    function run() external {
        _requireBaseSepolia();
        address broadcaster = vm.envAddress("B1N394_BROADCASTER");
        address cspPrior = vm.envAddress("B1N394_CSP_PREVIOUS_VALUATOR");
        address ccPrior = vm.envAddress("B1N394_CC_PREVIOUS_VALUATOR");
        address cspReplacement = vm.envAddress("B1N394_CSP_VALUATOR");
        address ccReplacement = vm.envAddress("B1N394_CC_VALUATOR");

        _requireMatchingPolicy(cspPrior, cspReplacement);
        _requireMatchingPolicy(ccPrior, ccReplacement);
        require(CspFundValuatorV2(cspReplacement).liabilityBufferBps() == 0, "B1N394: CSP buffer");
        require(CoveredCallFundValuatorV2(ccReplacement).liabilityBufferBps() == 0, "B1N394: CC buffer");

        _rebind(
            AccessManager(CSP_ACCESS),
            broadcaster,
            FundAccounting(CSP_ACCOUNTING),
            StrategyManager(CSP_MANAGER),
            CSP_ADAPTER,
            cspPrior,
            cspReplacement
        );
        _rebind(
            AccessManager(CC_ACCESS),
            broadcaster,
            FundAccounting(CC_ACCOUNTING),
            StrategyManager(CC_MANAGER),
            CC_ADAPTER,
            ccPrior,
            ccReplacement
        );
    }

    function _rebind(
        AccessManager access,
        address broadcaster,
        FundAccounting accounting,
        StrategyManager manager,
        address adapter,
        address prior,
        address replacement
    ) private {
        _requireImmediateRole(access, FundConstants.CURATOR_ROLE, broadcaster);
        FundTypes.StrategyConfig memory configBefore = manager.strategyConfig(adapter);
        bytes32 componentId = accounting.strategyComponentId(adapter);
        FundAccountingStorage.ComponentState memory componentBefore = accounting.componentState(componentId);
        require(!configBefore.active && configBefore.valuator == prior, "B1N394: prior strategy");
        require(
            componentBefore.active && componentBefore.valuator == prior
                && componentBefore.interfaceVersion == configBefore.interfaceVersion,
            "B1N394: prior component"
        );

        FundTypes.StrategyConfig memory replacementConfig = configBefore;
        replacementConfig.valuator = replacement;
        bytes[] memory calls = new bytes[](2);
        calls[0] = _managedCall(
            access,
            broadcaster,
            address(accounting),
            abi.encodeCall(accounting.setComponent, (componentId, replacement, componentBefore.interfaceVersion, true)),
            FundConstants.CURATOR_ROLE
        );
        calls[1] = _managedCall(
            access,
            broadcaster,
            address(manager),
            abi.encodeCall(manager.setStrategyConfig, (adapter, replacementConfig)),
            FundConstants.CURATOR_ROLE
        );

        vm.startBroadcast(broadcaster);
        access.multicall(calls);
        vm.stopBroadcast();

        FundTypes.StrategyConfig memory configAfter = manager.strategyConfig(adapter);
        FundAccountingStorage.ComponentState memory componentAfter = accounting.componentState(componentId);
        require(!configAfter.active && configAfter.valuator == replacement, "B1N394: rebound strategy");
        require(configAfter.maxAllocationBps == configBefore.maxAllocationBps, "B1N394: allocation cap");
        require(configAfter.maxLossBps == configBefore.maxLossBps, "B1N394: loss cap");
        require(configAfter.cooldown == configBefore.cooldown, "B1N394: cooldown");
        require(configAfter.interfaceVersion == configBefore.interfaceVersion, "B1N394: interface");
        require(configAfter.absoluteCap == configBefore.absoluteCap, "B1N394: absolute cap");
        require(
            componentAfter.valuator == replacement
                && componentAfter.interfaceVersion == componentBefore.interfaceVersion
                && componentAfter.nonce == componentBefore.nonce
                && componentAfter.positionStateHash == componentBefore.positionStateHash
                && componentAfter.active == componentBefore.active,
            "B1N394: component state changed"
        );
    }
}
