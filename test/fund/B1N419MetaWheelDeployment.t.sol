// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {CspFundAdapterOperations} from "../../src/fund/libraries/CspFundAdapterOperations.sol";
import {CoveredCallFundAdapterOperations} from "../../src/fund/libraries/CoveredCallFundAdapterOperations.sol";
import {ManagedStrategyOperations} from "../../src/fund/libraries/ManagedStrategyOperations.sol";
import {WheelCoordinatorPositionOperations} from "../../src/fund/libraries/WheelCoordinatorPositionOperations.sol";
import {WheelManagedOperationDispatcher} from "../../src/fund/libraries/WheelManagedOperationDispatcher.sol";
import {RotateMetaWheelRolesBaseSepolia} from "../../script/fund/RotateMetaWheelRolesBaseSepolia.s.sol";

contract B1N419MetaWheelDeploymentTest is Test, RotateMetaWheelRolesBaseSepolia {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockChainlinkFeed internal feed;
    MockSwapRouter internal router;
    AddressBook internal addressBook;
    BatchSettler internal settler;
    StandaloneBaseline internal standalone;

    function validateForTest(DeployConfig memory config, address broadcaster) external view {
        _validateConfig(config, broadcaster);
    }

    function validateFactoryDeploymentForTest(DeploymentAddresses memory deployed, uint64 expectedVersion)
        external
        view
    {
        _requireFactoryDeployment(deployed, expectedVersion);
    }

    function validateCanonicalPolicyForTest(DeployConfig memory config, DeploymentAddresses memory deployed)
        external
        view
    {
        _requireCanonicalPolicyState(config, deployed);
    }

    function writeManifestForTest(DeployConfig memory config, DeploymentAddresses memory deployed, string memory path)
        external
    {
        _writeManifest(config, deployed, path);
    }

    function setUp() public {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        feed = new MockChainlinkFeed(2_500e8);
        router = new MockSwapRouter(address(usdc));
        router.setPriceFeed(address(weth), address(feed));

        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), address(this), address(0xFEE1)))
                )
            )
        );
        addressBook.setController(address(feed));
        addressBook.setMarginPool(address(router));
        addressBook.setOTokenFactory(address(usdc));
        addressBook.setOracle(address(feed));
        addressBook.setWhitelist(address(weth));
        addressBook.setBatchSettler(address(settler));
        vm.prank(address(0xFEE1));
        settler.setProtocolFeeBps(PREMIUM_FEE_BPS);
        standalone = _standaloneBaseline();
    }

    function test_dryRunDeploysPausedIsolatedFourByFourTopology() public {
        DeployConfig memory config = _config();
        bytes32 cspVaultCodehashBefore = config.standalone.cspVaultProxy.codehash;
        bytes32 cspAdapterCodehashBefore = config.standalone.cspAdapterProxy.codehash;
        bytes32 ccVaultCodehashBefore = config.standalone.coveredCallVaultProxy.codehash;
        bytes32 ccAdapterCodehashBefore = config.standalone.coveredCallAdapterProxy.codehash;

        _validateConfig(config, address(this));
        DeploymentAddresses memory deployed = _deploy(config, address(this));
        _reconcileBootstrap(config, deployed);

        FundVault vault = FundVault(deployed.vault);
        assertEq(FundFactory(deployed.factory).owner(), config.finalRoles.admin);
        assertEq(vault.asset(), address(usdc));
        assertTrue(vault.depositsPaused());
        assertTrue(vault.redemptionsPaused());
        FundTypes.FeeConfig memory fees = FundAccounting(deployed.accounting).feeConfig();
        assertEq(fees.managementFeeWad, MANAGEMENT_FEE_WAD);
        assertEq(fees.performanceFeeBps, PERFORMANCE_FEE_BPS);
        assertEq(fees.feeRecipient, config.fund.feeRecipient);

        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(deployed.coordinator);
        assertEq(coordinator.registeredLaneCount(), 0);
        assertFalse(coordinator.allocationsPaused());
        assertEq(coordinator.policyHash(), config.wheel.policyHash);
        assertEq(coordinator.floorBufferUsd8(), config.wheel.floorBufferUsd8);
        assertEq(StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator).interfaceVersion, 0);
        CspFundValuatorV2 cspValuator = CspFundValuatorV2(deployed.cspValuator);
        CoveredCallFundValuatorV2 coveredCallValuator = CoveredCallFundValuatorV2(deployed.coveredCallValuator);
        assertEq(cspValuator.approvedObserverCount(), 2);
        assertEq(coveredCallValuator.approvedObserverCount(), 2);
        for (uint256 i; i < 2; ++i) {
            assertEq(cspValuator.approvedObserverAt(i), config.valuation.approvedObservers[i]);
            assertEq(coveredCallValuator.approvedObserverAt(i), config.valuation.approvedObservers[i + 2]);
            assertFalse(cspValuator.isApprovedObserver(config.valuation.approvedObservers[i + 2]));
            assertFalse(coveredCallValuator.isApprovedObserver(config.valuation.approvedObservers[i]));
        }

        for (uint256 i; i < 4; ++i) {
            assertEq(WheelCspChildLane(deployed.cspLanes[i]).coordinator(), deployed.coordinator);
            assertEq(WheelCspChildLane(deployed.cspLanes[i]).adapter(), deployed.cspAdapters[i]);
            assertTrue(WheelCspChildLane(deployed.cspLanes[i]).allocationsPaused());
            assertFalse(ICspFundAdapter(deployed.cspAdapters[i]).isOnboarded());
            assertEq(WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).coordinator(), deployed.coordinator);
            assertEq(WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).adapter(), deployed.coveredCallAdapters[i]);
            assertTrue(WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).allocationsPaused());
            assertEq(
                WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).executionCostBuffer8(),
                config.wheel.floorBufferUsd8
            );
            assertFalse(ICoveredCallFundAdapter(deployed.coveredCallAdapters[i]).isOnboarded());
        }

        _assertRoles(FundAccessManager(deployed.accessManager), config.fund.roles);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        assertEq(manager.configuredSelectorCount(deployed.coordinator), 1);
        vm.expectRevert(WheelCoordinatorAdapter.OnlyStrategyManager.selector);
        coordinator.registerLane(deployed.cspLanes[0], WheelTypes.LaneKind.Csp);
        vm.expectRevert(WheelCoordinatorAdapter.OnlyStrategyManager.selector);
        coordinator.pauseAllocations();
        assertEq(
            manager.getTargetFunctionRole(deployed.cspLanes[0], WheelCspChildLane.setMaxAssets.selector),
            FundConstants.CURATOR_ROLE
        );
        assertEq(
            manager.getTargetFunctionRole(
                deployed.coveredCallLanes[0], WheelCoveredCallChildLane.pauseAllocations.selector
            ),
            FundConstants.GUARDIAN_ROLE
        );
        assertEq(config.standalone.cspVaultProxy.codehash, cspVaultCodehashBefore);
        assertEq(config.standalone.cspAdapterProxy.codehash, cspAdapterCodehashBefore);
        assertEq(config.standalone.coveredCallVaultProxy.codehash, ccVaultCodehashBefore);
        assertEq(config.standalone.coveredCallAdapterProxy.codehash, ccAdapterCodehashBefore);
        _requireStandaloneBaseline(config.standalone);
    }

    function test_manifestWriterKeepsOperationalAndCanonicalPathsEqual() public {
        DeployConfig memory config = _config();
        DeploymentAddresses memory deployed = _deploy(config, address(this));
        string memory path =
            string.concat(vm.projectRoot(), "/deployments/base-sepolia/b1n-419/.test-producer-manifest.json");
        if (vm.exists(path)) vm.removeFile(path);

        this.writeManifestForTest(config, deployed, path);
        string memory manifest = vm.readFile(path);
        _assertManifestAddress(manifest, ".vault", ".contracts.fundVault.proxy", deployed.vault);
        _assertManifestAddress(
            manifest, ".vaultImplementation", ".contracts.fundVault.implementation", deployed.vaultImplementation
        );
        _assertManifestAddress(manifest, ".share", ".contracts.fundShare.proxy", deployed.share);
        _assertManifestAddress(
            manifest, ".shareImplementation", ".contracts.fundShare.implementation", deployed.shareImplementation
        );
        _assertManifestAddress(manifest, ".accounting", ".contracts.fundAccounting.proxy", deployed.accounting);
        _assertManifestAddress(
            manifest,
            ".accountingImplementation",
            ".contracts.fundAccounting.implementation",
            deployed.accountingImplementation
        );
        _assertManifestAddress(manifest, ".flow", ".contracts.fundFlowManager.proxy", deployed.flow);
        _assertManifestAddress(
            manifest, ".flowImplementation", ".contracts.fundFlowManager.implementation", deployed.flowImplementation
        );
        _assertManifestAddress(manifest, ".strategy", ".contracts.strategyManager.proxy", deployed.strategy);
        _assertManifestAddress(
            manifest,
            ".strategyImplementation",
            ".contracts.strategyManager.implementation",
            deployed.strategyImplementation
        );
        _assertManifestAddress(manifest, ".coordinator", ".contracts.wheelCoordinator.proxy", deployed.coordinator);
        _assertManifestAddress(
            manifest,
            ".coordinatorImplementation",
            ".contracts.wheelCoordinator.implementation",
            deployed.coordinatorImplementation
        );
        _assertManifestAddress(manifest, ".claimEscrow", ".contracts.claimEscrow.address", deployed.claimEscrow);
        _assertManifestAddress(manifest, ".accessManager", ".contracts.accessManager.address", deployed.accessManager);
        _assertManifestAddress(
            manifest, ".metaWheelValuator", ".contracts.metaWheelValuator.address", deployed.metaWheelValuator
        );
        _assertManifestAddress(manifest, ".navVerifier", ".contracts.navReportVerifier.address", deployed.navVerifier);
        _assertManifestCodehash(
            manifest,
            ".vaultImplementationCodehash",
            ".contracts.fundVault.implementationCodehash",
            deployed.vaultImplementation.codehash
        );
        _assertManifestCodehash(
            manifest,
            ".shareImplementationCodehash",
            ".contracts.fundShare.implementationCodehash",
            deployed.shareImplementation.codehash
        );
        _assertManifestCodehash(
            manifest,
            ".accountingImplementationCodehash",
            ".contracts.fundAccounting.implementationCodehash",
            deployed.accountingImplementation.codehash
        );
        _assertManifestCodehash(
            manifest,
            ".flowImplementationCodehash",
            ".contracts.fundFlowManager.implementationCodehash",
            deployed.flowImplementation.codehash
        );
        _assertManifestCodehash(
            manifest,
            ".strategyImplementationCodehash",
            ".contracts.strategyManager.implementationCodehash",
            deployed.strategyImplementation.codehash
        );
        _assertManifestCodehash(
            manifest,
            ".coordinatorImplementationCodehash",
            ".contracts.wheelCoordinator.implementationCodehash",
            deployed.coordinatorImplementation.codehash
        );
        _assertCanonicalCodehash(manifest, ".contracts.claimEscrow.codehash", deployed.claimEscrow.codehash);
        _assertCanonicalCodehash(manifest, ".contracts.accessManager.codehash", deployed.accessManager.codehash);
        _assertCanonicalCodehash(manifest, ".contracts.metaWheelValuator.codehash", deployed.metaWheelValuator.codehash);
        _assertCanonicalCodehash(manifest, ".contracts.navReportVerifier.codehash", deployed.navVerifier.codehash);

        _assertOperationalAddress(manifest, ".factory", deployed.factory);
        _assertOperationalAddress(manifest, ".accessManagerDeployer", deployed.accessManagerDeployer);
        _assertOperationalAddress(manifest, ".cspAdapterImplementation", deployed.cspAdapterImplementation);
        _assertOperationalAddress(manifest, ".cspLaneImplementation", deployed.cspLaneImplementation);
        _assertOperationalAddress(manifest, ".cspValuator", deployed.cspValuator);
        _assertOperationalAddress(
            manifest, ".coveredCallAdapterImplementation", deployed.coveredCallAdapterImplementation
        );
        _assertOperationalAddress(manifest, ".coveredCallLaneImplementation", deployed.coveredCallLaneImplementation);
        _assertOperationalAddress(manifest, ".coveredCallValuator", deployed.coveredCallValuator);
        _assertOperationalAddress(manifest, ".inKindEscrow", deployed.inKindEscrow);
        _assertOperationalAddress(manifest, ".emergencyEscrow", deployed.emergencyEscrow);

        _assertOperationalCodehash(manifest, ".factoryCodehash", deployed.factory.codehash);
        _assertOperationalCodehash(manifest, ".accessManagerDeployerCodehash", deployed.accessManagerDeployer.codehash);
        _assertOperationalCodehash(manifest, ".vaultProxyCodehash", deployed.vault.codehash);
        _assertOperationalCodehash(manifest, ".shareProxyCodehash", deployed.share.codehash);
        _assertOperationalCodehash(manifest, ".accountingProxyCodehash", deployed.accounting.codehash);
        _assertOperationalCodehash(manifest, ".flowProxyCodehash", deployed.flow.codehash);
        _assertOperationalCodehash(manifest, ".strategyProxyCodehash", deployed.strategy.codehash);
        _assertOperationalCodehash(manifest, ".coordinatorProxyCodehash", deployed.coordinator.codehash);
        _assertOperationalCodehash(
            manifest, ".cspAdapterImplementationCodehash", deployed.cspAdapterImplementation.codehash
        );
        _assertOperationalCodehash(manifest, ".cspLaneImplementationCodehash", deployed.cspLaneImplementation.codehash);
        _assertOperationalCodehash(
            manifest, ".coveredCallAdapterImplementationCodehash", deployed.coveredCallAdapterImplementation.codehash
        );
        _assertOperationalCodehash(
            manifest, ".coveredCallLaneImplementationCodehash", deployed.coveredCallLaneImplementation.codehash
        );
        _assertOperationalCodehash(manifest, ".cspValuatorCodehash", deployed.cspValuator.codehash);
        _assertOperationalCodehash(manifest, ".coveredCallValuatorCodehash", deployed.coveredCallValuator.codehash);

        _assertOperationalAddresses(manifest, ".cspLanes", deployed.cspLanes);
        _assertOperationalAddresses(manifest, ".cspAdapters", deployed.cspAdapters);
        _assertOperationalAddresses(manifest, ".coveredCallLanes", deployed.coveredCallLanes);
        _assertOperationalAddresses(manifest, ".coveredCallAdapters", deployed.coveredCallAdapters);
        _assertOperationalCodehashes(manifest, ".cspLaneCodehashes", deployed.cspLanes);
        _assertOperationalCodehashes(manifest, ".cspAdapterCodehashes", deployed.cspAdapters);
        _assertOperationalCodehashes(manifest, ".coveredCallLaneCodehashes", deployed.coveredCallLanes);
        _assertOperationalCodehashes(manifest, ".coveredCallAdapterCodehashes", deployed.coveredCallAdapters);
        vm.removeFile(path);
    }

    function test_reconciliationRejectsAlteredDeploymentId() public {
        DeployConfig memory config = _config();
        DeploymentAddresses memory deployed = _deploy(config, address(this));
        this.validateFactoryDeploymentForTest(deployed, config.fund.implementationVersion);

        deployed.deploymentId = keccak256("ALTERED_B1N419_DEPLOYMENT_ID");
        vm.expectRevert(bytes("B1N419: factory deployment"));
        this.validateFactoryDeploymentForTest(deployed, config.fund.implementationVersion);
    }

    function test_managedSetupRegistersFourByFourThenPausesWithoutActivating() public {
        DeployConfig memory config = _config();
        DeploymentAddresses memory deployed = _deploy(config, address(this));
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        _rotateRoles(manager, address(this), config.finalRoles);
        _requireFinalRoles(manager, config.finalRoles);

        StrategyManager strategy = StrategyManager(deployed.strategy);
        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(deployed.coordinator);
        bytes32 componentId = keccak256(abi.encodePacked("STRATEGY", deployed.coordinator));
        FundTypes.StrategyConfig memory strategyConfig = FundTypes.StrategyConfig({
            active: false,
            maxAllocationBps: config.wheel.strategyMaxAllocationBps,
            maxLossBps: config.wheel.strategyMaxLossBps,
            cooldown: config.wheel.strategyCooldown,
            interfaceVersion: 1,
            valuator: deployed.metaWheelValuator,
            absoluteCap: config.wheel.strategyAbsoluteCap
        });

        vm.startPrank(config.finalRoles.curator);
        FundAccounting(deployed.accounting).setComponent(componentId, deployed.metaWheelValuator, 1, true);
        strategy.setStrategyConfig(deployed.coordinator, strategyConfig);
        uint64 positionNonceBeforeRegistration = strategy.positionNonce(deployed.coordinator);
        for (uint256 i; i < 8; ++i) {
            bool isCsp = i < 4;
            uint256 laneIndex = isCsp ? i : i - 4;
            address lane = isCsp ? deployed.cspLanes[laneIndex] : deployed.coveredCallLanes[laneIndex];
            WheelTypes.LaneKind kind = isCsp ? WheelTypes.LaneKind.Csp : WheelTypes.LaneKind.CoveredCall;
            strategy.executeAdapterConfigurationOperation(
                deployed.coordinator, abi.encode(WheelTypes.ManagedOperation.RegisterLane, abi.encode(lane, kind))
            );
        }
        vm.stopPrank();

        assertEq(coordinator.registeredLaneCount(), 8);
        assertEq(strategy.positionNonce(deployed.coordinator), positionNonceBeforeRegistration + 8);
        assertFalse(strategy.strategyConfig(deployed.coordinator).active);
        for (uint256 i; i < 8; ++i) {
            (address lane, WheelTypes.LaneKind kind, bool active) = coordinator.registeredLaneAt(i);
            assertEq(lane, i < 4 ? deployed.cspLanes[i] : deployed.coveredCallLanes[i - 4]);
            assertEq(uint8(kind), uint8(i < 4 ? WheelTypes.LaneKind.Csp : WheelTypes.LaneKind.CoveredCall));
            assertTrue(active);
        }

        uint64 strategyNonceBeforePause = strategy.positionNonce(deployed.coordinator);
        uint64 coordinatorNonceBeforePause = coordinator.summary().stateNonce;
        vm.prank(config.finalRoles.guardian);
        strategy.executeAdapterGuardianOperation(
            deployed.coordinator, abi.encode(WheelTypes.ManagedOperation.PauseAllocations, bytes(""))
        );
        assertEq(strategy.positionNonce(deployed.coordinator), strategyNonceBeforePause + 1);
        assertEq(coordinator.summary().stateNonce, coordinatorNonceBeforePause);
        assertTrue(coordinator.allocationsPaused());
        assertTrue(FundVault(deployed.vault).depositsPaused());
        assertTrue(FundVault(deployed.vault).redemptionsPaused());
        for (uint256 i; i < 4; ++i) {
            assertFalse(ICspFundAdapter(deployed.cspAdapters[i]).isOnboarded());
            assertFalse(ICoveredCallFundAdapter(deployed.coveredCallAdapters[i]).isOnboarded());
        }

        vm.expectRevert(WheelCoordinatorAdapter.OnlyStrategyManager.selector);
        coordinator.pauseAllocations();
    }

    function test_preflightRejectsRoleOverlap() public {
        DeployConfig memory config = _config();
        config.finalRoles.guardian = config.finalRoles.curator;
        vm.expectRevert(bytes("B1N419: role overlap"));
        this.validateForTest(config, address(this));
    }

    function test_preflightRejectsObserverOrReporterRoleReuse() public {
        DeployConfig memory config = _config();
        config.valuation.approvedObservers[0] = config.finalRoles.accounting;
        vm.expectRevert(bytes("B1N419: observer reuses role"));
        this.validateForTest(config, address(this));

        config = _config();
        config.valuation.navReporters[0] = config.finalRoles.accounting;
        vm.expectRevert(bytes("B1N419: reporter reuses role"));
        this.validateForTest(config, address(this));
    }

    function test_preflightRejectsFeeRecipientIdentityReuse() public {
        DeployConfig memory config = _config();
        config.finalRoles.upgrader = config.fund.feeRecipient;
        vm.expectRevert(bytes("B1N419: fee recipient reuses role"));
        this.validateForTest(config, address(this));

        config = _config();
        config.valuation.approvedObservers[0] = config.fund.feeRecipient;
        vm.expectRevert(bytes("B1N419: observer reuses fee recipient"));
        this.validateForTest(config, address(this));

        config = _config();
        config.valuation.navReporters[0] = config.fund.feeRecipient;
        vm.expectRevert(bytes("B1N419: reporter reuses fee recipient"));
        this.validateForTest(config, address(this));
    }

    function test_canonicalPolicyAcceptsExactConfiguredState() public {
        (DeployConfig memory config, DeploymentAddresses memory deployed) = _configuredPolicyState();
        this.validateCanonicalPolicyForTest(config, deployed);
    }

    function test_canonicalPolicyRejectsFeeAndSettlerOwnerDrift() public {
        (DeployConfig memory config, DeploymentAddresses memory deployed) = _configuredPolicyState();
        FundTypes.FeeConfig memory fees = FundAccounting(deployed.accounting).feeConfig();
        fees.performanceFeeBps -= 1;
        FundAccounting(deployed.accounting).setFeeConfig(fees);
        vm.expectRevert(bytes("B1N419: fee config drift"));
        this.validateCanonicalPolicyForTest(config, deployed);

        vm.prank(config.fund.feeRecipient);
        settler.transferOwnership(address(0xBAD));
        vm.prank(address(0xBAD));
        settler.acceptOwnership();
        FundAccounting(deployed.accounting).setFeeConfig(_feeConfig(config.fund.feeRecipient));
        vm.expectRevert(bytes("B1N419: settler owner drift"));
        this.validateCanonicalPolicyForTest(config, deployed);
    }

    function test_canonicalPolicyRejectsStrategyAndMinimumIdleDrift() public {
        (DeployConfig memory config, DeploymentAddresses memory deployed) = _configuredPolicyState();
        StrategyManager strategy = StrategyManager(deployed.strategy);
        FundTypes.StrategyConfig memory strategyConfig = strategy.strategyConfig(deployed.coordinator);
        strategyConfig.maxLossBps -= 1;
        strategy.setStrategyConfig(deployed.coordinator, strategyConfig);
        vm.expectRevert(bytes("B1N419: strategy config drift"));
        this.validateCanonicalPolicyForTest(config, deployed);

        strategyConfig.maxLossBps = config.wheel.strategyMaxLossBps;
        strategy.setStrategyConfig(deployed.coordinator, strategyConfig);
        strategy.setMinimumIdleBps(config.fund.minimumIdleBps - 1);
        vm.expectRevert(bytes("B1N419: minimum idle drift"));
        this.validateCanonicalPolicyForTest(config, deployed);
    }

    function test_canonicalPolicyRejectsFlowEscrowDrift() public {
        (DeployConfig memory config, DeploymentAddresses memory deployed) = _configuredPolicyState();
        FundFlowManager(deployed.flow).setStrategyExitEscrows(deployed.emergencyEscrow, deployed.inKindEscrow);
        vm.expectRevert(bytes("B1N419: strategy exit escrow drift"));
        this.validateCanonicalPolicyForTest(config, deployed);
    }

    function test_canonicalPolicyRejectsLaneAndAdapterDrift() public {
        (DeployConfig memory config, DeploymentAddresses memory deployed) = _configuredPolicyState();
        WheelCspChildLane(deployed.cspLanes[0]).setMaxAssets(config.wheel.cspLaneMaxAssets - 1);
        vm.expectRevert(bytes("B1N419: CSP lane max assets drift"));
        this.validateCanonicalPolicyForTest(config, deployed);

        WheelCspChildLane(deployed.cspLanes[0]).setMaxAssets(config.wheel.cspLaneMaxAssets);
        ICoveredCallFundAdapter.AdapterConfig memory adapterConfig =
            ICoveredCallFundAdapter(deployed.coveredCallAdapters[0]).adapterConfig();
        adapterConfig.riskConfig.maxSwapSlippageBps -= 1;
        ICoveredCallFundAdapter(deployed.coveredCallAdapters[0])
            .setAdapterConfig(adapterConfig.riskConfig, adapterConfig.swapRouter, adapterConfig.swapFeeTier);
        vm.expectRevert(bytes("B1N419: CC adapter config drift"));
        this.validateCanonicalPolicyForTest(config, deployed);
    }

    function test_rotationRevokesSharedBootstrapAndKeepsFundInactive() public {
        DeployConfig memory config = _config();
        DeploymentAddresses memory deployed = _deploy(config, address(this));
        FundAccessManager manager = FundAccessManager(deployed.accessManager);

        _requireBootstrapRoles(manager, config.fund.roles);
        _rotateRoles(manager, address(this), config.finalRoles);
        _requireFinalRoles(manager, config.finalRoles);

        (bool bootstrapAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), address(this));
        (bool bootstrapAllocator,) = manager.hasRole(FundConstants.ALLOCATOR_ROLE, address(this));
        (bool bootstrapGuardian,) = manager.hasRole(FundConstants.GUARDIAN_ROLE, address(this));
        assertFalse(bootstrapAdmin);
        assertFalse(bootstrapAllocator);
        assertFalse(bootstrapGuardian);
        assertTrue(FundVault(deployed.vault).depositsPaused());
        assertTrue(FundVault(deployed.vault).redemptionsPaused());
        assertEq(StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator).interfaceVersion, 0);
        assertEq(WheelCoordinatorAdapter(deployed.coordinator).registeredLaneCount(), 0);
        for (uint256 i; i < 4; ++i) {
            assertFalse(ICspFundAdapter(deployed.cspAdapters[i]).isOnboarded());
            assertFalse(ICoveredCallFundAdapter(deployed.coveredCallAdapters[i]).isOnboarded());
        }
    }

    function test_preflightRejectsStandaloneImplementationDrift() public {
        DeployConfig memory config = _config();
        config.standalone.cspAdapterImplementation = address(0xBAD);
        vm.expectRevert(bytes("B1N419: CSP adapter baseline"));
        this.validateForTest(config, address(this));
    }

    function test_preflightRejectsPremiumFeeDrift() public {
        DeployConfig memory config = _config();
        vm.prank(config.fund.feeRecipient);
        settler.setProtocolFeeBps(PREMIUM_FEE_BPS - 1);
        vm.expectRevert(bytes("B1N419: premium fee"));
        this.validateForTest(config, address(this));
    }

    function _configuredPolicyState()
        private
        returns (DeployConfig memory config, DeploymentAddresses memory deployed)
    {
        config = _config();
        deployed = _deploy(config, address(this));
        FundTypes.StrategyConfig memory strategyConfig = FundTypes.StrategyConfig({
            active: false,
            maxAllocationBps: config.wheel.strategyMaxAllocationBps,
            maxLossBps: config.wheel.strategyMaxLossBps,
            cooldown: config.wheel.strategyCooldown,
            interfaceVersion: 1,
            valuator: deployed.metaWheelValuator,
            absoluteCap: config.wheel.strategyAbsoluteCap
        });
        FundAccounting(deployed.accounting)
            .setComponent(
                keccak256(abi.encodePacked("STRATEGY", deployed.coordinator)), deployed.metaWheelValuator, 1, true
            );
        StrategyManager(deployed.strategy).setStrategyConfig(deployed.coordinator, strategyConfig);
        FundFlowManager(deployed.flow).setStrategyExitEscrows(deployed.inKindEscrow, deployed.emergencyEscrow);
    }

    function _config() private view returns (DeployConfig memory config) {
        address[] memory observers = new address[](4);
        observers[0] = address(0xA001);
        observers[1] = address(0xA002);
        observers[2] = address(0xA003);
        observers[3] = address(0xA004);
        address[] memory reporters = new address[](2);
        reporters[0] = address(0xB001);
        reporters[1] = address(0xB002);
        address[] memory libraries = new address[](5);
        libraries[0] = address(CspFundAdapterOperations);
        libraries[1] = address(CoveredCallFundAdapterOperations);
        libraries[2] = address(ManagedStrategyOperations);
        libraries[3] = address(WheelManagedOperationDispatcher);
        libraries[4] = address(WheelCoordinatorPositionOperations);
        bytes32[] memory libraryCodehashes = new bytes32[](libraries.length);
        for (uint256 i; i < libraries.length; ++i) {
            libraryCodehashes[i] = libraries[i].codehash;
        }

        config.assets = AssetConfig({
            addressBook: address(addressBook),
            controller: address(feed),
            batchSettler: address(settler),
            marginPool: address(router),
            oracle: address(feed),
            oTokenFactory: address(usdc),
            whitelist: address(weth),
            usdc: address(usdc),
            weth: address(weth),
            swapRouter: address(router),
            swapFeeTier: 500
        });
        config.fund = FundConfig({
            factoryOwner: address(0x1000),
            implementationVersion: 1,
            compatibilityVersion: 1,
            salt: keccak256("B1N419_TEST"),
            name: "b1nary Meta Wheel",
            symbol: "b1WHEEL",
            minimumIdleBps: 2_000,
            navActivationDelay: 2,
            maxSnapshotAge: 32,
            maxNavWindowLength: 16,
            feeRecipient: address(0xFEE1),
            roles: FundFactory.RoleAccounts({
                admin: address(this),
                upgrader: address(this),
                accounting: address(this),
                allocator: address(this),
                processor: address(this),
                curator: address(this),
                guardian: address(this)
            })
        });
        config.finalRoles = FundFactory.RoleAccounts({
            admin: address(0x1000),
            upgrader: address(0x1001),
            accounting: address(0x1002),
            allocator: address(0x1003),
            processor: address(0x1004),
            curator: address(0x1005),
            guardian: address(0x1006)
        });
        config.wheel = WheelConfig({
            policyHash: 0x22e43a8c3c59627c5d08271585b0cf88f80f915d45f0360f71e5d84127172bf1,
            floorBufferUsd8: 10e8,
            cspLaneMaxAssets: 250_000e6,
            coveredCallLaneMaxAssets: 100 ether,
            transitionExitCostBps: 100,
            strategyMaxAllocationBps: 8_000,
            strategyMaxLossBps: 100,
            strategyCooldown: 0,
            strategyAbsoluteCap: 1_000_000e6
        });
        config.valuation = ValuationConfig({
            spotFeed: address(feed),
            spotFeedDecimals: 8,
            maxSpotStaleness: 1 hours,
            maxObservationWindow: 32,
            observationQuorum: 2,
            approvedObservers: observers,
            navReporters: reporters,
            navReporterThreshold: 2
        });
        config.cspRisk = ICspFundAdapter.RiskConfig({
            minExpiryDelay: 36 hours,
            maxExpiryDelay: 60 hours,
            settlementDefaultDelay: 1 days,
            minPremiumBps: 20,
            maxSwapSlippageBps: 100,
            maxOpenPositions: 1,
            minStrike: 1e8,
            maxStrike: 100_000e8,
            maxCollateralPerPosition: 250_000e6,
            maxWethPerSwap: 100 ether
        });
        config.coveredCallRisk = ICoveredCallFundAdapter.RiskConfig({
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 14 days,
            settlementDefaultDelay: 1 days,
            minPremiumBps: 1,
            maxSwapSlippageBps: 100,
            maxOpenPositions: 1,
            maxUtilizationBps: 10_000,
            minStrike: 1e8,
            maxStrike: 100_000e8,
            maxCollateralPerPosition: 100 ether,
            maxUsdcPerSwap: 250_000e6
        });
        config.standalone = standalone;
        config.sourceCommit = "df831a7e7a5110b7ae36f51d422b15e79b77e990";
        config.linkedLibraries = libraries;
        config.linkedLibraryCodehashes = libraryCodehashes;
    }

    function _standaloneBaseline() private returns (StandaloneBaseline memory baseline) {
        (baseline.cspVaultProxy, baseline.cspVaultImplementation, baseline.cspVaultImplementationCodehash) =
            _dummyProxy();
        (baseline.cspAdapterProxy, baseline.cspAdapterImplementation, baseline.cspAdapterImplementationCodehash) =
            _dummyProxy();
        (
            baseline.coveredCallVaultProxy,
            baseline.coveredCallVaultImplementation,
            baseline.coveredCallVaultImplementationCodehash
        ) = _dummyProxy();
        (
            baseline.coveredCallAdapterProxy,
            baseline.coveredCallAdapterImplementation,
            baseline.coveredCallAdapterImplementationCodehash
        ) = _dummyProxy();
    }

    function _dummyProxy() private returns (address proxy, address implementation, bytes32 codehash) {
        implementation = address(new MockERC20("Baseline", "BASE", 18));
        proxy = address(new ERC1967Proxy(implementation, ""));
        codehash = implementation.codehash;
    }

    function _assertManifestAddress(
        string memory manifest,
        string memory operationalPath,
        string memory canonicalPath,
        address expected
    ) private {
        address operational = vm.parseJsonAddress(manifest, operationalPath);
        address canonical = vm.parseJsonAddress(manifest, canonicalPath);
        assertNotEq(operational, address(0));
        assertEq(operational, expected);
        assertEq(canonical, expected);
    }

    function _assertManifestCodehash(
        string memory manifest,
        string memory operationalPath,
        string memory canonicalPath,
        bytes32 expected
    ) private {
        bytes32 operational = vm.parseJsonBytes32(manifest, operationalPath);
        bytes32 canonical = vm.parseJsonBytes32(manifest, canonicalPath);
        assertNotEq(operational, bytes32(0));
        assertEq(operational, expected);
        assertEq(canonical, expected);
    }

    function _assertCanonicalCodehash(string memory manifest, string memory path, bytes32 expected) private {
        bytes32 value = vm.parseJsonBytes32(manifest, path);
        assertNotEq(value, bytes32(0));
        assertEq(value, expected);
    }

    function _assertOperationalAddress(string memory manifest, string memory path, address expected) private {
        address value = vm.parseJsonAddress(manifest, path);
        assertNotEq(value, address(0));
        assertEq(value, expected);
    }

    function _assertOperationalCodehash(string memory manifest, string memory path, bytes32 expected) private {
        bytes32 value = vm.parseJsonBytes32(manifest, path);
        assertNotEq(value, bytes32(0));
        assertEq(value, expected);
    }

    function _assertOperationalAddresses(string memory manifest, string memory path, address[4] memory expected)
        private
    {
        address[] memory values = vm.parseJsonAddressArray(manifest, path);
        assertEq(values.length, expected.length);
        for (uint256 i; i < values.length; ++i) {
            assertNotEq(values[i], address(0));
            assertEq(values[i], expected[i]);
        }
    }

    function _assertOperationalCodehashes(string memory manifest, string memory path, address[4] memory deployed)
        private
    {
        bytes32[] memory values = vm.parseJsonBytes32Array(manifest, path);
        assertEq(values.length, deployed.length);
        for (uint256 i; i < values.length; ++i) {
            assertNotEq(values[i], bytes32(0));
            assertEq(values[i], deployed[i].codehash);
        }
    }

    function _assertRoles(FundAccessManager manager, FundFactory.RoleAccounts memory roles) private view {
        _requireSingleImmediateRole(manager, manager.ADMIN_ROLE(), roles.admin);
        _requireSingleImmediateRole(manager, FundConstants.UPGRADER_ROLE, roles.upgrader);
        _requireSingleImmediateRole(manager, FundConstants.ADAPTER_UPGRADER_ROLE, roles.upgrader);
        _requireSingleImmediateRole(manager, FundConstants.ACCOUNTING_ROLE, roles.accounting);
        _requireSingleImmediateRole(manager, FundConstants.ALLOCATOR_ROLE, roles.allocator);
        _requireSingleImmediateRole(manager, FundConstants.PROCESSOR_ROLE, roles.processor);
        _requireSingleImmediateRole(manager, FundConstants.CURATOR_ROLE, roles.curator);
        _requireSingleImmediateRole(manager, FundConstants.GUARDIAN_ROLE, roles.guardian);
    }
}
