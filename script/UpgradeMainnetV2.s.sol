// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/Controller.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";

/**
 * @title UpgradeMainnetV2
 * @notice Upgrades Controller + BatchSettler on Base mainnet and registers
 *         cbBTC as a new underlying asset.
 *
 *         Changes:
 *         - Controller: multi-asset decimal scaling (B1N-182)
 *         - BatchSettler: multi-asset decimal scaling (B1N-182)
 *         - Oracle: cbBTC/USD Chainlink feed
 *         - Whitelist: cbBTC underlying, collateral, PUT + CALL products
 *
 *         Dry run:
 *         forge script script/UpgradeMainnetV2.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           -vvv
 *
 *         Broadcast:
 *         forge script script/UpgradeMainnetV2.s.sol \
 *           --rpc-url $BASE_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           --broadcast --slow -vvv
 */
contract UpgradeMainnetV2 is Script {
    // --- Proxy addresses (from deployments-mainnet.json) ---
    address constant CONTROLLER_PROXY = 0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624;
    address constant BATCH_SETTLER_PROXY = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address constant ORACLE_PROXY = 0x09daa0194A3AF59b46C5443aF9C20fAd98347671;
    address constant WHITELIST_PROXY = 0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A;

    // --- External addresses (Base mainnet) ---
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // cbBTC/USD Chainlink feed on Base
    address constant CHAINLINK_CBBTC_USD = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;

    function run() external {
        vm.startBroadcast();

        // --- 1. Upgrade Controller ---
        Controller controllerImpl = new Controller();
        console.log("New Controller impl:", address(controllerImpl));

        Controller(CONTROLLER_PROXY).upgradeToAndCall(address(controllerImpl), "");
        console.log("Controller proxy upgraded");

        // --- 2. Upgrade BatchSettler ---
        BatchSettler settlerImpl = new BatchSettler();
        console.log("New BatchSettler impl:", address(settlerImpl));

        BatchSettler(BATCH_SETTLER_PROXY).upgradeToAndCall(address(settlerImpl), "");
        console.log("BatchSettler proxy upgraded");

        // --- 3. Register cbBTC in Oracle ---
        Oracle(ORACLE_PROXY).setPriceFeed(CBBTC, CHAINLINK_CBBTC_USD);
        console.log("Oracle: cbBTC/USD feed set");

        // --- 4. Whitelist cbBTC ---
        Whitelist wl = Whitelist(WHITELIST_PROXY);
        wl.whitelistUnderlying(CBBTC);
        console.log("Whitelist: cbBTC as underlying");

        wl.whitelistCollateral(CBBTC);
        console.log("Whitelist: cbBTC as collateral");

        // BTC PUT: cbBTC underlying, USDC strike, USDC collateral
        wl.whitelistProduct(CBBTC, USDC, USDC, true);
        console.log("Whitelist: cbBTC PUT product");

        // BTC CALL: cbBTC underlying, USDC strike, cbBTC collateral
        wl.whitelistProduct(CBBTC, USDC, CBBTC, false);
        console.log("Whitelist: cbBTC CALL product");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("Controller impl:", address(controllerImpl));
        console.log("BatchSettler impl:", address(settlerImpl));
        console.log("cbBTC:", CBBTC);
        console.log("Chainlink cbBTC/USD:", CHAINLINK_CBBTC_USD);
    }
}
