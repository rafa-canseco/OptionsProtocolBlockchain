// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/BatchSettler.sol";

/**
 * @title UpgradeMainnetV6
 * @notice Upgrades BatchSettler on Base mainnet (B1N-303).
 *         Changes: remove flash-loan dependency from physical redeem.
 *         No post-upgrade reinitializer or config mutation is required.
 *
 *         Dry run:
 *         forge script script/UpgradeMainnetV6.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           -vvv
 *
 *         Broadcast:
 *         forge script script/UpgradeMainnetV6.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           --broadcast --slow -vvv
 */
contract UpgradeMainnetV6 is Script {
    address constant BATCH_SETTLER_PROXY = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;

    function run() external {
        vm.startBroadcast();

        BatchSettler newImpl = new BatchSettler();
        console.log("New BatchSettler impl:", address(newImpl));

        BatchSettler settler = BatchSettler(BATCH_SETTLER_PROXY);
        settler.upgradeToAndCall(address(newImpl), "");
        console.log("BatchSettler proxy upgraded");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("BatchSettler impl:", address(newImpl));
        console.log("swapRouter:", settler.swapRouter());
        console.log("global fee tier:", settler.swapFeeTier());
        console.log("aavePool (deprecated runtime dependency):", settler.aavePool());
    }
}
