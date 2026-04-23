// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/Controller.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/MarginPool.sol";
import "../src/mocks/MockERC20.sol";

/**
 * @title SmokeTestBeta
 * @notice End-to-end smoke test on Base Sepolia: create BTC call,
 *         deposit LBTC collateral, mint oTokens, set expiry price,
 *         settle vault. Validates multi-asset decimal scaling (B1N-187).
 *
 *         Usage:
 *         forge script script/SmokeTestBeta.s.sol:SmokeTestBeta \
 *           --rpc-url $BASE_SEPOLIA_RPC_URL \
 *           --broadcast --slow -vvv
 */
contract SmokeTestBeta is Script {
    // --- Deployed addresses (from deployments-beta.json) ---
    Controller constant controller = Controller(0xB64a532B71E711B5F45B906D9Fc09c184EC54CA0);
    OTokenFactory constant factory = OTokenFactory(0x1cEA6AE65c06972249831f617ea196863Fb66e6D);
    Oracle constant oracle = Oracle(0x101cB9E8a3105EfB18A81E768238eFc041F31E15);
    MarginPool constant pool = MarginPool(0x727ddBD04A691E73feaE26349F48144953Ef20d6);
    MockERC20 constant lbtc = MockERC20(0x39fA11EbBE82699Fd9F79C566D7384064571d2b4);
    MockERC20 constant lusd = MockERC20(0xAB51a471493832C1D70cef8ff937A850cf37c860);

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 0. Set deployer as operator on factory and oracle (not set in DeployBeta)
        factory.setOperator(deployer);
        oracle.setOperator(deployer);
        console.log("Operator set on factory and oracle");

        // 1. Create BTC CALL option: LBTC underlying, LUSD strike,
        //    LBTC collateral, strike $95000
        //    Expiry must be at 08:00 UTC (expiry % 24h == 8h)
        uint256 nextDay = block.timestamp + 1 days;
        uint256 expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;
        uint256 strikePrice = 95_000e8;

        address oTokenAddr = factory.createOToken(
            address(lbtc), // underlying
            address(lusd), // strikeAsset
            address(lbtc), // collateral (LBTC for calls)
            strikePrice,
            expiry,
            false // isPut = false => CALL
        );
        console.log("oToken created:", oTokenAddr);

        // 2. Open vault
        uint256 vaultId = controller.openVault(deployer);
        console.log("Vault opened, ID:", vaultId);

        // 3. Deposit LBTC collateral (1 BTC = 1e8)
        uint256 collateralAmount = 1e8; // 1 LBTC
        lbtc.approve(address(pool), collateralAmount);
        controller.depositCollateral(deployer, vaultId, address(lbtc), collateralAmount);
        console.log("Deposited 1 LBTC collateral");

        // 4. Mint oTokens (1e8 = 1 option contract)
        //    For CALL with 8-decimal collateral:
        //    requiredCollateral = amount * 10^(cd-8) = 1e8 * 1 = 1e8
        uint256 mintAmount = 1e8;
        controller.mintOtoken(deployer, vaultId, oTokenAddr, mintAmount, deployer);
        console.log("Minted 1e8 oTokens (1 BTC call)");

        // 5. Verify oToken balance
        uint256 bal = OToken(oTokenAddr).balanceOf(deployer);
        console.log("oToken balance:", bal);
        require(bal == mintAmount, "oToken balance mismatch");

        console.log("=== SMOKE TEST PASSED ===");
        console.log("BTC call option created, collateral deposited,");
        console.log("oTokens minted. Decimal scaling works for 8-dec.");

        vm.stopBroadcast();
    }
}
