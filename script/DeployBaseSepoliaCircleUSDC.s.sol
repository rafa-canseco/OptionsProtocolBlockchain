// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressBook} from "../src/core/AddressBook.sol";
import {BatchSettler} from "../src/core/BatchSettler.sol";
import {Controller} from "../src/core/Controller.sol";
import {MarginPool} from "../src/core/MarginPool.sol";
import {Oracle} from "../src/core/Oracle.sol";
import {OTokenFactory} from "../src/core/OTokenFactory.sol";
import {Whitelist} from "../src/core/Whitelist.sol";
import {BaseVaultAdapter} from "../src/adapters/BaseVaultAdapter.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {MockChainlinkFeed} from "../src/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockFundedSwapRouter} from "../src/mocks/MockFundedSwapRouter.sol";

contract DeployBaseSepoliaCircleUSDC is Script {
    address public constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    MockERC20 public leth;
    MockERC20 public lbtc;
    MockChainlinkFeed public ethFeed;
    MockChainlinkFeed public btcFeed;
    MockAavePool public mockAave;
    MockFundedSwapRouter public mockRouter;
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;
    BaseVaultAdapter public adapter;
    address public adapterImplementation;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address owner = vm.envOr("BASE_OWNER", deployer);
        address operator = vm.envOr("BASE_OPERATOR", deployer);
        address agent = vm.envOr("BASE_AGENT", operator);
        address treasury = vm.envOr("BASE_TREASURY", deployer);
        address marketMaker = vm.envOr("BASE_MARKET_MAKER", operator);
        require(owner == deployer, "BASE_OWNER must be deployer for one-step deploy");

        vm.startBroadcast(deployerKey);

        _deployMocks();
        _deployProtocol(owner, operator);
        _wireAddressBook();
        _configure(owner, operator, agent, treasury, marketMaker);

        vm.stopBroadcast();

        _logAddresses(owner, operator, agent, treasury, marketMaker);
    }

    function _deployMocks() internal {
        leth = new MockERC20("Loot ETH", "LETH", 18);
        lbtc = new MockERC20("Loot BTC", "LBTC", 8);
        ethFeed = new MockChainlinkFeed(2500e8);
        btcFeed = new MockChainlinkFeed(90_000e8);
        mockAave = new MockAavePool();
        mockRouter = new MockFundedSwapRouter(BASE_SEPOLIA_USDC);
        mockRouter.setPriceFeed(address(leth), address(ethFeed));
        mockRouter.setPriceFeed(address(lbtc), address(btcFeed));
    }

    function _deployProtocol(address owner, address operator) internal {
        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (owner))))
        );
        controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), owner))
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
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), owner))
                )
            )
        );
        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), owner))
                )
            )
        );
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operator, owner))
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

    function _configure(address owner, address operator, address agent, address treasury, address marketMaker)
        internal
    {
        factory.setOperator(operator);
        oracle.setOperator(operator);

        settler.setWhitelistedMM(marketMaker, true);

        whitelist.whitelistUnderlying(address(leth));
        whitelist.whitelistUnderlying(address(lbtc));
        whitelist.whitelistCollateral(BASE_SEPOLIA_USDC);
        whitelist.whitelistCollateral(address(leth));
        whitelist.whitelistCollateral(address(lbtc));

        whitelist.whitelistProduct(address(leth), BASE_SEPOLIA_USDC, BASE_SEPOLIA_USDC, true);
        whitelist.whitelistProduct(address(leth), BASE_SEPOLIA_USDC, address(leth), false);
        whitelist.whitelistProduct(address(lbtc), BASE_SEPOLIA_USDC, BASE_SEPOLIA_USDC, true);
        whitelist.whitelistProduct(address(lbtc), BASE_SEPOLIA_USDC, address(lbtc), false);

        oracle.setPriceFeed(address(leth), address(ethFeed));
        oracle.setPriceFeed(address(lbtc), address(btcFeed));
        oracle.setPriceDeviationThreshold(1000);

        settler.setAavePool(address(mockAave));
        settler.setSwapRouter(address(mockRouter));
        settler.setSwapFeeTier(500);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400);

        controller.setPartialPauser(operator);

        BaseVaultAdapter adapterImpl = new BaseVaultAdapter();
        adapterImplementation = address(adapterImpl);
        adapter = BaseVaultAdapter(
            address(
                new ERC1967Proxy(
                    adapterImplementation,
                    abi.encodeCall(
                        BaseVaultAdapter.initialize,
                        (address(addressBook), address(settler), BASE_SEPOLIA_USDC, owner, operator, agent)
                    )
                )
            )
        );

        leth.mint(owner, 1_000e18);
        lbtc.mint(owner, 100e8);
        IERC20(BASE_SEPOLIA_USDC).approve(address(pool), type(uint256).max);
        IERC20(BASE_SEPOLIA_USDC).approve(address(settler), type(uint256).max);
    }

    function _logAddresses(address owner, address operator, address agent, address treasury, address marketMaker)
        internal
        view
    {
        console.log("DEPLOYED:LETH:%s", address(leth));
        console.log("DEPLOYED:LBTC:%s", address(lbtc));
        console.log("DEPLOYED:MockChainlinkFeedETH:%s", address(ethFeed));
        console.log("DEPLOYED:MockChainlinkFeedBTC:%s", address(btcFeed));
        console.log("DEPLOYED:MockAavePool:%s", address(mockAave));
        console.log("DEPLOYED:MockFundedSwapRouter:%s", address(mockRouter));
        console.log("DEPLOYED:AddressBook:%s", address(addressBook));
        console.log("DEPLOYED:Controller:%s", address(controller));
        console.log("DEPLOYED:MarginPool:%s", address(pool));
        console.log("DEPLOYED:OTokenFactory:%s", address(factory));
        console.log("DEPLOYED:Oracle:%s", address(oracle));
        console.log("DEPLOYED:Whitelist:%s", address(whitelist));
        console.log("DEPLOYED:BatchSettler:%s", address(settler));
        console.log("DEPLOYED:BaseVaultAdapterImplementation:%s", adapterImplementation);
        console.log("DEPLOYED:BaseVaultAdapter:%s", address(adapter));
        console.log("CONFIG:BaseSepoliaUSDC:%s", BASE_SEPOLIA_USDC);
        console.log("CONFIG:Owner:%s", owner);
        console.log("CONFIG:Operator:%s", operator);
        console.log("CONFIG:Agent:%s", agent);
        console.log("CONFIG:Treasury:%s", treasury);
        console.log("CONFIG:MarketMaker:%s", marketMaker);
    }
}
