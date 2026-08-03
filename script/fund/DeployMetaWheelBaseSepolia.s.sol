// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {NavReportVerifier} from "../../src/fund/NavReportVerifier.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {B1N419ZeroDelayMetaWheelFundFactory} from "../../src/fund/B1N419ZeroDelayMetaWheelFundFactory.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {WheelCoveredCallFundAdapter} from "../../src/fund/WheelCoveredCallFundAdapter.sol";
import {MetaWheelValuator} from "../../src/fund/MetaWheelValuator.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {CspFundAdapterOperations} from "../../src/fund/libraries/CspFundAdapterOperations.sol";
import {CoveredCallFundAdapterOperations} from "../../src/fund/libraries/CoveredCallFundAdapterOperations.sol";
import {ManagedStrategyOperations} from "../../src/fund/libraries/ManagedStrategyOperations.sol";
import {WheelCoordinatorPositionOperations} from "../../src/fund/libraries/WheelCoordinatorPositionOperations.sol";
import {WheelManagedOperationDispatcher} from "../../src/fund/libraries/WheelManagedOperationDispatcher.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";
import {WheelAccessPolicy} from "../../src/fund/libraries/WheelAccessPolicy.sol";
import {B1N419Base} from "./B1N419Base.sol";

/// @notice Fresh, paused Meta Wheel deployment. This script never upgrades or registers a standalone proxy.
/// @dev Child-adapter onboarding and parent strategy activation are deliberately separate phases.
contract DeployMetaWheelBaseSepolia is B1N419Base {
    function run() external virtual returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        require(
            keccak256(bytes(config.sourceCommit)) == keccak256(bytes(vm.envString("B1N419_SOURCE_COMMIT"))),
            "B1N419: source commit"
        );
        address deployer = vm.envAddress("B1N419_BROADCASTER");
        _validateConfig(config, deployer);

        vm.startBroadcast(deployer);
        deployed = _deploy(config, deployer);
        vm.stopBroadcast();

        _reconcileBootstrap(config, deployed);
        _writeManifest(config, deployed, vm.envString("B1N419_MANIFEST_PATH"));
        _logDeployment(deployed);
    }

    function _deploy(DeployConfig memory config, address deployer)
        internal
        returns (DeploymentAddresses memory deployed)
    {
        require(config.linkedLibraries[0] == address(CspFundAdapterOperations), "B1N419: CSP library binding");
        require(config.linkedLibraries[1] == address(CoveredCallFundAdapterOperations), "B1N419: CC library binding");
        require(config.linkedLibraries[2] == address(ManagedStrategyOperations), "B1N419: managed library binding");
        require(
            config.linkedLibraries[3] == address(WheelManagedOperationDispatcher), "B1N419: dispatcher library binding"
        );
        require(
            config.linkedLibraries[4] == address(WheelCoordinatorPositionOperations), "B1N419: position library binding"
        );

        deployed.vaultImplementation = address(new FundVault());
        deployed.shareImplementation = address(new FundShare());
        deployed.accountingImplementation = address(new FundAccounting());
        deployed.flowImplementation = address(new FundFlowManager());
        deployed.strategyImplementation = address(new StrategyManager());
        deployed.navVerifier = address(new NavReportVerifier());

        B1N419ZeroDelayMetaWheelFundFactory factory = new B1N419ZeroDelayMetaWheelFundFactory(deployer);
        deployed.factory = address(factory);
        deployed.accessManagerDeployer = address(factory.accessManagerDeployer());
        factory.registerImplementationVersion(
            config.fund.implementationVersion,
            FundFactory.ImplementationSet({
                vault: deployed.vaultImplementation,
                share: deployed.shareImplementation,
                accounting: deployed.accountingImplementation,
                navVerifier: deployed.navVerifier,
                flowManager: deployed.flowImplementation,
                strategyManager: deployed.strategyImplementation,
                compatibilityVersion: config.fund.compatibilityVersion,
                active: true
            })
        );
        FundFactory.CreateFundParams memory params = FundFactory.CreateFundParams({
            implementationVersion: config.fund.implementationVersion,
            salt: config.fund.salt,
            name: config.fund.name,
            symbol: config.fund.symbol,
            asset: IERC20(config.assets.usdc),
            minimumIdleBps: config.fund.minimumIdleBps,
            navActivationDelay: config.fund.navActivationDelay,
            maxSnapshotAge: config.fund.maxSnapshotAge,
            maxNavWindowLength: config.fund.maxNavWindowLength,
            feeConfig: _feeConfig(config.fund.feeRecipient),
            roles: config.fund.roles
        });
        deployed.deploymentId = factory.computeDeploymentId(params, deployer);
        FundFactory.FundDeployment memory fund = factory.createFund(params);
        deployed.vault = fund.vault;
        deployed.share = fund.share;
        deployed.accounting = fund.accounting;
        deployed.flow = fund.flowManager;
        deployed.strategy = fund.strategyManager;
        deployed.claimEscrow = fund.claimEscrow;
        deployed.accessManager = fund.accessManager;

        address[] memory cspObservers = _observerPair(config.valuation.approvedObservers, 0);
        address[] memory coveredCallObservers = _observerPair(config.valuation.approvedObservers, 2);
        deployed.cspValuator = address(
            new CspFundValuatorV2(
                config.valuation.spotFeed,
                config.valuation.spotFeedDecimals,
                config.valuation.maxSpotStaleness,
                config.valuation.maxObservationWindow,
                config.valuation.observationQuorum,
                cspObservers
            )
        );
        deployed.coveredCallValuator = address(
            new CoveredCallFundValuatorV2(
                config.valuation.spotFeed,
                config.valuation.spotFeedDecimals,
                config.valuation.maxSpotStaleness,
                config.valuation.maxObservationWindow,
                config.valuation.observationQuorum,
                coveredCallObservers
            )
        );
        deployed.metaWheelValuator = address(
            new MetaWheelValuator(
                config.assets.usdc,
                config.assets.weth,
                config.valuation.spotFeed,
                deployed.cspValuator,
                deployed.coveredCallValuator,
                config.valuation.spotFeedDecimals,
                config.valuation.maxSpotStaleness,
                config.wheel.transitionExitCostBps
            )
        );

        deployed.coordinatorImplementation = address(new WheelCoordinatorAdapter());
        deployed.coordinator = address(
            new ERC1967Proxy(
                deployed.coordinatorImplementation,
                abi.encodeCall(
                    WheelCoordinatorAdapter.initialize,
                    (WheelCoordinatorAdapter.InitializeParams({
                            fund: fund.vault,
                            strategyManager: fund.strategyManager,
                            usdc: config.assets.usdc,
                            weth: config.assets.weth,
                            authority: fund.accessManager,
                            maxCspLanes: uint16(CSP_LANE_COUNT),
                            maxCoveredCallLanes: uint16(COVERED_CALL_LANE_COUNT),
                            floorBufferUsd8: config.wheel.floorBufferUsd8,
                            policyHash: config.wheel.policyHash
                        }))
                )
            )
        );

        deployed.cspAdapterImplementation = address(new CspFundAdapter());
        deployed.cspLaneImplementation = address(new WheelCspChildLane());
        deployed.coveredCallAdapterImplementation = address(new WheelCoveredCallFundAdapter());
        deployed.coveredCallLaneImplementation = address(new WheelCoveredCallChildLane());

        _deployCspLanes(config, deployed);
        _deployCoveredCallLanes(config, deployed);

        _configureRules(
            FundAccessManager(deployed.accessManager), deployed.coordinator, WheelAccessPolicy.coordinatorRules()
        );

        deployed.inKindEscrow =
            address(new StrategyAssetEscrow(deployed.vault, deployed.accessManager, IN_KIND_ESCROW_PURPOSE));
        deployed.emergencyEscrow =
            address(new StrategyAssetEscrow(deployed.vault, deployed.accessManager, EMERGENCY_ESCROW_PURPOSE));
        _configureRules(
            FundAccessManager(deployed.accessManager),
            deployed.inKindEscrow,
            FundAccessPolicy.strategyAssetEscrowRules()
        );
        _configureRules(
            FundAccessManager(deployed.accessManager),
            deployed.emergencyEscrow,
            FundAccessPolicy.strategyAssetEscrowRules()
        );

        factory.transferOwnership(config.fund.factoryOwner);
    }

    function _deployCspLanes(DeployConfig memory config, DeploymentAddresses memory deployed) private {
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        for (uint256 i; i < CSP_LANE_COUNT; ++i) {
            address lane = address(new ERC1967Proxy(deployed.cspLaneImplementation, ""));
            address adapter = address(
                new ERC1967Proxy(
                    deployed.cspAdapterImplementation,
                    abi.encodeCall(
                        CspFundAdapter.initialize,
                        (CspFundAdapter.InitializeParams({
                                fund: lane,
                                strategyManager: lane,
                                addressBook: config.assets.addressBook,
                                accountingAsset: config.assets.usdc,
                                weth: config.assets.weth,
                                swapRouter: config.assets.swapRouter,
                                swapFeeTier: config.assets.swapFeeTier,
                                authority: deployed.accessManager,
                                riskConfig: config.cspRisk
                            }))
                    )
                )
            );
            WheelCspChildLane(lane)
                .initialize(
                    WheelCspChildLane.InitializeParams({
                        coordinator: deployed.coordinator,
                        adapter: adapter,
                        usdc: config.assets.usdc,
                        weth: config.assets.weth,
                        authority: deployed.accessManager,
                        maxAssets: config.wheel.cspLaneMaxAssets
                    })
                );
            _configureRules(manager, lane, WheelAccessPolicy.cspLaneRules());
            _configureRules(manager, adapter, FundAccessPolicy.cspAdapterRules());
            WheelCspChildLane(lane).pauseAllocations();
            deployed.cspLanes[i] = lane;
            deployed.cspAdapters[i] = adapter;
        }
    }

    function _observerPair(address[] memory observers, uint256 offset) private pure returns (address[] memory pair) {
        require(observers.length == 4 && offset <= 2, "B1N419: observer pair");
        pair = new address[](2);
        pair[0] = observers[offset];
        pair[1] = observers[offset + 1];
    }

    function _deployCoveredCallLanes(DeployConfig memory config, DeploymentAddresses memory deployed) private {
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        for (uint256 i; i < COVERED_CALL_LANE_COUNT; ++i) {
            address lane = address(new ERC1967Proxy(deployed.coveredCallLaneImplementation, ""));
            address adapter = address(
                new ERC1967Proxy(
                    deployed.coveredCallAdapterImplementation,
                    abi.encodeCall(
                        CoveredCallFundAdapter.initialize,
                        (CoveredCallFundAdapter.InitializeParams({
                                fund: lane,
                                strategyManager: lane,
                                addressBook: config.assets.addressBook,
                                accountingAsset: config.assets.weth,
                                usdc: config.assets.usdc,
                                swapRouter: config.assets.swapRouter,
                                swapFeeTier: config.assets.swapFeeTier,
                                authority: deployed.accessManager,
                                riskConfig: config.coveredCallRisk
                            }))
                    )
                )
            );
            WheelCoveredCallChildLane(lane)
                .initialize(
                    WheelCoveredCallChildLane.InitializeParams({
                        coordinator: deployed.coordinator,
                        adapter: adapter,
                        usdc: config.assets.usdc,
                        weth: config.assets.weth,
                        authority: deployed.accessManager,
                        maxAssets: config.wheel.coveredCallLaneMaxAssets,
                        executionCostBuffer8: config.wheel.floorBufferUsd8
                    })
                );
            _configureRules(manager, lane, WheelAccessPolicy.coveredCallLaneRules());
            _configureRules(manager, adapter, FundAccessPolicy.coveredCallAdapterRules());
            WheelCoveredCallChildLane(lane).pauseAllocations();
            deployed.coveredCallLanes[i] = lane;
            deployed.coveredCallAdapters[i] = adapter;
        }
    }

    function _configureRules(FundAccessManager manager, address target, FundAccessPolicy.Rule[] memory rules) private {
        for (uint256 i; i < rules.length; ++i) {
            bytes4[] memory selector = new bytes4[](1);
            selector[0] = rules[i].selector;
            manager.setTargetFunctionRole(target, selector, rules[i].role);
        }
    }

    function _reconcileBootstrap(DeployConfig memory config, DeploymentAddresses memory deployed) internal view {
        _requireFactoryDeployment(deployed, config.fund.implementationVersion);
        require(FundVault(deployed.vault).asset() == config.assets.usdc, "B1N419: vault asset");
        require(FundVault(deployed.vault).depositsPaused(), "B1N419: deposits open");
        require(FundVault(deployed.vault).redemptionsPaused(), "B1N419: redemptions open");
        require(WheelCoordinatorAdapter(deployed.coordinator).fund() == deployed.vault, "B1N419: coordinator fund");
        require(WheelCoordinatorAdapter(deployed.coordinator).registeredLaneCount() == 0, "B1N419: lanes registered");
        (uint16 cspCap, uint16 coveredCallCap) = WheelCoordinatorAdapter(deployed.coordinator).laneCaps();
        require(cspCap == CSP_LANE_COUNT && coveredCallCap == COVERED_CALL_LANE_COUNT, "B1N419: lane caps");
        require(WheelCoordinatorAdapter(deployed.coordinator).policyHash() == config.wheel.policyHash, "B1N419: policy");
        require(
            WheelCoordinatorAdapter(deployed.coordinator).floorBufferUsd8() == config.wheel.floorBufferUsd8,
            "B1N419: floor buffer"
        );
        require(
            StrategyManager(deployed.strategy).strategyConfig(deployed.coordinator).interfaceVersion == 0,
            "B1N419: configured early"
        );
        _requireV1Policy(config);
        _requireStandaloneBaseline(config.standalone);
    }

    function _loadConfig() internal returns (DeployConfig memory config) {
        string memory json = vm.readFile(vm.envString("B1N419_APPROVED_INPUTS_PATH"));
        require(sha256(bytes(json)) == vm.envBytes32("B1N419_APPROVED_INPUTS_SHA256"), "B1N419: input digest");
        _requireInputApproval(json);
        string memory root = ".environment.";
        config.sourceCommit = vm.parseJsonString(json, string.concat(root, "SOURCE_COMMIT"));
        config.assets = AssetConfig({
            addressBook: vm.parseJsonAddress(json, string.concat(root, "ADDRESS_BOOK")),
            controller: vm.parseJsonAddress(json, string.concat(root, "CONTROLLER")),
            batchSettler: vm.parseJsonAddress(json, string.concat(root, "BATCH_SETTLER")),
            marginPool: vm.parseJsonAddress(json, string.concat(root, "MARGIN_POOL")),
            oracle: vm.parseJsonAddress(json, string.concat(root, "ORACLE")),
            oTokenFactory: vm.parseJsonAddress(json, string.concat(root, "OTOKEN_FACTORY")),
            whitelist: vm.parseJsonAddress(json, string.concat(root, "WHITELIST")),
            usdc: vm.parseJsonAddress(json, string.concat(root, "USDC")),
            weth: vm.parseJsonAddress(json, string.concat(root, "WETH")),
            swapRouter: vm.parseJsonAddress(json, string.concat(root, "SWAP_ROUTER")),
            swapFeeTier: uint24(vm.parseJsonUint(json, string.concat(root, "SWAP_FEE_TIER")))
        });
        config.fund = _loadFundConfig(json, root);
        config.finalRoles = _loadFinalRoles(json, root);
        config.wheel = _loadWheelConfig(json, root);
        config.valuation = _loadValuationConfig(json, root);
        config.cspRisk = _loadCspRisk(json, root);
        config.coveredCallRisk = _loadCoveredCallRisk(json, root);
        config.standalone = _loadStandaloneBaseline(json, root);
        config.linkedLibraries = vm.parseJsonAddressArray(json, string.concat(root, "LINKED_LIBRARIES"));
        config.linkedLibraryCodehashes =
            vm.parseJsonBytes32Array(json, string.concat(root, "LINKED_LIBRARY_CODEHASHES"));
    }

    function _requireInputApproval(string memory json) private {
        string memory executionContext = vm.envString("B1N419_EXECUTION_CONTEXT");
        string memory approval = vm.parseJsonString(json, ".approval");
        string memory sourceCommit = vm.parseJsonString(json, ".environment.SOURCE_COMMIT");
        require(bytes(sourceCommit).length == 40, "B1N419: full approved source");
        require(
            keccak256(bytes(sourceCommit)) == keccak256(bytes(vm.envString("B1N419_SOURCE_COMMIT"))),
            "B1N419: source approval mismatch"
        );

        bool isBroadcast =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (keccak256(bytes(executionContext)) == keccak256("FORK_REHEARSAL")) {
            require(
                keccak256(bytes(approval)) == keccak256("APPROVED_BASE_SEPOLIA_DRY_RUN"), "B1N419: dry-run approval"
            );
            if (isBroadcast) {
                bytes memory anvilInfo = vm.rpc("anvil_nodeInfo", "[]");
                require(anvilInfo.length != 0, "B1N419: persistent rehearsal requires Anvil");
            }
        } else if (keccak256(bytes(executionContext)) == keccak256("BASE_SEPOLIA_LIVE")) {
            require(keccak256(bytes(approval)) == keccak256("APPROVED_BASE_SEPOLIA_LIVE"), "B1N419: live approval");
        } else {
            revert("B1N419: execution context");
        }
    }

    function _loadBoundManifest(DeployConfig memory config) internal view returns (string memory manifest) {
        manifest = vm.readFile(vm.envString("B1N419_MANIFEST_PATH"));
        require(sha256(bytes(manifest)) == vm.envBytes32("B1N419_MANIFEST_SHA256"), "B1N419: manifest digest");
        require(
            keccak256(bytes(vm.parseJsonString(manifest, ".sourceCommit"))) == keccak256(bytes(config.sourceCommit)),
            "B1N419: manifest source"
        );
        bytes32 deploymentId = vm.parseJsonBytes32(manifest, ".deploymentId");
        require(
            deploymentId != bytes32(0) && deploymentId == vm.envBytes32("B1N419_DEPLOYMENT_ID"), "B1N419: deployment id"
        );
    }

    function _loadFundConfig(string memory json, string memory root) private view returns (FundConfig memory config) {
        config.factoryOwner = vm.parseJsonAddress(json, string.concat(root, "FACTORY_OWNER"));
        config.implementationVersion = uint64(vm.parseJsonUint(json, string.concat(root, "IMPLEMENTATION_VERSION")));
        config.compatibilityVersion = uint64(vm.parseJsonUint(json, string.concat(root, "COMPATIBILITY_VERSION")));
        config.salt = vm.parseJsonBytes32(json, string.concat(root, "DEPLOYMENT_SALT"));
        config.name = vm.parseJsonString(json, string.concat(root, "FUND_NAME"));
        config.symbol = vm.parseJsonString(json, string.concat(root, "FUND_SYMBOL"));
        config.minimumIdleBps = uint16(vm.parseJsonUint(json, string.concat(root, "MINIMUM_IDLE_BPS")));
        config.navActivationDelay = uint64(vm.parseJsonUint(json, string.concat(root, "NAV_ACTIVATION_DELAY")));
        config.maxSnapshotAge = uint64(vm.parseJsonUint(json, string.concat(root, "MAX_SNAPSHOT_AGE")));
        config.maxNavWindowLength = uint64(vm.parseJsonUint(json, string.concat(root, "MAX_NAV_WINDOW_LENGTH")));
        config.feeRecipient = vm.parseJsonAddress(json, string.concat(root, "FEE_RECIPIENT"));
        config.roles = FundFactory.RoleAccounts({
            admin: vm.parseJsonAddress(json, string.concat(root, "ROLE_ADMIN")),
            upgrader: vm.parseJsonAddress(json, string.concat(root, "ROLE_UPGRADER")),
            accounting: vm.parseJsonAddress(json, string.concat(root, "ROLE_ACCOUNTING")),
            allocator: vm.parseJsonAddress(json, string.concat(root, "ROLE_ALLOCATOR")),
            processor: vm.parseJsonAddress(json, string.concat(root, "ROLE_PROCESSOR")),
            curator: vm.parseJsonAddress(json, string.concat(root, "ROLE_CURATOR")),
            guardian: vm.parseJsonAddress(json, string.concat(root, "ROLE_GUARDIAN"))
        });
    }

    function _loadWheelConfig(string memory json, string memory root) private view returns (WheelConfig memory config) {
        config.policyHash = vm.parseJsonBytes32(json, string.concat(root, "POLICY_HASH"));
        config.floorBufferUsd8 = vm.parseJsonUint(json, string.concat(root, "FLOOR_BUFFER_USD8"));
        config.cspLaneMaxAssets = vm.parseJsonUint(json, string.concat(root, "CSP_LANE_MAX_ASSETS"));
        config.coveredCallLaneMaxAssets = vm.parseJsonUint(json, string.concat(root, "CC_LANE_MAX_ASSETS"));
        config.transitionExitCostBps = uint16(vm.parseJsonUint(json, string.concat(root, "TRANSITION_EXIT_COST_BPS")));
        config.strategyMaxAllocationBps =
            uint16(vm.parseJsonUint(json, string.concat(root, "STRATEGY_MAX_ALLOCATION_BPS")));
        config.strategyMaxLossBps = uint16(vm.parseJsonUint(json, string.concat(root, "STRATEGY_MAX_LOSS_BPS")));
        config.strategyCooldown = uint32(vm.parseJsonUint(json, string.concat(root, "STRATEGY_COOLDOWN")));
        config.strategyAbsoluteCap = vm.parseJsonUint(json, string.concat(root, "STRATEGY_ABSOLUTE_CAP"));
    }

    function _loadFinalRoles(string memory json, string memory root)
        private
        view
        returns (FundFactory.RoleAccounts memory roles)
    {
        roles = FundFactory.RoleAccounts({
            admin: vm.parseJsonAddress(json, string.concat(root, "FINAL_ROLE_ADMIN")),
            upgrader: vm.parseJsonAddress(json, string.concat(root, "FINAL_ROLE_UPGRADER")),
            accounting: vm.parseJsonAddress(json, string.concat(root, "FINAL_ROLE_ACCOUNTING")),
            allocator: vm.parseJsonAddress(json, string.concat(root, "FINAL_ROLE_ALLOCATOR")),
            processor: vm.parseJsonAddress(json, string.concat(root, "FINAL_ROLE_PROCESSOR")),
            curator: vm.parseJsonAddress(json, string.concat(root, "FINAL_ROLE_CURATOR")),
            guardian: vm.parseJsonAddress(json, string.concat(root, "FINAL_ROLE_GUARDIAN"))
        });
    }

    function _loadValuationConfig(string memory json, string memory root)
        private
        view
        returns (ValuationConfig memory config)
    {
        config.spotFeed = vm.parseJsonAddress(json, string.concat(root, "SPOT_FEED"));
        config.spotFeedDecimals = uint8(vm.parseJsonUint(json, string.concat(root, "SPOT_FEED_DECIMALS")));
        config.maxSpotStaleness = uint64(vm.parseJsonUint(json, string.concat(root, "MAX_SPOT_STALENESS")));
        config.maxObservationWindow = uint64(vm.parseJsonUint(json, string.concat(root, "MAX_OBSERVATION_WINDOW")));
        config.observationQuorum = uint8(vm.parseJsonUint(json, string.concat(root, "OBSERVATION_QUORUM")));
        config.approvedObservers = vm.parseJsonAddressArray(json, string.concat(root, "APPROVED_OBSERVERS"));
        config.navReporters = vm.parseJsonAddressArray(json, string.concat(root, "NAV_REPORTERS"));
        config.navReporterThreshold = uint16(vm.parseJsonUint(json, string.concat(root, "NAV_REPORTER_THRESHOLD")));
    }

    function _loadCspRisk(string memory json, string memory root)
        private
        view
        returns (ICspFundAdapter.RiskConfig memory risk)
    {
        risk = ICspFundAdapter.RiskConfig({
            minExpiryDelay: uint64(vm.parseJsonUint(json, string.concat(root, "CSP_MIN_EXPIRY_DELAY"))),
            maxExpiryDelay: uint64(vm.parseJsonUint(json, string.concat(root, "CSP_MAX_EXPIRY_DELAY"))),
            settlementDefaultDelay: uint64(vm.parseJsonUint(json, string.concat(root, "CSP_SETTLEMENT_DEFAULT_DELAY"))),
            minPremiumBps: uint16(vm.parseJsonUint(json, string.concat(root, "CSP_MIN_PREMIUM_BPS"))),
            maxSwapSlippageBps: uint16(vm.parseJsonUint(json, string.concat(root, "CSP_MAX_SWAP_SLIPPAGE_BPS"))),
            maxOpenPositions: uint16(vm.parseJsonUint(json, string.concat(root, "CSP_MAX_OPEN_POSITIONS"))),
            minStrike: vm.parseJsonUint(json, string.concat(root, "CSP_MIN_STRIKE")),
            maxStrike: vm.parseJsonUint(json, string.concat(root, "CSP_MAX_STRIKE")),
            maxCollateralPerPosition: vm.parseJsonUint(json, string.concat(root, "CSP_MAX_COLLATERAL_PER_POSITION")),
            maxWethPerSwap: vm.parseJsonUint(json, string.concat(root, "CSP_MAX_WETH_PER_SWAP"))
        });
    }

    function _loadCoveredCallRisk(string memory json, string memory root)
        private
        view
        returns (ICoveredCallFundAdapter.RiskConfig memory risk)
    {
        risk = ICoveredCallFundAdapter.RiskConfig({
            minExpiryDelay: uint64(vm.parseJsonUint(json, string.concat(root, "CC_MIN_EXPIRY_DELAY"))),
            maxExpiryDelay: uint64(vm.parseJsonUint(json, string.concat(root, "CC_MAX_EXPIRY_DELAY"))),
            settlementDefaultDelay: uint64(vm.parseJsonUint(json, string.concat(root, "CC_SETTLEMENT_DEFAULT_DELAY"))),
            minPremiumBps: uint16(vm.parseJsonUint(json, string.concat(root, "CC_MIN_PREMIUM_BPS"))),
            maxSwapSlippageBps: uint16(vm.parseJsonUint(json, string.concat(root, "CC_MAX_SWAP_SLIPPAGE_BPS"))),
            maxOpenPositions: uint16(vm.parseJsonUint(json, string.concat(root, "CC_MAX_OPEN_POSITIONS"))),
            maxUtilizationBps: uint16(vm.parseJsonUint(json, string.concat(root, "CC_MAX_UTILIZATION_BPS"))),
            minStrike: vm.parseJsonUint(json, string.concat(root, "CC_MIN_STRIKE")),
            maxStrike: vm.parseJsonUint(json, string.concat(root, "CC_MAX_STRIKE")),
            maxCollateralPerPosition: vm.parseJsonUint(json, string.concat(root, "CC_MAX_COLLATERAL_PER_POSITION")),
            maxUsdcPerSwap: vm.parseJsonUint(json, string.concat(root, "CC_MAX_USDC_PER_SWAP"))
        });
    }

    function _loadStandaloneBaseline(string memory json, string memory root)
        private
        view
        returns (StandaloneBaseline memory baseline)
    {
        baseline.cspVaultProxy = vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CSP_VAULT_PROXY"));
        baseline.cspVaultImplementation =
            vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CSP_VAULT_IMPLEMENTATION"));
        baseline.cspVaultImplementationCodehash =
            vm.parseJsonBytes32(json, string.concat(root, "STANDALONE_CSP_VAULT_IMPLEMENTATION_CODEHASH"));
        baseline.cspAdapterProxy = vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CSP_ADAPTER_PROXY"));
        baseline.cspAdapterImplementation =
            vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CSP_ADAPTER_IMPLEMENTATION"));
        baseline.cspAdapterImplementationCodehash =
            vm.parseJsonBytes32(json, string.concat(root, "STANDALONE_CSP_ADAPTER_IMPLEMENTATION_CODEHASH"));
        baseline.coveredCallVaultProxy = vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CC_VAULT_PROXY"));
        baseline.coveredCallVaultImplementation =
            vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CC_VAULT_IMPLEMENTATION"));
        baseline.coveredCallVaultImplementationCodehash =
            vm.parseJsonBytes32(json, string.concat(root, "STANDALONE_CC_VAULT_IMPLEMENTATION_CODEHASH"));
        baseline.coveredCallAdapterProxy = vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CC_ADAPTER_PROXY"));
        baseline.coveredCallAdapterImplementation =
            vm.parseJsonAddress(json, string.concat(root, "STANDALONE_CC_ADAPTER_IMPLEMENTATION"));
        baseline.coveredCallAdapterImplementationCodehash =
            vm.parseJsonBytes32(json, string.concat(root, "STANDALONE_CC_ADAPTER_IMPLEMENTATION_CODEHASH"));
    }

    function _writeManifest(DeployConfig memory config, DeploymentAddresses memory deployed, string memory path)
        internal
    {
        string memory object = "b1n419";
        vm.serializeString(object, "schemaVersion", "1.0.0");
        vm.serializeString(object, "issue", "B1N-419");
        vm.serializeString(object, "status", "UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS");
        vm.serializeString(object, "deploymentStatus", "UNCONFIRMED");
        vm.serializeBool(object, "handoffReady", false);
        vm.serializeString(object, "sourceCommit", config.sourceCommit);
        vm.serializeBytes32(object, "deploymentId", deployed.deploymentId);
        vm.serializeAddress(object, "linkedLibraries", config.linkedLibraries);
        vm.serializeBytes32(object, "linkedLibraryCodehashes", config.linkedLibraryCodehashes);

        // Operational fields are retained for the read-only reconciliation scripts. Backend ingestion uses the
        // nested handoff contract documented in B1N419_META_WHEEL_MANIFEST_HANDOFF.md.
        vm.serializeAddress(object, "factory", deployed.factory);
        vm.serializeAddress(object, "accessManagerDeployer", deployed.accessManagerDeployer);
        vm.serializeAddress(object, "accessManager", deployed.accessManager);
        vm.serializeAddress(object, "vault", deployed.vault);
        vm.serializeAddress(object, "share", deployed.share);
        vm.serializeAddress(object, "accounting", deployed.accounting);
        vm.serializeAddress(object, "flow", deployed.flow);
        vm.serializeAddress(object, "strategy", deployed.strategy);
        vm.serializeAddress(object, "claimEscrow", deployed.claimEscrow);
        vm.serializeAddress(object, "navVerifier", deployed.navVerifier);
        vm.serializeAddress(object, "inKindEscrow", deployed.inKindEscrow);
        vm.serializeAddress(object, "emergencyEscrow", deployed.emergencyEscrow);
        vm.serializeAddress(object, "coordinator", deployed.coordinator);
        vm.serializeAddress(object, "metaWheelValuator", deployed.metaWheelValuator);
        vm.serializeAddress(object, "cspValuator", deployed.cspValuator);
        vm.serializeAddress(object, "coveredCallValuator", deployed.coveredCallValuator);
        vm.serializeAddress(object, "vaultImplementation", deployed.vaultImplementation);
        vm.serializeAddress(object, "shareImplementation", deployed.shareImplementation);
        vm.serializeAddress(object, "accountingImplementation", deployed.accountingImplementation);
        vm.serializeAddress(object, "flowImplementation", deployed.flowImplementation);
        vm.serializeAddress(object, "strategyImplementation", deployed.strategyImplementation);
        vm.serializeAddress(object, "coordinatorImplementation", deployed.coordinatorImplementation);
        vm.serializeAddress(object, "cspAdapterImplementation", deployed.cspAdapterImplementation);
        vm.serializeAddress(object, "cspLaneImplementation", deployed.cspLaneImplementation);
        vm.serializeAddress(object, "coveredCallAdapterImplementation", deployed.coveredCallAdapterImplementation);
        vm.serializeAddress(object, "coveredCallLaneImplementation", deployed.coveredCallLaneImplementation);
        vm.serializeBytes32(object, "factoryCodehash", deployed.factory.codehash);
        vm.serializeBytes32(object, "accessManagerDeployerCodehash", deployed.accessManagerDeployer.codehash);
        vm.serializeBytes32(object, "vaultProxyCodehash", deployed.vault.codehash);
        vm.serializeBytes32(object, "shareProxyCodehash", deployed.share.codehash);
        vm.serializeBytes32(object, "accountingProxyCodehash", deployed.accounting.codehash);
        vm.serializeBytes32(object, "flowProxyCodehash", deployed.flow.codehash);
        vm.serializeBytes32(object, "strategyProxyCodehash", deployed.strategy.codehash);
        vm.serializeBytes32(object, "coordinatorProxyCodehash", deployed.coordinator.codehash);
        vm.serializeBytes32(object, "vaultImplementationCodehash", deployed.vaultImplementation.codehash);
        vm.serializeBytes32(object, "shareImplementationCodehash", deployed.shareImplementation.codehash);
        vm.serializeBytes32(object, "accountingImplementationCodehash", deployed.accountingImplementation.codehash);
        vm.serializeBytes32(object, "flowImplementationCodehash", deployed.flowImplementation.codehash);
        vm.serializeBytes32(object, "strategyImplementationCodehash", deployed.strategyImplementation.codehash);
        vm.serializeBytes32(object, "coordinatorImplementationCodehash", deployed.coordinatorImplementation.codehash);
        vm.serializeBytes32(object, "cspAdapterImplementationCodehash", deployed.cspAdapterImplementation.codehash);
        vm.serializeBytes32(object, "cspLaneImplementationCodehash", deployed.cspLaneImplementation.codehash);
        vm.serializeBytes32(
            object, "coveredCallAdapterImplementationCodehash", deployed.coveredCallAdapterImplementation.codehash
        );
        vm.serializeBytes32(
            object, "coveredCallLaneImplementationCodehash", deployed.coveredCallLaneImplementation.codehash
        );
        vm.serializeAddress(object, "cspLanes", _dynamic(deployed.cspLanes));
        vm.serializeBytes32(object, "cspLaneCodehashes", _codehashes(deployed.cspLanes));
        vm.serializeAddress(object, "cspAdapters", _dynamic(deployed.cspAdapters));
        vm.serializeBytes32(object, "cspAdapterCodehashes", _codehashes(deployed.cspAdapters));
        vm.serializeAddress(object, "coveredCallLanes", _dynamic(deployed.coveredCallLanes));
        vm.serializeBytes32(object, "coveredCallLaneCodehashes", _codehashes(deployed.coveredCallLanes));
        vm.serializeAddress(object, "coveredCallAdapters", _dynamic(deployed.coveredCallAdapters));
        vm.serializeBytes32(object, "coveredCallAdapterCodehashes", _codehashes(deployed.coveredCallAdapters));
        vm.serializeBytes32(object, "cspValuatorCodehash", deployed.cspValuator.codehash);
        string memory json =
            vm.serializeBytes32(object, "coveredCallValuatorCodehash", deployed.coveredCallValuator.codehash);
        vm.writeJson(json, path);

        vm.writeJson(_networkManifest(), path, ".network");
        vm.writeJson('{"fundFirst":0,"fundLast":0}', path, ".network.deploymentBlocks");
        vm.writeJson("[]", path, ".canonicalReceipts");
        vm.writeJson(_assetsManifest(config), path, ".assets");
        vm.writeJson("{}", path, ".contracts");
        _writeContractManifest(deployed, path);
        vm.writeJson(_finalRolesManifest(config), path, ".finalRoles");
        vm.writeJson(_policyManifest(config), path, ".policy");
        vm.writeJson("{}", path, ".v1Boundary");
        _writeV1BoundaryManifest(config, path);
        vm.writeJson("{}", path, ".standaloneBaselines");
        _writeStandaloneManifest(config, path);
        vm.writeJson(_readinessManifest(), path, ".readiness");
    }

    function _dynamic(address[4] memory fixedAddresses) private pure returns (address[] memory values) {
        values = new address[](4);
        for (uint256 i; i < values.length; ++i) {
            values[i] = fixedAddresses[i];
        }
    }

    function _codehashes(address[4] memory addresses) private view returns (bytes32[] memory values) {
        values = new bytes32[](addresses.length);
        for (uint256 i; i < values.length; ++i) {
            values[i] = addresses[i].codehash;
        }
    }

    function _networkManifest() private returns (string memory json) {
        string memory object = "b1n419_network";
        vm.serializeString(object, "name", "base-sepolia");
        json = vm.serializeUint(object, "chainId", BASE_SEPOLIA_CHAIN_ID);
    }

    function _assetsManifest(DeployConfig memory config) private returns (string memory json) {
        string memory object = "b1n419_assets";
        vm.serializeAddress(object, "usdc", config.assets.usdc);
        vm.serializeAddress(object, "weth", config.assets.weth);
        json = vm.serializeAddress(object, "swapRouter", config.assets.swapRouter);
    }

    function _finalRolesManifest(DeployConfig memory config) private returns (string memory json) {
        string memory object = "b1n419_final_roles";
        vm.serializeAddress(object, "admin", config.finalRoles.admin);
        vm.serializeAddress(object, "upgrader", config.finalRoles.upgrader);
        vm.serializeAddress(object, "accounting", config.finalRoles.accounting);
        vm.serializeAddress(object, "allocator", config.finalRoles.allocator);
        vm.serializeAddress(object, "processor", config.finalRoles.processor);
        vm.serializeAddress(object, "curator", config.finalRoles.curator);
        json = vm.serializeAddress(object, "guardian", config.finalRoles.guardian);
    }

    function _policyManifest(DeployConfig memory config) private returns (string memory json) {
        string memory object = "b1n419_policy";
        vm.serializeBytes32(object, "policyHash", config.wheel.policyHash);
        vm.serializeUint(object, "managementFeeWad", MANAGEMENT_FEE_WAD);
        vm.serializeUint(object, "performanceFeeBps", PERFORMANCE_FEE_BPS);
        json = vm.serializeUint(object, "premiumFeeBps", PREMIUM_FEE_BPS);
    }

    function _writeContractManifest(DeploymentAddresses memory deployed, string memory path) private {
        vm.writeJson(_proxyContract(deployed.vault, deployed.vaultImplementation), path, ".contracts.fundVault");
        vm.writeJson(_proxyContract(deployed.share, deployed.shareImplementation), path, ".contracts.fundShare");
        vm.writeJson(
            _proxyContract(deployed.accounting, deployed.accountingImplementation), path, ".contracts.fundAccounting"
        );
        vm.writeJson(_proxyContract(deployed.flow, deployed.flowImplementation), path, ".contracts.fundFlowManager");
        vm.writeJson(
            _proxyContract(deployed.strategy, deployed.strategyImplementation), path, ".contracts.strategyManager"
        );
        vm.writeJson(
            _proxyContract(deployed.coordinator, deployed.coordinatorImplementation),
            path,
            ".contracts.wheelCoordinator"
        );
        vm.writeJson(_immutableContract(deployed.claimEscrow), path, ".contracts.claimEscrow");
        vm.writeJson(_immutableContract(deployed.accessManager), path, ".contracts.accessManager");
        vm.writeJson(_immutableContract(deployed.metaWheelValuator), path, ".contracts.metaWheelValuator");
        vm.writeJson(_immutableContract(deployed.navVerifier), path, ".contracts.navReportVerifier");
    }

    function _proxyContract(address proxy, address implementation) private returns (string memory json) {
        string memory object = string.concat("b1n419_proxy_", vm.toString(proxy));
        vm.serializeAddress(object, "proxy", proxy);
        vm.serializeAddress(object, "implementation", implementation);
        vm.serializeUint(object, "validFromBlock", 0);
        vm.serializeUint(object, "implementationValidFromBlock", 0);
        json = vm.serializeBytes32(object, "implementationCodehash", implementation.codehash);
    }

    function _immutableContract(address deployed) private returns (string memory json) {
        string memory object = string.concat("b1n419_immutable_", vm.toString(deployed));
        vm.serializeAddress(object, "address", deployed);
        vm.serializeUint(object, "validFromBlock", 0);
        json = vm.serializeBytes32(object, "codehash", deployed.codehash);
    }

    function _writeV1BoundaryManifest(DeployConfig memory config, string memory path) private {
        vm.writeJson(_v1Proxy(config.assets.controller), path, ".v1Boundary.controller");
        vm.writeJson(_v1Proxy(config.assets.batchSettler), path, ".v1Boundary.batchSettler");
        vm.writeJson(_v1Address(config.assets.addressBook), path, ".v1Boundary.addressBook");
        vm.writeJson(_v1Address(config.assets.marginPool), path, ".v1Boundary.marginPool");
        vm.writeJson(_v1Address(config.assets.oracle), path, ".v1Boundary.oracle");
        vm.writeJson(_v1Address(config.assets.oTokenFactory), path, ".v1Boundary.oTokenFactory");
        vm.writeJson(_v1Address(config.assets.whitelist), path, ".v1Boundary.whitelist");
    }

    function _v1Proxy(address proxy) private returns (string memory json) {
        string memory object = string.concat("b1n419_v1_proxy_", vm.toString(proxy));
        vm.serializeAddress(object, "proxy", proxy);
        vm.serializeAddress(object, "implementation", _implementationOf(proxy));
        json = vm.serializeBool(object, "unchanged", true);
    }

    function _v1Address(address proxy) private returns (string memory json) {
        string memory object = string.concat("b1n419_v1_address_", vm.toString(proxy));
        vm.serializeAddress(object, "proxy", proxy);
        json = vm.serializeBool(object, "unchanged", true);
    }

    function _writeStandaloneManifest(DeployConfig memory config, string memory path) private {
        vm.writeJson(
            _standaloneContract(
                config.standalone.cspVaultProxy,
                config.standalone.cspVaultImplementation,
                config.standalone.cspVaultImplementationCodehash
            ),
            path,
            ".standaloneBaselines.cspVault"
        );
        vm.writeJson(
            _standaloneContract(
                config.standalone.cspAdapterProxy,
                config.standalone.cspAdapterImplementation,
                config.standalone.cspAdapterImplementationCodehash
            ),
            path,
            ".standaloneBaselines.cspAdapter"
        );
        vm.writeJson(
            _standaloneContract(
                config.standalone.coveredCallVaultProxy,
                config.standalone.coveredCallVaultImplementation,
                config.standalone.coveredCallVaultImplementationCodehash
            ),
            path,
            ".standaloneBaselines.coveredCallVault"
        );
        vm.writeJson(
            _standaloneContract(
                config.standalone.coveredCallAdapterProxy,
                config.standalone.coveredCallAdapterImplementation,
                config.standalone.coveredCallAdapterImplementationCodehash
            ),
            path,
            ".standaloneBaselines.coveredCallAdapter"
        );
    }

    function _standaloneContract(address proxy, address implementation, bytes32 implementationCodehash)
        private
        returns (string memory json)
    {
        string memory object = string.concat("b1n419_standalone_", vm.toString(proxy));
        vm.serializeAddress(object, "proxy", proxy);
        vm.serializeAddress(object, "implementation", implementation);
        vm.serializeBytes32(object, "implementationCodehash", implementationCodehash);
        json = vm.serializeBool(object, "unchanged", true);
    }

    function _readinessManifest() private returns (string memory json) {
        string memory object = "b1n419_readiness";
        vm.serializeBool(object, "canonicalReceiptsRecorded", false);
        vm.serializeBool(object, "blockscoutVerificationComplete", false);
        vm.serializeBool(object, "bootstrapReconciled", false);
        vm.serializeBool(object, "finalRolesReconciled", false);
        vm.serializeBool(object, "standaloneBaselinesUnchanged", false);
        vm.serializeBool(object, "backendHandoffReady", false);
        json = vm.serializeBool(object, "mainnetAuthorized", false);
    }

    function _logDeployment(DeploymentAddresses memory deployed) private view {
        console2.log("B1N419_DEPLOYMENT_ID");
        console2.logBytes32(deployed.deploymentId);
        console2.log("B1N419_FUND_VAULT", deployed.vault);
        console2.log("B1N419_ACCESS_MANAGER", deployed.accessManager);
        console2.log("B1N419_COORDINATOR", deployed.coordinator);
        console2.log("B1N419_META_WHEEL_VALUATOR", deployed.metaWheelValuator);
        console2.log("B1N419_STATUS", "PAUSED_UNCONFIGURED_UNONBOARDED");
    }
}
