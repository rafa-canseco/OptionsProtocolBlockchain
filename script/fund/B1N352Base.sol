// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
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
        _requireApprovedInputsDigest();
    }

    function _requireApprovedInputsDigest() internal view {
        string memory approvedInputs = _approvedInputs();
        require(
            sha256(bytes(approvedInputs)) == vm.envBytes32("FUND_APPROVED_INPUTS_SHA256"),
            "B1N352: approved inputs digest"
        );
    }

    function _loadDeployConfig() internal view returns (DeployConfig memory config) {
        config.factoryOwner = _approvedAddress("FUND_FACTORY_OWNER");
        config.addressBook = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        config.accountingAsset = _approvedAddress("FUND_ACCOUNTING_ASSET");
        config.weth = _approvedAddress("FUND_WETH");
        config.adapterSwapRouter = _approvedAddress("FUND_ADAPTER_SWAP_ROUTER");
        config.adapterSwapFeeTier = _approvedUint24("FUND_ADAPTER_SWAP_FEE_TIER");
        config.implementationVersion = _approvedUint64("FUND_IMPLEMENTATION_VERSION");
        config.compatibilityVersion = _approvedUint64("FUND_COMPATIBILITY_VERSION");
        config.fundSalt = _approvedBytes32("FUND_DEPLOYMENT_SALT");
        config.fundName = _approvedString("FUND_NAME");
        config.fundSymbol = _approvedString("FUND_SYMBOL");
        config.minimumIdleBps = _approvedUint16("FUND_MINIMUM_IDLE_BPS");
        config.navActivationDelay = _approvedUint64("FUND_NAV_ACTIVATION_DELAY_BLOCKS");
        config.maxSnapshotAge = _approvedUint64("FUND_MAX_SNAPSHOT_AGE_BLOCKS");
        config.maxNavWindowLength = _approvedUint64("FUND_MAX_NAV_WINDOW_LENGTH_BLOCKS");
        config.feeConfig = FundTypes.FeeConfig({
            managementFeeWad: _approvedUint64("FUND_MANAGEMENT_FEE_WAD"),
            performanceFeeBps: _approvedUint16("FUND_PERFORMANCE_FEE_BPS"),
            maxManagementFeeBps: _approvedUint16("FUND_MAX_MANAGEMENT_FEE_BPS"),
            maxPerformanceFeeBps: _approvedUint16("FUND_MAX_PERFORMANCE_FEE_BPS"),
            maxAccrualInterval: _approvedUint32("FUND_MAX_ACCRUAL_INTERVAL_SECONDS"),
            crystallizationPeriod: _approvedUint32("FUND_CRYSTALLIZATION_PERIOD_SECONDS"),
            feeRecipient: _approvedAddress("FUND_FEE_RECIPIENT")
        });
        config.roles = FundFactory.RoleAccounts({
            admin: _approvedAddress("FUND_ADMIN"),
            upgrader: _approvedAddress("FUND_UPGRADER"),
            accounting: _approvedAddress("FUND_ACCOUNTING_OPERATOR"),
            allocator: _approvedAddress("FUND_ALLOCATOR"),
            processor: _approvedAddress("FUND_PROCESSOR"),
            curator: _approvedAddress("FUND_CURATOR"),
            guardian: _approvedAddress("FUND_GUARDIAN")
        });
        config.adapterRiskConfig = ICspFundAdapter.RiskConfig({
            minExpiryDelay: _approvedUint64("FUND_CSP_MIN_EXPIRY_DELAY_SECONDS"),
            maxExpiryDelay: _approvedUint64("FUND_CSP_MAX_EXPIRY_DELAY_SECONDS"),
            settlementDefaultDelay: _approvedUint64("FUND_CSP_SETTLEMENT_DEFAULT_DELAY_SECONDS"),
            minPremiumBps: _approvedUint16("FUND_CSP_MIN_PREMIUM_BPS"),
            maxSwapSlippageBps: _approvedUint16("FUND_CSP_MAX_SWAP_SLIPPAGE_BPS"),
            maxOpenPositions: _approvedUint16("FUND_CSP_MAX_OPEN_POSITIONS"),
            minStrike: _approvedUint("FUND_CSP_MIN_STRIKE"),
            maxStrike: _approvedUint("FUND_CSP_MAX_STRIKE"),
            maxCollateralPerPosition: _approvedUint("FUND_CSP_MAX_COLLATERAL_PER_POSITION"),
            maxWethPerSwap: _approvedUint("FUND_CSP_MAX_WETH_PER_SWAP")
        });
        config.spotFeed = _approvedAddress("FUND_CSP_SPOT_FEED");
        config.spotFeedDecimals = _approvedUint8("FUND_CSP_SPOT_FEED_DECIMALS");
        config.maxSpotStaleness = _approvedUint64("FUND_CSP_MAX_SPOT_STALENESS_SECONDS");
        config.maxObservationWindow = _approvedUint64("FUND_CSP_MAX_OBSERVATION_WINDOW_BLOCKS");
        config.observationQuorum = _approvedUint8("FUND_CSP_OBSERVATION_QUORUM");
        config.liabilityBufferBps = _approvedUint16("FUND_CSP_LIABILITY_BUFFER_BPS");
        config.approvedObservers = _approvedAddressArray("FUND_CSP_APPROVED_OBSERVERS");
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

    function _requireExpectedImplementationCodehash(
        address proxy,
        string memory expectedCodehashEnv,
        string memory errorMessage
    ) internal view {
        require(_implementationOf(proxy).codehash == _approvedBytes32(expectedCodehashEnv), errorMessage);
    }

    function _requireExpectedV1Baseline(address addressBook_) internal view {
        require(addressBook_ == _approvedAddress("FUND_EXPECTED_V1_ADDRESS_BOOK"), "B1N352: address book baseline");
        AddressBook book = AddressBook(addressBook_);
        _requireExpectedProxyBaseline(
            addressBook_,
            "FUND_EXPECTED_V1_ADDRESS_BOOK",
            "FUND_EXPECTED_V1_ADDRESS_BOOK_IMPLEMENTATION",
            "FUND_EXPECTED_V1_ADDRESS_BOOK_CODEHASH",
            "address book"
        );
        _requireExpectedProxyBaseline(
            book.controller(),
            "FUND_EXPECTED_V1_CONTROLLER_PROXY",
            "FUND_EXPECTED_V1_CONTROLLER_IMPLEMENTATION",
            "FUND_EXPECTED_V1_CONTROLLER_CODEHASH",
            "controller"
        );
        _requireExpectedProxyBaseline(
            book.marginPool(),
            "FUND_EXPECTED_V1_MARGIN_POOL_PROXY",
            "FUND_EXPECTED_V1_MARGIN_POOL_IMPLEMENTATION",
            "FUND_EXPECTED_V1_MARGIN_POOL_CODEHASH",
            "margin pool"
        );
        _requireExpectedProxyBaseline(
            book.oTokenFactory(),
            "FUND_EXPECTED_V1_OTOKEN_FACTORY_PROXY",
            "FUND_EXPECTED_V1_OTOKEN_FACTORY_IMPLEMENTATION",
            "FUND_EXPECTED_V1_OTOKEN_FACTORY_CODEHASH",
            "oToken factory"
        );
        _requireExpectedProxyBaseline(
            book.oracle(),
            "FUND_EXPECTED_V1_ORACLE_PROXY",
            "FUND_EXPECTED_V1_ORACLE_IMPLEMENTATION",
            "FUND_EXPECTED_V1_ORACLE_CODEHASH",
            "oracle"
        );
        _requireExpectedProxyBaseline(
            book.whitelist(),
            "FUND_EXPECTED_V1_WHITELIST_PROXY",
            "FUND_EXPECTED_V1_WHITELIST_IMPLEMENTATION",
            "FUND_EXPECTED_V1_WHITELIST_CODEHASH",
            "whitelist"
        );
        _requireExpectedProxyBaseline(
            book.batchSettler(),
            "FUND_EXPECTED_V1_BATCH_SETTLER_PROXY",
            "FUND_EXPECTED_V1_BATCH_SETTLER_IMPLEMENTATION",
            "FUND_EXPECTED_V1_BATCH_SETTLER_CODEHASH",
            "settler"
        );
        _requireExpectedOwnership(
            addressBook_,
            "FUND_EXPECTED_V1_ADDRESS_BOOK_OWNER",
            "FUND_EXPECTED_V1_ADDRESS_BOOK_PENDING_OWNER",
            "address book"
        );
        _requireExpectedOwnership(
            book.controller(),
            "FUND_EXPECTED_V1_CONTROLLER_OWNER",
            "FUND_EXPECTED_V1_CONTROLLER_PENDING_OWNER",
            "controller"
        );
        _requireExpectedOwnership(
            book.oracle(), "FUND_EXPECTED_V1_ORACLE_OWNER", "FUND_EXPECTED_V1_ORACLE_PENDING_OWNER", "oracle"
        );
        _requireExpectedOwnership(
            book.whitelist(),
            "FUND_EXPECTED_V1_WHITELIST_OWNER",
            "FUND_EXPECTED_V1_WHITELIST_PENDING_OWNER",
            "whitelist"
        );
        _requireExpectedOwnership(
            book.batchSettler(),
            "FUND_EXPECTED_V1_BATCH_SETTLER_OWNER",
            "FUND_EXPECTED_V1_BATCH_SETTLER_PENDING_OWNER",
            "settler"
        );
    }

    function _logV1Baseline(address addressBook_) internal view {
        AddressBook book = AddressBook(addressBook_);
        _logProxyBaseline("ADDRESS_BOOK", addressBook_);
        _logProxyBaseline("CONTROLLER", book.controller());
        _logProxyBaseline("MARGIN_POOL", book.marginPool());
        _logProxyBaseline("OTOKEN_FACTORY", book.oTokenFactory());
        _logProxyBaseline("ORACLE", book.oracle());
        _logProxyBaseline("WHITELIST", book.whitelist());
        _logProxyBaseline("BATCH_SETTLER", book.batchSettler());
        _logOwnership("ADDRESS_BOOK", addressBook_);
        _logOwnership("CONTROLLER", book.controller());
        _logOwnership("ORACLE", book.oracle());
        _logOwnership("WHITELIST", book.whitelist());
        _logOwnership("BATCH_SETTLER", book.batchSettler());
    }

    function _requireExpectedProxyBaseline(
        address proxy,
        string memory proxyEnv,
        string memory implementationEnv,
        string memory codehashEnv,
        string memory component
    ) private view {
        require(proxy == _approvedAddress(proxyEnv), string.concat("B1N352: ", component, " proxy"));
        address implementation = _implementationOf(proxy);
        require(
            implementation == _approvedAddress(implementationEnv),
            string.concat("B1N352: ", component, " implementation")
        );
        require(
            implementation.codehash == _approvedBytes32(codehashEnv), string.concat("B1N352: ", component, " codehash")
        );
    }

    function _logProxyBaseline(string memory component, address proxy) private view {
        address implementation = _implementationOf(proxy);
        console2.log(string.concat("V1_", component, "_PROXY"), proxy);
        console2.log(string.concat("V1_", component, "_IMPLEMENTATION"), implementation);
        console2.log(string.concat("V1_", component, "_IMPLEMENTATION_CODEHASH"));
        console2.logBytes32(implementation.codehash);
    }

    function _requireExpectedOwnership(
        address target,
        string memory ownerEnv,
        string memory pendingOwnerEnv,
        string memory component
    ) private view {
        require(
            _returnsAddress(target, "owner()") == _approvedAddress(ownerEnv),
            string.concat("B1N352: ", component, " owner")
        );
        require(
            _returnsAddress(target, "pendingOwner()") == _approvedAddress(pendingOwnerEnv),
            string.concat("B1N352: ", component, " pending owner")
        );
    }

    function _logOwnership(string memory component, address target) private view {
        console2.log(string.concat("V1_", component, "_OWNER"), _returnsAddress(target, "owner()"));
        console2.log(string.concat("V1_", component, "_PENDING_OWNER"), _returnsAddress(target, "pendingOwner()"));
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

    function _approvedInputs() internal view returns (string memory) {
        return vm.readFile(vm.envString("FUND_APPROVED_INPUTS_PATH"));
    }

    function _approvedJsonKey(string memory key) private pure returns (string memory) {
        return string.concat(".environment.", key);
    }

    function _approvedAddress(string memory key) internal view virtual returns (address) {
        return vm.parseJsonAddress(_approvedInputs(), _approvedJsonKey(key));
    }

    function _approvedAddressArray(string memory key) internal view returns (address[] memory) {
        return vm.parseJsonAddressArray(_approvedInputs(), _approvedJsonKey(key));
    }

    function _approvedBytes32(string memory key) internal view virtual returns (bytes32) {
        return vm.parseJsonBytes32(_approvedInputs(), _approvedJsonKey(key));
    }

    function _approvedString(string memory key) internal view returns (string memory) {
        return vm.parseJsonString(_approvedInputs(), _approvedJsonKey(key));
    }

    function _approvedUint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(_approvedInputs(), _approvedJsonKey(key));
    }

    function _approvedUint8(string memory key) internal view returns (uint8) {
        return _approvedUint(key).toUint8();
    }

    function _approvedUint16(string memory key) internal view returns (uint16) {
        return _approvedUint(key).toUint16();
    }

    function _approvedUint24(string memory key) internal view returns (uint24) {
        return _approvedUint(key).toUint24();
    }

    function _approvedUint32(string memory key) internal view returns (uint32) {
        return _approvedUint(key).toUint32();
    }

    function _approvedUint64(string memory key) internal view returns (uint64) {
        return _approvedUint(key).toUint64();
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
