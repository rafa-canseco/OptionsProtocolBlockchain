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
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {
    AssetNeutralCspFundAdapterV2,
    AssetNeutralCoveredCallFundAdapterV2,
    AssetNeutralOptionsFundAdapterV2
} from "../../src/fund/AssetNeutralOptionsFundAdapterV2.sol";
import {
    AssetNeutralCspFundValuatorV2,
    AssetNeutralOptionsFundValuatorV2
} from "../../src/fund/AssetNeutralOptionsFundValuatorV2.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";

contract AssetNeutralMockManagerV2 {
    address public fund;

    function setFund(address value) external {
        fund = value;
    }
}

contract AssetNeutralMockFundV2 {
    address public asset;
    address public strategyManager;
    uint256 public totalAssets;

    function configure(address asset_, address manager_, uint256 totalAssets_) external {
        asset = asset_;
        strategyManager = manager_;
        totalAssets = totalAssets_;
    }
}

contract AssetNeutralOptionsV2LifecycleTest is Test {
    uint256 private constant MM_KEY = 0xAA442;
    uint256 private constant OBSERVER_KEY = 0xBB442;
    uint256 private constant STRIKE = 50_000e8;
    uint256 private constant OPTION = 1e8;
    uint256 private constant CSP_COLLATERAL = 50_000e6;
    uint256 private constant PREMIUM = 500e6;

    AddressBook private book;
    Controller private controller;
    MarginPool private pool;
    OTokenFactory private factory;
    Oracle private oracle;
    Whitelist private whitelist;
    BatchSettler private settler;
    MockERC20 private lbtc;
    MockERC20 private usdc;
    MockChainlinkFeed private feed;
    MockSwapRouter private router;
    AssetNeutralMockManagerV2 private cspManager;
    AssetNeutralMockManagerV2 private callManager;
    AssetNeutralMockFundV2 private cspFund;
    AssetNeutralMockFundV2 private callFund;
    AssetNeutralCspFundAdapterV2 private csp;
    AssetNeutralCoveredCallFundAdapterV2 private call;
    address private mm;
    uint256 private expiry;
    uint256 private quoteId;

    function setUp() public {
        vm.warp(1_700_000_000);
        mm = vm.addr(MM_KEY);
        lbtc = new MockERC20("Loot BTC", "LBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        feed = new MockChainlinkFeed(50_000e8);
        router = new MockSwapRouter(address(usdc));
        router.setPriceFeed(address(lbtc), address(feed));

        book = AddressBook(_proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this)))));
        controller = Controller(
            _proxy(address(new Controller()), abi.encodeCall(Controller.initialize, (address(book), address(this))))
        );
        pool = MarginPool(_proxy(address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(book)))));
        factory = OTokenFactory(
            _proxy(address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(book))))
        );
        oracle =
            Oracle(_proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(book), address(this)))));
        whitelist = Whitelist(
            _proxy(address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(book), address(this))))
        );
        settler = BatchSettler(
            _proxy(
                address(new BatchSettler()),
                abi.encodeCall(BatchSettler.initialize, (address(book), address(this), address(this)))
            )
        );
        book.setController(address(controller));
        book.setMarginPool(address(pool));
        book.setOTokenFactory(address(factory));
        book.setOracle(address(oracle));
        book.setWhitelist(address(whitelist));
        book.setBatchSettler(address(settler));
        factory.setOperator(address(this));
        controller.setCustodiedRedemptionOnly(true);
        settler.setWhitelistedMM(mm, true);
        settler.setSwapRouter(address(router));
        settler.setSwapFeeTier(500);
        oracle.setPriceFeed(address(lbtc), address(feed));
        oracle.setMaxOracleStaleness(1_200);
        whitelist.whitelistUnderlying(address(lbtc));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(lbtc));
        whitelist.whitelistProduct(address(lbtc), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(lbtc), address(usdc), address(lbtc), false);

        cspManager = new AssetNeutralMockManagerV2();
        callManager = new AssetNeutralMockManagerV2();
        cspFund = new AssetNeutralMockFundV2();
        callFund = new AssetNeutralMockFundV2();
        cspManager.setFund(address(cspFund));
        callManager.setFund(address(callFund));
        cspFund.configure(address(usdc), address(cspManager), 1_000_000e6);
        callFund.configure(address(lbtc), address(callManager), 100e8);
        AccessManager authority = new AccessManager(address(this));
        csp = AssetNeutralCspFundAdapterV2(
            _proxy(
                address(new AssetNeutralCspFundAdapterV2()),
                abi.encodeCall(
                    AssetNeutralCspFundAdapterV2.initialize,
                    (_params(address(cspFund), address(cspManager), address(usdc), address(authority)))
                )
            )
        );
        call = AssetNeutralCoveredCallFundAdapterV2(
            _proxy(
                address(new AssetNeutralCoveredCallFundAdapterV2()),
                abi.encodeCall(
                    AssetNeutralCoveredCallFundAdapterV2.initialize,
                    (_params(address(callFund), address(callManager), address(lbtc), address(authority)))
                )
            )
        );
        settler.setPhysicalDeliveryVault(address(csp), true);
        settler.setPhysicalDeliveryVault(address(call), true);
        usdc.mint(mm, 10_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);
        expiry = _nextEightAm();
    }

    function test_cspAllocateWithPremiumBelowCollateralUpdatesRealLedgersAndInvalidatesOldMarkOnDonation() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(true);
        usdc.mint(address(csp), CSP_COLLATERAL);
        bytes32 beforeHash = csp.positionStateHash();
        vm.prank(address(cspManager));
        csp.allocate(address(usdc), CSP_COLLATERAL, abi.encode(open));
        IAdapter.AdapterStateV2 memory state = csp.adapterStateV2();
        assertEq(state.positionCount, 1);
        assertEq(state.activePositionCount, 1);
        assertEq(state.activeCollateralAmount, CSP_COLLATERAL);
        assertEq(state.accountedSettlementAmount, PREMIUM);
        assertEq(usdc.balanceOf(address(pool)), CSP_COLLATERAL);
        assertEq(usdc.balanceOf(address(csp)), PREMIUM);
        assertTrue(csp.positionStateHash() != beforeHash);

        address[] memory observers = new address[](2);
        observers[0] = mm;
        observers[1] = vm.addr(OBSERVER_KEY);
        AssetNeutralCspFundValuatorV2 valuator = new AssetNeutralCspFundValuatorV2(
            address(feed),
            1_200,
            10,
            2,
            observers,
            address(csp),
            address(cspFund),
            address(book),
            address(lbtc),
            address(usdc),
            csp.policyHash()
        );
        AssetNeutralOptionsFundValuatorV2.Observation[] memory marks =
            new AssetNeutralOptionsFundValuatorV2.Observation[](2);
        marks[0] = _observation(valuator, MM_KEY, 1, 100e6, 1e6, 1);
        marks[1] = _observation(valuator, OBSERVER_KEY, 1, 120e6, 2e6, 2);
        bytes memory data = abi.encode(AssetNeutralOptionsFundValuatorV2.ValuationData({observations: marks}));
        FundTypes.PositionValue memory value = valuator.value(address(csp), uint64(block.number), data);
        assertEq(value.liabilities, 120e6);
        assertEq(value.baseExitCost, 2e6);

        usdc.mint(address(csp), 1);
        vm.expectRevert();
        valuator.value(address(csp), uint64(block.number), data);
        assertEq(csp.adapterStateV2().accountedSettlementAmount, PREMIUM);
        assertEq(usdc.balanceOf(address(csp)), PREMIUM + 1);
    }

    function test_valuatorUsesStricterOracleStalenessAndAcceptsExactBoundary() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(true);
        usdc.mint(address(csp), CSP_COLLATERAL);
        vm.prank(address(cspManager));
        csp.allocate(address(usdc), CSP_COLLATERAL, abi.encode(open));

        oracle.setMaxOracleStaleness(600);
        address[] memory observers = new address[](2);
        observers[0] = mm;
        observers[1] = vm.addr(OBSERVER_KEY);
        AssetNeutralCspFundValuatorV2 valuator = new AssetNeutralCspFundValuatorV2(
            address(feed),
            1_200,
            10,
            2,
            observers,
            address(csp),
            address(cspFund),
            address(book),
            address(lbtc),
            address(usdc),
            csp.policyHash()
        );
        AssetNeutralOptionsFundValuatorV2.Observation[] memory marks =
            new AssetNeutralOptionsFundValuatorV2.Observation[](2);
        marks[0] = _observation(valuator, MM_KEY, 1, 100e6, 1e6, 1);
        marks[1] = _observation(valuator, OBSERVER_KEY, 1, 120e6, 2e6, 2);
        bytes memory data = abi.encode(AssetNeutralOptionsFundValuatorV2.ValuationData({observations: marks}));

        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(MockChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(50_000e8), uint256(0), block.timestamp - 900, uint80(1))
        );
        vm.expectRevert(AssetNeutralOptionsFundValuatorV2.InvalidSpotObservation.selector);
        valuator.value(address(csp), uint64(block.number), data);

        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(MockChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(50_000e8), uint256(0), block.timestamp - 600, uint80(1))
        );
        FundTypes.PositionValue memory value = valuator.value(address(csp), uint64(block.number), data);
        assertEq(value.liabilities, 120e6);
    }

    function test_coveredCallAllocateIsFullyCoveredAndTracksSeparatePremium() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(false);
        lbtc.mint(address(call), OPTION);
        vm.prank(address(callManager));
        call.allocate(address(lbtc), OPTION, abi.encode(open));
        IAdapter.AdapterStateV2 memory state = call.adapterStateV2();
        assertEq(state.activeCollateralAmount, OPTION);
        assertEq(state.accountedUnderlyingAmount, 0);
        assertEq(state.accountedSettlementAmount, PREMIUM);
        assertEq(lbtc.balanceOf(address(pool)), OPTION);
        assertEq(call.positionV2(1).collateralAmount, OPTION);
    }

    function test_cspOtmSettlementReturnsAllCollateralAndClosesExactlyOnce() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(true);
        usdc.mint(address(csp), CSP_COLLATERAL);
        vm.prank(address(cspManager));
        csp.allocate(address(usdc), CSP_COLLATERAL, abi.encode(open));
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(lbtc), expiry, STRIKE + 1);
        vm.prank(address(cspManager));
        csp.deallocate(1, 0, _settle(1));
        assertEq(csp.adapterStateV2().activePositionCount, 0);
        assertEq(uint256(csp.positionV2(1).lifecycle), uint256(IAdapter.Lifecycle.SettledOtm));
        vm.prank(address(cspManager));
        vm.expectRevert(abi.encodeWithSelector(IOperations.InvalidLifecycle.selector, 1, IAdapter.Lifecycle.SettledOtm));
        csp.deallocate(1, 0, _settle(1));
    }

    function test_cspItmPhysicalDeliveryAccountsExactUnderlyingAndIsolatesDonation() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(true);
        usdc.mint(address(csp), CSP_COLLATERAL);
        vm.prank(address(cspManager));
        csp.allocate(address(usdc), CSP_COLLATERAL, abi.encode(open));
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(lbtc), expiry, 45_000e8);
        vm.prank(address(cspManager));
        csp.deallocate(1, 0, _settle(1));
        assertEq(uint256(csp.positionV2(1).lifecycle), uint256(IAdapter.Lifecycle.AwaitingPhysicalDelivery));
        lbtc.mint(address(csp), 1);
        settler.operatorPhysicalRedeemVault(address(csp), 1, CSP_COLLATERAL);
        vm.prank(address(cspManager));
        csp.deallocate(1, 0, _settle(1));
        assertEq(uint256(csp.positionV2(1).lifecycle), uint256(IAdapter.Lifecycle.AssignedUnderlying));
        assertEq(csp.adapterStateV2().accountedUnderlyingAmount, OPTION);
        assertEq(lbtc.balanceOf(address(csp)), OPTION + 1);
    }

    function test_coveredCallOtmRetainsExactCollateralIsolatesDonationAndNormalizesPremium() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(false);
        lbtc.mint(address(call), OPTION + 1);
        vm.prank(address(callManager));
        call.allocate(address(lbtc), OPTION, abi.encode(open));
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(lbtc), expiry, STRIKE - 1);
        vm.prank(address(callManager));
        call.deallocate(1, 0, _settle(1));

        IAdapter.AdapterStateV2 memory settled = call.adapterStateV2();
        assertEq(uint256(call.positionV2(1).lifecycle), uint256(IAdapter.Lifecycle.SettledOtm));
        assertEq(settled.activePositionCount, 0);
        assertEq(settled.accountedUnderlyingAmount, OPTION);
        assertEq(settled.accountedSettlementAmount, PREMIUM);
        assertEq(lbtc.balanceOf(address(call)), OPTION + 1);

        uint256 expectedOut = 1e6;
        vm.prank(address(callManager));
        call.deallocate(1, 0, _normalize(PREMIUM, expectedOut));
        IAdapter.AdapterStateV2 memory normalized = call.adapterStateV2();
        assertEq(normalized.accountedSettlementAmount, 0);
        assertEq(normalized.accountedUnderlyingAmount, 0);
        assertEq(lbtc.balanceOf(address(call)), 1);
        assertEq(lbtc.balanceOf(address(callFund)), OPTION + expectedOut);
        assertEq(lbtc.balanceOf(address(call)) - normalized.accountedUnderlyingAmount, 1);
    }

    function test_coveredCallItmPhysicalCallAwayAccountsStrikeProceedsAndIsolatesDonation() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(false);
        lbtc.mint(address(call), OPTION);
        vm.prank(address(callManager));
        call.allocate(address(lbtc), OPTION, abi.encode(open));
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(lbtc), expiry, 55_000e8);
        vm.prank(address(callManager));
        call.deallocate(1, 0, _settle(1));
        assertEq(uint256(call.positionV2(1).lifecycle), uint256(IAdapter.Lifecycle.AwaitingPhysicalDelivery));

        usdc.mint(address(call), 1);
        settler.operatorPhysicalRedeemVault(address(call), 1, STRIKE / 1e2);
        vm.prank(address(callManager));
        call.deallocate(1, 0, _settle(1));

        uint256 strikeProceeds = STRIKE / 1e2;
        IAdapter.AdapterStateV2 memory state = call.adapterStateV2();
        assertEq(uint256(call.positionV2(1).lifecycle), uint256(IAdapter.Lifecycle.CalledAwaySettlement));
        assertEq(call.positionV2(1).calledAwaySettlementAmount, strikeProceeds);
        assertEq(state.activePositionCount, 0);
        assertEq(state.accountedUnderlyingAmount, 0);
        assertEq(state.accountedSettlementAmount, PREMIUM + strikeProceeds);
        assertEq(usdc.balanceOf(address(call)), PREMIUM + strikeProceeds + 1);
    }

    function test_coveredCallItmDefaultUsesExplicitAssetFallbackAndRejectsReplay() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(false);
        lbtc.mint(address(call), OPTION);
        vm.prank(address(callManager));
        call.allocate(address(lbtc), OPTION, abi.encode(open));
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(lbtc), expiry, 55_000e8);
        vm.prank(address(callManager));
        call.deallocate(1, 0, _settle(1));

        vm.warp(block.timestamp + 6 hours);
        vm.prank(address(callManager));
        call.deallocate(1, 0, _settle(1));
        uint256 mmUnderlying = (OPTION * 5_000e8 + 55_000e8 - 1) / 55_000e8;
        IAdapter.PositionV2 memory position = call.positionV2(1);
        assertEq(uint256(position.lifecycle), uint256(IAdapter.Lifecycle.CashFallback));
        assertEq(position.marketMakerUnderlyingPayoutAmount, mmUnderlying);
        assertEq(position.fallbackUnderlyingRecoveredAmount, OPTION - mmUnderlying);
        assertEq(call.adapterStateV2().accountedUnderlyingAmount, OPTION - mmUnderlying);
        assertEq(lbtc.balanceOf(mm), mmUnderlying);

        vm.prank(address(callManager));
        vm.expectRevert(
            abi.encodeWithSelector(IOperations.InvalidLifecycle.selector, 1, IAdapter.Lifecycle.CashFallback)
        );
        call.deallocate(1, 0, _settle(1));
    }

    function test_cspItmDefaultUsesCashFallbackAndPreservesExactAccounting() public {
        (IAdapter.OpenPositionDataV2 memory open,) = _open(true);
        usdc.mint(address(csp), CSP_COLLATERAL);
        vm.prank(address(cspManager));
        csp.allocate(address(usdc), CSP_COLLATERAL, abi.encode(open));
        uint256 mmBefore = usdc.balanceOf(mm);
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(lbtc), expiry, 45_000e8);
        vm.prank(address(cspManager));
        csp.deallocate(1, 0, _settle(1));
        vm.warp(block.timestamp + 6 hours);
        vm.prank(address(cspManager));
        csp.deallocate(1, 0, _settle(1));

        uint256 marketMakerPayout = usdc.balanceOf(mm) - mmBefore;
        IAdapter.PositionV2 memory position = csp.positionV2(1);
        IAdapter.AdapterStateV2 memory state = csp.adapterStateV2();
        assertEq(uint256(position.lifecycle), uint256(IAdapter.Lifecycle.CashFallback));
        assertGt(marketMakerPayout, 0);
        assertEq(position.premiumSettlementAmount, PREMIUM);
        assertEq(state.accountedSettlementAmount, usdc.balanceOf(address(csp)));
        assertEq(csp.freeAssets(address(usdc)), state.accountedSettlementAmount);
        assertEq(state.activePositionCount, 0);
    }

    function test_quotePartialFillReconcilesLedgerAndContinuationFailsClosedUntilNormalization() public {
        (IAdapter.OpenPositionDataV2 memory full,) = _open(false);
        uint256 half = OPTION / 2;
        IAdapter.OpenPositionDataV2 memory first = full;
        first.optionAmount8 = half;
        first.collateralAmount = half;
        IAdapter.OpenPositionDataV2 memory second = full;
        second.optionAmount8 = OPTION - half;
        second.collateralAmount = OPTION - half;
        lbtc.mint(address(call), OPTION);

        vm.prank(address(callManager));
        call.allocate(address(lbtc), half, abi.encode(first));
        bytes32 quoteHash = settler.hashQuote(full.quote);
        IAdapter.AdapterStateV2 memory partialState = call.adapterStateV2();
        assertEq(partialState.positionCount, 1);
        assertEq(partialState.activePositionCount, 1);
        assertEq(partialState.activeCollateralAmount, half);
        assertEq(partialState.accountedSettlementAmount, PREMIUM / 2);
        assertEq(call.positionV2(1).collateralAmount, half);
        assertEq(settler.quoteState(mm, quoteHash), half);
        assertEq(lbtc.balanceOf(address(pool)), half);

        vm.prank(address(callManager));
        vm.expectRevert(IOperations.InvalidRiskConfig.selector);
        call.allocate(address(lbtc), OPTION - half, abi.encode(second));
        assertEq(settler.quoteState(mm, quoteHash), half);
        assertEq(call.adapterStateV2().positionCount, 1);
        assertEq(lbtc.balanceOf(address(pool)), half);
    }

    function _params(address fund_, address manager_, address accountingAsset, address authority)
        private
        view
        returns (AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory)
    {
        accountingAsset;
        return AssetNeutralOptionsFundAdapterV2.InitializeParamsV2({
            fund: fund_,
            strategyManager: manager_,
            addressBook: address(book),
            underlyingAsset: address(lbtc),
            settlementAsset: address(usdc),
            swapRouter: address(router),
            swapFeeTier: 500,
            authority: authority,
            riskConfig: IOperations.RiskConfigV2({
                minExpiryDelay: 1 hours,
                maxExpiryDelay: 2 days,
                settlementDefaultDelay: 6 hours,
                minPremiumBps: 1,
                maxSwapSlippageBps: 100,
                maxOpenPositions: 4,
                maxUtilizationBps: 10_000,
                minStrikeUsd8: 1,
                maxStrikeUsd8: 100_000e8,
                maxCollateralPerPosition: 1_000_000e6,
                maxNormalizationInput: 1_000_000e6,
                protectedBasisUsd8: 0
            })
        });
    }

    function _open(bool put) private returns (IAdapter.OpenPositionDataV2 memory open, address oToken) {
        address collateral = put ? address(usdc) : address(lbtc);
        oToken = factory.createOToken(address(lbtc), address(usdc), collateral, STRIKE, expiry, put);
        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: PREMIUM,
            deadline: block.timestamp + 1 hours,
            quoteId: ++quoteId,
            maxAmount: OPTION,
            makerNonce: settler.makerNonce(mm)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, settler.hashQuote(quote));
        open = IAdapter.OpenPositionDataV2({
            quote: quote,
            signature: abi.encodePacked(r, s, v),
            optionAmount8: OPTION,
            collateralAmount: put ? CSP_COLLATERAL : OPTION
        });
    }

    function _observation(
        AssetNeutralCspFundValuatorV2 valuator,
        uint256 key,
        uint256 id,
        uint256 liability,
        uint256 cost,
        uint256 nonce
    ) private returns (AssetNeutralOptionsFundValuatorV2.Observation memory o) {
        uint64 snapshot = uint64(block.number);
        uint64 valid = snapshot + 5;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, valuator.observationDigest(address(csp), id, liability, cost, snapshot, valid, nonce));
        o = AssetNeutralOptionsFundValuatorV2.Observation({
            positionId: id,
            liability: liability,
            baseExitCost: cost,
            snapshotBlock: snapshot,
            validUntilBlock: valid,
            nonce: nonce,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _settle(uint256 id) private pure returns (bytes memory) {
        return abi.encode(
            IAdapter.DeallocateDataV2({
                action: IAdapter.DeallocateAction.Settle, positionId: id, amount: 0, minAmountOut: 0
            })
        );
    }

    function _normalize(uint256 amount, uint256 minAmountOut) private pure returns (bytes memory) {
        return abi.encode(
            IAdapter.DeallocateDataV2({
                action: IAdapter.DeallocateAction.Normalize, positionId: 0, amount: amount, minAmountOut: minAmountOut
            })
        );
    }

    function _nextEightAm() private view returns (uint256) {
        uint256 start = block.timestamp - (block.timestamp % 1 days);
        uint256 eight = start + 8 hours;
        return eight > block.timestamp ? eight : eight + 1 days;
    }

    function _proxy(address implementation, bytes memory initData) private returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }
}
