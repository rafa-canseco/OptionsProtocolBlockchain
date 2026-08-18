// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {B1N394Base, IB1N394ValuatorPolicy} from "./B1N394Base.sol";

/// @notice Deploys ABI-compatible V2 valuators without mutating either live fund.
contract DeployB1N394CompatibleValuators is B1N394Base {
    function run() external returns (address cspReplacement, address ccReplacement) {
        _requireBaseSepolia();
        address broadcaster = vm.envAddress("B1N394_BROADCASTER");
        address cspPrior = StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER).valuator;
        address ccPrior = StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER).valuator;
        IB1N394ValuatorPolicy cspPolicy = IB1N394ValuatorPolicy(cspPrior);
        IB1N394ValuatorPolicy ccPolicy = IB1N394ValuatorPolicy(ccPrior);

        vm.startBroadcast(broadcaster);
        cspReplacement = address(
            new CspFundValuatorV2(
                cspPolicy.spotFeed(),
                cspPolicy.spotFeedDecimals(),
                cspPolicy.maxSpotStaleness(),
                cspPolicy.maxObservationWindow(),
                cspPolicy.observationQuorum(),
                _approvedObservers(cspPrior)
            )
        );
        ccReplacement = address(
            new CoveredCallFundValuatorV2(
                ccPolicy.spotFeed(),
                ccPolicy.spotFeedDecimals(),
                ccPolicy.maxSpotStaleness(),
                ccPolicy.maxObservationWindow(),
                ccPolicy.observationQuorum(),
                _approvedObservers(ccPrior)
            )
        );
        vm.stopBroadcast();

        _requireMatchingPolicy(cspPrior, cspReplacement);
        _requireMatchingPolicy(ccPrior, ccReplacement);
        require(CspFundValuatorV2(cspReplacement).liabilityBufferBps() == 0, "B1N394: CSP buffer");
        require(CoveredCallFundValuatorV2(ccReplacement).liabilityBufferBps() == 0, "B1N394: CC buffer");
        _log("B1N394_CSP_VALUATOR", cspReplacement);
        _log("B1N394_CC_VALUATOR", ccReplacement);
    }

    function _log(string memory label, address deployed) private view {
        console2.log(label, deployed);
        console2.log(string.concat(label, "_CODEHASH"));
        console2.logBytes32(deployed.codehash);
    }
}
