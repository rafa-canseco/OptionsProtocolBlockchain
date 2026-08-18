// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice Read-only B1N-419 deployment gate. It cannot broadcast, deploy, onboard or activate.
contract PreflightMetaWheelBaseSepolia is DeployMetaWheelBaseSepolia {
    error UsePreflightEntryPoint();

    function run() external pure override returns (DeploymentAddresses memory) {
        revert UsePreflightEntryPoint();
    }

    function preflight() external {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        require(
            keccak256(bytes(config.sourceCommit)) == keccak256(bytes(vm.envString("B1N419_SOURCE_COMMIT"))),
            "B1N419: source commit"
        );
        address broadcaster = vm.envAddress("B1N419_BROADCASTER");
        _validateConfig(config, broadcaster);
        require(broadcaster.balance >= vm.envUint("B1N419_MIN_BROADCASTER_BALANCE_WEI"), "B1N419: balance");

        console2.log("B1N419_PREFLIGHT_CHAIN_ID", block.chainid);
        console2.log("B1N419_PREFLIGHT_BROADCASTER", broadcaster);
        console2.log("B1N419_PREFLIGHT_SOURCE_COMMIT", config.sourceCommit);
        console2.log("B1N419_PREFLIGHT_POLICY_HASH");
        console2.logBytes32(config.wheel.policyHash);
        console2.log("B1N419_PREFLIGHT_STATUS", "READY_FOR_DRY_RUN_ONLY");
    }
}
