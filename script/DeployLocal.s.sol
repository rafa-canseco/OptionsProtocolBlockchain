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
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockChainlinkFeed.sol";

/**
 * @title DeployLocal
 * @notice Deploys the full options protocol to local Anvil (UUPS proxied).
 *         Uses Anvil's default account[0] as deployer and operator.
 *         Deploys mock WETH, USDC, and a mock Chainlink feed.
 *
 *         Usage:
 *         forge script script/DeployLocal.s.sol:DeployLocal \
 *           --rpc-url http://127.0.0.1:8545 \
 *           --broadcast
 */
contract DeployLocal is Script {
    function run() external {
        // Anvil default account[0] private key
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // --- Deploy mock tokens ---
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        // --- Deploy mock Chainlink feed (ETH = $2500) ---
        MockChainlinkFeed ethFeed = new MockChainlinkFeed(2500e8);

        // --- Deploy protocol (behind proxies) ---
        AddressBook addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (deployer))))
        );
        Controller controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), deployer))
                )
            )
        );
        MarginPool pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );
        OTokenFactory factory = OTokenFactory(
            address(
                new ERC1967Proxy(
                    address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
                )
            )
        );
        Oracle oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), deployer))
                )
            )
        );
        Whitelist whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), deployer))
                )
            )
        );
        BatchSettler settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), deployer, deployer))
                )
            )
        );

        // --- Wire AddressBook ---
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        // --- Whitelist deployer as MM ---
        settler.setWhitelistedMM(deployer, true);

        // --- Whitelist assets and products ---
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true); // PUT
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false); // CALL

        // --- Set Chainlink feed ---
        oracle.setPriceFeed(address(weth), address(ethFeed));

        // --- Mint tokens to deployer for testing ---
        weth.mint(deployer, 1000e18);
        usdc.mint(deployer, 10_000_000e6);

        // --- Mint tokens to Anvil accounts 1-3 for testing ---
        address acc1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address acc2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        address acc3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

        weth.mint(acc1, 100e18);
        weth.mint(acc2, 100e18);
        weth.mint(acc3, 100e18);
        usdc.mint(acc1, 1_000_000e6);
        usdc.mint(acc2, 1_000_000e6);
        usdc.mint(acc3, 1_000_000e6);

        vm.stopBroadcast();

        // --- Log addresses (parsed by deploy.sh) ---
        console.log("DEPLOYED:AddressBook:%s", address(addressBook));
        console.log("DEPLOYED:Controller:%s", address(controller));
        console.log("DEPLOYED:MarginPool:%s", address(pool));
        console.log("DEPLOYED:OTokenFactory:%s", address(factory));
        console.log("DEPLOYED:Oracle:%s", address(oracle));
        console.log("DEPLOYED:Whitelist:%s", address(whitelist));
        console.log("DEPLOYED:BatchSettler:%s", address(settler));
        console.log("DEPLOYED:MockWETH:%s", address(weth));
        console.log("DEPLOYED:MockUSDC:%s", address(usdc));
        console.log("DEPLOYED:MockChainlinkFeed:%s", address(ethFeed));
    }
}
