// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";

/// @notice Admits the 61-hour calendar-grid edge without changing Covered Call economics.
contract ExtendB1N374CoveredCallExpiryTolerance is Script {
    uint64 private constant MAX_EXPIRY_DELAY = 61 hours;
    uint16 private constant ALLOCATION_BPS = 2_500;

    function run() external {
        uint256 callerKey = vm.envUint("PRIVATE_KEY");
        address adapterAddress = vm.envAddress("B1N374_COVERED_CALL_ADAPTER");
        ICoveredCallFundAdapter adapter = ICoveredCallFundAdapter(adapterAddress);
        ICoveredCallFundAdapter.AdapterConfig memory expected = adapter.adapterConfig();

        require(expected.riskConfig.maxUtilizationBps == ALLOCATION_BPS, "B1N374: utilization");
        require(expected.riskConfig.maxOpenPositions == 1, "B1N374: positions");
        require(expected.riskConfig.minExpiryDelay == 36 hours, "B1N374: minimum expiry");
        require(
            expected.riskConfig.maxExpiryDelay == 60 hours || expected.riskConfig.maxExpiryDelay == MAX_EXPIRY_DELAY,
            "B1N374: unexpected maximum expiry"
        );

        expected.riskConfig.maxExpiryDelay = MAX_EXPIRY_DELAY;

        vm.startBroadcast(callerKey);
        adapter.setAdapterConfig(expected.riskConfig, expected.swapRouter, expected.swapFeeTier);
        vm.stopBroadcast();

        ICoveredCallFundAdapter.AdapterConfig memory actual = adapter.adapterConfig();
        require(
            keccak256(abi.encode(actual)) == keccak256(abi.encode(expected)), "B1N374: covered call config mismatch"
        );

        console2.log("B1N374_COVERED_CALL_ADAPTER", adapterAddress);
        console2.log("B1N374_MAX_EXPIRY_DELAY_SECONDS", MAX_EXPIRY_DELAY);
    }
}
