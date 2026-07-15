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
import "../src/mocks/MockChainlinkFeed.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockSwapRouter.sol";
import "../src/vaults/CspBatchSettler.sol";
import "../src/vaults/EthCspOptionSelector.sol";
import "../src/vaults/EthCspVault.sol";
import "../src/vaults/interfaces/IEthCspOptionSelector.sol";

contract DeployCspVaultBaseSepolia is Script {
    uint256 private constant MAX_COLLATERAL_PER_BATCH = 1000e6;
    uint256 private constant MAX_UTILIZATION_BPS = 2500;
    uint256 private constant MIN_PREMIUM_BPS = 1;
    uint256 private constant MIN_STRIKE = 100e8;
    uint256 private constant MAX_STRIKE = 10_000e8;

    address private deployer;
    address private curator;
    address private allocator;
    address private settlementExecutor;
    address private feeRecipient;
    address private marketMaker;

    MockERC20 private usdc;
    MockERC20 private weth;
    MockChainlinkFeed private ethFeed;
    MockSwapRouter private swapRouter;
    AddressBook private addressBook;
    Controller private controller;
    MarginPool private marginPool;
    OTokenFactory private factory;
    Oracle private oracle;
    Whitelist private whitelist;
    CspBatchSettler private settler;
    EthCspVault private vault;
    EthCspOptionSelector private optionSelector;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
        curator = vm.envOr("CSP_CURATOR_ADDRESS", deployer);
        allocator = vm.envOr("CSP_ALLOCATOR_ADDRESS", deployer);
        settlementExecutor = vm.envOr("CSP_SETTLEMENT_EXECUTOR_ADDRESS", allocator);
        feeRecipient = vm.envOr("CSP_FEE_RECIPIENT_ADDRESS", deployer);
        marketMaker = vm.envOr("CSP_MARKET_MAKER_ADDRESS", deployer);

        usdc = MockERC20(vm.envAddress("CSP_MOCK_USDC_ADDRESS"));
        weth = MockERC20(vm.envAddress("CSP_MOCK_WETH_ADDRESS"));
        require(address(usdc).code.length > 0 && usdc.decimals() == 6, "invalid mock USDC");
        require(address(weth).code.length > 0 && weth.decimals() == 18, "invalid mock WETH");

        vm.startBroadcast(deployerKey);
        _deployInfrastructure();
        _deployCore();
        _wireCore();
        _configureCore();
        _deployAndConfigureVault();
        _fundSmokeAccounts();
        vm.stopBroadcast();

        _logDeployment();
    }

    function _deployInfrastructure() private {
        ethFeed = new MockChainlinkFeed(2500e8);
        swapRouter = new MockSwapRouter(address(usdc));
        swapRouter.setPriceFeed(address(weth), address(ethFeed));
    }

    function _deployCore() private {
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
        marginPool = MarginPool(
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
        settler = CspBatchSettler(
            address(
                new ERC1967Proxy(
                    address(new CspBatchSettler()),
                    abi.encodeCall(CspBatchSettler.initialize, (address(addressBook), settlementExecutor, deployer))
                )
            )
        );
    }

    function _wireCore() private {
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(marginPool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    function _configureCore() private {
        factory.setOperator(allocator);
        oracle.setOperator(allocator);
        oracle.setPriceFeed(address(weth), address(ethFeed));
        oracle.setPriceDeviationThreshold(1000);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        settler.setWhitelistedMM(marketMaker, true);
        settler.setTreasury(feeRecipient);
        settler.setProtocolFeeBps(400);
        settler.setSwapRouter(address(swapRouter));
        settler.setSwapFeeTier(500);

        controller.setPartialPauser(allocator);
        controller.setCustodiedRedemptionOnly(true);
    }

    function _deployAndConfigureVault() private {
        vault = new EthCspVault(address(addressBook), address(usdc), address(weth), allocator, feeRecipient, 1000);

        IEthCspOptionSelector.StrategyConfig memory selectorConfig = IEthCspOptionSelector.StrategyConfig({
            maxCollateralPerBatch: MAX_COLLATERAL_PER_BATCH,
            maxUtilizationBps: MAX_UTILIZATION_BPS,
            minPremiumBps: MIN_PREMIUM_BPS,
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 30 days,
            minStrike: MIN_STRIKE,
            maxStrike: MAX_STRIKE
        });
        optionSelector = new EthCspOptionSelector(deployer, selectorConfig);

        EthCspVault.StrategyConfig memory vaultConfig = EthCspVault.StrategyConfig({
            maxCollateralPerBatch: MAX_COLLATERAL_PER_BATCH,
            maxUtilizationBps: MAX_UTILIZATION_BPS,
            minPremiumBps: MIN_PREMIUM_BPS,
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 30 days,
            minStrike: MIN_STRIKE,
            maxStrike: MAX_STRIKE
        });
        vault.setStrategyConfig(vaultConfig);
        vault.setOptionSelector(address(optionSelector));
        vault.setSettlementDefaultDelay(1 hours);
        if (curator != deployer) {
            vault.setCurator(curator);
            optionSelector.setCurator(curator);
        }

        settler.setPhysicalDeliveryVault(address(vault), true);
        settler.setSettlementExecutorFor(address(vault), settlementExecutor, true);
    }

    function _fundSmokeAccounts() private {
        usdc.mint(deployer, 100_000e6);
        weth.mint(deployer, 100e18);
        if (marketMaker != deployer) usdc.mint(marketMaker, 100_000e6);
        if (marketMaker == deployer) usdc.approve(address(settler), type(uint256).max);
    }

    function _logDeployment() private view {
        console.log("DEPLOYED:MockUSDC:%s", address(usdc));
        console.log("DEPLOYED:MockWETH:%s", address(weth));
        console.log("DEPLOYED:MockChainlinkFeedETH:%s", address(ethFeed));
        console.log("DEPLOYED:MockSwapRouter:%s", address(swapRouter));
        console.log("DEPLOYED:AddressBook:%s", address(addressBook));
        console.log("DEPLOYED:Controller:%s", address(controller));
        console.log("DEPLOYED:MarginPool:%s", address(marginPool));
        console.log("DEPLOYED:OTokenFactory:%s", address(factory));
        console.log("DEPLOYED:Oracle:%s", address(oracle));
        console.log("DEPLOYED:Whitelist:%s", address(whitelist));
        console.log("DEPLOYED:CspBatchSettler:%s", address(settler));
        console.log("DEPLOYED:EthCspVault:%s", address(vault));
        console.log("DEPLOYED:EthCspOptionSelector:%s", address(optionSelector));
        console.log("ROLE:Owner:%s", deployer);
        console.log("ROLE:Curator:%s", curator);
        console.log("ROLE:Allocator:%s", allocator);
        console.log("ROLE:SettlementExecutor:%s", settlementExecutor);
        console.log("ROLE:MarketMaker:%s", marketMaker);
        console.log("CAP:MaxCollateralPerBatch:%s", MAX_COLLATERAL_PER_BATCH);
        console.log("CAP:MaxUtilizationBps:%s", MAX_UTILIZATION_BPS);
    }
}
