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
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockSwapRouter.sol";

/**
 * @title DeployBeta
 * @notice Deploys the full beta stack to Base Sepolia (UUPS proxied).
 *         Includes mock tokens (LUSD/LETH), mock infrastructure (Aave/SwapRouter),
 *         all 7 protocol contracts behind proxies.
 *
 *         Usage:
 *         forge script script/DeployBeta.s.sol:DeployBeta \
 *           --rpc-url base_sepolia \
 *           --broadcast \
 *           --verify \
 *           -vvvv
 */
contract DeployBeta is Script {
    // Store addresses as state to avoid stack-too-deep
    MockERC20 leth;
    MockERC20 lusd;
    MockERC20 lbtc;
    MockChainlinkFeed ethFeed;
    MockChainlinkFeed btcFeed;
    MockAavePool mockAave;
    MockSwapRouter mockRouter;
    AddressBook addressBook;
    Controller controller;
    MarginPool pool;
    OTokenFactory factory;
    Oracle oracle;
    Whitelist whitelist;
    BatchSettler settler;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        _deployMocks();
        _deployProtocol(deployer);
        _wireAddressBook();
        _configure(deployer);

        vm.stopBroadcast();

        _logAddresses();
    }

    function _deployMocks() internal {
        leth = new MockERC20("Loot ETH", "LETH", 18);
        lusd = new MockERC20("Loot USD", "LUSD", 6);
        lbtc = new MockERC20("Loot BTC", "LBTC", 8);
        ethFeed = new MockChainlinkFeed(2500e8);
        btcFeed = new MockChainlinkFeed(90_000e8);
        mockAave = new MockAavePool();
        mockRouter = new MockSwapRouter(address(lusd));
        mockRouter.setPriceFeed(address(leth), address(ethFeed));
        mockRouter.setPriceFeed(address(lbtc), address(btcFeed));
    }

    function _deployProtocol(address deployer) internal {
        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (deployer))))
        );
        controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), deployer))
                )
            )
        );
        pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );
        factory = OTokenFactory(
            address(
                new ERC1967Proxy(
                    address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
                )
            )
        );
        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), deployer))
                )
            )
        );
        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), deployer))
                )
            )
        );
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), deployer, deployer))
                )
            )
        );
    }

    function _wireAddressBook() internal {
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    function _configure(address deployer) internal {
        // Set deployer as operator on factory and oracle
        factory.setOperator(deployer);
        oracle.setOperator(deployer);

        // Whitelist deployer as MM
        settler.setWhitelistedMM(deployer, true);

        // Whitelist tokens and products — ETH
        whitelist.whitelistUnderlying(address(leth));
        whitelist.whitelistCollateral(address(lusd));
        whitelist.whitelistCollateral(address(leth));
        whitelist.whitelistProduct(address(leth), address(lusd), address(lusd), true); // ETH PUT
        whitelist.whitelistProduct(address(leth), address(lusd), address(leth), false); // ETH CALL

        // Whitelist tokens and products — BTC
        whitelist.whitelistUnderlying(address(lbtc));
        whitelist.whitelistCollateral(address(lbtc));
        whitelist.whitelistProduct(address(lbtc), address(lusd), address(lusd), true); // BTC PUT
        whitelist.whitelistProduct(address(lbtc), address(lusd), address(lbtc), false); // BTC CALL

        // Oracle price feeds
        oracle.setPriceFeed(address(leth), address(ethFeed));
        oracle.setPriceFeed(address(lbtc), address(btcFeed));

        // BatchSettler: mock infra + fees
        settler.setAavePool(address(mockAave));
        settler.setSwapRouter(address(mockRouter));
        settler.setSwapFeeTier(500);
        settler.setTreasury(deployer);
        settler.setProtocolFeeBps(400); // 4%

        // Oracle: price deviation threshold (10%)
        oracle.setPriceDeviationThreshold(1000);

        // Controller: set deployer as partial pauser
        controller.setPartialPauser(deployer);

        // Mint initial tokens to deployer
        lusd.mint(deployer, 1_000_000e6);
        leth.mint(deployer, 1_000e18);
        lbtc.mint(deployer, 100e8);

        // MM approvals: deployer approves MarginPool to pull collateral
        lusd.approve(address(pool), type(uint256).max);
        leth.approve(address(pool), type(uint256).max);
        lbtc.approve(address(pool), type(uint256).max);

        // MM approvals: deployer approves BatchSettler to pull premium
        lusd.approve(address(settler), type(uint256).max);
    }

    function _logAddresses() internal view {
        console.log("DEPLOYED:LETH:%s", address(leth));
        console.log("DEPLOYED:LUSD:%s", address(lusd));
        console.log("DEPLOYED:LBTC:%s", address(lbtc));
        console.log("DEPLOYED:MockChainlinkFeedETH:%s", address(ethFeed));
        console.log("DEPLOYED:MockChainlinkFeedBTC:%s", address(btcFeed));
        console.log("DEPLOYED:MockAavePool:%s", address(mockAave));
        console.log("DEPLOYED:MockSwapRouter:%s", address(mockRouter));
        console.log("DEPLOYED:AddressBook:%s", address(addressBook));
        console.log("DEPLOYED:Controller:%s", address(controller));
        console.log("DEPLOYED:MarginPool:%s", address(pool));
        console.log("DEPLOYED:OTokenFactory:%s", address(factory));
        console.log("DEPLOYED:Oracle:%s", address(oracle));
        console.log("DEPLOYED:Whitelist:%s", address(whitelist));
        console.log("DEPLOYED:BatchSettler:%s", address(settler));
    }
}
