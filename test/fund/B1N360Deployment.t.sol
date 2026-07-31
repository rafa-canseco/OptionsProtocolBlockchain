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
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {B1N360ZeroDelayFundFactory} from "../../src/fund/B1N360ZeroDelayFundFactory.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {B1N360Base} from "../../script/fund/B1N360Base.sol";
import {B1N360Operations} from "../../script/fund/B1N360Operations.sol";
import {
    DeployTokenizedCoveredCallFundBaseSepolia
} from "../../script/fund/DeployTokenizedCoveredCallFundBaseSepolia.s.sol";

contract B1N360DeployHarness is DeployTokenizedCoveredCallFundBaseSepolia {
    function deployForTest(DeployConfig memory config) external returns (DeploymentAddresses memory) {
        return _deploy(config, address(this));
    }

    function validateExternalConfig(DeployConfig memory config) external view {
        _validateExternalConfig(config);
    }
}

contract B1N360OperationsHarness is B1N360Operations {
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

    function accessFinalized(FundAccessManager manager, address adapter, address inKindEscrow, address emergencyEscrow)
        external
        view
        returns (bool)
    {
        return _isAccessPhaseFinalized(manager, adapter, inKindEscrow, emergencyEscrow);
    }

    function policyFinalized(PolicyConfig memory config) external view returns (bool) {
        return _isPolicyPhaseFinalized(config);
    }

    function verifyPolicy(DeployConfig memory deployConfig, PolicyConfig memory policyConfig) external view {
        _verifyDeployedPolicy(deployConfig, policyConfig);
    }

    function requireOpenDepositsReadiness(FundVault vault, StrategyManager strategyManager, address adapter)
        external
        view
    {
        _requireOpenDepositsReadiness(vault, strategyManager, adapter);
    }

    function openDepositsOperation(address vault) external pure returns (Operation memory) {
        return _openDepositsOperation(vault);
    }
}

