// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {MarginPool} from "../../src/core/MarginPool.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {Whitelist} from "../../src/core/Whitelist.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {ICspFundValuator} from "../../src/fund/interfaces/ICspFundValuator.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";

contract CspFundReceiver {}

contract CspStrategyManagerCaller {
    function allocate(CspFundAdapter adapter, address asset, uint256 amount, bytes calldata data) external {
        IERC20(asset).transfer(address(adapter), amount);
        adapter.allocate(asset, amount, data);
    }

    function deallocate(CspFundAdapter adapter, uint256 targetValue, uint256 minimumOut, bytes calldata data)
        external
        returns (uint256)
    {
        (uint256 accountingAssetsOut,) = adapter.deallocate(targetValue, minimumOut, data);
        return accountingAssetsOut;
    }

    function deallocateInKind(CspFundAdapter adapter, uint256 fractionWad, address escrow)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        return adapter.deallocateInKind(fractionWad, escrow, "");
    }

    function emergencyExit(CspFundAdapter adapter, address escrow)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        return adapter.emergencyExit(escrow, "");
    }
}

contract CspFundValuatorV2Test is Test {
    uint256 private constant STRIKE = 2_000e8;
    uint256 private constant OPTION_AMOUNT = 1e8;
    uint256 private constant COLLATERAL = 2_000e6;
    uint256 private constant PREMIUM = 70e6;
    uint256 private constant MM_KEY = 0xAA01;
    uint256 private constant OBSERVER_KEY = 0xBEEF;
    uint256 private constant MODEL_VERSION_PREFIX = uint256(1) << 192;

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
    CspFundReceiver private fund;
    CspStrategyManagerCaller private strategyManager;
    CspFundAdapter private adapter;
    CspFundAdapter private adapterImplementation;
    CspFundValuatorV2 private valuator;

    address private mm;
    address private observer;
    address private escrow = address(0xE5C0);
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
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        fund = new CspFundReceiver();
        strategyManager = new CspStrategyManagerCaller();
        AccessManager adapterAuthority = new AccessManager(address(this));
        adapterImplementation = new CspFundAdapter();
        adapter = CspFundAdapter(
            _proxy(
                address(adapterImplementation),
                abi.encodeCall(
                    CspFundAdapter.initialize,
                    (CspFundAdapter.InitializeParams({
                            fund: address(fund),
                            strategyManager: address(strategyManager),
                            addressBook: address(addressBook),
                            accountingAsset: address(usdc),
                            weth: address(weth),
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
        valuator = new CspFundValuatorV2(address(spotFeed), 8, 1 hours, 10, 2, observers);
        assertEq(valuator.liabilityBufferBps(), 0);

        expiry = _nextEightAm();
        usdc.mint(address(strategyManager), 20_000e6);
        usdc.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);
    }

    function test_requiresOnchainPhysicalDeliveryAuthorizationBeforeOpening() public {
        (ICspFundAdapter.OpenPositionData memory openData,) = _openData();
        bytes memory allocationData = abi.encode(openData);

        assertFalse(adapter.isOnboarded());
        vm.expectRevert(ICspFundAdapter.AdapterNotOnboarded.selector);
        strategyManager.allocate(adapter, address(usdc), COLLATERAL, allocationData);

        settler.setPhysicalDeliveryVault(address(adapter), true);
        assertTrue(adapter.isOnboarded());
        strategyManager.allocate(adapter, address(usdc), COLLATERAL, allocationData);

        ICspFundAdapter.Position memory opened = adapter.position(1);
        assertEq(adapter.adapterState().positionCount, 1);
        assertEq(adapter.adapterState().activePositionCount, 1);
        assertEq(opened.protocolVaultId, 1);
        assertEq(opened.marketMaker, mm);
        assertEq(opened.premiumEarned, PREMIUM);
        assertEq(uint256(opened.lifecycle), uint256(ICspFundAdapter.Lifecycle.Open));
        assertEq(adapter.adapterState().accountedUsdc, PREMIUM);
        assertEq(usdc.balanceOf(address(pool)), COLLATERAL);
        assertTrue(settler.physicalDeliveryReservedVault(address(adapter), 1));
        assertEq(settler.vaultOTokenBalance(address(adapter), 1), OPTION_AMOUNT);
        assertEq(adapter.adapterState().stateNonce, 1);
    }

    function test_onlyStrategyManagerCanMoveAssets() public {
        settler.setPhysicalDeliveryVault(address(adapter), true);
        (ICspFundAdapter.OpenPositionData memory openData,) = _openData();
        usdc.mint(address(adapter), COLLATERAL);

        vm.expectRevert(ICspFundAdapter.OnlyStrategyManager.selector);
        adapter.allocate(address(usdc), COLLATERAL, abi.encode(openData));

        vm.expectRevert(ICspFundAdapter.OnlyStrategyManager.selector);
        adapter.deallocate(
            1,
            0,
            abi.encode(
                ICspFundAdapter.DeallocateData({
                    action: ICspFundAdapter.DeallocateAction.ReturnIdle, positionId: 0, amount: 0, minAmountOut: 0
                })
            )
        );

        vm.expectRevert(ICspFundAdapter.OnlyStrategyManager.selector);
        adapter.emergencyExit(escrow, "");
    }

    function test_otmSettlementReturnsCollateralAndClearsV1Ledgers() public {
        _authorizeAndOpen();
        vm.warp(expiry + 1);
        spotFeed.setPrice(2_100e8);
        oracle.setExpiryPrice(address(weth), expiry, 2_100e8);

        uint256 returned = strategyManager.deallocate(adapter, COLLATERAL + PREMIUM, 0, _settleData());

        ICspFundAdapter.Position memory settled = adapter.position(1);
        assertEq(returned, COLLATERAL + PREMIUM);
        assertEq(uint256(settled.lifecycle), uint256(ICspFundAdapter.Lifecycle.SettledOtm));
        assertEq(settled.collateralReturned, COLLATERAL);
        assertEq(adapter.adapterState().activePositionCount, 0);
        assertEq(adapter.adapterState().accountedUsdc, 0);
        assertEq(usdc.balanceOf(address(fund)), COLLATERAL + PREMIUM);
        assertEq(settler.vaultOTokenBalance(address(adapter), 1), 0);
        assertFalse(settler.physicalDeliveryReservedVault(address(adapter), 1));
        assertEq(adapter.adapterState().stateNonce, 2);
    }

    function test_itmPhysicalDeliveryBecomesCollectiveWethThenSwapsBackToUsdc() public {
        _authorizeAndOpen();
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);

        strategyManager.deallocate(adapter, 1, 0, _settleData());
        assertEq(uint256(adapter.position(1).lifecycle), uint256(ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery));
        assertFalse(settler.physicalDeliveryReservedVault(address(adapter), 1));

        ICspFundValuator.ValuationData memory emptyData =
            ICspFundValuator.ValuationData({optionObservations: new ICspFundValuator.OptionObservation[](0)});
        FundTypes.PositionValue memory pendingValue =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        assertEq(pendingValue.grossAssets, PREMIUM - 1 + 1_800e6);
        assertEq(pendingValue.liabilities, 0);
        assertEq(pendingValue.baseExitCost, 18e6);

        settler.operatorPhysicalRedeemVault(address(adapter), 1, COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(ICspFundValuator.LedgerMismatch.selector, 1));
        valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        ICspFundAdapter.Position memory assigned = adapter.position(1);
        assertEq(uint256(assigned.lifecycle), uint256(ICspFundAdapter.Lifecycle.Assigned));
        assertEq(assigned.assignedWeth, 1e18);
        assertEq(adapter.adapterState().accountedWeth, 1e18);
        assertEq(weth.balanceOf(address(adapter)), 1e18);
        assertEq(weth.balanceOf(address(fund)), 0);

        FundTypes.PositionValue memory assignedValue =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        uint256 assignedUsdc = adapter.adapterState().accountedUsdc;
        assertEq(assignedValue.grossAssets, assignedUsdc + 1_800e6);
        assertEq(assignedValue.liabilities, 0);
        assertEq(assignedValue.liquidAccountingAssets, assignedUsdc);
        assertEq(assignedValue.baseExitCost, 18e6);

        uint256 returned = strategyManager.deallocate(
            adapter,
            COLLATERAL - 2,
            1_782e6,
            abi.encode(
                ICspFundAdapter.DeallocateData({
                    action: ICspFundAdapter.DeallocateAction.SwapAssignedWeth,
                    positionId: 1,
                    amount: 1e18,
                    minAmountOut: 1_782e6
                })
            )
        );

        assertEq(returned, PREMIUM - 2 + 1_800e6);
        assertEq(adapter.adapterState().accountedWeth, 0);
        assertEq(adapter.adapterState().accountedUsdc, 0);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(fund)), PREMIUM + 1_800e6);
        assertEq(adapter.adapterState().stateNonce, 4);
    }

    function test_itmCashFallbackPaysIntrinsicToMmWithoutWeth() public {
        _authorizeAndOpen();
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);
        uint256 mmBalanceAfterPremium = usdc.balanceOf(mm);

        strategyManager.deallocate(adapter, 1, 0, _settleData());
        vm.warp(block.timestamp + _riskConfig().settlementDefaultDelay);
        uint256 returned = strategyManager.deallocate(adapter, PREMIUM - 1 + 1_800e6, 0, _settleData());

        ICspFundAdapter.Position memory fallbackPosition = adapter.position(1);
        assertEq(uint256(fallbackPosition.lifecycle), uint256(ICspFundAdapter.Lifecycle.CashFallback));
        assertEq(returned, PREMIUM - 1 + 1_800e6);
        assertEq(usdc.balanceOf(mm) - mmBalanceAfterPremium, 200e6);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(adapter.adapterState().accountedUsdc, 0);
        assertEq(settler.vaultOTokenBalance(address(adapter), 1), 0);
    }

    function test_pendingPhysicalDeliveryCapsHighLiveSpotAtFallbackRecovery() public {
        _authorizeAndOpen();
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);

        strategyManager.deallocate(adapter, 1, 0, _settleData());
        spotFeed.setPrice(3_000e8);

        ICspFundValuator.ValuationData memory emptyData =
            ICspFundValuator.ValuationData({optionObservations: new ICspFundValuator.OptionObservation[](0)});
        FundTypes.PositionValue memory pendingValue =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));

        assertEq(uint256(adapter.position(1).lifecycle), uint256(ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery));
        assertEq(pendingValue.grossAssets, PREMIUM - 1 + 1_800e6);
        assertEq(pendingValue.liabilities, 0);
        assertEq(pendingValue.baseExitCost, 18e6);
    }

    function test_physicalDeliveryIsolatesUnexpectedWethDonation() public {
        _authorizeAndOpen();
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);

        strategyManager.deallocate(adapter, 1, 0, _settleData());
        weth.mint(address(adapter), 1);
        settler.operatorPhysicalRedeemVault(address(adapter), 1, COLLATERAL);
        strategyManager.deallocate(adapter, 1, 0, _settleData());

        ICspFundAdapter.Position memory assigned = adapter.position(1);
        assertEq(uint256(assigned.lifecycle), uint256(ICspFundAdapter.Lifecycle.Assigned));
        assertEq(assigned.assignedWeth, 1e18);
        assertEq(adapter.adapterState().accountedWeth, 1e18);
        assertEq(weth.balanceOf(address(adapter)), 1e18 + 1);

        ICspFundValuator.ValuationData memory emptyData =
            ICspFundValuator.ValuationData({optionObservations: new ICspFundValuator.OptionObservation[](0)});
        FundTypes.PositionValue memory value =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        assertEq(value.grossAssets, adapter.adapterState().accountedUsdc + 1_800e6);
    }

    function test_valuatorUsesFairMidpointAndSnapshotBinding() public {
        _authorizeAndOpen();
        uint64 snapshot = uint64(block.number);
        ICspFundValuator.OptionObservation[] memory observations = new ICspFundValuator.OptionObservation[](2);
        observations[0] = _observation(MM_KEY, snapshot, 100e6, 1e6, 1);
        observations[1] = _observation(OBSERVER_KEY, snapshot, 104e6, 1e6, 2);
        ICspFundValuator.ValuationData memory valuationData =
            ICspFundValuator.ValuationData({optionObservations: observations});

        FundTypes.PositionValue memory value = valuator.value(address(adapter), snapshot, abi.encode(valuationData));

        assertEq(value.grossAssets, COLLATERAL + PREMIUM);
        assertEq(value.liabilities, 102e6);
        assertEq(value.liquidAccountingAssets, PREMIUM);
        assertEq(value.baseExitCost, 1e6);
        assertNotEq(value.dataHash, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(ICspFundValuator.InvalidSnapshotBlock.selector, snapshot, snapshot - 1));
        valuator.value(address(adapter), snapshot - 1, abi.encode(valuationData));

        ICspFundValuator.ValuationData memory emptyData =
            ICspFundValuator.ValuationData({optionObservations: new ICspFundValuator.OptionObservation[](0)});
        vm.expectRevert(abi.encodeWithSelector(ICspFundValuator.InsufficientObservationQuorum.selector, 1, 2, 0));
        valuator.value(address(adapter), snapshot, abi.encode(emptyData));

        uint256 staleTimestamp = block.timestamp - 1 hours - 1;
        vm.mockCall(
            address(spotFeed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(1_800e8), staleTimestamp, staleTimestamp, uint80(1))
        );
        vm.expectRevert(ICspFundValuator.InvalidSpotObservation.selector);
        valuator.value(address(adapter), snapshot, abi.encode(valuationData));
    }

    function test_valuatorRejectsStressMarksDivergenceAndWrongModelVersion() public {
        _authorizeAndOpen();
        uint64 snapshot = uint64(block.number);
        ICspFundValuator.OptionObservation[] memory observations = new ICspFundValuator.OptionObservation[](2);
        observations[0] = _observation(MM_KEY, snapshot, 100e6, 1e6, 1);
        observations[1] = _observation(OBSERVER_KEY, snapshot, COLLATERAL, 1e6, 2);
        ICspFundValuator.ValuationData memory valuationData =
            ICspFundValuator.ValuationData({optionObservations: observations});
        vm.expectRevert(
            abi.encodeWithSelector(ICspFundValuator.ObservationDivergence.selector, 1, 100e6, COLLATERAL, 1_050e6)
        );
        valuator.value(address(adapter), snapshot, abi.encode(valuationData));

        observations[0] = _observationWithNonce(MM_KEY, snapshot, 100e6, 1e6, 1);
        observations[1] = _observation(OBSERVER_KEY, snapshot, 100e6, 1e6, 2);
        valuationData = ICspFundValuator.ValuationData({optionObservations: observations});
        vm.expectRevert(abi.encodeWithSelector(ICspFundValuator.InvalidModelVersion.selector, 1, 1, 0));
        valuator.value(address(adapter), snapshot, abi.encode(valuationData));
    }

    function test_expiredOpenPutFailsClosedUntilAuthoritativeExpiryPriceRegardlessOfSpotMovement() public {
        _authorizeAndOpen();
        vm.warp(expiry + 1);
        ICspFundValuator.ValuationData memory emptyData =
            ICspFundValuator.ValuationData({optionObservations: new ICspFundValuator.OptionObservation[](0)});

        vm.expectRevert(abi.encodeWithSelector(ICspFundValuator.ExpiryPriceUnavailable.selector, 1, expiry));
        valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));

        spotFeed.setPrice(2_100e8);
        vm.expectRevert(abi.encodeWithSelector(ICspFundValuator.ExpiryPriceUnavailable.selector, 1, expiry));
        valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));

        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);
        FundTypes.PositionValue memory finalized =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        assertEq(finalized.grossAssets, COLLATERAL + PREMIUM);
        assertEq(finalized.liabilities, 200e6);
    }

    function test_expiredOtmOpenPutHasZeroLiability() public {
        _authorizeAndOpen();
        vm.warp(expiry + 1);
        spotFeed.setPrice(2_100e8);
        oracle.setExpiryPrice(address(weth), expiry, 2_100e8);
        ICspFundValuator.ValuationData memory emptyData =
            ICspFundValuator.ValuationData({optionObservations: new ICspFundValuator.OptionObservation[](0)});
        FundTypes.PositionValue memory otm =
            valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));
        assertEq(otm.grossAssets, COLLATERAL + PREMIUM);
        assertEq(otm.liabilities, 0);
    }

    function test_fairMarkKeepsLockedCollateralInNavForSharePricing() public {
        settler.setPhysicalDeliveryVault(address(adapter), true);
        uint256 optionAmount = 0.4e8;
        uint256 lockedCollateral = 800e6;
        (ICspFundAdapter.OpenPositionData memory openData,) = _openDataFor(optionAmount, lockedCollateral, 75e6);
        strategyManager.allocate(adapter, address(usdc), lockedCollateral, abi.encode(openData));
        uint64 snapshot = uint64(block.number);
        ICspFundValuator.OptionObservation[] memory observations = new ICspFundValuator.OptionObservation[](2);
        observations[0] = _observation(MM_KEY, snapshot, 30e6, 0, 1);
        observations[1] = _observation(OBSERVER_KEY, snapshot, 30e6, 0, 2);
        ICspFundValuator.ValuationData memory valuationData =
            ICspFundValuator.ValuationData({optionObservations: observations});

        FundTypes.PositionValue memory value = valuator.value(address(adapter), snapshot, abi.encode(valuationData));
        uint256 idleFundAssets = 200e6;
        uint256 nav = idleFundAssets + value.grossAssets - value.liabilities;
        uint256 existingShares = 1_000e18;
        uint256 depositAssets = 200e6;
        uint256 previewShares = depositAssets * existingShares / nav;

        assertEq(value.grossAssets, lockedCollateral + 30e6);
        assertEq(value.liabilities, 30e6);
        assertEq(nav, 1_000e6);
        assertEq(previewShares, 200e18);
        assertNotEq(previewShares, 1_000e18);
    }

    function test_valuatorAndImplementationFailClosedBeforeActivation() public {
        ICspFundValuator.ValuationData memory emptyData =
            ICspFundValuator.ValuationData({optionObservations: new ICspFundValuator.OptionObservation[](0)});
        vm.expectRevert(abi.encodeWithSelector(ICspFundValuator.InvalidAdapter.selector, address(adapter)));
        valuator.value(address(adapter), uint64(block.number), abi.encode(emptyData));

        AccessManager unusedAuthority = new AccessManager(address(this));
        vm.expectRevert();
        adapterImplementation.initialize(
            CspFundAdapter.InitializeParams({
                fund: address(fund),
                strategyManager: address(strategyManager),
                addressBook: address(addressBook),
                accountingAsset: address(usdc),
                weth: address(weth),
                swapRouter: address(swapRouter),
                swapFeeTier: 500,
                authority: address(unusedAuthority),
                riskConfig: _riskConfig()
            })
        );
    }

    function test_inKindAndEmergencyRecoveryExposeOnlyAccountedUsdcAndWeth() public {
        _authorizeAndOpen();
        MockERC20 unrelated = new MockERC20("Unrelated", "NOPE", 18);
        unrelated.mint(address(adapter), 10e18);

        vm.expectRevert(ICspFundAdapter.InvalidRiskConfig.selector);
        strategyManager.deallocateInKind(adapter, 0.5e18, escrow);
        vm.expectRevert(ICspFundAdapter.InvalidRiskConfig.selector);
        strategyManager.emergencyExit(adapter, escrow);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1_800e8);
        strategyManager.deallocate(adapter, 1, 0, _settleData());
        settler.operatorPhysicalRedeemVault(address(adapter), 1, COLLATERAL);
        strategyManager.deallocate(adapter, 1, 0, _settleData());
        uint256 assignedUsdc = adapter.adapterState().accountedUsdc;

        (address[] memory assets, uint256[] memory amounts) = strategyManager.deallocateInKind(adapter, 0.5e18, escrow);
        assertEq(assets.length, 2);
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(weth));
        assertEq(amounts[0], assignedUsdc / 2);
        assertEq(amounts[1], 0.5e18);
        assertEq(usdc.balanceOf(escrow), assignedUsdc / 2);
        assertEq(weth.balanceOf(escrow), 0.5e18);

        (assets, amounts) = strategyManager.emergencyExit(adapter, escrow);
        assertEq(assets.length, 2);
        assertEq(amounts[0], assignedUsdc - assignedUsdc / 2);
        assertEq(amounts[1], 0.5e18);
        assertEq(usdc.balanceOf(escrow), assignedUsdc);
        assertEq(weth.balanceOf(escrow), 1e18);
        assertEq(unrelated.balanceOf(address(adapter)), 10e18);
    }

    function _authorizeAndOpen() private {
        settler.setPhysicalDeliveryVault(address(adapter), true);
        (ICspFundAdapter.OpenPositionData memory openData,) = _openData();
        strategyManager.allocate(adapter, address(usdc), COLLATERAL, abi.encode(openData));
    }

    function _openData() private returns (ICspFundAdapter.OpenPositionData memory openData, address oToken) {
        return _openDataFor(OPTION_AMOUNT, COLLATERAL, PREMIUM);
    }

    function _openDataFor(uint256 optionAmount, uint256 collateral, uint256 bidPrice)
        private
        returns (ICspFundAdapter.OpenPositionData memory openData, address oToken)
    {
        oToken = factory.createOToken(address(weth), address(usdc), address(usdc), STRIKE, expiry, true);
        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: optionAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, digest);
        openData = ICspFundAdapter.OpenPositionData({
            quote: quote, signature: abi.encodePacked(r, s, v), optionAmount: optionAmount, collateral: collateral
        });
    }

    function _observation(uint256 signerKey, uint64 snapshot, uint256 liability, uint256 exitCost, uint256 nonce)
        private
        returns (ICspFundValuator.OptionObservation memory observation)
    {
        return _observationWithNonce(signerKey, snapshot, liability, exitCost, MODEL_VERSION_PREFIX | nonce);
    }

    function _observationWithNonce(
        uint256 signerKey,
        uint64 snapshot,
        uint256 liability,
        uint256 exitCost,
        uint256 nonce
    ) private returns (ICspFundValuator.OptionObservation memory observation) {
        uint64 validUntil = snapshot + 5;
        bytes32 digest =
            valuator.observationDigest(address(adapter), 1, snapshot, validUntil, liability, exitCost, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        observation = ICspFundValuator.OptionObservation({
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
            ICspFundAdapter.DeallocateData({
                action: ICspFundAdapter.DeallocateAction.Settle, positionId: 1, amount: 0, minAmountOut: 0
            })
        );
    }

    function _riskConfig() private pure returns (ICspFundAdapter.RiskConfig memory) {
        return ICspFundAdapter.RiskConfig({
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 2 days,
            settlementDefaultDelay: 6 hours,
            minPremiumBps: 100,
            maxSwapSlippageBps: 100,
            maxOpenPositions: 4,
            minStrike: 1_000e8,
            maxStrike: 4_000e8,
            maxCollateralPerPosition: 10_000e6,
            maxWethPerSwap: 5e18
        });
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
