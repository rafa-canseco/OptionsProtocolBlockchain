// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {MarginPool} from "../../src/core/MarginPool.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {Whitelist} from "../../src/core/Whitelist.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {ICoveredCallFundValuator} from "../../src/fund/interfaces/ICoveredCallFundValuator.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";

contract CoveredCallFundReceiver {
    uint256 public totalAssets = 10e18;
}

contract CoveredCallStrategyManagerCaller {
    function allocate(CoveredCallFundAdapter adapter, address asset, uint256 amount, bytes calldata data) external {
        IERC20(asset).transfer(address(adapter), amount);
        adapter.allocate(asset, amount, data);
    }

    function deallocate(CoveredCallFundAdapter adapter, uint256 targetValue, uint256 minimumOut, bytes calldata data)
        external
        returns (uint256)
    {
        return adapter.deallocate(targetValue, minimumOut, data);
    }

    function deallocateInKind(CoveredCallFundAdapter adapter, uint256 fractionWad, address escrow)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        return adapter.deallocateInKind(fractionWad, escrow, "");
    }

    function emergencyExit(CoveredCallFundAdapter adapter, address escrow)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        return adapter.emergencyExit(escrow, "");
    }
}

contract CoveredCallFundAdapterTest is Test {
    uint256 private constant STRIKE = 2_000e8;
    uint256 private constant OPTION_AMOUNT = 1e8;
    uint256 private constant COLLATERAL = 1e18;
    uint256 private constant PREMIUM = 70e6;
    uint256 private constant MM_KEY = 0xAA02;
    uint256 private constant OBSERVER_KEY = 0xCA11;
    uint256 private constant MODEL_VERSION_PREFIX = uint256(1) << 192;
    bytes32 private constant STORAGE_SLOT = 0x87c2fcf2eb487ab099069387b4c834e159db5117bd35c067363dcc0f68a6c200;

    AddressBook private addressBook;
    Controller private controller;
    MarginPool private pool;
    OTokenFactory private factory;
    Oracle private oracle;
    Whitelist private whitelist;
    BatchSettler private settler;
    MockERC20 private weth;
    MockERC20 private usdc;
    MockChainlinkFeed private spotFeed;
    MockSwapRouter private swapRouter;
    CoveredCallFundReceiver private fund;
    CoveredCallStrategyManagerCaller private strategyManager;
    CoveredCallFundAdapter private adapter;
    CoveredCallFundAdapter private adapterImplementation;
    CoveredCallFundValuatorV2 private valuator;

    address private mm;
    address private observer;
    address private escrow = address(0xCC55);
    uint256 private expiry;
    uint256 private nextQuoteId = 1;

    function setUp() public {
        vm.warp(1_700_000_000);
        mm = vm.addr(MM_KEY);
        observer = vm.addr(OBSERVER_KEY);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        spotFeed = new MockChainlinkFeed(1_800e8);
        swapRouter = new MockSwapRouter(address(usdc));
        swapRouter.setPriceFeed(address(weth), address(spotFeed));

        addressBook =
            AddressBook(_proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this)))));
        controller = Controller(
            _proxy(
                address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), address(this)))
            )
        );
        pool = MarginPool(
            _proxy(address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook))))
        );
        factory = OTokenFactory(
            _proxy(address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook))))
        );
        oracle = Oracle(
            _proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), address(this))))
        );
        whitelist = Whitelist(
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
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
        factory.setOperator(address(this));
        controller.setCustodiedRedemptionOnly(true);
        settler.setWhitelistedMM(mm, true);
        settler.setSwapRouter(address(swapRouter));
        settler.setSwapFeeTier(500);
        oracle.setPriceFeed(address(weth), address(spotFeed));
        oracle.setMaxOracleStaleness(1 hours);
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        fund = new CoveredCallFundReceiver();
        strategyManager = new CoveredCallStrategyManagerCaller();
        AccessManager adapterAuthority = new AccessManager(address(this));
        adapterImplementation = new CoveredCallFundAdapter();
        adapter = CoveredCallFundAdapter(
            _proxy(
                address(adapterImplementation),
                abi.encodeCall(
                    CoveredCallFundAdapter.initialize,
                    (CoveredCallFundAdapter.InitializeParams({
                            fund: address(fund),
                            strategyManager: address(strategyManager),
                            addressBook: address(addressBook),
                            accountingAsset: address(weth),
                            usdc: address(usdc),
                            swapRouter: address(swapRouter),
                            swapFeeTier: 500,
                            authority: address(adapterAuthority),
                            riskConfig: _riskConfig()
                        }))
                )
            )
        );

        address[] memory observers = new address[](2);
        observers[0] = mm;
        observers[1] = observer;
        valuator = new CoveredCallFundValuatorV2(address(spotFeed), 8, 1 hours, 10, 2, 0, observers);

        expiry = _nextEightAm();
        weth.mint(address(strategyManager), 20e18);
        usdc.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);
    }

    function test_requiresOnchainPhysicalDeliveryAuthorizationBeforeOpening() public {
        (ICoveredCallFundAdapter.OpenPositionData memory openData,) = _openData();

        assertFalse(adapter.isOnboarded());
        vm.expectRevert(ICoveredCallFundAdapter.AdapterNotOnboarded.selector);
        strategyManager.allocate(adapter, address(weth), COLLATERAL, abi.encode(openData));

        settler.setPhysicalDeliveryVault(address(adapter), true);
        assertTrue(adapter.isOnboarded());
        strategyManager.allocate(adapter, address(weth), COLLATERAL, abi.encode(openData));

        ICoveredCallFundAdapter.AdapterState memory state = adapter.adapterState();
        ICoveredCallFundAdapter.Position memory opened = adapter.position(1);
        assertEq(state.positionCount, 1);
        assertEq(state.activePositionCount, 1);
        assertEq(state.activeCollateral, COLLATERAL);
        assertEq(state.accountedWeth, 0);
        assertEq(state.accountedUsdc, PREMIUM);
        assertEq(opened.protocolVaultId, 1);
        assertEq(opened.marketMaker, mm);
        assertEq(opened.premiumEarned, PREMIUM);
        assertEq(uint256(opened.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.Open));
        assertEq(weth.balanceOf(address(pool)), COLLATERAL);
        assertTrue(settler.physicalDeliveryReservedVault(address(adapter), 1));
        assertEq(settler.vaultOTokenBalance(address(adapter), 1), OPTION_AMOUNT);
        assertEq(state.stateNonce, 1);
    }

    function test_storageNamespaceAndImplementationInitializationAreLocked() public {
        assertEq(address(uint160(uint256(vm.load(address(adapter), STORAGE_SLOT)))), address(fund));

        AccessManager unusedAuthority = new AccessManager(address(this));
        vm.expectRevert();
        adapterImplementation.initialize(
            CoveredCallFundAdapter.InitializeParams({
                fund: address(fund),
                strategyManager: address(strategyManager),
                addressBook: address(addressBook),
                accountingAsset: address(weth),
                usdc: address(usdc),
                swapRouter: address(swapRouter),
                swapFeeTier: 500,
                authority: address(unusedAuthority),
                riskConfig: _riskConfig()
            })
        );
    }

    function test_onlyStrategyManagerCanMoveAssets() public {
        settler.setPhysicalDeliveryVault(address(adapter), true);
        (ICoveredCallFundAdapter.OpenPositionData memory openData,) = _openData();
        weth.mint(address(adapter), COLLATERAL);

        vm.expectRevert(ICoveredCallFundAdapter.OnlyStrategyManager.selector);
        adapter.allocate(address(weth), COLLATERAL, abi.encode(openData));

        vm.expectRevert(ICoveredCallFundAdapter.OnlyStrategyManager.selector);
        adapter.deallocate(1, 0, _settleData());

        vm.expectRevert(ICoveredCallFundAdapter.OnlyStrategyManager.selector);
        adapter.emergencyExit(escrow, "");
    }

    function test_rejectsPutSeriesAndReopeningWithUnresolvedPremium() public {
        settler.setPhysicalDeliveryVault(address(adapter), true);
        address put = factory.createOToken(address(weth), address(usdc), address(weth), STRIKE, expiry, true);
        BatchSettler.Quote memory quote = _quote(put);
        ICoveredCallFundAdapter.OpenPositionData memory badOpen = ICoveredCallFundAdapter.OpenPositionData({
            quote: quote, signature: _signQuote(quote), optionAmount: OPTION_AMOUNT, collateral: COLLATERAL
        });
        vm.expectRevert(abi.encodeWithSelector(ICoveredCallFundAdapter.InvalidSeries.selector, put));
        strategyManager.allocate(adapter, address(weth), COLLATERAL, abi.encode(badOpen));

        _open();
        BatchSettler.Quote memory secondQuote = _quote(adapter.position(1).oToken);
        ICoveredCallFundAdapter.OpenPositionData memory secondOpen = ICoveredCallFundAdapter.OpenPositionData({
            quote: secondQuote, signature: _signQuote(secondQuote), optionAmount: OPTION_AMOUNT, collateral: COLLATERAL
        });
        vm.expectRevert(ICoveredCallFundAdapter.InvalidRiskConfig.selector);
        strategyManager.allocate(adapter, address(weth), COLLATERAL, abi.encode(secondOpen));
    }

    function test_otmSettlementNormalizesPremiumAndReturnsOnlyWeth() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(1_800e8);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);

        uint256 settlementReturn = strategyManager.deallocate(adapter, 1, 0, _settleData());
        ICoveredCallFundAdapter.Position memory settled = adapter.position(1);
        assertEq(settlementReturn, 0);
        assertEq(uint256(settled.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.SettledOtm));
        assertEq(settled.collateralReturned, COLLATERAL);
        assertEq(adapter.adapterState().activePositionCount, 0);
        assertEq(adapter.adapterState().accountedWeth, COLLATERAL);
        assertEq(adapter.adapterState().accountedUsdc, PREMIUM);
        assertEq(weth.balanceOf(address(fund)), 0);

        vm.expectRevert(abi.encodeWithSelector(ICoveredCallFundAdapter.UnresolvedUsdc.selector, PREMIUM));
        strategyManager.deallocateInKind(adapter, 0.5e18, escrow);

        uint256 normalizedWeth = _expectedWeth(PREMIUM, 1_800e8);
        uint256 returned = strategyManager.deallocate(
            adapter,
            COLLATERAL + normalizedWeth,
            COLLATERAL + normalizedWeth,
            _normalizeData(PREMIUM, _policyMinimum(normalizedWeth))
        );

        assertEq(returned, COLLATERAL + normalizedWeth);
        assertEq(weth.balanceOf(address(fund)), returned);
        assertEq(usdc.balanceOf(address(fund)), 0);
        assertEq(adapter.adapterState().accountedWeth, 0);
        assertEq(adapter.adapterState().accountedUsdc, 0);
        assertEq(settler.vaultOTokenBalance(address(adapter), 1), 0);
        assertFalse(settler.physicalDeliveryReservedVault(address(adapter), 1));
    }

    function test_itmPhysicalDeliveryAccountsStrikeUsdcThenReturnsOnlyNormalizedWeth() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(2_200e8);
        oracle.setExpiryPrice(address(weth), expiry, 2_200e8);

        strategyManager.deallocate(adapter, 1, 0, _settleData());
        assertEq(
            uint256(adapter.position(1).lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.AwaitingPhysicalDelivery)
        );
        assertFalse(settler.physicalDeliveryReservedVault(address(adapter), 1));

        ICoveredCallFundValuator.ValuationData memory emptyData = ICoveredCallFundValuator.ValuationData({
            optionObservations: new ICoveredCallFundValuator.OptionObservation[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(ICoveredCallFundValuator.PendingPhysicalDelivery.selector, 1));
        valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));

        uint256 mmBeforeDelivery = usdc.balanceOf(mm);
        settler.operatorPhysicalRedeemVault(address(adapter), 1, 2_000e6);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        ICoveredCallFundAdapter.Position memory calledAway = adapter.position(1);
        assertEq(uint256(calledAway.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.CalledAway));
        assertEq(calledAway.calledAwayUsdc, 2_000e6);
        assertEq(usdc.balanceOf(mm) - mmBeforeDelivery, 200e6);
        assertEq(adapter.adapterState().accountedUsdc, PREMIUM + 2_000e6);
        assertEq(adapter.adapterState().accountedWeth, 0);

        FundTypes.PositionValue memory calledAwayValue =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        uint256 expectedWethValue = _expectedWeth(PREMIUM + 2_000e6, 2_200e8);
        assertEq(calledAwayValue.grossAssets, expectedWethValue);
        assertEq(calledAwayValue.liquidAccountingAssets, 0);
        assertEq(calledAwayValue.baseExitCost, Math.mulDiv(expectedWethValue, 100, 10_000, Math.Rounding.Ceil));

        uint256 returned = strategyManager.deallocate(
            adapter,
            expectedWethValue,
            expectedWethValue,
            _normalizeData(PREMIUM + 2_000e6, _policyMinimum(expectedWethValue))
        );
        assertEq(returned, expectedWethValue);
        assertEq(weth.balanceOf(address(fund)), expectedWethValue);
        assertEq(usdc.balanceOf(address(fund)), 0);
        assertEq(adapter.adapterState().accountedUsdc, 0);
    }

    function test_itmFallbackPaysIntrinsicInWethAndStillNormalizesPremium() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(2_200e8);
        oracle.setExpiryPrice(address(weth), expiry, 2_200e8);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        vm.warp(block.timestamp + _riskConfig().settlementDefaultDelay);
        spotFeed.setPrice(2_200e8);
        uint256 mmWethBefore = weth.balanceOf(mm);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        uint256 expectedMmPayout = Math.mulDiv(COLLATERAL, 2_200e8 - STRIKE, 2_200e8, Math.Rounding.Ceil);
        ICoveredCallFundAdapter.Position memory fallbackPosition = adapter.position(1);
        assertEq(uint256(fallbackPosition.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.CashFallback));
        assertEq(fallbackPosition.mmWethPayout, expectedMmPayout);
        assertEq(fallbackPosition.fallbackWethRecovered, COLLATERAL - expectedMmPayout);
        assertEq(weth.balanceOf(mm) - mmWethBefore, expectedMmPayout);
        assertEq(adapter.adapterState().accountedWeth, COLLATERAL - expectedMmPayout);
        assertEq(adapter.adapterState().accountedUsdc, PREMIUM);

        uint256 normalizedPremium = _expectedWeth(PREMIUM, 2_200e8);
        uint256 expectedReturn = COLLATERAL - expectedMmPayout + normalizedPremium;
        uint256 returned = strategyManager.deallocate(
            adapter, expectedReturn, expectedReturn, _normalizeData(PREMIUM, _policyMinimum(normalizedPremium))
        );
        assertEq(returned, expectedReturn);
        assertEq(usdc.balanceOf(address(fund)), 0);
        assertEq(weth.balanceOf(address(fund)), expectedReturn);
    }

    function test_calledAwayDeliveryIsolatesUnexpectedUsdcDonation() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(2_200e8);
        oracle.setExpiryPrice(address(weth), expiry, 2_200e8);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        usdc.mint(address(adapter), 5e6);
        settler.operatorPhysicalRedeemVault(address(adapter), 1, 2_000e6);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        assertEq(adapter.position(1).calledAwayUsdc, 2_000e6);
        assertEq(adapter.adapterState().accountedUsdc, PREMIUM + 2_000e6);
        assertEq(usdc.balanceOf(address(adapter)), PREMIUM + 2_005e6);
    }

    function testFuzz_rawDonationsNeverEnterAccountedBalances(uint96 wethDonation, uint96 usdcDonation) public {
        _open();
        ICoveredCallFundAdapter.AdapterState memory beforeState = adapter.adapterState();

        weth.mint(address(adapter), wethDonation);
        usdc.mint(address(adapter), usdcDonation);

        ICoveredCallFundAdapter.AdapterState memory afterState = adapter.adapterState();
        assertEq(afterState.stateNonce, beforeState.stateNonce);
        assertEq(afterState.positionsHash, beforeState.positionsHash);
        assertEq(afterState.activeCollateral, beforeState.activeCollateral);
        assertEq(afterState.accountedWeth, beforeState.accountedWeth);
        assertEq(afterState.accountedUsdc, beforeState.accountedUsdc);
        assertEq(adapter.freeAssets(address(weth)), 0);
        assertEq(adapter.freeAssets(address(usdc)), PREMIUM);
    }

    function test_normalizationFailsClosedOnStaleOracleAndWeakMinimum() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(1_800e8);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        uint256 expected = _expectedWeth(PREMIUM, 1_800e8);
        uint256 policyMinimum = _policyMinimum(expected);
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredCallFundAdapter.SlippageExceeded.selector, policyMinimum, policyMinimum - 1)
        );
        strategyManager.deallocate(adapter, 1, 0, _normalizeData(PREMIUM, policyMinimum - 1));

        uint256 staleTimestamp = block.timestamp - 1 hours - 1;
        vm.mockCall(
            address(spotFeed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1_800e8), staleTimestamp, staleTimestamp, uint80(1))
        );
        vm.expectRevert(abi.encodeWithSelector(Oracle.StaleOraclePrice.selector, staleTimestamp, uint256(1 hours)));
        strategyManager.deallocate(adapter, 1, 0, _normalizeData(PREMIUM, policyMinimum));
    }

    function testFuzz_normalizationRejectsEveryMinimumBelowPolicy(uint64 gapSeed) public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(1_800e8);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        uint256 policyMinimum = _policyMinimum(_expectedWeth(PREMIUM, 1_800e8));
        uint256 gap = bound(uint256(gapSeed), 1, policyMinimum);
        uint256 callerMinimum = policyMinimum - gap;
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredCallFundAdapter.SlippageExceeded.selector, policyMinimum, callerMinimum)
        );
        strategyManager.deallocate(adapter, 1, 0, _normalizeData(PREMIUM, callerMinimum));
    }

    function test_valuatorUsesWethUnitsQuorumAndDonationIsolation() public {
        _open();
        usdc.mint(address(adapter), 50e6);
        weth.mint(address(adapter), 2e18);
        uint64 snapshot = uint64(block.number);
        ICoveredCallFundValuator.OptionObservation[] memory observations =
            new ICoveredCallFundValuator.OptionObservation[](2);
        observations[0] = _observation(MM_KEY, snapshot, 0.1e18, 0.001e18, 1);
        observations[1] = _observation(OBSERVER_KEY, snapshot, 0.104e18, 0.00104e18, 2);
        ICoveredCallFundValuator.ValuationData memory valuationData =
            ICoveredCallFundValuator.ValuationData({optionObservations: observations});

        FundTypes.PositionValue memory value = valuator.value(address(adapter), snapshot, abi.encode(valuationData));
        uint256 premiumWeth = _expectedWeth(PREMIUM, 1_800e8);
        uint256 normalizationCost = Math.mulDiv(premiumWeth, 100, 10_000, Math.Rounding.Ceil);
        assertEq(value.grossAssets, COLLATERAL + premiumWeth);
        assertEq(value.liabilities, 0.102e18);
        assertEq(value.liquidAccountingAssets, 0);
        assertEq(value.baseExitCost, 0.00102e18 + normalizationCost);

        ICoveredCallFundValuator.ValuationData memory emptyData = ICoveredCallFundValuator.ValuationData({
            optionObservations: new ICoveredCallFundValuator.OptionObservation[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredCallFundValuator.InsufficientObservationQuorum.selector, 1, 2, 0)
        );
        valuator.value(address(adapter), snapshot, abi.encode(emptyData));
    }

    function test_valuatorV2RejectsWrongModelZeroSequenceAndDivergentMarks() public {
        _open();
        uint64 snapshot = uint64(block.number);
        ICoveredCallFundValuator.OptionObservation[] memory observations =
            new ICoveredCallFundValuator.OptionObservation[](2);

        observations[0] = _observationWithNonce(MM_KEY, snapshot, 0.1e18, 0.001e18, 1);
        observations[1] = _observation(OBSERVER_KEY, snapshot, 0.1e18, 0.001e18, 2);
        ICoveredCallFundValuator.ValuationData memory valuationData =
            ICoveredCallFundValuator.ValuationData({optionObservations: observations});
        vm.expectRevert(
            abi.encodeWithSelector(ICoveredCallFundValuator.InvalidModelVersion.selector, 1, uint64(1), uint64(0))
        );
        valuator.value(address(adapter), snapshot, abi.encode(valuationData));

        observations[0] = _observationWithNonce(MM_KEY, snapshot, 0.1e18, 0.001e18, MODEL_VERSION_PREFIX);
        observations[1] = _observation(OBSERVER_KEY, snapshot, 0.1e18, 0.001e18, 2);
        valuationData = ICoveredCallFundValuator.ValuationData({optionObservations: observations});
        vm.expectRevert(abi.encodeWithSelector(ICoveredCallFundValuator.InvalidObservation.selector, 1));
        valuator.value(address(adapter), snapshot, abi.encode(valuationData));

        observations[0] = _observation(MM_KEY, snapshot, 0.1e18, 0.001e18, 1);
        observations[1] = _observation(OBSERVER_KEY, snapshot, 0.11e18, 0.001e18, 2);
        valuationData = ICoveredCallFundValuator.ValuationData({optionObservations: observations});
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoveredCallFundValuator.ObservationDivergence.selector, 1, 0.1e18, 0.11e18, 0.105e18
            )
        );
        valuator.value(address(adapter), snapshot, abi.encode(valuationData));
    }

    function test_valuatorV2RejectsOneSidedTransactionalNavBuffer() public {
        address[] memory observers = new address[](2);
        observers[0] = mm;
        observers[1] = observer;
        vm.expectRevert(ICoveredCallFundValuator.InvalidFairValuePolicy.selector);
        new CoveredCallFundValuatorV2(address(spotFeed), 8, 1 hours, 10, 2, 1, observers);
    }

    function test_expiredOpenCallFailsClosedUntilOracleExpiryPriceExists() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(1_800e8);
        ICoveredCallFundValuator.ValuationData memory emptyData = ICoveredCallFundValuator.ValuationData({
            optionObservations: new ICoveredCallFundValuator.OptionObservation[](0)
        });

        vm.expectRevert(abi.encodeWithSelector(ICoveredCallFundValuator.ExpiryPriceUnavailable.selector, 1, expiry));
        valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
    }

    function test_expiredOtmOpenCallRetainsLockedCollateralAndNav() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(1_800e8);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);
        ICoveredCallFundValuator.ValuationData memory emptyData = ICoveredCallFundValuator.ValuationData({
            optionObservations: new ICoveredCallFundValuator.OptionObservation[](0)
        });

        FundTypes.PositionValue memory value =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        uint256 premiumWeth = _expectedWeth(PREMIUM, 1_800e8);
        uint256 nav = value.grossAssets - value.liabilities - value.baseExitCost;

        assertEq(value.grossAssets, COLLATERAL + premiumWeth);
        assertEq(value.liabilities, 0);
        assertGt(nav, COLLATERAL);
        assertGt(nav, 0.9e18);
    }

    function test_expiredItmOpenCallUsesIntrinsicWithoutTreatingCollateralAsLost() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(2_200e8);
        oracle.setExpiryPrice(address(weth), expiry, 2_200e8);
        ICoveredCallFundValuator.ValuationData memory emptyData = ICoveredCallFundValuator.ValuationData({
            optionObservations: new ICoveredCallFundValuator.OptionObservation[](0)
        });

        FundTypes.PositionValue memory value =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        uint256 premiumWeth = _expectedWeth(PREMIUM, 2_200e8);
        uint256 intrinsic = Math.mulDiv(OPTION_AMOUNT * 1e10, 2_200e8 - STRIKE, 2_200e8, Math.Rounding.Ceil);
        uint256 nav = value.grossAssets - value.liabilities - value.baseExitCost;
        uint256 sharePrice = Math.mulDiv(nav, 1e18, 1e18);

        assertEq(value.grossAssets, COLLATERAL + premiumWeth);
        assertEq(value.liabilities, intrinsic);
        assertLt(value.liabilities, COLLATERAL);
        assertGt(nav, 0.9e18);
        assertEq(sharePrice, nav);
    }

    function test_inKindIsWethOnlyAndEmergencyQuarantinesTransientUsdc() public {
        _open();
        vm.warp(expiry + 1);
        spotFeed.setPrice(1_800e8);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        vm.expectRevert(abi.encodeWithSelector(ICoveredCallFundAdapter.UnresolvedUsdc.selector, PREMIUM));
        strategyManager.deallocateInKind(adapter, 0.5e18, escrow);

        (address[] memory assets, uint256[] memory amounts) = strategyManager.emergencyExit(adapter, escrow);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth));
        assertEq(assets[1], address(usdc));
        assertEq(amounts[0], COLLATERAL);
        assertEq(amounts[1], PREMIUM);
        assertEq(weth.balanceOf(escrow), COLLATERAL);
        assertEq(usdc.balanceOf(escrow), PREMIUM);
        assertEq(usdc.balanceOf(address(fund)), 0);
    }

    function _open() private {
        settler.setPhysicalDeliveryVault(address(adapter), true);
        (ICoveredCallFundAdapter.OpenPositionData memory openData,) = _openData();
        strategyManager.allocate(adapter, address(weth), COLLATERAL, abi.encode(openData));
    }

    function _openData() private returns (ICoveredCallFundAdapter.OpenPositionData memory openData, address oToken) {
        oToken = factory.createOToken(address(weth), address(usdc), address(weth), STRIKE, expiry, false);
        BatchSettler.Quote memory quote = _quote(oToken);
        openData = ICoveredCallFundAdapter.OpenPositionData({
            quote: quote, signature: _signQuote(quote), optionAmount: OPTION_AMOUNT, collateral: COLLATERAL
        });
    }

    function _quote(address oToken) private returns (BatchSettler.Quote memory quote) {
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: PREMIUM,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: OPTION_AMOUNT,
            makerNonce: settler.makerNonce(mm)
        });
    }

    function _signQuote(BatchSettler.Quote memory quote) private view returns (bytes memory) {
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _observation(uint256 signerKey, uint64 snapshot, uint256 liability, uint256 exitCost, uint256 nonce)
        private
        returns (ICoveredCallFundValuator.OptionObservation memory observation)
    {
        return _observationWithNonce(signerKey, snapshot, liability, exitCost, MODEL_VERSION_PREFIX | nonce);
    }

    function _observationWithNonce(
        uint256 signerKey,
        uint64 snapshot,
        uint256 liability,
        uint256 exitCost,
        uint256 nonce
    ) private returns (ICoveredCallFundValuator.OptionObservation memory observation) {
        uint64 validUntil = snapshot + 5;
        bytes32 digest =
            valuator.observationDigest(address(adapter), 1, snapshot, validUntil, liability, exitCost, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        observation = ICoveredCallFundValuator.OptionObservation({
            positionId: 1,
            snapshotBlock: snapshot,
            validUntilBlock: validUntil,
            liability: liability,
            baseExitCost: exitCost,
            nonce: nonce,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _settleData() private pure returns (bytes memory) {
        return abi.encode(
            ICoveredCallFundAdapter.DeallocateData({
                action: ICoveredCallFundAdapter.DeallocateAction.Settle, positionId: 1, amount: 0, minAmountOut: 0
            })
        );
    }

    function _normalizeData(uint256 usdcAmount, uint256 minimumWethOut) private pure returns (bytes memory) {
        return abi.encode(
            ICoveredCallFundAdapter.DeallocateData({
                action: ICoveredCallFundAdapter.DeallocateAction.NormalizeUsdc,
                positionId: 0,
                amount: usdcAmount,
                minAmountOut: minimumWethOut
            })
        );
    }

    function _riskConfig() private pure returns (ICoveredCallFundAdapter.RiskConfig memory) {
        return ICoveredCallFundAdapter.RiskConfig({
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 2 days,
            settlementDefaultDelay: 6 hours,
            minPremiumBps: 100,
            maxSwapSlippageBps: 100,
            maxOpenPositions: 1,
            maxUtilizationBps: 9_000,
            minStrike: 1_000e8,
            maxStrike: 4_000e8,
            maxCollateralPerPosition: 2e18,
            maxUsdcPerSwap: 10_000e6
        });
    }

    function _expectedWeth(uint256 usdcAmount, uint256 price) private pure returns (uint256) {
        return Math.mulDiv(usdcAmount, 1e20, price);
    }

    function _policyMinimum(uint256 expectedWeth) private pure returns (uint256) {
        return Math.mulDiv(expectedWeth, 9_900, 10_000);
    }

    function _nextEightAm() private view returns (uint256) {
        uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
        uint256 todayEightAm = dayStart + 8 hours;
        return todayEightAm > block.timestamp ? todayEightAm : todayEightAm + 1 days;
    }

    function _proxy(address implementation, bytes memory initData) private returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }
}
