// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Script.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";

/**
 * @title Deploy
 * @notice Deploys the full options protocol to Base Sepolia.
 *
 *         Usage:
 *         forge script script/Deploy.s.sol:Deploy \
 *           --rpc-url base_sepolia \
 *           --broadcast \
 *           --verify \
 *           -vvvv
 */
contract Deploy is Script {
    function run() external {
        // Load config from environment
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address chainlinkEthUsd = vm.envAddress("CHAINLINK_ETH_USD_FEED");

        vm.startBroadcast(deployerKey);

        // 1. Deploy AddressBook (central registry)
        AddressBook addressBook = new AddressBook();
        console.log("AddressBook:", address(addressBook));

        // 2. Deploy core contracts
        Controller controller = new Controller(address(addressBook));
        console.log("Controller:", address(controller));

        MarginPool pool = new MarginPool(address(addressBook));
        console.log("MarginPool:", address(pool));

        OTokenFactory factory = new OTokenFactory(address(addressBook));
        console.log("OTokenFactory:", address(factory));

        Oracle oracle = new Oracle(address(addressBook));
        console.log("Oracle:", address(oracle));

        Whitelist whitelist = new Whitelist(address(addressBook));
        console.log("Whitelist:", address(whitelist));

        BatchSettler settler = new BatchSettler(address(addressBook), operator);
        console.log("BatchSettler:", address(settler));

        // 3. Wire AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        // 4. Whitelist assets and products (ETH only for MVP)
        whitelist.whitelistUnderlying(weth);
        whitelist.whitelistCollateral(usdc);
        whitelist.whitelistCollateral(weth);
        whitelist.whitelistProduct(weth, usdc, usdc, true);   // ETH PUT (USDC collateral)
        whitelist.whitelistProduct(weth, usdc, weth, false);   // ETH CALL (WETH collateral)

        // 5. Set Chainlink price feed for WETH
        oracle.setPriceFeed(weth, chainlinkEthUsd);

        vm.stopBroadcast();

        // Summary
        console.log("\n=== Deployment Complete ===");
        console.log("Chain: Base Sepolia");
        console.log("Operator:", operator);
        console.log("WETH:", weth);
        console.log("USDC:", usdc);
        console.log("Chainlink ETH/USD:", chainlinkEthUsd);
    }
}
