// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {
    AssetNeutralWheelChildLaneV2,
    AssetNeutralCspWheelChildLaneV2,
    AssetNeutralCoveredCallWheelChildLaneV2,
    AssetNeutralMetaWheelCoordinatorV2
} from "../../src/fund/AssetNeutralMetaWheelV2.sol";
import {
    AssetNeutralOptionsFundAdapterV2,
    AssetNeutralCspFundAdapterV2,
    AssetNeutralCoveredCallFundAdapterV2
} from "../../src/fund/AssetNeutralOptionsFundAdapterV2.sol";
import {
    AssetNeutralCspFundValuatorV2,
    AssetNeutralCoveredCallFundValuatorV2
} from "../../src/fund/AssetNeutralOptionsFundValuatorV2.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";
import {IAssetNeutralWheelV2 as IWheel} from "../../src/fund/interfaces/IAssetNeutralWheelV2.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {WheelManagedOperationDispatcher} from "../../src/fund/libraries/WheelManagedOperationDispatcher.sol";

contract B1N444Code {
    address public strategyManager;
    address public asset;
    address public fund;

    function configureFund(address manager_, address asset_) external {
        strategyManager = manager_;
        asset = asset_;
    }

    function configureManager(address fund_) external {
        fund = fund_;
    }
}

contract B1N444CspLaneHarness is AssetNeutralCspWheelChildLaneV2 {
    function slot() external pure returns (bytes32) {
        return _storageLocation();
    }

    function marker() external pure returns (bytes32) {
        return keccak256("B1N444_CSP_UPGRADE");
    }
}

contract B1N444CallLaneHarness is AssetNeutralCoveredCallWheelChildLaneV2 {
    function slot() external pure returns (bytes32) {
        return _storageLocation();
    }

    function marker() external pure returns (bytes32) {
        return keccak256("B1N444_CALL_UPGRADE");
    }
}

contract B1N444CspAdapterHarness is AssetNeutralCspFundAdapterV2 {
    function slot() external pure returns (bytes32) {
        return _storageLocation();
    }
}

contract B1N444CallAdapterHarness is AssetNeutralCoveredCallFundAdapterV2 {
    function slot() external pure returns (bytes32) {
        return _storageLocation();
    }
}

contract B1N444TerminalTransferAdapter {
    MockERC20 public immutable settlement;
    MockERC20 public immutable underlying;
    uint256 public settlementOut;
    uint256 public underlyingOut;
    IAdapter.PositionV2 private position;

    constructor(MockERC20 settlement_, MockERC20 underlying_) {
        settlement = settlement_;
        underlying = underlying_;
        position.strategyKind = IAdapter.StrategyKind.Csp;
        position.lifecycle = IAdapter.Lifecycle.Open;
        position.protocolVaultId = 1;
        position.collateralAmount = 1;
    }

    function configure(uint256 settlementAmount, uint256 underlyingAmount, IAdapter.Lifecycle terminal) external {
        settlementOut = settlementAmount;
        underlyingOut = underlyingAmount;
        position.lifecycle = terminal;
    }

    function deallocate(uint256, uint256, bytes calldata) external returns (uint256, uint256) {
        if (settlementOut != 0) settlement.transfer(msg.sender, settlementOut);
        return (settlementOut, 1);
    }

    function deallocateInKind(uint256, address escrow, bytes calldata)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](2);
        amounts = new uint256[](2);
        assets[0] = address(settlement);
        assets[1] = address(underlying);
        amounts[1] = underlyingOut;
        if (underlyingOut != 0) underlying.transfer(escrow, underlyingOut);
    }

    function positionV2(uint256) external view returns (IAdapter.PositionV2 memory) {
        return position;
    }

    function positionStateHash() external view returns (bytes32) {
        return keccak256(abi.encode(position.lifecycle, settlementOut, underlyingOut));
    }
}

