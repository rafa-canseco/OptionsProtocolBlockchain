// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

abstract contract B1N367Base is Script {
    using SafeCast for uint256;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    struct FairNavConfig {
        address phaseScheduler;
        address spotFeed;
        uint8 spotFeedDecimals;
        uint64 maxSpotStaleness;
        uint64 maxObservationWindow;
        uint8 observationQuorum;
        address[] approvedObservers;
    }

    function _requireApprovedBaseSepolia() internal view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "B1N367: wrong chain");
        string memory approvedInputs = _approvedInputs();
        require(
            sha256(bytes(approvedInputs)) == vm.envBytes32("B1N367_APPROVED_INPUTS_SHA256"),
            "B1N367: approved inputs digest"
        );
    }

    function _loadFairNavConfig() internal view returns (FairNavConfig memory config) {
        config.phaseScheduler = _approvedAddress("FUND_PHASE_SCHEDULER");
        config.spotFeed = _approvedAddress("FUND_CSP_SPOT_FEED");
        config.spotFeedDecimals = _approvedUint("FUND_CSP_SPOT_FEED_DECIMALS").toUint8();
        config.maxSpotStaleness = _approvedUint("FUND_CSP_MAX_SPOT_STALENESS_SECONDS").toUint64();
        config.maxObservationWindow = _approvedUint("FUND_CSP_MAX_OBSERVATION_WINDOW_BLOCKS").toUint64();
        config.observationQuorum = _approvedUint("FUND_CSP_OBSERVATION_QUORUM").toUint8();
        config.approvedObservers =
            vm.parseJsonAddressArray(_approvedInputs(), _approvedJsonKey("FUND_CSP_APPROVED_OBSERVERS"));
    }

    function _phaseSchedulerKey(FairNavConfig memory config) internal view returns (uint256 key) {
        key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == config.phaseScheduler, "B1N367: phase scheduler key");
    }

    function _approvedInputs() internal view returns (string memory) {
        return vm.readFile(vm.envString("B1N367_APPROVED_INPUTS_PATH"));
    }

    function _approvedJsonKey(string memory key) private pure returns (string memory) {
        return string.concat(".environment.", key);
    }

    function _approvedAddress(string memory key) private view returns (address) {
        return vm.parseJsonAddress(_approvedInputs(), _approvedJsonKey(key));
    }

    function _approvedUint(string memory key) private view returns (uint256) {
        return vm.parseJsonUint(_approvedInputs(), _approvedJsonKey(key));
    }
}
