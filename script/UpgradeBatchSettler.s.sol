// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/BatchSettler.sol";

/**
 * @title UpgradeBatchSettler
 * @notice Upgrades BatchSettler implementation on Base mainnet (B1N-171).
 *         Changes: call settlement now swaps all WETH via exactInputSingle,
 *         delivering surplus as USDC to MM instead of WETH.
 *
 *         Dry run:
 *         source .env && forge script script/UpgradeBatchSettler.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           -vvv
 *
 *         Broadcast:
 *         source .env && forge script script/UpgradeBatchSettler.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           --broadcast --slow -vvv
 */
contract UpgradeBatchSettler is Script {
    address constant BATCH_SETTLER_PROXY = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy new implementation
        BatchSettler newImpl = new BatchSettler();
        console.log("New BatchSettler impl:", address(newImpl));

        // 2. Upgrade proxy (no reinitializer needed — no new state)
        BatchSettler(BATCH_SETTLER_PROXY).upgradeToAndCall(address(newImpl), "");
        console.log("BatchSettler proxy upgraded");

        vm.stopBroadcast();
    }
}
