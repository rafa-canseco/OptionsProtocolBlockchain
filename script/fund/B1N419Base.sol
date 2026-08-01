// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";

abstract contract B1N419Base is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal constant CSP_LANE_COUNT = 4;
    uint256 internal constant COVERED_CALL_LANE_COUNT = 4;
    uint256 internal constant PREMIUM_FEE_BPS = 1_000;
    uint64 internal constant MANAGEMENT_FEE_WAD = 0.02e18;
    uint16 internal constant PERFORMANCE_FEE_BPS = 1_000;
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 200;
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 2_000;
    uint32 internal constant MAX_ACCRUAL_INTERVAL = 30 days;
    uint32 internal constant CRYSTALLIZATION_PERIOD = 1 days;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant IN_KIND_ESCROW_PURPOSE = keccak256("B1NARY_META_WHEEL_IN_KIND_ESCROW");
    bytes32 internal constant EMERGENCY_ESCROW_PURPOSE = keccak256("B1NARY_META_WHEEL_EMERGENCY_ESCROW");

    struct AssetConfig {
        address addressBook;
        address controller;
        address batchSettler;
        address marginPool;
        address oracle;
        address oTokenFactory;
        address whitelist;
        address usdc;
        address weth;
        address swapRouter;
        uint24 swapFeeTier;
    }

    struct FundConfig {
        address factoryOwner;
        uint64 implementationVersion;
        uint64 compatibilityVersion;
        bytes32 salt;
        string name;
        string symbol;
        uint16 minimumIdleBps;
        uint64 navActivationDelay;
        uint64 maxSnapshotAge;
        uint64 maxNavWindowLength;
        address feeRecipient;
        FundFactory.RoleAccounts roles;
    }

    struct WheelConfig {
        bytes32 policyHash;
        uint256 floorBufferUsd8;
        uint256 cspLaneMaxAssets;
        uint256 coveredCallLaneMaxAssets;
        uint16 transitionExitCostBps;
        uint16 strategyMaxAllocationBps;
        uint16 strategyMaxLossBps;
        uint32 strategyCooldown;
        uint256 strategyAbsoluteCap;
    }

    struct ValuationConfig {
        address spotFeed;
        uint8 spotFeedDecimals;
        uint64 maxSpotStaleness;
        uint64 maxObservationWindow;
        uint8 observationQuorum;
        address[] approvedObservers;
        address[] navReporters;
        uint16 navReporterThreshold;
    }

    struct StandaloneBaseline {
        address cspVaultProxy;
        address cspVaultImplementation;
        bytes32 cspVaultImplementationCodehash;
        address cspAdapterProxy;
        address cspAdapterImplementation;
        bytes32 cspAdapterImplementationCodehash;
        address coveredCallVaultProxy;
        address coveredCallVaultImplementation;
        bytes32 coveredCallVaultImplementationCodehash;
        address coveredCallAdapterProxy;
        address coveredCallAdapterImplementation;
        bytes32 coveredCallAdapterImplementationCodehash;
    }

    struct DeployConfig {
        AssetConfig assets;
        FundConfig fund;
        WheelConfig wheel;
        ValuationConfig valuation;
        ICspFundAdapter.RiskConfig cspRisk;
        ICoveredCallFundAdapter.RiskConfig coveredCallRisk;
        StandaloneBaseline standalone;
        FundFactory.RoleAccounts finalRoles;
        string sourceCommit;
        address[] linkedLibraries;
        bytes32[] linkedLibraryCodehashes;
    }

    struct DeploymentAddresses {
        bytes32 deploymentId;
        address factory;
        address accessManagerDeployer;
        address vaultImplementation;
        address shareImplementation;
        address accountingImplementation;
        address flowImplementation;
        address strategyImplementation;
        address navVerifier;
        address vault;
        address share;
        address accounting;
        address flow;
        address strategy;
        address claimEscrow;
        address accessManager;
        address coordinatorImplementation;
        address coordinator;
        address metaWheelValuator;
        address cspAdapterImplementation;
        address cspLaneImplementation;
        address cspValuator;
        address coveredCallAdapterImplementation;
        address coveredCallLaneImplementation;
        address coveredCallValuator;
        address inKindEscrow;
        address emergencyEscrow;
        address[4] cspLanes;
        address[4] cspAdapters;
        address[4] coveredCallLanes;
        address[4] coveredCallAdapters;
    }

    function _requireBaseSepolia() internal view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "B1N419: Base Sepolia only");
    }

    function _feeConfig(address recipient) internal pure returns (FundTypes.FeeConfig memory config) {
        config = FundTypes.FeeConfig({
            managementFeeWad: MANAGEMENT_FEE_WAD,
            performanceFeeBps: PERFORMANCE_FEE_BPS,
            maxManagementFeeBps: MAX_MANAGEMENT_FEE_BPS,
            maxPerformanceFeeBps: MAX_PERFORMANCE_FEE_BPS,
            maxAccrualInterval: MAX_ACCRUAL_INTERVAL,
            crystallizationPeriod: CRYSTALLIZATION_PERIOD,
            feeRecipient: recipient
        });
    }

    function _validateConfig(DeployConfig memory config, address broadcaster) internal view {
        require(config.fund.roles.admin == broadcaster, "B1N419: broadcaster not admin");
        require(config.fund.factoryOwner != address(0) && config.fund.feeRecipient != address(0), "B1N419: owner");
        require(config.fund.implementationVersion != 0 && config.fund.compatibilityVersion != 0, "B1N419: version");
        require(config.fund.salt != bytes32(0), "B1N419: salt");
        require(bytes(config.fund.name).length != 0 && bytes(config.fund.symbol).length != 0, "B1N419: metadata");
        require(config.assets.addressBook.code.length != 0, "B1N419: address book");
        AddressBook book = AddressBook(config.assets.addressBook);
        require(book.controller() == config.assets.controller, "B1N419: controller drift");
        require(book.batchSettler() == config.assets.batchSettler, "B1N419: settler drift");
        require(book.marginPool() == config.assets.marginPool, "B1N419: margin pool drift");
        require(book.oracle() == config.assets.oracle, "B1N419: oracle drift");
        require(book.oTokenFactory() == config.assets.oTokenFactory, "B1N419: factory drift");
        require(book.whitelist() == config.assets.whitelist, "B1N419: whitelist drift");
        require(
            config.assets.controller.code.length != 0 && config.assets.batchSettler.code.length != 0
                && config.assets.marginPool.code.length != 0 && config.assets.oracle.code.length != 0
                && config.assets.oTokenFactory.code.length != 0 && config.assets.whitelist.code.length != 0,
            "B1N419: protocol dependency"
        );
        require(config.assets.usdc.code.length != 0 && config.assets.weth.code.length != 0, "B1N419: assets");
        require(config.assets.swapRouter.code.length != 0, "B1N419: router");
        require(IERC20Metadata(config.assets.usdc).decimals() == 6, "B1N419: USDC decimals");
        require(IERC20Metadata(config.assets.weth).decimals() == 18, "B1N419: WETH decimals");
        require(config.valuation.spotFeed.code.length != 0, "B1N419: spot feed");
        require(
            IERC20Metadata(config.valuation.spotFeed).decimals() == config.valuation.spotFeedDecimals,
            "B1N419: feed decimals"
        );
        require(
            config.valuation.maxSpotStaleness != 0 && config.valuation.maxObservationWindow != 0, "B1N419: valuation"
        );
        require(
            config.valuation.approvedObservers.length == 4 && config.valuation.observationQuorum == 2,
            "B1N419: observers"
        );
        require(
            config.valuation.navReporters.length == 2 && config.valuation.navReporterThreshold == 2, "B1N419: reporters"
        );
        require(config.wheel.policyHash != bytes32(0), "B1N419: policy hash");
        require(
            config.wheel.floorBufferUsd8 != 0 && config.wheel.cspLaneMaxAssets != 0
                && config.wheel.coveredCallLaneMaxAssets != 0 && config.wheel.strategyAbsoluteCap != 0,
            "B1N419: wheel bounds"
        );
        require(
            config.wheel.strategyMaxAllocationBps <= 10_000 && config.wheel.strategyMaxLossBps <= 10_000
                && config.wheel.transitionExitCostBps <= 10_000,
            "B1N419: wheel bps"
        );
        require(
            config.linkedLibraries.length == 5
                && config.linkedLibraries.length == config.linkedLibraryCodehashes.length,
            "B1N419: linked libraries"
        );
        for (uint256 i; i < config.linkedLibraries.length; ++i) {
            require(
                config.linkedLibraries[i] != address(0) && config.linkedLibraries[i].code.length != 0
                    && config.linkedLibraries[i].codehash == config.linkedLibraryCodehashes[i],
                "B1N419: library"
            );
        }
        _requireNonzeroRoles(config.fund.roles);
        require(
            config.fund.roles.upgrader == broadcaster && config.fund.roles.accounting == broadcaster
                && config.fund.roles.allocator == broadcaster && config.fund.roles.processor == broadcaster
                && config.fund.roles.curator == broadcaster && config.fund.roles.guardian == broadcaster,
            "B1N419: bootstrap role account"
        );
        _requireDistinctRoles(config.finalRoles);
        require(config.fund.factoryOwner == config.finalRoles.admin, "B1N419: factory owner role");
        require(
            config.finalRoles.admin != broadcaster && config.finalRoles.upgrader != broadcaster
                && config.finalRoles.accounting != broadcaster && config.finalRoles.allocator != broadcaster
                && config.finalRoles.processor != broadcaster && config.finalRoles.curator != broadcaster
                && config.finalRoles.guardian != broadcaster,
            "B1N419: bootstrap retained"
        );
        _requireUniqueNonzero(config.valuation.approvedObservers, "B1N419: observer address");
        _requireUniqueNonzero(config.valuation.navReporters, "B1N419: reporter address");
        _requireValuationKeySeparation(config);
        _requireV1Policy(config);
        _requireStandaloneBaseline(config.standalone);
    }

    function _requireV1Policy(DeployConfig memory config) internal view {
        require(config.assets.batchSettler.code.length != 0, "B1N419: settler");
        require(BatchSettler(config.assets.batchSettler).protocolFeeBps() == PREMIUM_FEE_BPS, "B1N419: premium fee");
    }

    function _requireStandaloneBaseline(StandaloneBaseline memory baseline) internal view {
        _requireProxyBaseline(
            baseline.cspVaultProxy,
            baseline.cspVaultImplementation,
            baseline.cspVaultImplementationCodehash,
            "B1N419: CSP vault baseline"
        );
        _requireProxyBaseline(
            baseline.cspAdapterProxy,
            baseline.cspAdapterImplementation,
            baseline.cspAdapterImplementationCodehash,
            "B1N419: CSP adapter baseline"
        );
        _requireProxyBaseline(
            baseline.coveredCallVaultProxy,
            baseline.coveredCallVaultImplementation,
            baseline.coveredCallVaultImplementationCodehash,
            "B1N419: CC vault baseline"
        );
        _requireProxyBaseline(
            baseline.coveredCallAdapterProxy,
            baseline.coveredCallAdapterImplementation,
            baseline.coveredCallAdapterImplementationCodehash,
            "B1N419: CC adapter baseline"
        );
    }

    function _requireProxyBaseline(address proxy, address implementation, bytes32 codehash, string memory reason)
        internal
        view
    {
        require(proxy != address(0) && proxy.code.length != 0, reason);
        require(_implementationOf(proxy) == implementation && implementation.codehash == codehash, reason);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _requireFactoryDeployment(DeploymentAddresses memory deployed, uint64 expectedVersion) internal view {
        FundFactory.FundDeployment memory registered = FundFactory(deployed.factory).deployment(deployed.deploymentId);
        require(
            registered.vault == deployed.vault && registered.share == deployed.share
                && registered.accounting == deployed.accounting && registered.navVerifier == deployed.navVerifier
                && registered.flowManager == deployed.flow && registered.strategyManager == deployed.strategy
                && registered.claimEscrow == deployed.claimEscrow && registered.accessManager == deployed.accessManager,
            "B1N419: factory deployment"
        );
        require(registered.implementationVersion == expectedVersion, "B1N419: factory version");
    }

    function _requireNonzeroRoles(FundFactory.RoleAccounts memory roles) private pure {
        require(
            roles.admin != address(0) && roles.upgrader != address(0) && roles.accounting != address(0)
                && roles.allocator != address(0) && roles.processor != address(0) && roles.curator != address(0)
                && roles.guardian != address(0),
            "B1N419: zero role"
        );
    }

    function _requireDistinctRoles(FundFactory.RoleAccounts memory roles) private pure {
        address[7] memory accounts = [
            roles.admin,
            roles.upgrader,
            roles.accounting,
            roles.allocator,
            roles.processor,
            roles.curator,
            roles.guardian
        ];
        for (uint256 i; i < accounts.length; ++i) {
            require(accounts[i] != address(0), "B1N419: zero role");
            for (uint256 j; j < i; ++j) {
                require(accounts[i] != accounts[j], "B1N419: role overlap");
            }
        }
    }

    function _requireUniqueNonzero(address[] memory accounts, string memory reason) private pure {
        for (uint256 i; i < accounts.length; ++i) {
            require(accounts[i] != address(0), reason);
            for (uint256 j; j < i; ++j) {
                require(accounts[i] != accounts[j], reason);
            }
        }
    }

    function _requireValuationKeySeparation(DeployConfig memory config) private pure {
        for (uint256 i; i < config.valuation.approvedObservers.length; ++i) {
            address observer = config.valuation.approvedObservers[i];
            require(
                !_isRoleAccount(observer, config.fund.roles) && !_isRoleAccount(observer, config.finalRoles),
                "B1N419: observer reuses role"
            );
            for (uint256 j; j < config.valuation.navReporters.length; ++j) {
                require(observer != config.valuation.navReporters[j], "B1N419: observer reporter overlap");
            }
        }
        for (uint256 i; i < config.valuation.navReporters.length; ++i) {
            address reporter = config.valuation.navReporters[i];
            require(
                !_isRoleAccount(reporter, config.fund.roles) && !_isRoleAccount(reporter, config.finalRoles),
                "B1N419: reporter reuses role"
            );
        }
    }

    function _isRoleAccount(address account, FundFactory.RoleAccounts memory roles) private pure returns (bool) {
        return account == roles.admin || account == roles.upgrader || account == roles.accounting
            || account == roles.allocator || account == roles.processor || account == roles.curator
            || account == roles.guardian;
    }

    function _requireSingleImmediateRole(FundAccessManager manager, uint64 role, address expected) internal view {
        require(manager.roleMemberCount(role) == 1, "B1N419: role member count");
        require(manager.roleMemberAt(role, 0) == expected, "B1N419: role member");
        (bool active, uint32 delay) = manager.hasRole(role, expected);
        require(active && delay == 0, "B1N419: role unavailable");
    }

    function _requireFinalRoles(FundAccessManager manager, FundFactory.RoleAccounts memory roles) internal view {
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
