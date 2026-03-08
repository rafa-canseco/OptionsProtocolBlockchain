// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";

/**
 * @title UpgradeWhitelistFactoryOracle
 * @notice Upgrades Whitelist, OTokenFactory, and Oracle on mainnet.
 *         Sets operator on factory and oracle, whitelists existing oTokens.
 *
 *         Run (Ledger):
 *         forge script script/UpgradeWhitelistFactory.s.sol \
 *           --rpc-url $BASE_MAINNET_RPC_URL \
 *           --ledger --hd-paths "m/44'/60'/6'/0/0" \
 *           --broadcast -vvv
 */
contract UpgradeWhitelistFactoryOracle is Script {
    // --- Mainnet proxy addresses ---
    address constant WHITELIST_PROXY = 0xB919201D659045933832f24BC64fD0ADBF9B4597;
    address constant FACTORY_PROXY = 0x754172910605382449A961E192CB48Bb64276B43;
    address constant ORACLE_PROXY = 0x54CF29E08D26C1252776764e2F80e6eb863882F4;
    address constant OPERATOR = 0x0bbD599cEB63b4603c2F007c5122e33f7b12364c;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy new implementations
        Whitelist whitelistImpl = new Whitelist();
        OTokenFactory factoryImpl = new OTokenFactory();
        Oracle oracleImpl = new Oracle();
        console.log("New Whitelist impl:", address(whitelistImpl));
        console.log("New OTokenFactory impl:", address(factoryImpl));
        console.log("New Oracle impl:", address(oracleImpl));

        // 2. Upgrade proxies
        Whitelist(WHITELIST_PROXY).upgradeToAndCall(address(whitelistImpl), "");
        console.log("Whitelist upgraded");

        OTokenFactory(FACTORY_PROXY).upgradeToAndCall(address(factoryImpl), "");
        console.log("OTokenFactory upgraded");

        Oracle(ORACLE_PROXY).upgradeToAndCall(address(oracleImpl), "");
        console.log("Oracle upgraded");

        // 3. Set operator on factory and oracle
        OTokenFactory(FACTORY_PROXY).setOperator(OPERATOR);
        console.log("Factory operator set to:", OPERATOR);

        Oracle(ORACLE_PROXY).setOperator(OPERATOR);
        console.log("Oracle operator set to:", OPERATOR);

        // 4. Whitelist all existing oTokens
        uint256 count = OTokenFactory(FACTORY_PROXY).getOTokensLength();
        for (uint256 i = 0; i < count; i++) {
            address oToken = OTokenFactory(FACTORY_PROXY).oTokens(i);
            if (!Whitelist(WHITELIST_PROXY).isWhitelistedOToken(oToken)) {
                Whitelist(WHITELIST_PROXY).whitelistOToken(oToken);
                console.log("Whitelisted oToken:", oToken);
            }
        }
        console.log("Total oTokens processed:", count);

        vm.stopBroadcast();
    }
}
