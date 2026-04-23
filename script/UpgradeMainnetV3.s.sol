// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/BatchSettler.sol";

/**
 * @title UpgradeMainnetV3
 * @notice Upgrades BatchSettler on Base mainnet (B1N-188).
 *         Changes: per-asset swap fee tier support.
 *         After upgrade, sets cbBTC fee tier to 500 (0.05%).
 *
 *         Dry run:
 *         forge script script/UpgradeMainnetV3.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           -vvv
 *
 *         Broadcast:
 *         forge script script/UpgradeMainnetV3.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           --broadcast --slow -vvv
 */
contract UpgradeMainnetV3 is Script {
    address constant BATCH_SETTLER_PROXY = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy new implementation
        BatchSettler newImpl = new BatchSettler();
        console.log("New BatchSettler impl:", address(newImpl));

        // 2. Upgrade proxy (no reinitializer — mapping defaults to zero)
        BatchSettler settler = BatchSettler(BATCH_SETTLER_PROXY);
        settler.upgradeToAndCall(address(newImpl), "");
        console.log("BatchSettler proxy upgraded");

        // 3. Set cbBTC fee tier to 500 (0.05% — deepest liquidity)
        settler.setAssetSwapFeeTier(CBBTC, 500);
        console.log("cbBTC swap fee tier set to 500");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("BatchSettler impl:", address(newImpl));
        console.log("cbBTC fee tier:", settler.assetSwapFeeTier(CBBTC));
        console.log("Global fee tier:", settler.swapFeeTier());
    }
}
