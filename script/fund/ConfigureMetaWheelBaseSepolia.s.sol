// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice Curator phase: binds NAV/reporting and the inactive parent strategy.
/// @dev Does not onboard children, resume lanes, open deposits, or allocate capital.
contract ConfigureMetaWheelBaseSepolia is DeployMetaWheelBaseSepolia {
    function run() external override returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = _loadBoundManifest(config);
        deployed.vault = vm.parseJsonAddress(manifest, ".vault");
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        deployed.accounting = vm.parseJsonAddress(manifest, ".accounting");
        deployed.flow = vm.parseJsonAddress(manifest, ".flow");
        deployed.strategy = vm.parseJsonAddress(manifest, ".strategy");
        deployed.coordinator = vm.parseJsonAddress(manifest, ".coordinator");
        deployed.metaWheelValuator = vm.parseJsonAddress(manifest, ".metaWheelValuator");
        deployed.inKindEscrow = vm.parseJsonAddress(manifest, ".inKindEscrow");
        deployed.emergencyEscrow = vm.parseJsonAddress(manifest, ".emergencyEscrow");

        address curator = vm.envAddress("B1N419_BROADCASTER");
        require(curator == config.finalRoles.curator, "B1N419: curator broadcaster");
        _requireFinalRoles(FundAccessManager(deployed.accessManager), config.finalRoles);
        bytes32 componentId = keccak256(abi.encodePacked("STRATEGY", deployed.coordinator));
        FundTypes.StrategyConfig memory strategyConfig = FundTypes.StrategyConfig({
            active: false,
            maxAllocationBps: config.wheel.strategyMaxAllocationBps,
            maxLossBps: config.wheel.strategyMaxLossBps,
            cooldown: config.wheel.strategyCooldown,
            interfaceVersion: 1,
            valuator: deployed.metaWheelValuator,
            absoluteCap: config.wheel.strategyAbsoluteCap
        });

        vm.startBroadcast(curator);
        FundAccounting(deployed.accounting)
            .setReporterSet(config.valuation.navReporters, config.valuation.navReporterThreshold, 1);
        FundAccounting(deployed.accounting).setComponent(componentId, deployed.metaWheelValuator, 1, true);
        StrategyManager(deployed.strategy).setStrategyConfig(deployed.coordinator, strategyConfig);
        FundFlowManager(deployed.flow).setStrategyExitEscrows(deployed.inKindEscrow, deployed.emergencyEscrow);
        vm.stopBroadcast();

        require(
            StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator).interfaceVersion == 1,
            "B1N419: strategy not configured"
        );
        require(
            !StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator).active,
            "B1N419: strategy activated"
        );
        require(
            WheelCoordinatorAdapter(deployed.coordinator).registeredLaneCount() == 0,
            "B1N419: lanes registered before inactive config"
        );
    }
}
