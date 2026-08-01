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
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {CspFundAdapterOperations} from "../../src/fund/libraries/CspFundAdapterOperations.sol";
import {CoveredCallFundAdapterOperations} from "../../src/fund/libraries/CoveredCallFundAdapterOperations.sol";
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
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), address(this), address(this)))
                )
            )
        );
        addressBook.setController(address(feed));
        addressBook.setMarginPool(address(router));
        addressBook.setOTokenFactory(address(usdc));
        addressBook.setOracle(address(feed));
        addressBook.setWhitelist(address(weth));
        addressBook.setBatchSettler(address(settler));
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
        assertEq(coordinator.registeredLaneCount(), 8);
        assertEq(coordinator.policyHash(), config.wheel.policyHash);
        assertEq(coordinator.floorBufferUsd8(), config.wheel.floorBufferUsd8);
        assertEq(StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator).interfaceVersion, 0);

        for (uint256 i; i < 4; ++i) {
            assertEq(WheelCspChildLane(deployed.cspLanes[i]).coordinator(), deployed.coordinator);
            assertEq(WheelCspChildLane(deployed.cspLanes[i]).adapter(), deployed.cspAdapters[i]);
            assertFalse(ICspFundAdapter(deployed.cspAdapters[i]).isOnboarded());
            assertEq(WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).coordinator(), deployed.coordinator);
            assertEq(WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).adapter(), deployed.coveredCallAdapters[i]);
            assertEq(
                WheelCoveredCallChildLane(deployed.coveredCallLanes[i]).executionCostBuffer8(),
                config.wheel.floorBufferUsd8
            );
            assertFalse(ICoveredCallFundAdapter(deployed.coveredCallAdapters[i]).isOnboarded());
        }

        _assertRoles(FundAccessManager(deployed.accessManager), config.fund.roles);
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        assertEq(
            manager.getTargetFunctionRole(deployed.coordinator, WheelCoordinatorAdapter.openCspTranche.selector),
            FundConstants.ALLOCATOR_ROLE
        );
        assertEq(
            manager.getTargetFunctionRole(deployed.coordinator, WheelCoordinatorAdapter.settleCspTranche.selector),
            FundConstants.PROCESSOR_ROLE
        );
        assertEq(
            manager.getTargetFunctionRole(deployed.coordinator, WheelCoordinatorAdapter.pauseAllocations.selector),
            FundConstants.GUARDIAN_ROLE
        );
        assertEq(
            manager.getTargetFunctionRole(deployed.coordinator, WheelCoordinatorAdapter.registerLane.selector),
            FundConstants.CURATOR_ROLE
        );
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

    function test_preflightRejectsRoleOverlap() public {
        DeployConfig memory config = _config();
        config.finalRoles.guardian = config.finalRoles.curator;
        vm.expectRevert(bytes("B1N419: role overlap"));
        this.validateForTest(config, address(this));
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
        settler.setProtocolFeeBps(PREMIUM_FEE_BPS - 1);
        vm.expectRevert(bytes("B1N419: premium fee"));
        this.validateForTest(config, address(this));
    }

    function _config() private view returns (DeployConfig memory config) {
        address[] memory observers = new address[](2);
        observers[0] = address(0xA001);
        observers[1] = address(0xA002);
        address[] memory reporters = new address[](2);
        reporters[0] = address(0xB001);
        reporters[1] = address(0xB002);
        address[] memory libraries = new address[](5);
        libraries[0] = address(CspFundAdapterOperations);
        libraries[1] = address(CoveredCallFundAdapterOperations);
        libraries[2] = address(feed);
        libraries[3] = address(router);
        libraries[4] = address(addressBook);
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
            minimumIdleBps: 500,
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
            policyHash: 0xdb47fcd1f4f96b656fe462956c85194b1f5e25d0c1d8c8862864b256d38fa93c,
            floorBufferUsd8: 10e8,
            cspLaneMaxAssets: 250_000e6,
            coveredCallLaneMaxAssets: 100 ether,
            transitionExitCostBps: 100,
            strategyMaxAllocationBps: 9_500,
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
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 14 days,
            settlementDefaultDelay: 1 days,
            minPremiumBps: 1,
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
        config.sourceCommit = "7882c9d";
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
