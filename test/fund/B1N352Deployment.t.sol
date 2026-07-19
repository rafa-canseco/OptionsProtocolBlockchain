// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {MarginPool} from "../../src/core/MarginPool.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {Whitelist} from "../../src/core/Whitelist.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {B1N352Base} from "../../script/fund/B1N352Base.sol";
import {DeployTokenizedCspFundBaseSepolia} from "../../script/fund/DeployTokenizedCspFundBaseSepolia.s.sol";
import {B1N352Operations} from "../../script/fund/B1N352Operations.sol";

contract B1N352DeployHarness is DeployTokenizedCspFundBaseSepolia {
    function deployForTest(DeployConfig memory config) external returns (DeploymentAddresses memory) {
        return _deploy(config, address(this));
    }
}

contract B1N352OperationsHarness is B1N352Operations {
    function accessOperations(address manager, address adapter, address inKindEscrow, address emergencyEscrow)
        external
        pure
        returns (Operation[] memory)
    {
        return _accessOperations(manager, adapter, inKindEscrow, emergencyEscrow);
    }

    function policyOperations(PolicyConfig memory config) external pure returns (Operation[] memory) {
        return _policyOperations(config);
    }

    function activationOperation(address strategyManager, address adapter) external view returns (Operation memory) {
        return _activationOperation(strategyManager, adapter);
    }
}

