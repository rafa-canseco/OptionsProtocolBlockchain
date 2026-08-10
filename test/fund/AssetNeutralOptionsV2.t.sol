// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {MarginPool} from "../../src/core/MarginPool.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {Whitelist} from "../../src/core/Whitelist.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {AssetNeutralUnitsV2} from "../../src/fund/libraries/AssetNeutralUnitsV2.sol";
import {
    AssetNeutralCspFundAdapterV2,
    AssetNeutralCoveredCallFundAdapterV2,
    AssetNeutralOptionsFundAdapterV2
} from "../../src/fund/AssetNeutralOptionsFundAdapterV2.sol";
import {
    AssetNeutralCspFundValuatorV2,
    AssetNeutralCoveredCallFundValuatorV2
} from "../../src/fund/AssetNeutralOptionsFundValuatorV2.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {PreflightB1N442Lbtc8} from "../../script/fund/PreflightB1N442Lbtc8.s.sol";

contract CspStorageLocationHarness is AssetNeutralCspFundAdapterV2 {
    function exposedStorageLocation() external pure returns (bytes32) {
        return _storageLocation();
    }

    function cspPremium(uint256 before_, uint256 after_, uint256 collateral) external pure returns (uint256) {
        return _cspPremiumEarned(before_, after_, collateral);
    }
}

contract CallStorageLocationHarness is AssetNeutralCoveredCallFundAdapterV2 {
    function exposedStorageLocation() external pure returns (bytes32) {
        return _storageLocation();
    }
}

contract MockFreshFeedV2 {
    uint8 public constant decimals = 8;
    int256 public answer = 50_000e8;
    uint256 public updatedAt = block.timestamp;

    function setUpdatedAt(uint256 value) external {
        updatedAt = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 0, updatedAt, 1);
    }
}

contract MockFreshOracleV2 {
    uint256 public maxOracleStaleness;
    mapping(address => address) public priceFeed;

    function configure(address asset, address feed, uint256 age) external {
        priceFeed[asset] = feed;
        maxOracleStaleness = age;
    }
}

contract MockCounterfeitAdapterV2 {}

contract MockBindingManagerV2 {
    address public fund;
    mapping(address => FundTypes.StrategyConfig) private _strategyConfigs;

    function setFund(address value) external {
        fund = value;
    }

    function setStrategyConfig(address adapter, FundTypes.StrategyConfig calldata config) external {
        _strategyConfigs[adapter] = config;
    }

    function strategyConfig(address adapter) external view returns (FundTypes.StrategyConfig memory) {
        return _strategyConfigs[adapter];
    }
}

contract MockBindingFundV2 {
    address public asset;
    address public strategyManager;
    bool public depositsPaused = true;

    function configure(address asset_, address manager_) external {
        asset = asset_;
        strategyManager = manager_;
    }

    function totalAssets() external pure returns (uint256) {
        return 0;
    }
}

contract MockPreflightRouterV2 {
    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }
}

contract MockPreflightFactoryV2 {
    address public pool;

    function setPool(address value) external {
        pool = value;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return pool;
    }
}

contract MockPreflightPoolV2 {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint128 public liquidity = 1;

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }
}

