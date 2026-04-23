// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/MarginPool.sol";

/**
 * @title UpgradeMainnetV5
 * @notice Upgrades MarginPool on Base mainnet (B1N-267).
 *         Changes: Aave V3 yield integration for idle collateral.
 *         Configures Aave for USDC, WETH, and cbBTC but does NOT
 *         enable routing — setAaveEnabled is called manually after
 *         on-chain verification.
 *
 *         Dry run:
 *         forge script script/UpgradeMainnetV5.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           -vvv
 *
 *         Broadcast:
 *         forge script script/UpgradeMainnetV5.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           --broadcast --slow -vvv
 */
contract UpgradeMainnetV5 is Script {
    // --- Proxy ---
    address constant MARGIN_POOL_PROXY = 0xa1e04873F6d112d84824C88c9D6937bE38811657;

    // --- Aave V3 on Base ---
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    // --- Collateral assets ---
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    // --- Aave aTokens (from getReserveData, verified 2026-04-02) ---
    address constant A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant A_WETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address constant A_CBBTC = 0xBdb9300b7CDE636d9cD4AFF00f6F009fFBBc8EE6;

    // --- Operator (yield recipient + harvest caller) ---
    address constant OPERATOR = 0x0bbD599cEB63b4603c2F007c5122e33f7b12364c;

    function run() external {
        vm.startBroadcast();

        MarginPool pool = MarginPool(MARGIN_POOL_PROXY);

        // 1. Deploy new implementation
        MarginPool newImpl = new MarginPool();
        console.log("New MarginPool impl:", address(newImpl));

        // 2. Upgrade proxy (no reinitializer — new vars default to
        //    zero/false)
        pool.upgradeToAndCall(address(newImpl), "");
        console.log("MarginPool proxy upgraded");

        // 3. Configure Aave pool
        pool.setAavePool(AAVE_V3_POOL);
        console.log("Aave pool set:", AAVE_V3_POOL);

        // 4. Set yield recipient and operator
        pool.setYieldRecipient(OPERATOR);
        pool.setOperator(OPERATOR);
        console.log("Yield recipient + operator:", OPERATOR);

        // 5. Map aTokens for each collateral asset
        pool.setAToken(USDC, A_USDC);
        pool.setAToken(WETH, A_WETH);
        pool.setAToken(CBBTC, A_CBBTC);
        console.log("aTokens configured: USDC, WETH, cbBTC");

        // 6. Approve Aave to spend each collateral asset
        pool.approveAave(USDC);
        pool.approveAave(WETH);
        pool.approveAave(CBBTC);
        console.log("Aave approvals granted: USDC, WETH, cbBTC");

        // NOTE: setAaveEnabled is NOT called here.
        // Enable manually after on-chain verification:
        //   pool.setAaveEnabled(USDC, true)
        //   pool.setAaveEnabled(WETH, true)
        //   pool.setAaveEnabled(CBBTC, true)

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("MarginPool impl:", address(newImpl));
        console.log("aavePool:", address(pool.aavePool()));
        console.log("yieldRecipient:", pool.yieldRecipient());
        console.log("operator:", pool.operator());
        console.log("isAaveEnabled(USDC):", pool.isAaveEnabled(USDC));
        console.log("isAaveEnabled(WETH):", pool.isAaveEnabled(WETH));
        console.log("isAaveEnabled(cbBTC):", pool.isAaveEnabled(CBBTC));
    }
}
