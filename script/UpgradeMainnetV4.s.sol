// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/Controller.sol";

/**
 * @title UpgradeMainnetV4
 * @notice Upgrades Controller on Base mainnet (B1N-204).
 *         Changes: guard against zero-collateral put minting
 *         via integer truncation.
 *
 *         Dry run:
 *         forge script script/UpgradeMainnetV4.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           -vvv
 *
 *         Broadcast:
 *         forge script script/UpgradeMainnetV4.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           --broadcast --slow -vvv
 */
contract UpgradeMainnetV4 is Script {
    address constant CONTROLLER_PROXY = 0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy new implementation
        Controller newImpl = new Controller();
        console.log("New Controller impl:", address(newImpl));

        // 2. Upgrade proxy (no reinitializer — pure logic fix)
        Controller(CONTROLLER_PROXY).upgradeToAndCall(address(newImpl), "");
        console.log("Controller proxy upgraded");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("Controller impl:", address(newImpl));
        console.log("Owner:", Controller(CONTROLLER_PROXY).owner());
    }
}
