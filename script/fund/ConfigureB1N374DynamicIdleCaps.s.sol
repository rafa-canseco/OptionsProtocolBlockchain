// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";

/// @notice Removes static absolute caps while preserving percentage-based allocation controls.
/// @dev Base Sepolia only. Existing positions are not resized or otherwise mutated.
contract ConfigureB1N374DynamicIdleCaps is Script {
    uint16 private constant CSP_ALLOCATION_BPS = 8_000;
    uint16 private constant COVERED_CALL_ALLOCATION_BPS = 2_500;
    uint256 private constant DYNAMIC_IDLE_CAP = type(uint256).max;

    function run() external {
        uint256 callerKey = vm.envUint("PRIVATE_KEY");
        StrategyManager cspStrategy = StrategyManager(vm.envAddress("B1N374_CSP_STRATEGY_MANAGER"));
        address cspAdapterAddress = vm.envAddress("B1N374_CSP_ADAPTER");
        StrategyManager coveredCallStrategy = StrategyManager(vm.envAddress("B1N374_COVERED_CALL_STRATEGY_MANAGER"));
        address coveredCallAdapterAddress = vm.envAddress("B1N374_COVERED_CALL_ADAPTER");

        FundTypes.StrategyConfig memory cspStrategyConfig = cspStrategy.strategyConfig(cspAdapterAddress);
        ICspFundAdapter.AdapterConfig memory cspAdapterConfig = ICspFundAdapter(cspAdapterAddress).adapterConfig();
        FundTypes.StrategyConfig memory coveredCallStrategyConfig =
            coveredCallStrategy.strategyConfig(coveredCallAdapterAddress);
        ICoveredCallFundAdapter.AdapterConfig memory coveredCallAdapterConfig =
            ICoveredCallFundAdapter(coveredCallAdapterAddress).adapterConfig();

        require(cspStrategyConfig.active, "B1N374: CSP inactive");
        require(cspStrategyConfig.maxAllocationBps == CSP_ALLOCATION_BPS, "B1N374: CSP utilization");
        require(cspAdapterConfig.riskConfig.maxOpenPositions == 1, "B1N374: CSP positions");
        require(coveredCallStrategyConfig.active, "B1N374: CC inactive");
        require(coveredCallStrategyConfig.maxAllocationBps == COVERED_CALL_ALLOCATION_BPS, "B1N374: CC utilization");
        require(
            coveredCallAdapterConfig.riskConfig.maxUtilizationBps == COVERED_CALL_ALLOCATION_BPS,
            "B1N374: CC adapter utilization"
        );
        require(coveredCallAdapterConfig.riskConfig.maxOpenPositions == 1, "B1N374: CC positions");

        cspStrategyConfig.absoluteCap = DYNAMIC_IDLE_CAP;
        cspAdapterConfig.riskConfig.maxCollateralPerPosition = DYNAMIC_IDLE_CAP;
        coveredCallStrategyConfig.absoluteCap = DYNAMIC_IDLE_CAP;
        coveredCallAdapterConfig.riskConfig.maxCollateralPerPosition = DYNAMIC_IDLE_CAP;

        vm.startBroadcast(callerKey);
        cspStrategy.setStrategyConfig(cspAdapterAddress, cspStrategyConfig);
        ICspFundAdapter(cspAdapterAddress)
            .setAdapterConfig(cspAdapterConfig.riskConfig, cspAdapterConfig.swapRouter, cspAdapterConfig.swapFeeTier);
        coveredCallStrategy.setStrategyConfig(coveredCallAdapterAddress, coveredCallStrategyConfig);
        ICoveredCallFundAdapter(coveredCallAdapterAddress)
            .setAdapterConfig(
                coveredCallAdapterConfig.riskConfig,
                coveredCallAdapterConfig.swapRouter,
                coveredCallAdapterConfig.swapFeeTier
            );
        vm.stopBroadcast();

        FundTypes.StrategyConfig memory cspAfter = cspStrategy.strategyConfig(cspAdapterAddress);
        ICspFundAdapter.AdapterConfig memory cspAdapterAfter = ICspFundAdapter(cspAdapterAddress).adapterConfig();
        FundTypes.StrategyConfig memory coveredCallAfter = coveredCallStrategy.strategyConfig(coveredCallAdapterAddress);
        ICoveredCallFundAdapter.AdapterConfig memory coveredCallAdapterAfter =
            ICoveredCallFundAdapter(coveredCallAdapterAddress).adapterConfig();

        require(
            keccak256(abi.encode(cspAfter)) == keccak256(abi.encode(cspStrategyConfig)), "B1N374: CSP strategy mismatch"
        );
        require(
            keccak256(abi.encode(cspAdapterAfter)) == keccak256(abi.encode(cspAdapterConfig)),
            "B1N374: CSP adapter mismatch"
        );
        require(
            keccak256(abi.encode(coveredCallAfter)) == keccak256(abi.encode(coveredCallStrategyConfig)),
            "B1N374: CC strategy mismatch"
        );
        require(
            keccak256(abi.encode(coveredCallAdapterAfter)) == keccak256(abi.encode(coveredCallAdapterConfig)),
            "B1N374: CC adapter mismatch"
        );

        console2.log("B1N374_DYNAMIC_IDLE_CAP", DYNAMIC_IDLE_CAP);
        console2.log("B1N374_CSP_STRATEGY_MANAGER", address(cspStrategy));
        console2.log("B1N374_CSP_ADAPTER", cspAdapterAddress);
        console2.log("B1N374_COVERED_CALL_STRATEGY_MANAGER", address(coveredCallStrategy));
        console2.log("B1N374_COVERED_CALL_ADAPTER", coveredCallAdapterAddress);
    }
}
