// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
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

    function requireExpectedV1Baseline(address addressBook_) external view {
        _requireExpectedV1Baseline(addressBook_);
    }

    function envUint16(string memory key) external view returns (uint16) {
        return _envUint16(key);
    }

    function requireExpectedImplementationCodehash(address proxy, string memory envKey) external view {
        _requireExpectedImplementationCodehash(proxy, envKey, "B1N352: test implementation hash");
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

    function verifyDeployedPolicy(DeployConfig memory deployConfig, PolicyConfig memory policyConfig, bool active)
        external
        view
    {
        _verifyDeployedPolicy(deployConfig, policyConfig, active);
    }

    function scheduleOperations(
        AccessManager manager,
        Operation[] memory operations,
        uint256 callerKey,
        bool phaseFinalized
    ) external {
        _scheduleOperations(manager, operations, callerKey, phaseFinalized);
    }

    function restartOperations(
        AccessManager manager,
        Operation[] memory operations,
        address scheduledCaller,
        uint256 restartCallerKey,
        bool phaseFinalized
    ) external {
        _restartOperations(manager, operations, scheduledCaller, restartCallerKey, phaseFinalized);
    }

    function executeOperations(
        AccessManager manager,
        Operation[] memory operations,
        uint256 callerKey,
        bool phaseFinalized
    ) external {
        _executeOperations(manager, operations, callerKey, phaseFinalized);
    }

    function cancelOperations(
        AccessManager manager,
        Operation[] memory operations,
        address scheduledCaller,
        uint256 cancelerKey
    ) external {
        _cancelOperations(manager, operations, scheduledCaller, cancelerKey);
    }

    function isPolicyPhaseFinalized(PolicyConfig memory config) external view returns (bool) {
        return _isPolicyPhaseFinalized(config);
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
        B1N352Base.DeployConfig memory deployConfig = _deployConfig();
        B1N352Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(deployConfig);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);

        assertEq(FundFactory(deployed.fundFactory).owner(), address(this));
        assertEq(address(FundFactory(deployed.fundFactory).accessManagerDeployer()), deployed.fundAccessManagerDeployer);
        assertEq(_implementation(deployed.fundVaultProxy), deployed.fundVaultImplementation);
        assertEq(_implementation(deployed.fundShareProxy), deployed.fundShareImplementation);
        assertEq(_implementation(deployed.fundAccountingProxy), deployed.fundAccountingImplementation);
        assertEq(_implementation(deployed.fundFlowManagerProxy), deployed.fundFlowManagerImplementation);
        assertEq(_implementation(deployed.strategyManagerProxy), deployed.strategyManagerImplementation);
        assertEq(_implementation(deployed.cspFundAdapterProxy), deployed.cspFundAdapterImplementation);
        assertGt(deployed.cspAdapterOperations.code.length, 0);
        assertEq(manager.roleMemberCount(manager.ADMIN_ROLE()), 1);
        assertEq(manager.roleMemberAt(manager.ADMIN_ROLE(), 0), address(this));
        assertEq(manager.roleMemberCount(FundConstants.REPORTER_ROLE), 0);
        assertEq(manager.configuredSelectorCount(deployed.strategyManagerProxy), 10);

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
        uint256 accessExecutedAt = block.timestamp;
        assertEq(
            manager.getTargetFunctionRole(address(adapter), bytes4(keccak256("upgradeToAndCall(address,bytes)"))),
            FundConstants.ADAPTER_UPGRADER_ROLE
        );
        assertEq(manager.getTargetAdminDelay(address(adapter)), 0);

        B1N352Operations.PolicyConfig memory policy = _policyConfig(deployed);
        _scheduleAndExecute(manager, operationsHarness.policyOperations(policy), FundConstants.CURATOR_DELAY);
        assertFalse(strategy.strategyConfig(address(adapter)).active);
        operationsHarness.verifyDeployedPolicy(deployConfig, policy, false);
        (inKindEscrow, emergencyEscrow) = flow.strategyExitEscrows();
        assertEq(inKindEscrow, deployed.inKindStrategyEscrow);
        assertEq(emergencyEscrow, deployed.emergencyStrategyEscrow);

        settler.setPhysicalDeliveryVault(address(adapter), true);
        assertTrue(adapter.isOnboarded());

        B1N352Operations.Operation[] memory activationOperations = new B1N352Operations.Operation[](1);
        activationOperations[0] = operationsHarness.activationOperation(address(strategy), address(adapter));
        _schedule(manager, activationOperations);
        strategy.reduceStrategyCap(address(adapter), 500e6, 2_500);
        vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
        _execute(manager, activationOperations);
        FundTypes.StrategyConfig memory activatedConfig = strategy.strategyConfig(address(adapter));
        assertTrue(activatedConfig.active);
        assertEq(activatedConfig.absoluteCap, 500e6);
        assertEq(activatedConfig.maxAllocationBps, 2_500);
        policy.absoluteCap = 500e6;
        policy.maxAllocationBps = 2_500;

        operationsHarness.verifyDeployedPolicy(deployConfig, policy, true);
        _assertPolicyMismatchesRejected(deployConfig, policy);

        assertEq(manager.getTargetAdminDelay(address(adapter)), 0);
        vm.warp(accessExecutedAt + manager.minSetback());
        assertEq(manager.getTargetAdminDelay(address(adapter)), FundConstants.CORE_UPGRADE_DELAY);
        assertEq(manager.getTargetAdminDelay(deployed.inKindStrategyEscrow), FundConstants.CORE_UPGRADE_DELAY);
        assertEq(manager.getTargetAdminDelay(deployed.emergencyStrategyEscrow), FundConstants.CORE_UPGRADE_DELAY);

        _assertLegacyPerUserStateAbsent(address(vault));
    }

    function test_expectedV1BaselineRejectsStructurallyValidWrongImplementation() public {
        _setExpectedV1Baseline();
        deployHarness.requireExpectedV1Baseline(address(addressBook));

        vm.setEnv("FUND_EXPECTED_V1_CONTROLLER_PROXY", vm.toString(address(new Controller())));
        vm.expectRevert(bytes("B1N352: controller proxy"));
        deployHarness.requireExpectedV1Baseline(address(addressBook));
        vm.setEnv("FUND_EXPECTED_V1_CONTROLLER_PROXY", vm.toString(addressBook.controller()));

        address wrongControllerImplementation = address(new Controller());
        vm.setEnv("FUND_EXPECTED_V1_CONTROLLER_IMPLEMENTATION", vm.toString(wrongControllerImplementation));
        vm.setEnv("FUND_EXPECTED_V1_CONTROLLER_CODEHASH", vm.toString(wrongControllerImplementation.codehash));
        vm.expectRevert(bytes("B1N352: controller implementation"));
        deployHarness.requireExpectedV1Baseline(address(addressBook));

        _setExpectedV1Baseline();
        vm.setEnv("FUND_EXPECTED_V1_ORACLE_PROXY", vm.toString(address(new Oracle())));
        vm.expectRevert(bytes("B1N352: oracle proxy"));
        deployHarness.requireExpectedV1Baseline(address(addressBook));
    }

    function test_linkedAdapterRequiresCompleteImplementationCodehash() public {
        B1N352Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(_deployConfig());
        vm.setEnv(
            "FUND_CSP_ADAPTER_IMPLEMENTATION_CODEHASH", vm.toString(deployed.cspFundAdapterImplementation.codehash)
        );
        deployHarness.requireExpectedImplementationCodehash(
            deployed.cspFundAdapterProxy, "FUND_CSP_ADAPTER_IMPLEMENTATION_CODEHASH"
        );

        vm.setEnv("FUND_CSP_ADAPTER_IMPLEMENTATION_CODEHASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert(bytes("B1N352: test implementation hash"));
        deployHarness.requireExpectedImplementationCodehash(
            deployed.cspFundAdapterProxy, "FUND_CSP_ADAPTER_IMPLEMENTATION_CODEHASH"
        );
    }

    function test_envDowncastRevertsInsteadOfWrapping() public {
        vm.setEnv("B1N352_TEST_UINT16", "65535");
        assertEq(deployHarness.envUint16("B1N352_TEST_UINT16"), type(uint16).max);

        vm.setEnv("B1N352_TEST_UINT16", "65536");
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 16, 65_536));
        deployHarness.envUint16("B1N352_TEST_UINT16");
    }

    function test_fundAccessManagerEnumeratesExactCurrentAuthority() public {
        FundAccessManager manager = new FundAccessManager(address(this));
        address member = address(0xA11CE);
        address target = address(0xB0B);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("configuredFunction()"));

        manager.grantRole(FundConstants.ACCOUNTING_ROLE, member, 0);
        assertEq(manager.roleMemberCount(FundConstants.ACCOUNTING_ROLE), 1);
        assertEq(manager.roleMemberAt(FundConstants.ACCOUNTING_ROLE, 0), member);
        manager.revokeRole(FundConstants.ACCOUNTING_ROLE, member);
        assertEq(manager.roleMemberCount(FundConstants.ACCOUNTING_ROLE), 0);

        manager.setTargetFunctionRole(target, selectors, FundConstants.ACCOUNTING_ROLE);
        assertEq(manager.configuredSelectorCount(target), 1);
        manager.setTargetFunctionRole(target, selectors, manager.ADMIN_ROLE());
        assertEq(manager.configuredSelectorCount(target), 0);
    }

    function test_phaseExecutionIsAtomicAndPreservesSchedulesOnFailure() public {
        B1N352Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(_deployConfig());
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        B1N352Operations.PolicyConfig memory policy = _policyConfig(deployed);
        B1N352Operations.Operation[] memory allOperations = operationsHarness.policyOperations(policy);
        B1N352Operations.Operation[] memory operations = new B1N352Operations.Operation[](2);
        operations[0] = allOperations[0];
        operations[1] = allOperations[1];
        operations[1].data = abi.encodeCall(FundAccounting.setComponent, (bytes32(0), address(0), uint64(1), true));

        _schedule(manager, operations);
        vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
        bytes32 firstId = manager.hashOperation(address(this), operations[0].target, operations[0].data);
        bytes32 secondId = manager.hashOperation(address(this), operations[1].target, operations[1].data);
        vm.expectRevert();
        _execute(manager, operations);

        assertEq(FundAccounting(deployed.fundAccountingProxy).reporterSetVersion(), 0);
        assertGt(manager.getSchedule(firstId), 0);
        assertGt(manager.getSchedule(secondId), 0);
    }

    function test_completedPolicyPhaseIsIdempotentAndCannotBeScheduledAgain() public {
        uint256 phaseKey = 0xB1A352;
        address phaseCaller = vm.addr(phaseKey);
        B1N352Base.DeployConfig memory deployConfig = _deployConfig();
        deployConfig.roles = _roleAccounts(phaseCaller);
        B1N352Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(deployConfig);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        B1N352Operations.PolicyConfig memory policy = _policyConfig(deployed);
        B1N352Operations.Operation[] memory operations = operationsHarness.policyOperations(policy);

        operationsHarness.scheduleOperations(manager, operations, phaseKey, false);
        vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
        operationsHarness.executeOperations(manager, operations, phaseKey, false);
        assertTrue(operationsHarness.isPolicyPhaseFinalized(policy));

        bytes32 firstId = manager.hashOperation(phaseCaller, operations[0].target, operations[0].data);
        uint32 nonce = manager.getNonce(firstId);
        operationsHarness.scheduleOperations(manager, operations, phaseKey, true);
        assertEq(manager.getNonce(firstId), nonce);
        assertEq(manager.getSchedule(firstId), 0);

        vm.prank(phaseCaller);
        StrategyManager(deployed.strategyManagerProxy).reduceStrategyCap(policy.adapter, 500e6, 2_500);
        assertTrue(operationsHarness.isPolicyPhaseFinalized(policy));
        operationsHarness.scheduleOperations(manager, operations, phaseKey, true);
        assertEq(manager.getNonce(firstId), nonce);
    }

    function test_partialCancellationCanBeAtomicallyClearedAndExplicitlyRestarted() public {
        uint256 phaseKey = 0xB1A353;
        address phaseCaller = vm.addr(phaseKey);
        B1N352Base.DeployConfig memory deployConfig = _deployConfig();
        deployConfig.roles = _roleAccounts(phaseCaller);
        B1N352Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(deployConfig);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        B1N352Operations.Operation[] memory operations = operationsHarness.policyOperations(_policyConfig(deployed));

        operationsHarness.scheduleOperations(manager, operations, phaseKey, false);
        vm.prank(phaseCaller);
        manager.cancel(phaseCaller, operations[0].target, operations[0].data);

        vm.expectRevert(bytes("B1N352: partial phase schedule"));
        operationsHarness.scheduleOperations(manager, operations, phaseKey, false);
        vm.expectRevert(bytes("B1N352: restart caller differs"));
        operationsHarness.restartOperations(manager, operations, phaseCaller, phaseKey + 1, false);
        operationsHarness.restartOperations(manager, operations, phaseCaller, phaseKey, false);
        for (uint256 i; i < operations.length; ++i) {
            bytes32 operationId = manager.hashOperation(phaseCaller, operations[i].target, operations[i].data);
            assertGt(manager.getSchedule(operationId), 0);
            assertEq(manager.getNonce(operationId), 2);
        }
    }

    function test_reconciliationRejectsAdditionalRegisteredAdapterAfterItsAccountingComponentIsDisabled() public {
        B1N352Base.DeployConfig memory deployConfig = _deployConfig();
        B1N352Base.DeploymentAddresses memory deployed = deployHarness.deployForTest(deployConfig);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        B1N352Operations.PolicyConfig memory policy = _policyConfig(deployed);
        _scheduleAndExecute(manager, operationsHarness.policyOperations(policy), FundConstants.CURATOR_DELAY);

        CspFundAdapter.InitializeParams memory params = CspFundAdapter.InitializeParams({
            fund: deployed.fundVaultProxy,
            strategyManager: deployed.strategyManagerProxy,
            addressBook: address(addressBook),
            accountingAsset: address(usdc),
            weth: address(weth),
            swapRouter: address(swapRouter),
            swapFeeTier: deployConfig.adapterSwapFeeTier,
            authority: address(manager),
            riskConfig: deployConfig.adapterRiskConfig
        });
        address extraAdapter = address(
            new ERC1967Proxy(address(new CspFundAdapter()), abi.encodeCall(CspFundAdapter.initialize, (params)))
        );
        bytes32 extraComponentId = keccak256(abi.encodePacked("STRATEGY", extraAdapter));

        B1N352Operations.Operation[] memory registerOperations = new B1N352Operations.Operation[](2);
        registerOperations[0] = B1N352Operations.Operation({
            target: deployed.fundAccountingProxy,
            data: abi.encodeCall(
                FundAccounting.setComponent, (extraComponentId, deployed.cspFundValuator, uint64(1), true)
            ),
            label: keccak256("REGISTER_EXTRA_COMPONENT")
        });
        registerOperations[1] = B1N352Operations.Operation({
            target: deployed.strategyManagerProxy,
            data: abi.encodeCall(
                StrategyManager.setStrategyConfig,
                (
                    extraAdapter,
                    FundTypes.StrategyConfig({
                        active: true,
                        maxAllocationBps: policy.maxAllocationBps,
                        maxLossBps: policy.maxLossBps,
                        cooldown: policy.cooldown,
                        interfaceVersion: policy.adapterInterfaceVersion,
                        valuator: deployed.cspFundValuator,
                        absoluteCap: policy.absoluteCap
                    })
                )
            ),
            label: keccak256("REGISTER_EXTRA_STRATEGY")
        });
        _scheduleAndExecute(manager, registerOperations, FundConstants.CURATOR_DELAY);

        B1N352Operations.Operation[] memory disableComponentOperations = new B1N352Operations.Operation[](1);
        disableComponentOperations[0] = B1N352Operations.Operation({
            target: deployed.fundAccountingProxy,
            data: abi.encodeCall(
                FundAccounting.setComponent, (extraComponentId, deployed.cspFundValuator, uint64(1), false)
            ),
            label: keccak256("DISABLE_EXTRA_COMPONENT")
        });
        _scheduleAndExecute(manager, disableComponentOperations, FundConstants.CURATOR_DELAY);

        assertEq(FundAccounting(deployed.fundAccountingProxy).activeComponentCount(), 2);
        assertEq(StrategyManager(deployed.strategyManagerProxy).activeAdapterCount(), 2);
        vm.expectRevert(bytes("B1N352: registered adapter count"));
        operationsHarness.verifyDeployedPolicy(deployConfig, policy, false);
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

    function _assertPolicyMismatchesRejected(
        B1N352Base.DeployConfig memory deployConfig,
        B1N352Operations.PolicyConfig memory policy
    ) private {
        policy.reporterThreshold = 1;
        vm.expectRevert(bytes("B1N352: reporter threshold"));
        operationsHarness.verifyDeployedPolicy(deployConfig, policy, true);
        policy.reporterThreshold = 2;

        policy.maxExitFeeBps += 1;
        vm.expectRevert(bytes("B1N352: exit fee"));
        operationsHarness.verifyDeployedPolicy(deployConfig, policy, true);
        policy.maxExitFeeBps -= 1;

        policy.maxLossBps += 1;
        vm.expectRevert(bytes("B1N352: strategy config"));
        operationsHarness.verifyDeployedPolicy(deployConfig, policy, true);
        policy.maxLossBps -= 1;

        deployConfig.adapterSwapFeeTier = 3_000;
        vm.expectRevert(bytes("B1N352: adapter config"));
        operationsHarness.verifyDeployedPolicy(deployConfig, policy, true);
        deployConfig.adapterSwapFeeTier = 500;

        deployConfig.approvedObservers[0] = address(0xBAD);
        vm.expectRevert(bytes("B1N352: valuator observer order"));
        operationsHarness.verifyDeployedPolicy(deployConfig, policy, true);
    }

    function _setExpectedV1Baseline() private {
        vm.setEnv("FUND_EXPECTED_V1_ADDRESS_BOOK", vm.toString(address(addressBook)));
        _setExpectedProxyBaseline("FUND_EXPECTED_V1_ADDRESS_BOOK", address(addressBook), false);
        _setExpectedProxyBaseline("FUND_EXPECTED_V1_CONTROLLER", addressBook.controller(), true);
        _setExpectedProxyBaseline("FUND_EXPECTED_V1_MARGIN_POOL", addressBook.marginPool(), true);
        _setExpectedProxyBaseline("FUND_EXPECTED_V1_OTOKEN_FACTORY", addressBook.oTokenFactory(), true);
        _setExpectedProxyBaseline("FUND_EXPECTED_V1_ORACLE", addressBook.oracle(), true);
        _setExpectedProxyBaseline("FUND_EXPECTED_V1_WHITELIST", addressBook.whitelist(), true);
        _setExpectedProxyBaseline("FUND_EXPECTED_V1_BATCH_SETTLER", addressBook.batchSettler(), true);
    }

    function _setExpectedProxyBaseline(string memory prefix, address proxy, bool setProxy) private {
        if (setProxy) vm.setEnv(string.concat(prefix, "_PROXY"), vm.toString(proxy));
        address implementation = _implementation(proxy);
        vm.setEnv(string.concat(prefix, "_IMPLEMENTATION"), vm.toString(implementation));
        vm.setEnv(string.concat(prefix, "_CODEHASH"), vm.toString(implementation.codehash));
    }

    function _roleAccounts(address account) private pure returns (FundFactory.RoleAccounts memory roles) {
        roles = FundFactory.RoleAccounts({
            admin: account,
            upgrader: account,
            accounting: account,
            allocator: account,
            processor: account,
            curator: account,
            guardian: account
        });
    }

    function _scheduleAndExecute(AccessManager manager, B1N352Operations.Operation[] memory operations, uint256 delay)
        private
    {
        _schedule(manager, operations);
        vm.warp(block.timestamp + delay);
        _execute(manager, operations);
    }

    function _schedule(AccessManager manager, B1N352Operations.Operation[] memory operations) private {
        bytes[] memory calls = new bytes[](operations.length);
        for (uint256 i; i < operations.length; ++i) {
            calls[i] = abi.encodeCall(manager.schedule, (operations[i].target, operations[i].data, uint48(0)));
        }
        manager.multicall(calls);
    }

    function _execute(AccessManager manager, B1N352Operations.Operation[] memory operations) private {
        bytes[] memory calls = new bytes[](operations.length);
        for (uint256 i; i < operations.length; ++i) {
            calls[i] = abi.encodeCall(manager.execute, (operations[i].target, operations[i].data));
        }
        manager.multicall(calls);
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
