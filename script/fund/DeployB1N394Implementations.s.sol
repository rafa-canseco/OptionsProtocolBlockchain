// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {CspFundAdapterOperations} from "../../src/fund/libraries/CspFundAdapterOperations.sol";
import {CoveredCallFundAdapterOperations} from "../../src/fund/libraries/CoveredCallFundAdapterOperations.sol";
import {B1N394Base, IB1N394ValuatorPolicy} from "./B1N394Base.sol";

/// @notice Deploys the B1N-392 implementations and replacement valuators without touching any proxy.
/// @dev Bind freshly deployed operations libraries with forge's --libraries option.
contract DeployB1N394Implementations is B1N394Base {
    function run() external returns (Implementations memory deployed) {
        _requireBaseSepolia();
        address broadcaster = vm.envAddress("B1N394_BROADCASTER");
        require(BatchSettler(BATCH_SETTLER).owner() == broadcaster, "B1N394: settler owner");
        _requireImmediateRoles(AccessManager(CSP_ACCESS), broadcaster);
        _requireImmediateRoles(AccessManager(CC_ACCESS), broadcaster);
        require(address(CspFundAdapterOperations).code.length != 0, "B1N394: CSP library");
        require(address(CoveredCallFundAdapterOperations).code.length != 0, "B1N394: CC library");

        IB1N394ValuatorPolicy cspPrior = IB1N394ValuatorPolicy(CSP_CURRENT_VALUATOR);
        IB1N394ValuatorPolicy ccPrior = IB1N394ValuatorPolicy(CC_CURRENT_VALUATOR);

        vm.startBroadcast(broadcaster);
        deployed.accounting = address(new FundAccounting());
        deployed.flow = address(new FundFlowManager());
        deployed.manager = address(new StrategyManager());
        deployed.cspAdapter = address(new CspFundAdapter());
        deployed.ccAdapter = address(new CoveredCallFundAdapter());
        deployed.cspValuator = address(
            new CspFundValuatorV2(
                cspPrior.spotFeed(),
                cspPrior.spotFeedDecimals(),
                cspPrior.maxSpotStaleness(),
                cspPrior.maxObservationWindow(),
                cspPrior.observationQuorum(),
                _approvedObservers(CSP_CURRENT_VALUATOR)
            )
        );
        deployed.ccValuator = address(
            new CoveredCallFundValuatorV2(
                ccPrior.spotFeed(),
                ccPrior.spotFeedDecimals(),
                ccPrior.maxSpotStaleness(),
                ccPrior.maxObservationWindow(),
                ccPrior.observationQuorum(),
                _approvedObservers(CC_CURRENT_VALUATOR)
            )
        );
        vm.stopBroadcast();

        _requireMatchingPolicy(CSP_CURRENT_VALUATOR, deployed.cspValuator);
        _requireMatchingPolicy(CC_CURRENT_VALUATOR, deployed.ccValuator);
        _log("B1N394_FUND_ACCOUNTING_IMPLEMENTATION", deployed.accounting);
        _log("B1N394_FUND_FLOW_IMPLEMENTATION", deployed.flow);
        _log("B1N394_STRATEGY_MANAGER_IMPLEMENTATION", deployed.manager);
        _log("B1N394_CSP_ADAPTER_IMPLEMENTATION", deployed.cspAdapter);
        _log("B1N394_CC_ADAPTER_IMPLEMENTATION", deployed.ccAdapter);
        _log("B1N394_CSP_VALUATOR", deployed.cspValuator);
        _log("B1N394_CC_VALUATOR", deployed.ccValuator);
        _log("B1N394_CSP_OPERATIONS_LIBRARY", address(CspFundAdapterOperations));
        _log("B1N394_CC_OPERATIONS_LIBRARY", address(CoveredCallFundAdapterOperations));
    }

    function _requireImmediateRoles(AccessManager manager, address broadcaster) private view {
        _requireImmediateRole(manager, FundConstants.UPGRADER_ROLE, broadcaster);
        _requireImmediateRole(manager, FundConstants.CURATOR_ROLE, broadcaster);
        _requireImmediateRole(manager, FundConstants.GUARDIAN_ROLE, broadcaster);
        _requireImmediateRole(manager, FundConstants.ADAPTER_UPGRADER_ROLE, broadcaster);
    }

    function _log(string memory label, address deployed) private view {
        console2.log(label, deployed);
        console2.log(string.concat(label, "_CODEHASH"));
        console2.logBytes32(deployed.codehash);
    }
}
