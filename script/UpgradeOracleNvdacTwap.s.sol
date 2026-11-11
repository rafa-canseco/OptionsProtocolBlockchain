// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/Oracle.sol";

/**
 * @notice Atomically upgrades the Base mainnet Oracle and enables NVDAc TWAP settlement.
 *
 * Dry run:
 * forge script script/UpgradeOracleNvdacTwap.s.sol \
 *   --rpc-url "$BASE_RPC_URL" --ledger --mnemonic-derivation-paths "m/44'/60'/6'/0/0" -vvv
 *
 * Broadcast (requires the Oracle owner Ledger):
 * forge script script/UpgradeOracleNvdacTwap.s.sol \
 *   --rpc-url "$BASE_RPC_URL" --ledger --mnemonic-derivation-paths "m/44'/60'/6'/0/0" \
 *   --broadcast --slow -vvv
 */
contract UpgradeOracleNvdacTwap is Script {
    address private constant ORACLE_PROXY = 0x09daa0194A3AF59b46C5443aF9C20fAd98347671;
    address private constant EXPECTED_OWNER = 0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7;
    address private constant PRICE_POOL = 0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC;
    address private constant PRICE_POOL_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint32 private constant MAX_SETTLEMENT_DELAY = 1 days;
    uint128 private constant MIN_HARMONIC_LIQUIDITY = 6_900_000_000_000;
    uint32 private constant USDC_FEED_MAX_AGE = 72 hours;
    uint32 private constant REFERENCE_MAX_AGE = 1 hours;
    uint16 private constant REFERENCE_DEVIATION_BPS = 100;

    function run() external {
        require(block.chainid == 8453, "Base mainnet only");
        Oracle oracle = Oracle(ORACLE_PROXY);
        require(oracle.owner() == EXPECTED_OWNER, "unexpected Oracle owner");
        (bool configReadable, bytes memory configData) =
            ORACLE_PROXY.staticcall(abi.encodeWithSelector(bytes4(keccak256("nvdacTwapConfig()"))));
        if (configReadable) {
            require(configData.length >= 64, "invalid NVDAc config response");
            address configuredPool;
            assembly {
                configuredPool := mload(add(configData, 64))
            }
            require(configuredPool == address(0), "NVDAc TWAP already configured");
        }

        vm.startBroadcast();
        Oracle implementation = new Oracle();
        bytes memory configure = abi.encodeCall(
            Oracle.configureNvdacTwap,
            (
                PRICE_POOL,
                PRICE_POOL_FACTORY,
                USDC,
                MAX_SETTLEMENT_DELAY,
                MIN_HARMONIC_LIQUIDITY,
                USDC_FEED_MAX_AGE,
                REFERENCE_MAX_AGE,
                REFERENCE_DEVIATION_BPS,
                true
            )
        );
        oracle.upgradeToAndCall(address(implementation), configure);
        vm.stopBroadcast();

        (
            address asset,
            address pool,
            address factory,
            address usdc,
            int24 tickSpacing,
            uint32 maxDelay,
            uint128 minLiquidity,
            uint32 usdcMaxAge,
            uint32 referenceMaxAge,
            uint16 deviationBps,
            bool enabled
        ) = oracle.nvdacTwapConfig();
        require(asset == 0xb20000000000000000000078ee7ce2fE4908108C, "asset mismatch");
        require(pool == PRICE_POOL && factory == PRICE_POOL_FACTORY && usdc == USDC, "route mismatch");
        require(tickSpacing == 10, "tick spacing mismatch");
        require(maxDelay == MAX_SETTLEMENT_DELAY && minLiquidity == MIN_HARMONIC_LIQUIDITY, "risk mismatch");
        require(usdcMaxAge == USDC_FEED_MAX_AGE && referenceMaxAge == REFERENCE_MAX_AGE, "age mismatch");
        require(deviationBps == REFERENCE_DEVIATION_BPS && enabled, "activation mismatch");

        console.log("Oracle implementation:", address(implementation));
        console.log("Oracle proxy upgraded and NVDAc TWAP enabled:", ORACLE_PROXY);
    }
}
