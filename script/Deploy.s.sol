// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";

/**
 * @title Deploy
 * @notice Deploys the full options protocol (UUPS proxied).
 *
 *         Usage (Ledger):
 *         forge script script/Deploy.s.sol:Deploy \
 *           --rpc-url $BASE_MAINNET_RPC_URL \
 *           --ledger --sender $DEPLOYER_ADDRESS \
 *           --broadcast --slow -vvvv
 *
 *         Usage (Keystore):
 *         forge script script/Deploy.s.sol:Deploy \
 *           --rpc-url $BASE_MAINNET_RPC_URL \
 *           --account deployer --sender $DEPLOYER_ADDRESS \
 *           --broadcast --slow -vvvv
 */
contract Deploy is Script {
    function run() external {
        // Load config from environment (no private keys — use --ledger or --account)
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address chainlinkEthUsd = vm.envAddress("CHAINLINK_ETH_USD_FEED");

        vm.startBroadcast();
        address deployer = msg.sender;

        // 1. Deploy AddressBook (central registry)
        AddressBook addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (deployer))))
        );
        console.log("AddressBook:", address(addressBook));

        // 2. Deploy core contracts
        Controller controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), deployer))
                )
            )
        );
        console.log("Controller:", address(controller));

        MarginPool pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );
        console.log("MarginPool:", address(pool));

        OTokenFactory factory = OTokenFactory(
            address(
                new ERC1967Proxy(
                    address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
                )
            )
        );
        console.log("OTokenFactory:", address(factory));

        Oracle oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), deployer))
                )
            )
        );
        console.log("Oracle:", address(oracle));

        Whitelist whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), deployer))
                )
            )
        );
        console.log("Whitelist:", address(whitelist));

        BatchSettler settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operator, deployer))
                )
            )
        );
        console.log("BatchSettler:", address(settler));

        // 3. Wire AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        // 4. Set operator roles on factory and oracle
        factory.setOperator(operator);
        oracle.setOperator(operator);

        // 5. Whitelist MM (same as operator in founder-operated phase)
        address mmAddress = vm.envOr("MM_ADDRESS", operator);
        settler.setWhitelistedMM(mmAddress, true);

        // 6. Whitelist assets and products (ETH only for MVP)
        whitelist.whitelistUnderlying(weth);
        whitelist.whitelistCollateral(usdc);
        whitelist.whitelistCollateral(weth);
        whitelist.whitelistProduct(weth, usdc, usdc, true); // ETH PUT (USDC collateral)
        whitelist.whitelistProduct(weth, usdc, weth, false); // ETH CALL (WETH collateral)

        // 7. Set Chainlink price feed for WETH
        oracle.setPriceFeed(weth, chainlinkEthUsd);

        // 8. Configure protocol fee
        _configureProtocolFee(settler);

        // 9. Configure physical delivery infrastructure (Aave V3 + Uniswap V3)
        _configurePhysicalDelivery(settler);

        // 10. Configure oracle safety bounds
        _configureOracleSafety(oracle);

        // 11. Configure escape hatch delay for MMs
        uint256 escapeDelay = vm.envOr("ESCAPE_DELAY", uint256(3 days));
        settler.setEscapeDelay(escapeDelay);
        console.log("Escape Delay (s):", escapeDelay);

        // 12. Set partial pauser (operator can pause new positions)
        controller.setPartialPauser(operator);

        vm.stopBroadcast();

        // Summary
        console.log("\n=== Deployment Complete ===");
        console.log("Chain:", vm.envOr("CHAIN_LABEL", string("Base")));
        console.log("Operator:", operator);
        console.log("MM:", mmAddress);
        console.log("WETH:", weth);
        console.log("USDC:", usdc);
        console.log("Chainlink ETH/USD:", chainlinkEthUsd);
    }

    function _configureProtocolFee(BatchSettler settler) internal {
        address treasury = vm.envOr("TREASURY_ADDRESS", address(0));
        uint256 feeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(0));

        if (treasury != address(0)) {
            settler.setTreasury(treasury);
            console.log("Treasury:", treasury);
        }
        if (feeBps > 0) {
            settler.setProtocolFeeBps(feeBps);
            console.log("Protocol Fee (bps):", feeBps);
        }
    }

    function _configureOracleSafety(Oracle oracle) internal {
        uint256 deviationBps = vm.envOr("PRICE_DEVIATION_THRESHOLD_BPS", uint256(1000));
        uint256 staleness = vm.envOr("MAX_ORACLE_STALENESS", uint256(3600));

        oracle.setPriceDeviationThreshold(deviationBps);
        console.log("Price Deviation Threshold (bps):", deviationBps);

        oracle.setMaxOracleStaleness(staleness);
        console.log("Max Oracle Staleness (s):", staleness);
    }

    function _configurePhysicalDelivery(BatchSettler settler) internal {
        address aavePool = vm.envOr("AAVE_POOL_ADDRESS", address(0));
        address router = vm.envOr("UNISWAP_SWAP_ROUTER", address(0));
        uint24 feeTier = uint24(vm.envOr("SWAP_FEE_TIER", uint256(3000)));

        if (aavePool == address(0)) {
            console.log("WARNING: AAVE_POOL_ADDRESS not set. Physical delivery will be non-functional.");
        } else {
            settler.setAavePool(aavePool);
            console.log("Aave Pool:", aavePool);
        }
        if (router == address(0)) {
            console.log("WARNING: UNISWAP_SWAP_ROUTER not set. Physical delivery will be non-functional.");
        } else {
            settler.setSwapRouter(router);
            console.log("Uniswap Router:", router);
        }
        settler.setSwapFeeTier(feeTier);
        console.log("Swap Fee Tier:", feeTier);
    }
}