contract B1N444SettlementLaneHarness is AssetNeutralCspWheelChildLaneV2 {
    function prime(address adapter_, uint256 trancheId, uint256 positionId, uint256 shares_) external {
        Layout storage $ = _layout();
        $.adapter = adapter_;
        $.state = LaneState.Open;
        $.activeTrancheId = trancheId;
        $.activePositionId = positionId;
        $.shares = shares_;
    }
}

contract B1N444CoordinatorUpgrade is AssetNeutralMetaWheelCoordinatorV2 {
    function marker() external pure returns (bytes32) {
        return keccak256("B1N444_COORDINATOR_UPGRADE");
    }
}

contract B1N444AssetNeutralMetaWheelSecurityTest is Test {
    bytes32 constant POLICY = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;
    uint256 constant BUFFER = 1e8;
    bytes32 constant ERC1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockERC20 lbtc;
    MockERC20 usdc;
    MockChainlinkFeed feed;
    MockSwapRouter router;
    AccessManager authority;
    B1N444Code fundGraph;
    B1N444Code managerGraph;
    B1N444Code book;
    AssetNeutralMetaWheelCoordinatorV2 wheel;

    function setUp() public {
        vm.chainId(84532);
        lbtc = new MockERC20("Loot BTC", "LBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        feed = new MockChainlinkFeed(50_000e8);
        router = new MockSwapRouter(address(usdc));
        authority = new AccessManager(address(this));
        fundGraph = new B1N444Code();
        managerGraph = new B1N444Code();
        book = new B1N444Code();
        fundGraph.configureFund(address(managerGraph), address(usdc));
        managerGraph.configureManager(address(fundGraph));
        wheel = _coordinator(address(fundGraph), address(managerGraph));
    }

    function test_actualLanesTwoPhaseBindReciprocalAndCannotOpenRegisterOrRebindBeforeBinding() public {
        (AssetNeutralCspWheelChildLaneV2 lane, AssetNeutralCspFundAdapterV2 adapter) = _cspPair();
        assertEq(lane.adapter(), address(adapter));
        assertEq(adapter.fund(), address(lane));
        assertEq(adapter.strategyManager(), address(lane));
        assertEq(adapter.underlyingAsset(), address(lbtc));
        assertEq(adapter.settlementAsset(), address(usdc));

        (AssetNeutralCoveredCallWheelChildLaneV2 callLane, AssetNeutralCoveredCallFundAdapterV2 callAdapter) =
            _callPair();
        assertEq(callLane.adapter(), address(callAdapter));
        assertEq(callAdapter.fund(), address(callLane));
        assertEq(callAdapter.strategyManager(), address(callLane));
        assertEq(callAdapter.underlyingAsset(), address(lbtc));
        assertEq(callAdapter.settlementAsset(), address(usdc));
        vm.expectRevert(AssetNeutralWheelChildLaneV2.InvalidAddress.selector);
        callLane.bindAdapter(address(callAdapter));

        vm.expectRevert(AssetNeutralWheelChildLaneV2.InvalidAddress.selector);
        lane.bindAdapter(address(adapter));

        AssetNeutralCspWheelChildLaneV2 unbound = _cspLane();
        vm.expectRevert(AssetNeutralWheelChildLaneV2.InvalidLaneState.selector);
        vm.prank(address(wheel));
        unbound.open(1, bytes32(uint256(1)), 0, 0, 1, "");
        vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidLane.selector);
        _managed(WheelTypes.ManagedOperation.RegisterLane, abi.encode(address(unbound), WheelTypes.LaneKind.Csp));
    }

    function test_twoDistinctSameKindActualLanesAndExactValuatorsAcceptedSwappedOrMissingFails() public {
        (AssetNeutralCspWheelChildLaneV2 lane1, AssetNeutralCspFundAdapterV2 adapter1) = _cspPair();
        (AssetNeutralCspWheelChildLaneV2 lane2, AssetNeutralCspFundAdapterV2 adapter2) = _cspPair();
        _register(address(lane1), WheelTypes.LaneKind.Csp);
        _register(address(lane2), WheelTypes.LaneKind.Csp);
        assertEq(wheel.registeredLaneCount(), 2);

        AssetNeutralCspFundValuatorV2 v1 = _cspValuator(address(adapter1), address(lane1));
        AssetNeutralCspFundValuatorV2 v2 = _cspValuator(address(adapter2), address(lane2));
        vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidLane.selector);
        _setValuator(address(lane1), address(v2));
        vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidLane.selector);
        _managed(WheelTypes.ManagedOperation.ResumeAllocations, "");
        _setValuator(address(lane1), address(v1));
        _setValuator(address(lane2), address(v2));
        _managed(WheelTypes.ManagedOperation.ResumeAllocations, "");
        assertFalse(wheel.allocationsPaused());
        assertEq(wheel.laneValuator(address(lane1)), address(v1));
        assertEq(wheel.laneValuator(address(lane2)), address(v2));
    }

    function test_uupsLocksReinitAuthorizationAndUpgradePreservesBoundAndCoordinatorState() public {
        AssetNeutralCspWheelChildLaneV2 laneImpl = new AssetNeutralCspWheelChildLaneV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        laneImpl.initialize(_laneParams());
        AssetNeutralCoveredCallWheelChildLaneV2 callImpl = new AssetNeutralCoveredCallWheelChildLaneV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        callImpl.initialize(_callLaneParams());
        AssetNeutralMetaWheelCoordinatorV2 wheelImpl = new AssetNeutralMetaWheelCoordinatorV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wheelImpl.initialize(_coordinatorParams(address(fundGraph), address(managerGraph)));

        (AssetNeutralCspWheelChildLaneV2 lane, AssetNeutralCspFundAdapterV2 adapter) = _cspPair();
        (AssetNeutralCoveredCallWheelChildLaneV2 callLane, AssetNeutralCoveredCallFundAdapterV2 callAdapter) =
            _callPair();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        lane.initialize(_laneParams());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        callLane.initialize(_callLaneParams());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wheel.initialize(_coordinatorParams(address(fundGraph), address(managerGraph)));
        _managed(WheelTypes.ManagedOperation.ResumeAllocations, "");
        usdc.mint(address(wheel), 77e6);
        vm.prank(address(managerGraph));
        wheel.allocate(address(usdc), 77e6, abi.encode(bytes32("NONTRIVIAL")));
        bytes32 beforeHash = wheel.positionStateHash();

        address stranger = address(0xB444);
        B1N444CspLaneHarness laneUpgrade = new B1N444CspLaneHarness();
        vm.prank(stranger);
        vm.expectRevert();
        lane.upgradeToAndCall(address(laneUpgrade), "");
        lane.upgradeToAndCall(address(laneUpgrade), "");
        assertEq(B1N444CspLaneHarness(address(lane)).marker(), keccak256("B1N444_CSP_UPGRADE"));
        assertEq(lane.adapter(), address(adapter));
        B1N444CallLaneHarness callUpgrade = new B1N444CallLaneHarness();
        callLane.upgradeToAndCall(address(callUpgrade), "");
        assertEq(B1N444CallLaneHarness(address(callLane)).marker(), keccak256("B1N444_CALL_UPGRADE"));
        assertEq(callLane.adapter(), address(callAdapter));

        B1N444CoordinatorUpgrade coordinatorUpgrade = new B1N444CoordinatorUpgrade();
        vm.prank(stranger);
        vm.expectRevert();
        wheel.upgradeToAndCall(address(coordinatorUpgrade), "");
        wheel.upgradeToAndCall(address(coordinatorUpgrade), "");
        assertEq(B1N444CoordinatorUpgrade(address(wheel)).marker(), keccak256("B1N444_COORDINATOR_UPGRADE"));
        assertEq(wheel.summaryV2().pendingCspSettlementAmount, 77e6);
        assertEq(wheel.positionStateHash(), beforeHash);
    }

    function test_authorizedOutboundUpgradesRejectOffChainAndPreserveEveryProxy() public {
        (AssetNeutralCspWheelChildLaneV2 cspLane, AssetNeutralCspFundAdapterV2 cspAdapter) = _cspPair();
        (AssetNeutralCoveredCallWheelChildLaneV2 callLane, AssetNeutralCoveredCallFundAdapterV2 callAdapter) =
            _callPair();
        address[5] memory proxies =
            [address(wheel), address(cspLane), address(callLane), address(cspAdapter), address(callAdapter)];
        address[5] memory upgrades = [
            address(new B1N444CoordinatorUpgrade()),
            address(new B1N444CspLaneHarness()),
            address(new B1N444CallLaneHarness()),
            address(new B1N444CspAdapterHarness()),
            address(new B1N444CallAdapterHarness())
        ];
        bytes32[5] memory implementations;
        for (uint256 i; i < proxies.length; ++i) {
            implementations[i] = vm.load(proxies[i], ERC1967_IMPLEMENTATION_SLOT);
        }
        vm.chainId(8453);
        bytes32 wheelState = wheel.positionStateHash();
        bytes32 cspLaneState = cspLane.positionStateHash();
        bytes32 callLaneState = callLane.positionStateHash();
        bytes32 cspAdapterState = cspAdapter.positionStateHash();
        bytes32 callAdapterState = callAdapter.positionStateHash();

        for (uint256 i; i < proxies.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(AssetNeutralMetaWheelCoordinatorV2.UnsupportedChain.selector, uint256(8453))
            );
            AssetNeutralMetaWheelCoordinatorV2(proxies[i]).upgradeToAndCall(upgrades[i], "");
            assertEq(vm.load(proxies[i], ERC1967_IMPLEMENTATION_SLOT), implementations[i]);
        }

        assertEq(wheel.positionStateHash(), wheelState);
        assertEq(cspLane.positionStateHash(), cspLaneState);
        assertEq(callLane.positionStateHash(), callLaneState);
        assertEq(cspAdapter.positionStateHash(), cspAdapterState);
        assertEq(callAdapter.positionStateHash(), callAdapterState);
    }

    function test_slotsPinnedAndDisjointFromBothB1N442Adapters() public {
        bytes32[5] memory slots = [
            B1N444CspLaneHarness(address(new B1N444CspLaneHarness())).slot(),
            B1N444CallLaneHarness(address(new B1N444CallLaneHarness())).slot(),
            bytes32(0x25f3c781a3b4b2732130427eafb87fab390547f217493bc67910823b9bed6700),
            B1N444CspAdapterHarness(address(new B1N444CspAdapterHarness())).slot(),
            B1N444CallAdapterHarness(address(new B1N444CallAdapterHarness())).slot()
        ];
        assertEq(slots[0], 0x4b0b8ea6a52df75cfa8ed49827d37929d1a4a1000d79a2ce66bcf9d217145400);
        assertEq(slots[1], 0xcdd7b84632977a6efabdb67715271088399ab37515012c5a3cc39afba75e3600);
        assertEq(slots[3], 0x9591e324b6bef4f293bf5b406270137e316bf81c5dc4459c5dff3f5d92b0e500);
        assertEq(slots[4], 0xb56377e01ba7390bcdce9ef7c884367de0dad4bbdc8649f6c3222c65bccb4300);
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i] != slots[j]);
            }
        }
    }

    function test_baseMainnetRejectsCoordinatorAndBothLaneInitializers() public {
        vm.chainId(8453);
        AssetNeutralMetaWheelCoordinatorV2 coordinatorImpl = new AssetNeutralMetaWheelCoordinatorV2();
        vm.expectRevert(
            abi.encodeWithSelector(AssetNeutralMetaWheelCoordinatorV2.UnsupportedChain.selector, uint256(8453))
        );
        new ERC1967Proxy(
            address(coordinatorImpl),
            abi.encodeCall(
                AssetNeutralMetaWheelCoordinatorV2.initialize,
                (_coordinatorParams(address(fundGraph), address(managerGraph)))
            )
        );
        AssetNeutralCspWheelChildLaneV2 cspImpl = new AssetNeutralCspWheelChildLaneV2();
        vm.expectRevert(abi.encodeWithSelector(AssetNeutralWheelChildLaneV2.UnsupportedChain.selector, uint256(8453)));
        new ERC1967Proxy(address(cspImpl), abi.encodeCall(AssetNeutralCspWheelChildLaneV2.initialize, (_laneParams())));
        AssetNeutralCoveredCallWheelChildLaneV2 callImpl = new AssetNeutralCoveredCallWheelChildLaneV2();
        vm.expectRevert(abi.encodeWithSelector(AssetNeutralWheelChildLaneV2.UnsupportedChain.selector, uint256(8453)));
        new ERC1967Proxy(
            address(callImpl), abi.encodeCall(AssetNeutralCoveredCallWheelChildLaneV2.initialize, (_laneParams()))
        );
    }

    function test_actualLaneSettlementAccountsPrimaryReturnBeforeInKindRecovery() public {
        B1N444SettlementLaneHarness implementation = new B1N444SettlementLaneHarness();
        AssetNeutralWheelChildLaneV2.InitializeParams memory params = _laneParams();
        params.coordinator = address(this);
        B1N444SettlementLaneHarness lane = B1N444SettlementLaneHarness(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(AssetNeutralCspWheelChildLaneV2.initialize, (params))
                )
            )
        );
        B1N444TerminalTransferAdapter adapter = new B1N444TerminalTransferAdapter(usdc, lbtc);
        uint256 settlementReturned = 1_250e6;
        uint256 underlyingRecovered = 2e8;
        usdc.mint(address(adapter), settlementReturned);
        lbtc.mint(address(adapter), underlyingRecovered);
        adapter.configure(settlementReturned, underlyingRecovered, IAdapter.Lifecycle.SettledOtm);
        lane.prime(address(adapter), 7, 1, 1_000e6);

        bytes32 expected = lane.executionStateHash();
        (IWheel.SettlementKind kind,) = lane.settle(7, expected);
        (uint256 accountedSettlement, uint256 accountedUnderlying) = lane.accountingState();
        assertEq(uint256(kind), uint256(IWheel.SettlementKind.CspOtm));
        assertEq(accountedSettlement, settlementReturned);
        assertEq(accountedUnderlying, underlyingRecovered);
        assertEq(usdc.balanceOf(address(lane)), settlementReturned);
        assertEq(lbtc.balanceOf(address(lane)), underlyingRecovered);
    }

    function test_actualLaneAccountsNonterminalPrimaryReturnAcrossAwaitingThenTerminalSettlement() public {
        B1N444SettlementLaneHarness implementation = new B1N444SettlementLaneHarness();
        AssetNeutralWheelChildLaneV2.InitializeParams memory params = _laneParams();
        params.coordinator = address(this);
        B1N444SettlementLaneHarness lane = B1N444SettlementLaneHarness(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(AssetNeutralCspWheelChildLaneV2.initialize, (params))
                )
            )
        );
        B1N444TerminalTransferAdapter adapter = new B1N444TerminalTransferAdapter(usdc, lbtc);
        usdc.mint(address(adapter), 1_000e6);
        lbtc.mint(address(adapter), 2e8);
        adapter.configure(1, 0, IAdapter.Lifecycle.AwaitingPhysicalDelivery);
        lane.prime(address(adapter), 8, 1, 1_000e6);

        (IWheel.SettlementKind pendingKind, bytes32 pendingHash) = lane.settle(8, lane.executionStateHash());
        (uint256 pendingSettlement, uint256 pendingUnderlying) = lane.accountingState();
        assertEq(uint256(pendingKind), uint256(IWheel.SettlementKind.None));
        assertEq(pendingSettlement, 1);
        assertEq(pendingUnderlying, 0);

        adapter.configure(1_000e6 - 1, 2e8, IAdapter.Lifecycle.SettledOtm);
        (IWheel.SettlementKind terminalKind,) = lane.settle(8, pendingHash);
        (uint256 finalSettlement, uint256 finalUnderlying) = lane.accountingState();
        assertEq(uint256(terminalKind), uint256(IWheel.SettlementKind.CspOtm));
        assertEq(finalSettlement, 1_000e6);
        assertEq(finalUnderlying, 2e8);
        assertEq(usdc.balanceOf(address(lane)), 1_000e6);
        assertEq(lbtc.balanceOf(address(lane)), 2e8);
    }

    function test_runtimeBudgetsAndDispatcherLinkDependency() public {
        assertLt(address(new AssetNeutralMetaWheelCoordinatorV2()).code.length, 24_576);
        assertLt(address(new AssetNeutralCspWheelChildLaneV2()).code.length, 24_576);
        assertLt(address(new AssetNeutralCoveredCallWheelChildLaneV2()).code.length, 24_576);
        assertLt(address(new AssetNeutralCspFundAdapterV2()).code.length, 24_576);
        assertLt(address(new AssetNeutralCoveredCallFundAdapterV2()).code.length, 24_576);
        assertLt(address(WheelManagedOperationDispatcher).code.length, 24_576);
        bytes memory coordinatorCode = type(AssetNeutralMetaWheelCoordinatorV2).creationCode;
        assertGt(coordinatorCode.length, 0);
        // Compilation of this type requires the linked WheelManagedOperationDispatcher library used by initialize,
        // lane validation, valuator validation, and managed-operation dispatch.
        assertGt(address(WheelManagedOperationDispatcher).code.length, 0);
    }

    function test_unauthorizedBindPauseResumeAndUpgradeFail() public {
        AssetNeutralCspWheelChildLaneV2 lane = _cspLane();
        address stranger = address(0xBAD);
        vm.startPrank(stranger);
        vm.expectRevert();
        lane.bindAdapter(address(1));
        vm.expectRevert();
        lane.pauseAllocations();
        vm.expectRevert();
        lane.resumeAllocations();
        vm.expectRevert();
        lane.upgradeToAndCall(address(0xCAFE), "");
        vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.OnlyStrategyManager.selector);
        wheel.pauseAllocations();
        vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.OnlyStrategyManager.selector);
        wheel.resumeAllocations();
        vm.expectRevert();
        wheel.upgradeToAndCall(address(0xCAFE), "");
        vm.stopPrank();
    }

    function _cspPair() private returns (AssetNeutralCspWheelChildLaneV2 lane, AssetNeutralCspFundAdapterV2 adapter) {
        lane = _cspLane();
        adapter = AssetNeutralCspFundAdapterV2(
            address(
                new ERC1967Proxy(
                    address(new AssetNeutralCspFundAdapterV2()),
                    abi.encodeCall(
                        AssetNeutralCspFundAdapterV2.initialize, (_adapterParams(address(lane), address(usdc)))
                    )
                )
            )
        );
        lane.bindAdapter(address(adapter));
    }

    function _cspLane() private returns (AssetNeutralCspWheelChildLaneV2) {
        return AssetNeutralCspWheelChildLaneV2(
            address(
                new ERC1967Proxy(
                    address(new AssetNeutralCspWheelChildLaneV2()),
                    abi.encodeCall(AssetNeutralCspWheelChildLaneV2.initialize, (_laneParams()))
                )
            )
        );
    }

    function _callPair()
        private
        returns (AssetNeutralCoveredCallWheelChildLaneV2 lane, AssetNeutralCoveredCallFundAdapterV2 adapter)
    {
        AssetNeutralWheelChildLaneV2.InitializeParams memory p = _callLaneParams();
        lane = AssetNeutralCoveredCallWheelChildLaneV2(
            address(
                new ERC1967Proxy(
                    address(new AssetNeutralCoveredCallWheelChildLaneV2()),
                    abi.encodeCall(AssetNeutralCoveredCallWheelChildLaneV2.initialize, (p))
                )
            )
        );
        adapter = AssetNeutralCoveredCallFundAdapterV2(
            address(
                new ERC1967Proxy(
                    address(new AssetNeutralCoveredCallFundAdapterV2()),
                    abi.encodeCall(
                        AssetNeutralCoveredCallFundAdapterV2.initialize, (_adapterParams(address(lane), address(lbtc)))
                    )
                )
            )
        );
        lane.bindAdapter(address(adapter));
    }

    function _callLaneParams() private view returns (AssetNeutralWheelChildLaneV2.InitializeParams memory p) {
        p = _laneParams();
        p.executionCostBufferUsd8 = BUFFER;
    }

    function _laneParams() private view returns (AssetNeutralWheelChildLaneV2.InitializeParams memory) {
        return AssetNeutralWheelChildLaneV2.InitializeParams(
            address(wheel), address(0), address(lbtc), address(usdc), address(authority), 1_000_000e6, 0, POLICY
        );
    }

    function _adapterParams(address lane, address accounting)
        private
        view
        returns (AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory)
    {
        accounting;
        return AssetNeutralOptionsFundAdapterV2.InitializeParamsV2(
            lane,
            lane,
            address(book),
            address(lbtc),
            address(usdc),
            address(router),
            500,
            address(authority),
            IOperations.RiskConfigV2(
                1 hours, 2 days, 6 hours, 1, 100, 4, 10_000, 1, 100_000e8, 1_000_000e6, 1_000_000e6, 0
            )
        );
    }

    function _coordinator(address fund_, address manager_) private returns (AssetNeutralMetaWheelCoordinatorV2) {
        return AssetNeutralMetaWheelCoordinatorV2(
            address(
                new ERC1967Proxy(
                    address(new AssetNeutralMetaWheelCoordinatorV2()),
                    abi.encodeCall(AssetNeutralMetaWheelCoordinatorV2.initialize, (_coordinatorParams(fund_, manager_)))
                )
            )
        );
    }

    function _coordinatorParams(address fund_, address manager_)
        private
        view
        returns (AssetNeutralMetaWheelCoordinatorV2.InitializeParams memory)
    {
        return AssetNeutralMetaWheelCoordinatorV2.InitializeParams(
            fund_, manager_, address(lbtc), address(usdc), address(authority), 4, 4, BUFFER, POLICY
        );
    }

    function _cspValuator(address adapter, address lane) private returns (AssetNeutralCspFundValuatorV2) {
        address[] memory observers = new address[](2);
        observers[0] = address(0x11);
        observers[1] = address(0x22);
        return new AssetNeutralCspFundValuatorV2(
            address(feed), 1_200, 10, 2, observers, adapter, lane, address(book), address(lbtc), address(usdc), POLICY
        );
    }

    function _register(address lane, WheelTypes.LaneKind kind) private {
        _managed(WheelTypes.ManagedOperation.RegisterLane, abi.encode(lane, kind));
    }

    function _setValuator(address lane, address valuator) private {
        _managed(WheelTypes.ManagedOperation.SetLaneValuator, abi.encode(lane, valuator));
    }

    function _managed(WheelTypes.ManagedOperation op, bytes memory args) private returns (bytes memory) {
        vm.prank(address(managerGraph));
        return
            wheel.executeManagedOperation(uint8(WheelTypes.ManagedOperationClass.Configuration), abi.encode(op, args));
    }
}