contract B1N360DeploymentTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockChainlinkFeed internal spotFeed;
    MockSwapRouter internal swapRouter;
    AddressBook internal addressBook;
    BatchSettler internal settler;
    B1N360DeployHarness internal deployHarness;
    B1N360OperationsHarness internal operationsHarness;

    function setUp() public {
        vm.chainId(84_532);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        spotFeed = new MockChainlinkFeed(2_500e8);
        swapRouter = new MockSwapRouter(address(usdc));
        swapRouter.setPriceFeed(address(weth), address(spotFeed));
        _deployV1();
        deployHarness = new B1N360DeployHarness();
        operationsHarness = new B1N360OperationsHarness();
    }

    function test_deployConfigureAndOnboardRemainPausedAndInactive() public {
        B1N360Base.DeployConfig memory deployConfig = _deployConfig();
        address controller = addressBook.controller();
        address settlerAddress = address(settler);
        address controllerImplementation = _implementation(controller);
        address settlerImplementation = _implementation(settlerAddress);

        B1N360Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(deployConfig);
        assertTrue(B1N360ZeroDelayFundFactory(deployed.fundFactory).fundCreated());
        assertEq(FundVault(deployed.fundVaultProxy).asset(), address(weth));
        assertTrue(FundVault(deployed.fundVaultProxy).depositsPaused());
        assertEq(FundShare(deployed.fundShareProxy).asset(), address(weth));

        CoveredCallFundAdapter adapter = CoveredCallFundAdapter(deployed.coveredCallFundAdapterProxy);
        assertEq(adapter.fund(), deployed.fundVaultProxy);
        assertEq(adapter.strategyManager(), deployed.strategyManagerProxy);
        assertEq(adapter.accountingAsset(), address(weth));
        assertEq(adapter.usdc(), address(usdc));
        assertFalse(adapter.isOnboarded());

        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        B1N360Operations.Operation[] memory access = operationsHarness.accessOperations(
            address(manager),
            deployed.coveredCallFundAdapterProxy,
            deployed.inKindStrategyEscrow,
            deployed.emergencyStrategyEscrow
        );
        _executeManagerOperations(manager, access);
        assertTrue(
            operationsHarness.accessFinalized(
                manager,
                deployed.coveredCallFundAdapterProxy,
                deployed.inKindStrategyEscrow,
                deployed.emergencyStrategyEscrow
            )
        );

        B1N360Operations.PolicyConfig memory policy = _policyConfig(deployed);
        _executeRestrictedOperations(manager, operationsHarness.policyOperations(policy));
        assertTrue(operationsHarness.policyFinalized(policy));
        operationsHarness.verifyPolicy(deployConfig, policy);
        FundTypes.StrategyConfig memory strategy =
            StrategyManager(deployed.strategyManagerProxy).strategyConfig(deployed.coveredCallFundAdapterProxy);
        assertFalse(strategy.active);
        assertEq(strategy.maxAllocationBps, 2_500);
        assertEq(strategy.absoluteCap, 0.0025 ether);
        assertTrue(FundVault(deployed.fundVaultProxy).depositsPaused());

        settler.setPhysicalDeliveryVault(deployed.coveredCallFundAdapterProxy, true);
        assertTrue(adapter.isOnboarded());
        assertEq(_implementation(controller), controllerImplementation);
        assertEq(_implementation(settlerAddress), settlerImplementation);
    }

    function test_v1ProductConfigurationFailsClosedAndChangesOnlyRequiredFlags() public {
        Whitelist whitelist = Whitelist(
            _proxy(
                address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
            )
        );
        whitelist.whitelistUnderlying(address(weth));
        addressBook.setWhitelist(address(whitelist));
        address implementationBefore = _implementation(address(whitelist));

        vm.expectRevert(bytes("B1N360: WETH collateral"));
        deployHarness.validateExternalConfig(_deployConfig());

        whitelist.whitelistCollateral(address(weth));
        vm.expectRevert(bytes("B1N360: call product"));
        deployHarness.validateExternalConfig(_deployConfig());

        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);
        deployHarness.validateExternalConfig(_deployConfig());
        assertEq(_implementation(address(whitelist)), implementationBefore);
        assertTrue(whitelist.isWhitelistedUnderlying(address(weth)));
        assertTrue(whitelist.isWhitelistedCollateral(address(weth)));
        assertTrue(whitelist.isProductWhitelisted(address(weth), address(usdc), address(weth), false));
        assertFalse(whitelist.isWhitelistedCollateral(address(usdc)));
        assertFalse(whitelist.isProductWhitelisted(address(weth), address(usdc), address(usdc), true));
    }

    function test_externalConfigRejectsThirdCoveredCallObserver() public {
        B1N360Base.DeployConfig memory config = _deployConfig();
        address[] memory observers = new address[](3);
        observers[0] = config.approvedObservers[0];
        observers[1] = config.approvedObservers[1];
        observers[2] = address(0xC0FFEE);
        config.approvedObservers = observers;

        vm.expectRevert(bytes("B1N360: observers"));
        deployHarness.validateExternalConfig(config);
    }

    function test_activationDoesNotOpenDepositsAndExplicitNavGatedPhaseDoes() public {
        B1N360Base.DeployConfig memory deployConfig = _deployConfig();
        B1N360Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(deployConfig);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        FundVault vault = FundVault(deployed.fundVaultProxy);
        StrategyManager strategyManager = StrategyManager(deployed.strategyManagerProxy);

        _executeManagerOperations(
            manager,
            operationsHarness.accessOperations(
                address(manager),
                deployed.coveredCallFundAdapterProxy,
                deployed.inKindStrategyEscrow,
                deployed.emergencyStrategyEscrow
            )
        );
        B1N360Operations.PolicyConfig memory policy = _policyConfig(deployed);
        _executeRestrictedOperations(manager, operationsHarness.policyOperations(policy));
        settler.setPhysicalDeliveryVault(deployed.coveredCallFundAdapterProxy, true);

        assertTrue(vault.depositsPaused());
        bytes memory activationData = abi.encodeCall(
            strategyManager.resumeAllocation,
            (
                deployed.coveredCallFundAdapterProxy,
                strategyManager.allocationPauseNonce(deployed.coveredCallFundAdapterProxy)
            )
        );
        manager.execute(address(strategyManager), activationData);
        assertTrue(strategyManager.strategyConfig(deployed.coveredCallFundAdapterProxy).active);
        assertTrue(vault.depositsPaused());

        vm.setEnv("FUND_BACKEND_NAV_RECONCILED", "false");
        vm.expectRevert(bytes("B1N360: backend NAV not reconciled"));
        operationsHarness.requireOpenDepositsReadiness(vault, strategyManager, deployed.coveredCallFundAdapterProxy);

        vm.setEnv("FUND_BACKEND_NAV_RECONCILED", "true");
        _commitZeroNav(vault, deployed.fundAccountingProxy);
        operationsHarness.requireOpenDepositsReadiness(vault, strategyManager, deployed.coveredCallFundAdapterProxy);

        B1N360Operations.Operation memory open = operationsHarness.openDepositsOperation(address(vault));
        manager.execute(open.target, open.data);
        assertFalse(vault.depositsPaused());
    }

    function test_accountingRoleMigrationPreservesReporterSetAndOtherRoles() public {
        B1N360Base.DeployConfig memory deployConfig = _deployConfig();
        B1N360Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(deployConfig);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        FundAccounting accounting = FundAccounting(deployed.fundAccountingProxy);
        B1N360Operations.PolicyConfig memory policy = _policyConfig(deployed);
        _executeRestrictedOperations(manager, operationsHarness.policyOperations(policy));

        address oldAccounting = address(this);
        address navSubmitter = address(0x195D);
        bytes32 reportersBefore = keccak256(
            abi.encode(
                accounting.reporterSetVersion(),
                accounting.reporterThreshold(),
                accounting.activeReporterAt(0),
                accounting.activeReporterAt(1)
            )
        );
        uint256 allocatorCountBefore = manager.roleMemberCount(FundConstants.ALLOCATOR_ROLE);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(manager.grantRole, (FundConstants.ACCOUNTING_ROLE, navSubmitter, uint32(0)));
        calls[1] = abi.encodeCall(manager.revokeRole, (FundConstants.ACCOUNTING_ROLE, oldAccounting));
        manager.multicall(calls);

        assertEq(manager.roleMemberCount(FundConstants.ACCOUNTING_ROLE), 1);
        assertEq(manager.roleMemberAt(FundConstants.ACCOUNTING_ROLE, 0), navSubmitter);
        (bool submitterActive, uint32 submitterDelay) = manager.hasRole(FundConstants.ACCOUNTING_ROLE, navSubmitter);
        (bool oldActive,) = manager.hasRole(FundConstants.ACCOUNTING_ROLE, oldAccounting);
        assertTrue(submitterActive);
        assertEq(submitterDelay, 0);
        assertFalse(oldActive);
        assertEq(manager.roleMemberCount(FundConstants.ALLOCATOR_ROLE), allocatorCountBefore);
        assertEq(
            manager.getTargetFunctionRole(deployed.fundAccountingProxy, FundAccounting.submitNav.selector),
            FundConstants.ACCOUNTING_ROLE
        );
        assertEq(
            keccak256(
                abi.encode(
                    accounting.reporterSetVersion(),
                    accounting.reporterThreshold(),
                    accounting.activeReporterAt(0),
                    accounting.activeReporterAt(1)
                )
            ),
            reportersBefore
        );
    }

    function test_factoryIsOneShotAndBaseSepoliaOnly() public {
        B1N360Base.DeployConfig memory config = _deployConfig();
        B1N360Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(config);
        B1N360ZeroDelayFundFactory factory = B1N360ZeroDelayFundFactory(deployed.fundFactory);

        FundFactory.CreateFundParams memory duplicate = FundFactory.CreateFundParams({
            implementationVersion: config.implementationVersion,
            salt: keccak256("SECOND"),
            name: config.fundName,
            symbol: config.fundSymbol,
            asset: weth,
            minimumIdleBps: config.minimumIdleBps,
            navActivationDelay: config.navActivationDelay,
            maxSnapshotAge: config.maxSnapshotAge,
            maxNavWindowLength: config.maxNavWindowLength,
            feeConfig: config.feeConfig,
            roles: config.roles
        });
        vm.expectRevert(B1N360ZeroDelayFundFactory.FundAlreadyCreated.selector);
        factory.createFund(duplicate);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(B1N360ZeroDelayFundFactory.WrongDeploymentChain.selector, 1));
        new B1N360ZeroDelayFundFactory(address(this));
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
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);
    }

    function _deployConfig() private view returns (B1N360Base.DeployConfig memory config) {
        address[] memory observers = new address[](2);
        observers[0] = address(0xA11CE);
        observers[1] = address(0xB0B);
        config = B1N360Base.DeployConfig({
            factoryOwner: address(this),
            addressBook: address(addressBook),
            weth: address(weth),
            usdc: address(usdc),
            adapterSwapRouter: address(swapRouter),
            adapterSwapFeeTier: 3_000,
            implementationVersion: 1,
            compatibilityVersion: 1,
            fundSalt: keccak256("B1N-360-LOCAL-DRY-RUN"),
            fundName: "b1nary ETH Covered Call Fund",
            fundSymbol: "bCALL",
            minimumIdleBps: 0,
            navActivationDelay: 1,
            maxSnapshotAge: 50,
            maxNavWindowLength: 50,
            feeConfig: FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 0,
                maxManagementFeeBps: 0,
                maxPerformanceFeeBps: 0,
                maxAccrualInterval: 0,
                crystallizationPeriod: 0,
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
            adapterRiskConfig: ICoveredCallFundAdapter.RiskConfig({
                minExpiryDelay: 129_600,
                maxExpiryDelay: 216_000,
                settlementDefaultDelay: 1 hours,
                minPremiumBps: 10,
                maxSwapSlippageBps: 500,
                maxOpenPositions: 1,
                maxUtilizationBps: 2_500,
                minStrike: 1_000e8,
                maxStrike: 10_000e8,
                maxCollateralPerPosition: 0.0025 ether,
                maxUsdcPerSwap: 32e6
            }),
            spotFeed: address(spotFeed),
            spotFeedDecimals: 8,
            maxSpotStaleness: 1 hours,
            maxObservationWindow: 120,
            observationQuorum: 2,
            approvedObservers: observers
        });
    }

    function _commitZeroNav(FundVault vault, address accounting) private {
        vm.roll(block.number + 2);
        FundTypes.NavCommit memory current = vault.activeNavWindow();
        FundTypes.NavCommit memory nav = FundTypes.NavCommit({
            grossAssets: 0,
            liabilities: 0,
            netAssets: 0,
            liquidAccountingAssets: 0,
            baseExitCost: 0,
            snapshotBlock: uint64(block.number - 1),
            validAfterBlock: uint64(block.number),
            validUntilBlock: uint64(block.number + 10),
            reporterSetVersion: 1,
            reportNonce: current.reportNonce + 1,
            positionsHash: current.positionsHash,
            reportHash: keccak256("B1N360_TEST_NAV"),
            signaturesHash: keccak256("B1N360_TEST_SIGNATURES"),
            fundFlowNonce: vault.fundFlowNonce(),
            idleStateHash: vault.idleStateHash()
        });

        vm.startPrank(accounting);
        uint256 lockId = vault.beginModuleExecution(vault.compatibilityVersion());
        vault.commitNav(nav, 0, address(0));
        vault.endModuleExecution(lockId);
        vm.stopPrank();
    }

    function _policyConfig(B1N360Base.DeploymentAddresses memory deployed)
        private
        pure
        returns (B1N360Operations.PolicyConfig memory config)
    {
        address[] memory reporters = new address[](2);
        reporters[0] = address(0xA11CE);
        reporters[1] = address(0xB0B);
        config = B1N360Operations.PolicyConfig({
            accounting: deployed.fundAccountingProxy,
            flowManager: deployed.fundFlowManagerProxy,
            strategyManager: deployed.strategyManagerProxy,
            adapter: deployed.coveredCallFundAdapterProxy,
            valuator: deployed.coveredCallFundValuator,
            inKindEscrow: deployed.inKindStrategyEscrow,
            emergencyEscrow: deployed.emergencyStrategyEscrow,
            reporters: reporters,
            reporterThreshold: 2,
            reporterSetVersion: 1,
            maxExitFeeBps: 0,
            maxWindowOutflowBps: 2_500,
            minimumIdleBps: 0,
            maxAllocationBps: 2_500,
            maxLossBps: 10_000,
            cooldown: 0,
            adapterInterfaceVersion: 1,
            absoluteCap: 0.0025 ether
        });
    }

    function _executeManagerOperations(FundAccessManager manager, B1N360Operations.Operation[] memory operations)
        private
    {
        bytes[] memory calls = new bytes[](operations.length);
        for (uint256 i; i < operations.length; ++i) {
            calls[i] = operations[i].data;
        }
        manager.multicall(calls);
    }

    function _executeRestrictedOperations(AccessManager manager, B1N360Operations.Operation[] memory operations)
        private
    {
        bytes[] memory calls = new bytes[](operations.length);
        for (uint256 i; i < operations.length; ++i) {
            calls[i] = abi.encodeCall(manager.execute, (operations[i].target, operations[i].data));
        }
        manager.multicall(calls);
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _proxy(address implementation, bytes memory data) private returns (address) {
        return address(new ERC1967Proxy(implementation, data));
    }
}
