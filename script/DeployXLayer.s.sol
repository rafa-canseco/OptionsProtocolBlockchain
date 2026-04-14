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
 * @title DeployXLayer
 * @notice Deploys the full stack to XLayer testnet (chain 1952).
 *         Includes MockOKB/MockUSDC, mock infrastructure,
 *         all 7 protocol contracts behind UUPS proxies.
 *
 *         Usage:
 *         forge script script/DeployXLayer.s.sol:DeployXLayer \
 *           --rpc-url $XLAYER_TESTNET_RPC_URL \
 *           --broadcast \
 *           --slow \
 *           -vvvv
 */
contract DeployXLayer is Script {
    MockERC20 mockOkb;
    MockERC20 mockUsdc;
    MockChainlinkFeed okbFeed;
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
        mockOkb = new MockERC20("Mock OKB", "MockOKB", 18);
        mockUsdc = new MockERC20("Mock USDC", "MockUSDC", 6);
        okbFeed = new MockChainlinkFeed(50e8);
        mockAave = new MockAavePool();
        mockRouter = new MockSwapRouter(address(mockUsdc));
        mockRouter.setPriceFeed(address(mockOkb), address(okbFeed));
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
        factory.setOperator(deployer);
        oracle.setOperator(deployer);

        settler.setWhitelistedMM(deployer, true);

        // Whitelist OKB and USDC
        whitelist.whitelistUnderlying(address(mockOkb));
        whitelist.whitelistCollateral(address(mockUsdc));
        whitelist.whitelistCollateral(address(mockOkb));
        whitelist.whitelistProduct(address(mockOkb), address(mockUsdc), address(mockUsdc), true); // OKB PUT
        whitelist.whitelistProduct(address(mockOkb), address(mockUsdc), address(mockOkb), false); // OKB CALL

        // Oracle
        oracle.setPriceFeed(address(mockOkb), address(okbFeed));
        oracle.setPriceDeviationThreshold(1000);

        // BatchSettler
        settler.setAavePool(address(mockAave));
        settler.setSwapRouter(address(mockRouter));
        settler.setSwapFeeTier(500);
        settler.setTreasury(deployer);
        settler.setProtocolFeeBps(400);

        // Controller
        controller.setPartialPauser(deployer);

        // Mint initial tokens
        mockUsdc.mint(deployer, 10_000_000e6);
        mockOkb.mint(deployer, 1_000e18);

        // MM approvals: deployer approves MarginPool
        mockUsdc.approve(address(pool), type(uint256).max);
        mockOkb.approve(address(pool), type(uint256).max);

        // MM approvals: deployer approves BatchSettler
        mockUsdc.approve(address(settler), type(uint256).max);
    }

    function _logAddresses() internal view {
        console.log("DEPLOYED:MockOKB:%s", address(mockOkb));
        console.log("DEPLOYED:MockUSDC:%s", address(mockUsdc));
        console.log("DEPLOYED:MockChainlinkFeedOKB:%s", address(okbFeed));
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