contract AssetNeutralOptionsV2Test is Test {
    function test_exactEightDecimalCoveredCollateral() external pure {
        assertEq(AssetNeutralUnitsV2.coveredCallCollateral(123_456_789), 123_456_789);
    }

    function test_cspCollateralRoundsUpAndCallAwayRoundsDown() external pure {
        assertEq(AssetNeutralUnitsV2.cspCollateral(1, 1), 1);
        assertEq(AssetNeutralUnitsV2.callAwaySettlement(1, 1), 0);
        assertEq(AssetNeutralUnitsV2.cspCollateral(1e8, 50_000e8), 50_000e6);
    }

    function test_liabilitiesRoundAgainstNav() external pure {
        assertGe(
            AssetNeutralUnitsV2.underlyingLiabilityToSettlement(7, 31_337e8),
            AssetNeutralUnitsV2.underlyingToSettlement(7, 31_337e8)
        );
        assertGe(
            AssetNeutralUnitsV2.settlementLiabilityToUnderlying(7, 31_337e8),
            AssetNeutralUnitsV2.settlementToUnderlying(7, 31_337e8)
        );
    }

    function test_newImplementationsExposeOnlyV2StrategyIdentity() external {
        AssetNeutralCspFundAdapterV2 csp = new AssetNeutralCspFundAdapterV2();
        AssetNeutralCoveredCallFundAdapterV2 call = new AssetNeutralCoveredCallFundAdapterV2();
        assertEq(csp.interfaceVersion(), 2);
        assertEq(call.interfaceVersion(), 2);
        assertEq(uint256(csp.strategyKind()), uint256(IAdapter.StrategyKind.Csp));
        assertEq(uint256(call.strategyKind()), uint256(IAdapter.StrategyKind.CoveredCall));
    }

    function test_storageNamespacesAreNewPinnedAndDisjoint() external {
        bytes32 csp = new CspStorageLocationHarness().exposedStorageLocation();
        bytes32 call = new CallStorageLocationHarness().exposedStorageLocation();
        assertEq(csp, 0x9591e324b6bef4f293bf5b406270137e316bf81c5dc4459c5dff3f5d92b0e500);
        assertEq(call, 0xb56377e01ba7390bcdce9ef7c884367de0dad4bbdc8649f6c3222c65bccb4300);
        assertTrue(csp != call);
    }

    function test_preflightReadbackIsPinnedAndFailsClosedOffBaseSepolia() external {
        PreflightB1N442Lbtc8 preflight = new PreflightB1N442Lbtc8();
        assertEq(preflight.LBTC8(), 0x39fA11EbBE82699Fd9F79C566D7384064571d2b4);
        vm.chainId(8453);
        vm.expectRevert(abi.encodeWithSelector(PreflightB1N442Lbtc8.PreflightFailed.selector, bytes32("CHAIN")));
        preflight.check(
            PreflightB1N442Lbtc8.Inputs({
                settlement: address(0),
                addressBook: address(0),
                router: address(0),
                swapFactory: address(0),
                swapFeeTier: 0,
                expectedAuthority: address(0),
                cspProxy: address(0),
                callProxy: address(0),
                cspValuator: address(0),
                callValuator: address(0)
            })
        );
    }

    function test_releasePreflightCannotBypassMandatoryAdapterAndValuatorReadback() external {
        PreflightB1N442Lbtc8 preflight = new PreflightB1N442Lbtc8();
        vm.chainId(84532);
        vm.expectRevert(
            abi.encodeWithSelector(PreflightB1N442Lbtc8.PreflightFailed.selector, bytes32("RELEASE_READBACK_REQUIRED"))
        );
        preflight.check(
            PreflightB1N442Lbtc8.Inputs({
                settlement: address(1),
                addressBook: address(2),
                router: address(3),
                swapFactory: address(4),
                swapFeeTier: 500,
                expectedAuthority: address(5),
                cspProxy: address(0),
                callProxy: address(0),
                cspValuator: address(0),
                callValuator: address(0)
            })
        );
    }

    function test_identityEvidencePinsSourceCreationAndRuntimeWithoutMintBroadcast() external {
        PreflightB1N442Lbtc8 preflight = new PreflightB1N442Lbtc8();
        assertEq(
            preflight.LBTC8_VERIFIED_SOURCE_ARTIFACT_SHA256(),
            0xb56bda7d0ad8c8cd7519779294d53af692da257ea41b31769d19a5826b012cec
        );
        assertEq(
            preflight.LBTC8_VERIFIED_SOURCE_SHA256(), 0x736cb364367e0b2c03a3b8c98968554cd586c9850b517ae904c3f46a9772fa79
        );
        assertEq(
            preflight.LBTC8_CREATION_TRANSACTION(), 0x840289b3d7c49de8d281e1ed09d0f31d5a42ae57601537fc632f27f02b216a61
        );
    }

    function test_cspOrdinaryPremiumUsesCombinedSettlementEquation() external {
        CspStorageLocationHarness harness = new CspStorageLocationHarness();
        assertEq(harness.cspPremium(1_000e6, 105e6, 900e6), 5e6);
        vm.expectRevert(abi.encodeWithSelector(IOperations.LedgerMismatch.selector, uint256(0)));
        harness.cspPremium(1_000e6, 99e6, 900e6);
    }

    function test_freshSpotRejectsDisabledStalenessAndAcceptsPolicyBoundary() external {
        vm.warp(5_000);
        AssetNeutralCspFundAdapterV2 adapter = new AssetNeutralCspFundAdapterV2();
        MockFreshOracleV2 oracle = new MockFreshOracleV2();
        MockFreshFeedV2 feed = new MockFreshFeedV2();
        address asset = address(0xB7C);
        oracle.configure(asset, address(feed), 0);
        vm.expectRevert(IOperations.InvalidRiskConfig.selector);
        adapter.validateFreshSpotV2(address(oracle), asset);
        oracle.configure(asset, address(feed), 1_200);
        assertEq(adapter.validateFreshSpotV2(address(oracle), asset), 50_000e8);
        feed.setUpdatedAt(block.timestamp - 1_201);
        vm.expectRevert(IOperations.InvalidRiskConfig.selector);
        adapter.validateFreshSpotV2(address(oracle), asset);
    }

    function test_valuatorRejectsCounterfeitSameDecimalAdapterBeforeValuation() external {
        MockFreshFeedV2 feed = new MockFreshFeedV2();
        address[] memory observers = new address[](2);
        observers[0] = address(0xA11CE);
        observers[1] = address(0xB0B);
        AssetNeutralCspFundValuatorV2 valuator = new AssetNeutralCspFundValuatorV2(
            address(feed),
            1_200,
            10,
            2,
            observers,
            address(0x1234),
            address(0xF00D),
            address(0xB00C),
            address(0xB7C),
            address(0x5E77),
            bytes32(uint256(1))
        );
        address counterfeit = address(new MockCounterfeitAdapterV2());
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("InvalidAdapter(address)")), counterfeit));
        valuator.value(counterfeit, uint64(block.number), "");
    }

    function test_initializeRejectsManagerFundOrAccountingAssetMismatch() external {
        MockERC20 underlying = new MockERC20("LBTC", "LBTC", 8);
        MockERC20 settlement = new MockERC20("USDC", "USDC", 6);
        MockBindingManagerV2 manager = new MockBindingManagerV2();
        MockBindingFundV2 fund = new MockBindingFundV2();
        manager.setFund(address(fund));
        fund.configure(address(underlying), address(manager));
        IOperations.RiskConfigV2 memory risk = IOperations.RiskConfigV2(1, 2, 1, 1, 1, 1, 1, 1, 2, 1, 1, 0);
        AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory p =
            AssetNeutralOptionsFundAdapterV2.InitializeParamsV2(
                address(fund),
                address(manager),
                address(this),
                address(underlying),
                address(settlement),
                address(this),
                500,
                address(this),
                risk
            );
        AssetNeutralCspFundAdapterV2 implementation = new AssetNeutralCspFundAdapterV2();
        vm.expectRevert(IOperations.InvalidAddress.selector);
        new ERC1967Proxy(address(implementation), abi.encodeCall(AssetNeutralCspFundAdapterV2.initialize, (p)));
    }

    function test_releasePreflightAcceptsCompletePausedCurrentV2Readback() external {
        vm.chainId(84532);
        vm.warp(10_000);
        PreflightB1N442Lbtc8 preflight = new PreflightB1N442Lbtc8();
        bytes memory pinnedRuntime = vm.parseBytes(vm.readFile("test/fixtures/b1n442-lbtc-runtime.hex"));
        vm.etch(preflight.LBTC8(), pinnedRuntime);
        assertEq(preflight.LBTC8().codehash, preflight.LBTC8_RUNTIME_CODEHASH());
        vm.mockCall(preflight.LBTC8(), abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

        MockERC20 settlement = new MockERC20("USD Coin", "USDC", 6);
        MockFreshFeedV2 feed = new MockFreshFeedV2();
        AddressBook book =
            AddressBook(_proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this)))));
        Controller controller = Controller(
            _proxy(address(new Controller()), abi.encodeCall(Controller.initialize, (address(book), address(this))))
        );
        MarginPool marginPool =
            MarginPool(_proxy(address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(book)))));
        OTokenFactory oTokenFactory = OTokenFactory(
            _proxy(address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(book))))
        );
        Oracle oracle =
            Oracle(_proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(book), address(this)))));
        Whitelist whitelist = Whitelist(
            _proxy(address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(book), address(this))))
        );
        BatchSettler settler = BatchSettler(
            _proxy(
                address(new BatchSettler()),
                abi.encodeCall(BatchSettler.initialize, (address(book), address(this), address(this)))
            )
        );
        book.setController(address(controller));
        book.setMarginPool(address(marginPool));
        book.setOTokenFactory(address(oTokenFactory));
        book.setOracle(address(oracle));
        book.setWhitelist(address(whitelist));
        book.setBatchSettler(address(settler));
        oracle.setPriceFeed(preflight.LBTC8(), address(feed));
        oracle.setMaxOracleStaleness(600);
        whitelist.whitelistUnderlying(preflight.LBTC8());
        whitelist.whitelistCollateral(address(settlement));
        whitelist.whitelistCollateral(preflight.LBTC8());
        whitelist.whitelistProduct(preflight.LBTC8(), address(settlement), address(settlement), true);
        whitelist.whitelistProduct(preflight.LBTC8(), address(settlement), preflight.LBTC8(), false);

        MockPreflightFactoryV2 swapFactory = new MockPreflightFactoryV2();
        MockPreflightRouterV2 router = new MockPreflightRouterV2(address(swapFactory));
        MockPreflightPoolV2 routePool = new MockPreflightPoolV2(preflight.LBTC8(), address(settlement), 500);
        swapFactory.setPool(address(routePool));
        settler.setSwapRouter(address(router));
        settler.setAssetSwapFeeTier(preflight.LBTC8(), 500);

        MockBindingManagerV2 cspManager = new MockBindingManagerV2();
        MockBindingManagerV2 callManager = new MockBindingManagerV2();
        MockBindingFundV2 cspFund = new MockBindingFundV2();
        MockBindingFundV2 callFund = new MockBindingFundV2();
        cspManager.setFund(address(cspFund));
        callManager.setFund(address(callFund));
        cspFund.configure(address(settlement), address(cspManager));
        callFund.configure(preflight.LBTC8(), address(callManager));
        AccessManager authority = new AccessManager(address(this));
        AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory cspParams = _preflightParams(
            address(cspFund),
            address(cspManager),
            address(book),
            preflight.LBTC8(),
            address(settlement),
            address(router),
            address(authority)
        );
        AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory callParams = _preflightParams(
            address(callFund),
            address(callManager),
            address(book),
            preflight.LBTC8(),
            address(settlement),
            address(router),
            address(authority)
        );
        AssetNeutralCspFundAdapterV2 csp = AssetNeutralCspFundAdapterV2(
            _proxy(
                address(new AssetNeutralCspFundAdapterV2()),
                abi.encodeCall(AssetNeutralCspFundAdapterV2.initialize, (cspParams))
            )
        );
        AssetNeutralCoveredCallFundAdapterV2 call = AssetNeutralCoveredCallFundAdapterV2(
            _proxy(
                address(new AssetNeutralCoveredCallFundAdapterV2()),
                abi.encodeCall(AssetNeutralCoveredCallFundAdapterV2.initialize, (callParams))
            )
        );
        address[] memory observers = new address[](2);
        observers[0] = address(0xA11CE);
        observers[1] = address(0xB0B);
        AssetNeutralCspFundValuatorV2 cspValuator = new AssetNeutralCspFundValuatorV2(
            address(feed),
            1_200,
            10,
            2,
            observers,
            address(csp),
            address(cspFund),
            address(book),
            preflight.LBTC8(),
            address(settlement),
            csp.policyHash()
        );
        AssetNeutralCoveredCallFundValuatorV2 callValuator = new AssetNeutralCoveredCallFundValuatorV2(
            address(feed),
            1_200,
            10,
            2,
            observers,
            address(call),
            address(callFund),
            address(book),
            preflight.LBTC8(),
            address(settlement),
            call.policyHash()
        );
        cspManager.setStrategyConfig(address(csp), _pausedConfig(address(cspValuator)));
        callManager.setStrategyConfig(address(call), _pausedConfig(address(callValuator)));

        assertTrue(
            preflight.check(
                PreflightB1N442Lbtc8.Inputs({
                    settlement: address(settlement),
                    addressBook: address(book),
                    router: address(router),
                    swapFactory: address(swapFactory),
                    swapFeeTier: 500,
                    expectedAuthority: address(authority),
                    cspProxy: address(csp),
                    callProxy: address(call),
                    cspValuator: address(cspValuator),
                    callValuator: address(callValuator)
                })
            )
        );
    }

    function testFuzz_conservativeRounding(uint128 amount, uint128 price) external pure {
        if (price == 0) return;
        uint256 asset = AssetNeutralUnitsV2.underlyingToSettlement(amount, price);
        uint256 liability = AssetNeutralUnitsV2.underlyingLiabilityToSettlement(amount, price);
        assertGe(liability, asset);
        assertLe(liability - asset, 1);
        uint256 reverseAsset = AssetNeutralUnitsV2.settlementToUnderlying(amount, price);
        uint256 reverseLiability = AssetNeutralUnitsV2.settlementLiabilityToUnderlying(amount, price);
        assertGe(reverseLiability, reverseAsset);
        assertLe(reverseLiability - reverseAsset, 1);
    }

    function _proxy(address implementation, bytes memory data) private returns (address) {
        return address(new ERC1967Proxy(implementation, data));
    }

    function _preflightParams(
        address fund_,
        address manager_,
        address book_,
        address underlying_,
        address settlement_,
        address router_,
        address authority_
    ) private pure returns (AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory) {
        return AssetNeutralOptionsFundAdapterV2.InitializeParamsV2({
            fund: fund_,
            strategyManager: manager_,
            addressBook: book_,
            underlyingAsset: underlying_,
            settlementAsset: settlement_,
            swapRouter: router_,
            swapFeeTier: 500,
            authority: authority_,
            riskConfig: IOperations.RiskConfigV2(1 hours, 2 days, 6 hours, 1, 100, 4, 10_000, 1, 100_000e8, 1, 1, 0)
        });
    }

    function _pausedConfig(address valuator) private pure returns (FundTypes.StrategyConfig memory) {
        return FundTypes.StrategyConfig({
            active: false,
            maxAllocationBps: 10_000,
            maxLossBps: 100,
            cooldown: 0,
            interfaceVersion: 2,
            valuator: valuator,
            absoluteCap: type(uint128).max
        });
    }
}

contract AssetNeutralUnitsV2Handler {
    uint256 public lastAmount;
    uint256 public lastPrice;

    function exercise(uint128 amount, uint128 price) external {
        lastAmount = amount;
        lastPrice = price;
    }
}

contract AssetNeutralUnitsV2InvariantTest is Test {
    AssetNeutralUnitsV2Handler private handler;

    function setUp() external {
        handler = new AssetNeutralUnitsV2Handler();
        targetContract(address(handler));
    }

    function invariant_exact8To8NeverCreatesScaleDust() external view {
        assertEq(AssetNeutralUnitsV2.coveredCallCollateral(handler.lastAmount()), handler.lastAmount());
    }

    function invariant_cashSecurityNeverRoundsDown() external view {
        uint256 a = handler.lastAmount();
        uint256 p = handler.lastPrice();
        assertGe(AssetNeutralUnitsV2.cspCollateral(a, p) * 1e10, a * p);
    }
}
