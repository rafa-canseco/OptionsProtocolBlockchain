// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";

/// @notice Matches the Base Sepolia covered-call utilization policy to the CSP policy.
/// @dev The active position is not resized. The 80% target applies when the next position opens.
contract ConfigureB1N374CoveredCallUtilization is Script {
    uint16 private constant PREVIOUS_ALLOCATION_BPS = 2_500;
    uint16 private constant TARGET_ALLOCATION_BPS = 8_000;
    uint256 private constant DYNAMIC_IDLE_CAP = type(uint256).max;

    function run() external {
        require(block.chainid == 84532, "B1N374: Base Sepolia only");

        uint256 curatorKey = vm.envUint("PRIVATE_KEY");
        StrategyManager strategy = StrategyManager(vm.envAddress("B1N374_COVERED_CALL_STRATEGY_MANAGER"));
        address adapterAddress = vm.envAddress("B1N374_COVERED_CALL_ADAPTER");

        FundTypes.StrategyConfig memory strategyConfig = strategy.strategyConfig(adapterAddress);
        ICoveredCallFundAdapter.AdapterConfig memory adapterConfig =
            ICoveredCallFundAdapter(adapterAddress).adapterConfig();

        require(strategyConfig.active, "B1N374: CC inactive");
        require(
            strategyConfig.maxAllocationBps == PREVIOUS_ALLOCATION_BPS
                || strategyConfig.maxAllocationBps == TARGET_ALLOCATION_BPS,
            "B1N374: unexpected strategy utilization"
        );
        require(strategyConfig.absoluteCap == DYNAMIC_IDLE_CAP, "B1N374: static strategy cap");
        require(
            adapterConfig.riskConfig.maxUtilizationBps == PREVIOUS_ALLOCATION_BPS
                || adapterConfig.riskConfig.maxUtilizationBps == TARGET_ALLOCATION_BPS,
            "B1N374: unexpected adapter utilization"
        );
        require(adapterConfig.riskConfig.maxOpenPositions == 1, "B1N374: CC positions");
        require(adapterConfig.riskConfig.maxCollateralPerPosition == DYNAMIC_IDLE_CAP, "B1N374: static collateral cap");

        bool strategyNeedsUpdate = strategyConfig.maxAllocationBps != TARGET_ALLOCATION_BPS;
        bool adapterNeedsUpdate = adapterConfig.riskConfig.maxUtilizationBps != TARGET_ALLOCATION_BPS;
        strategyConfig.maxAllocationBps = TARGET_ALLOCATION_BPS;
        adapterConfig.riskConfig.maxUtilizationBps = TARGET_ALLOCATION_BPS;

        if (strategyNeedsUpdate || adapterNeedsUpdate) {
            vm.startBroadcast(curatorKey);
            if (strategyNeedsUpdate) {
                strategy.setStrategyConfig(adapterAddress, strategyConfig);
            }
            if (adapterNeedsUpdate) {
                ICoveredCallFundAdapter(adapterAddress)
                    .setAdapterConfig(adapterConfig.riskConfig, adapterConfig.swapRouter, adapterConfig.swapFeeTier);
            }
            vm.stopBroadcast();
        }

        FundTypes.StrategyConfig memory strategyAfter = strategy.strategyConfig(adapterAddress);
        ICoveredCallFundAdapter.AdapterConfig memory adapterAfter =
            ICoveredCallFundAdapter(adapterAddress).adapterConfig();

        require(strategyAfter.maxAllocationBps == TARGET_ALLOCATION_BPS, "B1N374: strategy mismatch");
        require(adapterAfter.riskConfig.maxUtilizationBps == TARGET_ALLOCATION_BPS, "B1N374: adapter mismatch");
        require(strategyAfter.absoluteCap == DYNAMIC_IDLE_CAP, "B1N374: strategy cap changed");
        require(adapterAfter.riskConfig.maxCollateralPerPosition == DYNAMIC_IDLE_CAP, "B1N374: collateral cap changed");

        console2.log("B1N374_COVERED_CALL_TARGET_ALLOCATION_BPS", TARGET_ALLOCATION_BPS);
        console2.log("B1N374_COVERED_CALL_STRATEGY_MANAGER", address(strategy));
        console2.log("B1N374_COVERED_CALL_ADAPTER", adapterAddress);
    }
}
