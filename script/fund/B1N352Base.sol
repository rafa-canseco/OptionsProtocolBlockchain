// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {Whitelist} from "../../src/core/Whitelist.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";

abstract contract B1N352Base is Script {
    using SafeCast for uint256;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant IN_KIND_ESCROW_PURPOSE = keccak256("B1NARY_STRATEGY_IN_KIND_ESCROW");
    bytes32 internal constant EMERGENCY_ESCROW_PURPOSE = keccak256("B1NARY_STRATEGY_EMERGENCY_ESCROW");

    struct DeployConfig {
        address factoryOwner;
        address addressBook;
        address accountingAsset;
        address weth;
        address adapterSwapRouter;
        uint24 adapterSwapFeeTier;
        uint64 implementationVersion;
        uint64 compatibilityVersion;
        bytes32 fundSalt;
        string fundName;
        string fundSymbol;
        uint16 minimumIdleBps;
        uint64 navActivationDelay;
        uint64 maxSnapshotAge;
        uint64 maxNavWindowLength;
        FundTypes.FeeConfig feeConfig;
        FundFactory.RoleAccounts roles;
        ICspFundAdapter.RiskConfig adapterRiskConfig;
        address spotFeed;
        uint8 spotFeedDecimals;
        uint64 maxSpotStaleness;
        uint64 maxObservationWindow;
        uint8 observationQuorum;
        uint16 liabilityBufferBps;
        address[] approvedObservers;
    }

    struct DeploymentAddresses {
        address fundFactory;
        address fundAccessManagerDeployer;
        bytes32 deploymentId;
        address fundVaultImplementation;
        address fundShareImplementation;
        address fundAccountingImplementation;
        address fundFlowManagerImplementation;
        address strategyManagerImplementation;
        address navReportVerifier;
        address fundVaultProxy;
        address fundShareProxy;
        address fundAccountingProxy;
        address fundFlowManagerProxy;
        address strategyManagerProxy;
        address claimEscrow;
        address accessManager;
        address cspAdapterOperations;
        address cspFundAdapterImplementation;
        address cspFundAdapterProxy;
        address cspFundValuator;
        address inKindStrategyEscrow;
        address emergencyStrategyEscrow;
    }

    function _requireBaseSepolia() internal view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "B1N352: wrong chain");
    }

    function _loadDeployConfig() internal view returns (DeployConfig memory config) {
        config.factoryOwner = vm.envAddress("FUND_FACTORY_OWNER");
        config.addressBook = vm.envAddress("FUND_V1_ADDRESS_BOOK");
        config.accountingAsset = vm.envAddress("FUND_ACCOUNTING_ASSET");
        config.weth = vm.envAddress("FUND_WETH");
        config.adapterSwapRouter = vm.envAddress("FUND_ADAPTER_SWAP_ROUTER");
        config.adapterSwapFeeTier = _envUint24("FUND_ADAPTER_SWAP_FEE_TIER");
        config.implementationVersion = _envUint64("FUND_IMPLEMENTATION_VERSION");
        config.compatibilityVersion = _envUint64("FUND_COMPATIBILITY_VERSION");
        config.fundSalt = vm.envBytes32("FUND_DEPLOYMENT_SALT");
        config.fundName = vm.envString("FUND_NAME");
        config.fundSymbol = vm.envString("FUND_SYMBOL");
        config.minimumIdleBps = _envUint16("FUND_MINIMUM_IDLE_BPS");
        config.navActivationDelay = _envUint64("FUND_NAV_ACTIVATION_DELAY_BLOCKS");
        config.maxSnapshotAge = _envUint64("FUND_MAX_SNAPSHOT_AGE_BLOCKS");
        config.maxNavWindowLength = _envUint64("FUND_MAX_NAV_WINDOW_LENGTH_BLOCKS");
        config.feeConfig = FundTypes.FeeConfig({
            managementFeeWad: _envUint64("FUND_MANAGEMENT_FEE_WAD"),
            performanceFeeBps: _envUint16("FUND_PERFORMANCE_FEE_BPS"),
            maxManagementFeeBps: _envUint16("FUND_MAX_MANAGEMENT_FEE_BPS"),
            maxPerformanceFeeBps: _envUint16("FUND_MAX_PERFORMANCE_FEE_BPS"),
            maxAccrualInterval: _envUint32("FUND_MAX_ACCRUAL_INTERVAL_SECONDS"),
            crystallizationPeriod: _envUint32("FUND_CRYSTALLIZATION_PERIOD_SECONDS"),
            feeRecipient: vm.envAddress("FUND_FEE_RECIPIENT")
        });
        config.roles = FundFactory.RoleAccounts({
            admin: vm.envAddress("FUND_ADMIN"),
            upgrader: vm.envAddress("FUND_UPGRADER"),
            accounting: vm.envAddress("FUND_ACCOUNTING_OPERATOR"),
            allocator: vm.envAddress("FUND_ALLOCATOR"),
            processor: vm.envAddress("FUND_PROCESSOR"),
            curator: vm.envAddress("FUND_CURATOR"),
            guardian: vm.envAddress("FUND_GUARDIAN")
        });
        config.adapterRiskConfig = ICspFundAdapter.RiskConfig({
            minExpiryDelay: _envUint64("FUND_CSP_MIN_EXPIRY_DELAY_SECONDS"),
            maxExpiryDelay: _envUint64("FUND_CSP_MAX_EXPIRY_DELAY_SECONDS"),
            settlementDefaultDelay: _envUint64("FUND_CSP_SETTLEMENT_DEFAULT_DELAY_SECONDS"),
            minPremiumBps: _envUint16("FUND_CSP_MIN_PREMIUM_BPS"),
            maxSwapSlippageBps: _envUint16("FUND_CSP_MAX_SWAP_SLIPPAGE_BPS"),
            maxOpenPositions: _envUint16("FUND_CSP_MAX_OPEN_POSITIONS"),
            minStrike: vm.envUint("FUND_CSP_MIN_STRIKE"),
            maxStrike: vm.envUint("FUND_CSP_MAX_STRIKE"),
            maxCollateralPerPosition: vm.envUint("FUND_CSP_MAX_COLLATERAL_PER_POSITION"),
            maxWethPerSwap: vm.envUint("FUND_CSP_MAX_WETH_PER_SWAP")
        });
        config.spotFeed = vm.envAddress("FUND_CSP_SPOT_FEED");
        config.spotFeedDecimals = _envUint8("FUND_CSP_SPOT_FEED_DECIMALS");
        config.maxSpotStaleness = _envUint64("FUND_CSP_MAX_SPOT_STALENESS_SECONDS");
        config.maxObservationWindow = _envUint64("FUND_CSP_MAX_OBSERVATION_WINDOW_BLOCKS");
        config.observationQuorum = _envUint8("FUND_CSP_OBSERVATION_QUORUM");
        config.liabilityBufferBps = _envUint16("FUND_CSP_LIABILITY_BUFFER_BPS");
        config.approvedObservers = vm.envAddress("FUND_CSP_APPROVED_OBSERVERS", ",");
    }

    function _validateExternalConfig(DeployConfig memory config) internal view {
        require(config.factoryOwner != address(0), "B1N352: factory owner");
        require(config.implementationVersion != 0 && config.compatibilityVersion != 0, "B1N352: version");
        require(config.fundSalt != bytes32(0), "B1N352: salt");
        require(bytes(config.fundName).length != 0 && bytes(config.fundSymbol).length != 0, "B1N352: metadata");
        require(config.accountingAsset.code.length != 0 && config.weth.code.length != 0, "B1N352: tokens");
        require(config.adapterSwapRouter.code.length != 0, "B1N352: adapter router");
        require(config.spotFeed.code.length != 0, "B1N352: spot feed");
        require(IERC20Metadata(config.accountingAsset).decimals() == 6, "B1N352: accounting decimals");
        require(IERC20Metadata(config.weth).decimals() == 18, "B1N352: WETH decimals");
        require(config.approvedObservers.length >= 2, "B1N352: observers");
        _validateV1(config.addressBook, config.accountingAsset, config.weth);
    }

    function _validateV1(address addressBook_, address accountingAsset, address weth) internal view {
        require(addressBook_.code.length != 0, "B1N352: address book");
        AddressBook book = AddressBook(addressBook_);
        address controller = book.controller();
        address settler = book.batchSettler();
        address pool = book.marginPool();
        address oTokenFactory = book.oTokenFactory();
        address oracle = book.oracle();
        address whitelist = book.whitelist();
        require(
            controller.code.length != 0 && settler.code.length != 0 && pool.code.length != 0
                && oTokenFactory.code.length != 0 && oracle.code.length != 0 && whitelist.code.length != 0,
            "B1N352: V1 code"
        );
        require(_returnsAddress(controller, "addressBook()") == addressBook_, "B1N352: controller wiring");
        require(_returnsAddress(settler, "addressBook()") == addressBook_, "B1N352: settler wiring");
        require(_returnsAddress(pool, "addressBook()") == addressBook_, "B1N352: pool wiring");
        require(_returnsAddress(oTokenFactory, "addressBook()") == addressBook_, "B1N352: factory wiring");
        require(_returnsAddress(oracle, "addressBook()") == addressBook_, "B1N352: oracle wiring");
        require(_returnsAddress(whitelist, "addressBook()") == addressBook_, "B1N352: whitelist wiring");
        require(_returnsBool(controller, "custodiedRedemptionOnly()"), "B1N352: custodial-only disabled");
        require(BatchSettler(settler).swapRouter().code.length != 0, "B1N352: settler router");
        require(
            BatchSettler(settler).swapFeeTier() != 0 || BatchSettler(settler).assetSwapFeeTier(weth) != 0,
            "B1N352: settler fee tier"
        );
        require(Oracle(oracle).priceFeed(weth).code.length != 0, "B1N352: WETH feed");
        require(Whitelist(whitelist).isWhitelistedUnderlying(weth), "B1N352: WETH underlying");
        require(Whitelist(whitelist).isWhitelistedCollateral(accountingAsset), "B1N352: USDC collateral");
        require(
            Whitelist(whitelist).isProductWhitelisted(weth, accountingAsset, accountingAsset, true),
            "B1N352: put product"
        );
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _requireExpectedV1Baseline(address addressBook_) internal view {
        require(addressBook_ == vm.envAddress("FUND_EXPECTED_V1_ADDRESS_BOOK"), "B1N352: address book baseline");
        AddressBook book = AddressBook(addressBook_);
        address controllerProxy = book.controller();
        address settlerProxy = book.batchSettler();
        require(controllerProxy == vm.envAddress("FUND_EXPECTED_V1_CONTROLLER_PROXY"), "B1N352: controller proxy");
        require(settlerProxy == vm.envAddress("FUND_EXPECTED_V1_BATCH_SETTLER_PROXY"), "B1N352: settler proxy");
        address controllerImplementation = _implementationOf(controllerProxy);
        address settlerImplementation = _implementationOf(settlerProxy);
        require(
            controllerImplementation == vm.envAddress("FUND_EXPECTED_V1_CONTROLLER_IMPLEMENTATION"),
            "B1N352: controller implementation"
        );
        require(
            controllerImplementation.codehash == vm.envBytes32("FUND_EXPECTED_V1_CONTROLLER_CODEHASH"),
            "B1N352: controller codehash"
        );
        require(
            settlerImplementation == vm.envAddress("FUND_EXPECTED_V1_BATCH_SETTLER_IMPLEMENTATION"),
            "B1N352: settler implementation"
        );
        require(
            settlerImplementation.codehash == vm.envBytes32("FUND_EXPECTED_V1_BATCH_SETTLER_CODEHASH"),
            "B1N352: settler codehash"
        );
    }

    function _logV1Baseline(address addressBook_) internal view {
        AddressBook book = AddressBook(addressBook_);
        address controllerImplementation = _implementationOf(book.controller());
        address settlerImplementation = _implementationOf(book.batchSettler());
        console2.log("V1_CONTROLLER_PROXY", book.controller());
        console2.log("V1_CONTROLLER_IMPLEMENTATION", controllerImplementation);
        console2.log("V1_CONTROLLER_IMPLEMENTATION_CODEHASH");
        console2.logBytes32(controllerImplementation.codehash);
        console2.log("V1_BATCH_SETTLER_PROXY", book.batchSettler());
        console2.log("V1_BATCH_SETTLER_IMPLEMENTATION", settlerImplementation);
        console2.log("V1_BATCH_SETTLER_IMPLEMENTATION_CODEHASH");
        console2.logBytes32(settlerImplementation.codehash);
    }

    function _returnsAddress(address target, string memory signature) private view returns (address value) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && result.length >= 32, "B1N352: address read");
        value = abi.decode(result, (address));
    }

    function _returnsBool(address target, string memory signature) private view returns (bool value) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && result.length >= 32, "B1N352: bool read");
        value = abi.decode(result, (bool));
    }

    function _envUint8(string memory key) internal view returns (uint8) {
        return vm.envUint(key).toUint8();
    }

    function _envUint16(string memory key) internal view returns (uint16) {
        return vm.envUint(key).toUint16();
    }

    function _envUint24(string memory key) internal view returns (uint24) {
        return vm.envUint(key).toUint24();
    }

    function _envUint32(string memory key) internal view returns (uint32) {
        return vm.envUint(key).toUint32();
    }

    function _envUint64(string memory key) internal view returns (uint64) {
        return vm.envUint(key).toUint64();
    }
}