contract B1N352DeploymentTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockChainlinkFeed internal spotFeed;
    MockSwapRouter internal swapRouter;
    AddressBook internal addressBook;
    BatchSettler internal settler;
    B1N352DeployHarness internal deployHarness;
    B1N352OperationsHarness internal operationsHarness;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        spotFeed = new MockChainlinkFeed(2_500e8);
        swapRouter = new MockSwapRouter(address(usdc));
        swapRouter.setPriceFeed(address(weth), address(spotFeed));
        _deployV1();
        deployHarness = new B1N352DeployHarness();
        operationsHarness = new B1N352OperationsHarness();
    }

    function test_localDryRunDeployConfigureOnboardAndActivate() public {
        B1N352Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(_deployConfig());
        AccessManager manager = AccessManager(deployed.accessManager);

        assertEq(FundFactory(deployed.fundFactory).owner(), address(this));
        assertEq(_implementation(deployed.fundVaultProxy), deployed.fundVaultImplementation);
        assertEq(_implementation(deployed.fundShareProxy), deployed.fundShareImplementation);
        assertEq(_implementation(deployed.fundAccountingProxy), deployed.fundAccountingImplementation);
        assertEq(_implementation(deployed.fundFlowManagerProxy), deployed.fundFlowManagerImplementation);
        assertEq(_implementation(deployed.strategyManagerProxy), deployed.strategyManagerImplementation);
        assertEq(_implementation(deployed.cspFundAdapterProxy), deployed.cspFundAdapterImplementation);
        assertGt(deployed.cspAdapterOperations.code.length, 0);

        FundVault vault = FundVault(deployed.fundVaultProxy);
        FundFlowManager flow = FundFlowManager(deployed.fundFlowManagerProxy);
        StrategyManager strategy = StrategyManager(deployed.strategyManagerProxy);
        ICspFundAdapter adapter = ICspFundAdapter(deployed.cspFundAdapterProxy);
        assertEq(vault.asset(), address(usdc));
        assertEq(vault.strategyManager(), address(strategy));
        assertEq(StrategyAssetEscrow(deployed.inKindStrategyEscrow).FUND(), address(vault));
        assertEq(StrategyAssetEscrow(deployed.emergencyStrategyEscrow).FUND(), address(vault));
        assertFalse(adapter.isOnboarded());
        assertEq(strategy.strategyConfig(address(adapter)).interfaceVersion, 0);
        (address inKindEscrow, address emergencyEscrow) = flow.strategyExitEscrows();
        assertEq(inKindEscrow, address(0));
        assertEq(emergencyEscrow, address(0));

        (bool adapterUpgrader, uint32 adapterUpgradeDelay) =
            manager.hasRole(FundConstants.ADAPTER_UPGRADER_ROLE, address(this));
        assertTrue(adapterUpgrader);
        assertEq(adapterUpgradeDelay, FundConstants.ADAPTER_UPGRADE_DELAY);

        B1N352Operations.Operation[] memory accessOperations = operationsHarness.accessOperations(
            address(manager), address(adapter), deployed.inKindStrategyEscrow, deployed.emergencyStrategyEscrow
        );
        _scheduleAndExecute(manager, accessOperations, FundConstants.CORE_UPGRADE_DELAY);
        assertEq(
            manager.getTargetFunctionRole(address(adapter), bytes4(keccak256("upgradeToAndCall(address,bytes)"))),
            FundConstants.ADAPTER_UPGRADER_ROLE
        );

        B1N352Operations.PolicyConfig memory policy = _policyConfig(deployed);
        _scheduleAndExecute(manager, operationsHarness.policyOperations(policy), FundConstants.CURATOR_DELAY);
        assertFalse(strategy.strategyConfig(address(adapter)).active);
        (inKindEscrow, emergencyEscrow) = flow.strategyExitEscrows();
        assertEq(inKindEscrow, deployed.inKindStrategyEscrow);
        assertEq(emergencyEscrow, deployed.emergencyStrategyEscrow);

        settler.setPhysicalDeliveryVault(address(adapter), true);
        assertTrue(adapter.isOnboarded());

        B1N352Operations.Operation[] memory activationOperations = new B1N352Operations.Operation[](1);
        activationOperations[0] = operationsHarness.activationOperation(address(strategy), address(adapter));
        _scheduleAndExecute(manager, activationOperations, FundConstants.CURATOR_DELAY);
        assertTrue(strategy.strategyConfig(address(adapter)).active);

        _assertLegacyPerUserStateAbsent(address(vault));
    }

    function _deployV1() private {
        addressBook =
            AddressBook(_proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this)))));
        Controller controller = Controller(
            _proxy(
                address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), address(this)))
            )
        );
        MarginPool pool = MarginPool(
            _proxy(address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook))))
        );
        OTokenFactory optionFactory = OTokenFactory(
            _proxy(address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook))))
        );
        Oracle oracle = Oracle(
            _proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), address(this))))
        );
        Whitelist whitelist = Whitelist(
            _proxy(
                address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
            )
        );
        settler = BatchSettler(
            _proxy(
                address(new BatchSettler()),
                abi.encodeCall(BatchSettler.initialize, (address(addressBook), address(this), address(this)))
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(optionFactory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
        controller.setCustodiedRedemptionOnly(true);
        settler.setSwapRouter(address(swapRouter));
        settler.setSwapFeeTier(500);
        oracle.setPriceFeed(address(weth), address(spotFeed));
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
    }

    function _deployConfig() private view returns (B1N352Base.DeployConfig memory config) {
        address[] memory observers = new address[](2);
        observers[0] = address(0xA11CE);
        observers[1] = address(0xB0B);
        config = B1N352Base.DeployConfig({
            factoryOwner: address(this),
            addressBook: address(addressBook),
            accountingAsset: address(usdc),
            weth: address(weth),
            adapterSwapRouter: address(swapRouter),
            adapterSwapFeeTier: 500,
            implementationVersion: 1,
            compatibilityVersion: 1,
            fundSalt: keccak256("B1N-352-LOCAL-DRY-RUN"),
            fundName: "b1nary ETH CSP Fund",
            fundSymbol: "bCSP",
            minimumIdleBps: 2_000,
            navActivationDelay: 1,
            maxSnapshotAge: 20,
            maxNavWindowLength: 100,
            feeConfig: FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 0,
                maxManagementFeeBps: 200,
                maxPerformanceFeeBps: 2_000,
                maxAccrualInterval: 30 days,
                crystallizationPeriod: 1 days,
                feeRecipient: address(this)
            }),
            roles: FundFactory.RoleAccounts({
                admin: address(this),
                upgrader: address(this),
                accounting: address(this),
                allocator: address(this),
                processor: address(this),
                curator: address(this),
                guardian: address(this)
            }),
            adapterRiskConfig: ICspFundAdapter.RiskConfig({
                minExpiryDelay: 1 hours,
                maxExpiryDelay: 30 days,
                settlementDefaultDelay: 1 hours,
                minPremiumBps: 1,
                maxSwapSlippageBps: 100,
                maxOpenPositions: 1,
                minStrike: 100e8,
                maxStrike: 10_000e8,
                maxCollateralPerPosition: 1_000e6,
                maxWethPerSwap: 10e18
            }),
            spotFeed: address(spotFeed),
            spotFeedDecimals: 8,
            maxSpotStaleness: 1 hours,
            maxObservationWindow: 20,
            observationQuorum: 2,
            liabilityBufferBps: 1_000,
            approvedObservers: observers
        });
    }

    function _policyConfig(B1N352Base.DeploymentAddresses memory deployed)
        private
        pure
        returns (B1N352Operations.PolicyConfig memory config)
    {
        address[] memory reporters = new address[](2);
        reporters[0] = address(0xA11CE);
        reporters[1] = address(0xB0B);
        config = B1N352Operations.PolicyConfig({
            accounting: deployed.fundAccountingProxy,
            flowManager: deployed.fundFlowManagerProxy,
            strategyManager: deployed.strategyManagerProxy,
            adapter: deployed.cspFundAdapterProxy,
            valuator: deployed.cspFundValuator,
            inKindEscrow: deployed.inKindStrategyEscrow,
            emergencyEscrow: deployed.emergencyStrategyEscrow,
            reporters: reporters,
            reporterThreshold: 2,
            reporterSetVersion: 1,
            maxExitFeeBps: 50,
            maxWindowOutflowBps: 1_000,
            minimumIdleBps: 2_000,
            maxAllocationBps: 5_000,
            maxLossBps: 100,
            cooldown: 1 hours,
            adapterInterfaceVersion: 1,
            absoluteCap: 1_000e6
        });
    }

    function _scheduleAndExecute(AccessManager manager, B1N352Operations.Operation[] memory operations, uint256 delay)
        private
    {
        for (uint256 i; i < operations.length; ++i) {
            manager.schedule(operations[i].target, operations[i].data, 0);
        }
        vm.warp(block.timestamp + delay);
        for (uint256 i; i < operations.length; ++i) {
            manager.execute(operations[i].target, operations[i].data);
        }
    }

    function _assertLegacyPerUserStateAbsent(address vault) private view {
        (bool sharesOfSuccess,) = vault.staticcall(abi.encodeWithSignature("sharesOf(address)", address(this)));
        (bool assignedSuccess,) =
            vault.staticcall(abi.encodeWithSignature("claimableAssignedUnderlying(address)", address(this)));
        (bool generationSuccess,) = vault.staticcall(abi.encodeWithSignature("currentShareGeneration()"));
        assertFalse(sharesOfSuccess);
        assertFalse(assignedSuccess);
        assertFalse(generationSuccess);
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _proxy(address implementation, bytes memory data) private returns (address) {
        return address(new ERC1967Proxy(implementation, data));
    }
}
