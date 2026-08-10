// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {OToken} from "../../src/core/OToken.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {IPositionValuator} from "../../src/fund/interfaces/IPositionValuator.sol";
import {IAssetNeutralWheelV2 as IWheel} from "../../src/fund/interfaces/IAssetNeutralWheelV2.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralWheelChildLaneV2 as IChildLane,
    AssetNeutralMetaWheelCoordinatorV2,
    AssetNeutralMetaWheelValuatorV2
} from "../../src/fund/AssetNeutralMetaWheelV2.sol";

contract B1N443FundCode {}

contract B1N443WrongVersionValuator {
    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }
}

contract B1N443MockValuator is IPositionValuator {
    FundTypes.PositionValue internal configured;
    address public expectedAdapter;
    address public expectedFund;
    address public expectedUnderlying;
    address public expectedSettlement;
    bytes32 public expectedPolicyHash;
    IAdapter.StrategyKind public expectedStrategyKind;

    function bind(
        address adapter_,
        address fund_,
        address underlying_,
        address settlement_,
        IAdapter.StrategyKind kind_
    ) external {
        expectedAdapter = adapter_;
        expectedFund = fund_;
        expectedUnderlying = underlying_;
        expectedSettlement = settlement_;
        expectedPolicyHash = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;
        expectedStrategyKind = kind_;
    }

    function configure(uint256 gross, uint256 liabilities, uint256 exitCost) external {
        configured = FundTypes.PositionValue(gross, liabilities, exitCost, 0, keccak256("MOCK_CHILD_VALUE"));
    }

    function interfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function value(address, uint64, bytes calldata) external view returns (FundTypes.PositionValue memory) {
        return configured;
    }
}

abstract contract B1N443MockAdapterBase is IAdapter {
    address public override fund;
    address public immutable override underlyingAsset;
    address public immutable override settlementAsset;
    bytes32 public constant POLICY = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;

    constructor(address f, address u, address s) {
        fund = f;
        underlyingAsset = u;
        settlementAsset = s;
    }

    function bindFund(address f) external {
        require(fund == address(0));
        fund = f;
    }

    function strategyManager() external view returns (address) {
        return fund;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function deallocationInterfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function accountingAsset() external view returns (address) {
        return settlementAsset;
    }

    function policyHash() external pure returns (bytes32) {
        return POLICY;
    }

    function assetConfigV2() external view returns (AssetConfigV2 memory) {
        return AssetConfigV2(underlyingAsset, settlementAsset, 8, 8, 8, 6);
    }

    function adapterStateV2() external pure returns (AdapterStateV2 memory v) {
        return v;
    }

    function positionV2(uint256) external pure returns (PositionV2 memory p) {
        return p;
    }

    function positionStateHash() external pure returns (bytes32) {
        return keccak256("MOCK_ADAPTER");
    }

    function freeAssets(address) external pure returns (uint256) {
        return 0;
    }
    function allocate(address, uint256, bytes calldata) external pure {}

    function deallocate(uint256, uint256, bytes calldata) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function deallocateInKind(uint256, address, bytes calldata)
        external
        pure
        returns (address[] memory a, uint256[] memory b)
    {
        return (a, b);
    }

    function emergencyExit(address, bytes calldata) external pure returns (address[] memory a, uint256[] memory b) {
        return (a, b);
    }
}

    contract B1N443MockCspAdapter is B1N443MockAdapterBase {
        constructor(address f, address u, address s) B1N443MockAdapterBase(f, u, s) {}

        function strategyKind() external pure returns (StrategyKind) {
            return StrategyKind.Csp;
        }
    }

    contract B1N443MockCallAdapter is B1N443MockAdapterBase {
        constructor(address f, address u, address s) B1N443MockAdapterBase(f, u, s) {}

        function strategyKind() external pure returns (StrategyKind) {
            return StrategyKind.CoveredCall;
        }
    }

    contract B1N443MockLane is IChildLane {
        address public immutable override coordinator;
        address public immutable override adapter;
        address immutable underlying;
        address immutable settlement;
        IWheel.LaneKind public immutable override laneKind;
        uint256 public immutable override executionCostBufferUsd8;
        uint256 public override childShares;
        uint256 public override activePositionId;
        bytes32 public override positionStateHash;
        IWheel.SettlementKind nextKind;
        uint256 nextSettlement;
        uint256 nextUnderlying;
        uint256 nextLiteral;
        uint256 nextCallAway;

        constructor(address c, address a, address u, address s, IWheel.LaneKind k, uint256 buffer) {
            coordinator = c;
            adapter = a;
            underlying = u;
            settlement = s;
            laneKind = k;
            executionCostBufferUsd8 = buffer;
        }

        function configure(
            IWheel.SettlementKind kind,
            uint256 settlementOut,
            uint256 underlyingOut,
            uint256 literalStrike,
            uint256 calledAway
        ) external {
            nextKind = kind;
            nextSettlement = settlementOut;
            nextUnderlying = underlyingOut;
            nextLiteral = literalStrike;
            nextCallAway = calledAway;
            if (settlementOut != 0) MockERC20(settlement).mint(address(this), settlementOut);
            if (underlyingOut != 0) MockERC20(underlying).mint(address(this), underlyingOut);
        }

        function accountingState() external pure returns (uint256, uint256) {
            return (0, 0);
        }

        function open(
            uint256 trancheId,
            bytes32 transitionHash,
            uint256,
            uint256 literalStrike,
            uint256 amount,
            bytes calldata
        ) external returns (uint256 shares, uint256 positionId, uint64 expiry, bytes32 hash) {
            require(msg.sender == coordinator);
            address token = laneKind == IWheel.LaneKind.Csp ? settlement : underlying;
            MockERC20(token).transferFrom(msg.sender, address(this), amount);
            childShares = amount;
            activePositionId++;
            nextLiteral = literalStrike == 0 ? nextLiteral : literalStrike;
            positionStateHash = keccak256(abi.encode("OPEN", trancheId, transitionHash, activePositionId, amount));
            return (amount, activePositionId, uint64(block.timestamp + 2 days), positionStateHash);
        }

        function settle(uint256 trancheId, bytes32 expected)
            external
            returns (IWheel.SettlementKind kind, bytes32 hash)
        {
            require(msg.sender == coordinator && expected == positionStateHash);
            positionStateHash = keccak256(abi.encode("SETTLE", trancheId, expected, nextKind));
            return (nextKind, positionStateHash);
        }

        function handoff(uint256 trancheId, bytes32 expected, bytes32 transitionHash, address receiver)
            external
            returns (Basket memory b)
        {
            require(msg.sender == coordinator && expected == positionStateHash);
            if (nextSettlement != 0) MockERC20(settlement).transfer(receiver, nextSettlement);
            if (nextUnderlying != 0) MockERC20(underlying).transfer(receiver, nextUnderlying);
            b = Basket(
                nextKind,
                childShares,
                nextSettlement,
                nextUnderlying,
                activePositionId,
                nextLiteral,
                nextCallAway,
                expected,
                transitionHash
            );
            childShares = 0;
            positionStateHash = keccak256(abi.encode("HANDOFF", trancheId, transitionHash));
        }
    }

        contract B1N443Manager is Test {
            MockERC20 public usdc;
            AssetNeutralMetaWheelCoordinatorV2 public wheel;

            constructor(MockERC20 u) {
                usdc = u;
            }

            function bind(AssetNeutralMetaWheelCoordinatorV2 w) external {
                require(address(wheel) == address(0));
                wheel = w;
            }

            function managed(WheelTypes.ManagedOperationClass c, WheelTypes.ManagedOperation op, bytes memory args)
                public
                returns (bytes memory)
            {
                return wheel.executeManagedOperation(uint8(c), abi.encode(op, args));
            }

            function queue(uint96 raw) external {
                if (wheel.summaryV2().trancheCount >= 48) return;
                uint256 a = bound(uint256(raw), 1, 1_000_000e6);
                usdc.mint(address(wheel), a);
                wheel.allocate(address(usdc), a, abi.encode(keccak256(abi.encode(raw, a))));
            }

            function reserve(uint256 rawId, uint96 raw) external {
                uint256 n = wheel.summaryV2().trancheCount;
                if (n == 0) return;
                uint256 id = bound(rawId, 1, n);
                IWheel.TrancheV2 memory t = wheel.trancheV2(id);
                if (t.leg != IWheel.TrancheLeg.PendingCsp || t.pendingSettlementAmount == 0) return;
                uint256 a = bound(uint256(raw), 1, t.pendingSettlementAmount);
                managed(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.ReserveRedemption,
                    abi.encode(id, a)
                );
            }

            function release(uint96 raw) external {
                uint256 r = wheel.summaryV2().reservedRedemptionSettlementAmount;
                if (r == 0 || wheel.summaryV2().trancheCount >= 48) return;
                managed(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.ReleaseRedemption,
                    abi.encode(bound(uint256(raw), 1, r))
                );
            }
        }

        contract B1N443LBTCMetaWheelTest is Test {
            MockERC20 lbtc;
            MockERC20 usdc;
            B1N443Manager manager;
            AssetNeutralMetaWheelCoordinatorV2 wheel;
            B1N443MockLane cspLane;
            B1N443MockLane callLane;
            uint256 constant TEST_BUFFER = 1e8;

            function setUp() public {
                lbtc = new MockERC20("Loot BTC", "LBTC", 8);
                usdc = new MockERC20("USDC", "USDC", 6);
                manager = new B1N443Manager(usdc);
                B1N443FundCode fund = new B1N443FundCode();
                AccessManager authority = new AccessManager(address(this));
                wheel = AssetNeutralMetaWheelCoordinatorV2(
                    address(
                        new ERC1967Proxy(
                            address(new AssetNeutralMetaWheelCoordinatorV2()),
                            abi.encodeCall(
                                AssetNeutralMetaWheelCoordinatorV2.initialize,
                                (AssetNeutralMetaWheelCoordinatorV2.InitializeParams(
                                        address(fund),
                                        address(manager),
                                        address(lbtc),
                                        address(usdc),
                                        address(authority),
                                        4,
                                        4,
                                        TEST_BUFFER,
                                        bytes32(0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180)
                                    ))
                            )
                        )
                    )
                );
                manager.bind(wheel);
                B1N443MockCspAdapter ca = new B1N443MockCspAdapter(address(0), address(lbtc), address(usdc));
                B1N443MockCallAdapter aa = new B1N443MockCallAdapter(address(0), address(lbtc), address(usdc));
                cspLane = new B1N443MockLane(
                    address(wheel), address(ca), address(lbtc), address(usdc), IWheel.LaneKind.Csp, 0
                );
                callLane = new B1N443MockLane(
                    address(wheel), address(aa), address(lbtc), address(usdc), IWheel.LaneKind.CoveredCall, TEST_BUFFER
                );
                ca.bindFund(address(cspLane));
                aa.bindFund(address(callLane));
            }

            function _managed(WheelTypes.ManagedOperationClass c, WheelTypes.ManagedOperation op, bytes memory args)
                internal
                returns (bytes memory)
            {
                return manager.managed(c, op, args);
            }

            function _enable() internal {
                _managed(
                    WheelTypes.ManagedOperationClass.Configuration,
                    WheelTypes.ManagedOperation.RegisterLane,
                    abi.encode(address(cspLane), WheelTypes.LaneKind.Csp)
                );
                _managed(
                    WheelTypes.ManagedOperationClass.Configuration,
                    WheelTypes.ManagedOperation.RegisterLane,
                    abi.encode(address(callLane), WheelTypes.LaneKind.CoveredCall)
                );
                _managed(
                    WheelTypes.ManagedOperationClass.Configuration, WheelTypes.ManagedOperation.ResumeAllocations, ""
                );
            }

            function _queue(uint256 amount) internal returns (uint256 id) {
                usdc.mint(address(wheel), amount);
                vm.prank(address(manager));
                wheel.allocate(address(usdc), amount, "");
                return wheel.summaryV2().trancheCount;
            }

            function _op(WheelTypes.ManagedOperationClass c, WheelTypes.ManagedOperation op, bytes memory args)
                internal
            {
                _managed(c, op, args);
            }

            function _callData(uint256 strike, uint256 amount) internal returns (bytes memory) {
                OToken token = new OToken();
                token.init(
                    address(lbtc), address(usdc), address(lbtc), strike, block.timestamp + 2 days, false, address(this)
                );
                return abi.encode(
                    IAdapter.OpenPositionDataV2(
                        BatchSettler.Quote(address(token), 0, block.timestamp + 1 days, strike, amount, 0),
                        "",
                        amount,
                        amount
                    )
                );
            }

            function _openCsp(uint256 id) internal {
                _op(
                    WheelTypes.ManagedOperationClass.Allocation,
                    WheelTypes.ManagedOperation.OpenCsp,
                    abi.encode(id, address(cspLane), bytes(""))
                );
            }

            function _settleCsp(uint256 id) internal {
                _op(WheelTypes.ManagedOperationClass.Processing, WheelTypes.ManagedOperation.SettleCsp, abi.encode(id));
                _op(WheelTypes.ManagedOperationClass.Processing, WheelTypes.ManagedOperation.HandoffCsp, abi.encode(id));
            }

            function _openCall(uint256 id, uint256 strike, uint256 amount) internal {
                _op(
                    WheelTypes.ManagedOperationClass.Allocation,
                    WheelTypes.ManagedOperation.OpenCoveredCall,
                    abi.encode(id, address(callLane), _callData(strike, amount))
                );
            }

            function _settleCall(uint256 id) internal {
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.SettleCoveredCall,
                    abi.encode(id)
                );
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.HandoffCoveredCall,
                    abi.encode(id)
                );
            }

            function test_preflightIdentityIsV2Lbtc8Usdc6AndStartsPaused() public view {
                assertEq(wheel.interfaceVersion(), 2);
                IWheel.AssetConfigV2 memory c = wheel.assetConfigV2();
                assertEq(c.underlyingAsset, address(lbtc));
                assertEq(c.settlementAsset, address(usdc));
                assertEq(c.underlyingDecimals, 8);
                assertEq(c.settlementDecimals, 6);
                assertTrue(wheel.allocationsPaused());
                assertEq(wheel.registeredLaneCount(), 0);
            }

            function test_pausedDeploymentCannotAllocateAndDoesNotTouchEthWheel() public {
                usdc.mint(address(wheel), 1e6);
                vm.prank(address(manager));
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.AllocationPaused.selector);
                wheel.allocate(address(usdc), 1e6, "");
            }

            function test_fuzz_pendingReserveReleaseConservesNav(uint96 rawDeposit, uint96 rawReserve) public {
                manager.managed(
                    WheelTypes.ManagedOperationClass.Configuration, WheelTypes.ManagedOperation.ResumeAllocations, ""
                );
                uint256 a = bound(uint256(rawDeposit), 2, 1_000_000e6);
                usdc.mint(address(wheel), a);
                vm.prank(address(manager));
                wheel.allocate(address(usdc), a, "");
                uint256 r = bound(uint256(rawReserve), 1, a - 1);
                manager.managed(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.ReserveRedemption,
                    abi.encode(1, r)
                );
                manager.managed(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.ReleaseRedemption,
                    abi.encode(r)
                );
                IWheel.SummaryV2 memory s = wheel.summaryV2();
                assertEq(s.accountedSettlementAmount, a);
                assertEq(s.pendingCspSettlementAmount, a);
                assertEq(s.reservedRedemptionSettlementAmount, 0);
                assertEq(usdc.balanceOf(address(wheel)), a);
            }

            function test_allocationIdReplayAndFreeAssetReservationFailClosed() public {
                _enable();
                bytes32 allocationId = keccak256("EXACT_ALLOCATION");
                uint256 amount = 10_000e6;
                usdc.mint(address(wheel), amount * 2);
                vm.prank(address(manager));
                wheel.allocate(address(usdc), amount, abi.encode(allocationId));
                assertEq(wheel.freeAssets(address(usdc)), 0);
                assertEq(wheel.freeAssets(address(lbtc)), 0);

                vm.prank(address(manager));
                vm.expectRevert(
                    abi.encodeWithSelector(
                        AssetNeutralMetaWheelCoordinatorV2.DuplicateTransition.selector, allocationId
                    )
                );
                wheel.allocate(address(usdc), amount, abi.encode(allocationId));
                assertEq(wheel.summaryV2().trancheCount, 1);

                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.ReserveRedemption,
                    abi.encode(1, 4_000e6)
                );
                assertEq(wheel.freeAssets(address(usdc)), 4_000e6);
                vm.prank(address(manager));
                (uint256 out, uint256 principal) = wheel.deallocate(1_500e6, 1_500e6, "");
                assertEq(out, 1_500e6);
                assertEq(principal, 1_500e6);
                assertEq(wheel.freeAssets(address(usdc)), 2_500e6);
                assertEq(wheel.freeAssets(address(lbtc)), 0);
            }

            function test_partialAssignmentPartitionsPrincipalWithoutTreatingReturnedCashAsProfit() public {
                _enable();
                uint256 id = _queue(30_000e6);
                _openCsp(id);
                cspLane.configure(IWheel.SettlementKind.CspAssigned, 10_000e6, 5e7, 30_000e8, 0);
                _settleCsp(id);

                IWheel.TrancheV2 memory assigned = wheel.trancheV2(id);
                IWheel.TrancheV2 memory returned = wheel.trancheV2(2);
                assertEq(assigned.principalSettlementAmount, 20_000e6);
                assertEq(returned.principalSettlementAmount, 10_000e6);
                assertEq(returned.pendingSettlementAmount, 10_000e6);
                assertEq(assigned.principalSettlementAmount + returned.principalSettlementAmount, 30_000e6);
            }

            function test_partialCallFallbackPartitionsPrincipalByLiteralBasisAndConservesDust() public {
                _enable();
                uint256 id = _queue(30_000e6);
                _openCsp(id);
                cspLane.configure(IWheel.SettlementKind.CspAssigned, 0, 1e8, 30_000e8, 0);
                _settleCsp(id);
                _openCall(id, 31_000e8, 1e8);
                callLane.configure(IWheel.SettlementKind.UnderlyingFallback, 18_000e6, 4e7, 30_000e8, 0);
                _settleCall(id);

                IWheel.TrancheV2 memory remaining = wheel.trancheV2(id);
                IWheel.TrancheV2 memory returned = wheel.trancheV2(2);
                assertEq(remaining.principalSettlementAmount, 12_000e6);
                assertEq(returned.principalSettlementAmount, 18_000e6);
                assertEq(remaining.principalSettlementAmount + returned.principalSettlementAmount, 30_000e6);
            }

            function test_callAwayRequiresOpenedBufferedStrikeWithCeilingRounding() public {
                _enable();
                uint256 id = _queue(1_000e6);
                _openCsp(id);
                uint256 literal = 30_000e8;
                cspLane.configure(IWheel.SettlementKind.CspAssigned, 0, 1, literal, 0);
                _settleCsp(id);
                uint256 strike = literal + TEST_BUFFER;
                _openCall(id, strike, 1);
                uint256 exactCeiling = 301;
                callLane.configure(IWheel.SettlementKind.CallAway, exactCeiling - 1, 0, literal, exactCeiling - 1);
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.SettleCoveredCall,
                    abi.encode(id)
                );
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidSettlement.selector);
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.HandoffCoveredCall,
                    abi.encode(id)
                );
            }

            function test_cspOtmReturnsPremiumAndReopensWithoutDoubleCounting() public {
                _enable();
                uint256 amount = 30_000e6;
                uint256 id = _queue(amount);
                _openCsp(id);
                cspLane.configure(IWheel.SettlementKind.CspOtm, amount + 25e6, 0, 0, 0);
                _settleCsp(id);
                IWheel.TrancheV2 memory t = wheel.trancheV2(id);
                assertEq(uint8(t.leg), uint8(IWheel.TrancheLeg.PendingCsp));
                assertEq(t.pendingSettlementAmount, amount + 25e6);
                assertEq(wheel.summaryV2().accountedSettlementAmount, amount + 25e6);
                assertEq(wheel.summaryV2().pendingCspSettlementAmount, amount + 25e6);
                _openCsp(id);
                assertEq(uint8(wheel.trancheV2(id).leg), uint8(IWheel.TrancheLeg.CspOpen));
            }

            function test_assignmentCallOtmReopenThenCallAwayCompletesNextCspCycle() public {
                _enable();
                uint256 collateral = 30_000e6;
                uint256 underlying = 1e8;
                uint256 literal = 30_000e8;
                uint256 id = _queue(collateral);
                _openCsp(id);
                cspLane.configure(IWheel.SettlementKind.CspAssigned, 0, underlying, literal, 0);
                _settleCsp(id);
                IWheel.TrancheV2 memory t = wheel.trancheV2(id);
                assertEq(uint8(t.leg), uint8(IWheel.TrancheLeg.UnderlyingTransition));
                IWheel.AssignmentLotV2 memory lot = wheel.assignmentLotV2(t.assignmentLotId);
                assertEq(lot.underlyingReceivedAmount, underlying);
                assertEq(lot.remainingUnderlyingAmount, underlying);
                assertEq(lot.literalAssignmentStrikeUsd8, literal);
                assertEq(lbtc.balanceOf(address(wheel)), underlying);

                uint256 below = literal + TEST_BUFFER - 1;
                bytes memory belowData = _callData(below, underlying);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        AssetNeutralMetaWheelCoordinatorV2.CallStrikeBelowFloor.selector, below, literal + TEST_BUFFER
                    )
                );
                _op(
                    WheelTypes.ManagedOperationClass.Allocation,
                    WheelTypes.ManagedOperation.OpenCoveredCall,
                    abi.encode(id, address(callLane), belowData)
                );
                assertEq(uint8(wheel.trancheV2(id).leg), uint8(IWheel.TrancheLeg.UnderlyingTransition));
                assertEq(lbtc.balanceOf(address(wheel)), underlying);

                uint256 strike = literal + TEST_BUFFER;
                _openCall(id, strike, underlying);
                assertEq(lbtc.balanceOf(address(wheel)), 0);
                assertEq(lbtc.balanceOf(address(callLane)), underlying);
                callLane.configure(IWheel.SettlementKind.CallOtm, 20e6, underlying, literal, 0);
                _settleCall(id);
                lot = wheel.assignmentLotV2(t.assignmentLotId);
                assertEq(uint8(lot.status), uint8(IWheel.LotStatus.Available));
                assertEq(lot.remainingUnderlyingAmount, underlying);
                assertEq(lot.literalAssignmentStrikeUsd8, literal);
                assertEq(lbtc.balanceOf(address(wheel)), underlying);

                _openCall(id, strike, underlying);
                uint256 calledAway = (underlying * strike) / 1e10;
                callLane.configure(IWheel.SettlementKind.CallAway, calledAway + 30e6, 0, literal, calledAway);
                _settleCall(id);
                t = wheel.trancheV2(id);
                lot = wheel.assignmentLotV2(t.assignmentLotId);
                assertEq(uint8(lot.status), uint8(IWheel.LotStatus.CalledAway));
                assertEq(lot.remainingUnderlyingAmount, 0);
                assertEq(uint8(t.leg), uint8(IWheel.TrancheLeg.PendingCsp));
                assertEq(t.pendingSettlementAmount, calledAway + 30e6);
                assertEq(wheel.summaryV2().pendingCspSettlementAmount, 20e6 + calledAway + 30e6);
                _openCsp(id);
                assertEq(uint8(wheel.trancheV2(id).leg), uint8(IWheel.TrancheLeg.CspOpen));
            }

            function test_concurrentTranchesPauseAsyncRedemptionAndReplayFailClosed() public {
                _enable();
                uint256 first = _queue(25_000e6);
                _openCsp(first);
                cspLane.configure(IWheel.SettlementKind.CspAssigned, 0, 1e8, 25_000e8, 0);
                _settleCsp(first);
                _openCall(first, 25_000e8 + TEST_BUFFER, 1e8);

                uint256 second = _queue(10_000e6);
                assertEq(uint8(wheel.trancheV2(first).leg), uint8(IWheel.TrancheLeg.CallOpen));
                assertEq(uint8(wheel.trancheV2(second).leg), uint8(IWheel.TrancheLeg.PendingCsp));
                _openCsp(second);
                assertEq(uint8(wheel.trancheV2(second).leg), uint8(IWheel.TrancheLeg.CspOpen));

                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidAmount.selector);
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.ReserveRedemption,
                    abi.encode(first, 1e6)
                );
                _op(WheelTypes.ManagedOperationClass.Guardian, WheelTypes.ManagedOperation.PauseAllocations, "");
                usdc.mint(address(wheel), 1e6);
                vm.prank(address(manager));
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.AllocationPaused.selector);
                wheel.allocate(address(usdc), 1e6, "");

                callLane.configure(IWheel.SettlementKind.CallAway, 25_100e6, 0, 25_000e8, 25_100e6);
                _settleCall(first);
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidLeg.selector);
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.SettleCoveredCall,
                    abi.encode(first)
                );
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.ReserveRedemption,
                    abi.encode(first, 1e6)
                );
                assertEq(wheel.summaryV2().reservedRedemptionSettlementAmount, 1e6);
                vm.prank(address(manager));
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InKindRedemptionDisabled.selector);
                wheel.deallocateInKind(1e18, address(this), "");
            }

            function test_callOtmRejectsPartialUnderlyingAndKeepsLotInCallAtomically() public {
                _enable();
                uint256 id = _queue(20_000e6);
                _openCsp(id);
                cspLane.configure(IWheel.SettlementKind.CspAssigned, 0, 1e8, 20_000e8, 0);
                _settleCsp(id);
                _openCall(id, 20_000e8 + TEST_BUFFER, 1e8);
                callLane.configure(IWheel.SettlementKind.CallOtm, 0, 1e8 - 1, 20_000e8, 0);
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.SettleCoveredCall,
                    abi.encode(id)
                );
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidSettlement.selector);
                _op(
                    WheelTypes.ManagedOperationClass.Processing,
                    WheelTypes.ManagedOperation.HandoffCoveredCall,
                    abi.encode(id)
                );
                assertEq(uint8(wheel.assignmentLotV2(1).status), uint8(IWheel.LotStatus.InCall));
            }

            function test_registerLaneRejectsWrongKindWrongCustodyAndMalformedAdapter() public {
                B1N443MockCallAdapter wrongKindAdapter =
                    new B1N443MockCallAdapter(address(0), address(lbtc), address(usdc));
                B1N443MockLane wrongKindLane = new B1N443MockLane(
                    address(wheel), address(wrongKindAdapter), address(lbtc), address(usdc), IWheel.LaneKind.Csp, 0
                );
                wrongKindAdapter.bindFund(address(wrongKindLane));
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidLane.selector);
                _managed(
                    WheelTypes.ManagedOperationClass.Configuration,
                    WheelTypes.ManagedOperation.RegisterLane,
                    abi.encode(address(wrongKindLane), WheelTypes.LaneKind.Csp)
                );

                B1N443MockCspAdapter wrongCustodyAdapter =
                    new B1N443MockCspAdapter(address(0xBEEF), address(lbtc), address(usdc));
                B1N443MockLane wrongCustodyLane = new B1N443MockLane(
                    address(wheel), address(wrongCustodyAdapter), address(lbtc), address(usdc), IWheel.LaneKind.Csp, 0
                );
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidLane.selector);
                _managed(
                    WheelTypes.ManagedOperationClass.Configuration,
                    WheelTypes.ManagedOperation.RegisterLane,
                    abi.encode(address(wrongCustodyLane), WheelTypes.LaneKind.Csp)
                );

                B1N443FundCode malformedAdapter = new B1N443FundCode();
                B1N443MockLane malformedLane = new B1N443MockLane(
                    address(wheel), address(malformedAdapter), address(lbtc), address(usdc), IWheel.LaneKind.Csp, 0
                );
                vm.expectRevert(AssetNeutralMetaWheelCoordinatorV2.InvalidLane.selector);
                _managed(
                    WheelTypes.ManagedOperationClass.Configuration,
                    WheelTypes.ManagedOperation.RegisterLane,
                    abi.encode(address(malformedLane), WheelTypes.LaneKind.Csp)
                );
            }

            function test_parentValuatorRejectsSwappedAndWrongVersionChildren() public {
                _enable();
                B1N443MockValuator cspChild = new B1N443MockValuator();
                B1N443MockValuator callChild = new B1N443MockValuator();
                cspChild.bind(
                    cspLane.adapter(), address(cspLane), address(lbtc), address(usdc), IAdapter.StrategyKind.Csp
                );
                callChild.bind(
                    callLane.adapter(),
                    address(callLane),
                    address(lbtc),
                    address(usdc),
                    IAdapter.StrategyKind.CoveredCall
                );
                MockChainlinkFeed feed = new MockChainlinkFeed(25_000e8);

                vm.expectRevert(AssetNeutralMetaWheelValuatorV2.InvalidAdapter.selector);
                new AssetNeutralMetaWheelValuatorV2(
                    address(wheel),
                    address(lbtc),
                    address(usdc),
                    address(feed),
                    address(callChild),
                    address(cspChild),
                    1 hours
                );

                B1N443WrongVersionValuator wrongVersion = new B1N443WrongVersionValuator();
                vm.expectRevert(AssetNeutralMetaWheelValuatorV2.InvalidAdapter.selector);
                new AssetNeutralMetaWheelValuatorV2(
                    address(wheel),
                    address(lbtc),
                    address(usdc),
                    address(feed),
                    address(wrongVersion),
                    address(callChild),
                    1 hours
                );
            }

            function test_parentValuatorCountsTransitionLbtcExactlyOnce() public {
                _enable();
                uint256 id = _queue(25_000e6);
                _openCsp(id);
                cspLane.configure(IWheel.SettlementKind.CspAssigned, 0, 1e8, 25_000e8, 0);
                _settleCsp(id);
                B1N443MockValuator cspChild = new B1N443MockValuator();
                B1N443MockValuator callChild = new B1N443MockValuator();
                cspChild.bind(
                    cspLane.adapter(), address(cspLane), address(lbtc), address(usdc), IAdapter.StrategyKind.Csp
                );
                callChild.bind(
                    callLane.adapter(),
                    address(callLane),
                    address(lbtc),
                    address(usdc),
                    IAdapter.StrategyKind.CoveredCall
                );
                MockChainlinkFeed feed = new MockChainlinkFeed(25_000e8);
                AssetNeutralMetaWheelValuatorV2 valuator = new AssetNeutralMetaWheelValuatorV2(
                    address(wheel),
                    address(lbtc),
                    address(usdc),
                    address(feed),
                    address(cspChild),
                    address(callChild),
                    1 hours
                );
                IWheel.LaneValuationV2[] memory reports = new IWheel.LaneValuationV2[](0);
                FundTypes.PositionValue memory v = valuator.value(
                    address(wheel), uint64(block.number), abi.encode(reports)
                );
                assertEq(v.grossAssets, 25_000e6);
                assertEq(v.liabilities, 0);
                assertEq(v.liquidAccountingAssets, 0);
                assertEq(wheel.summaryV2().accountedUnderlyingAmount, 1e8);
                assertEq(wheel.summaryV2().transitionUnderlyingAmount, 1e8);
            }

            function test_runtimeBudgetsRetainEip170Margin() public {
                assertLt(address(new AssetNeutralMetaWheelCoordinatorV2()).code.length, 24_576);
            }

            function test_wrongDecimalsAndNonCanonicalPolicyFailPreflight() public {
                MockERC20 bad = new MockERC20("bad", "bad", 18);
                B1N443FundCode f = new B1N443FundCode();
                AccessManager a = new AccessManager(address(this));
                address implementation = address(new AssetNeutralMetaWheelCoordinatorV2());
                vm.expectRevert();
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(
                        AssetNeutralMetaWheelCoordinatorV2.initialize,
                        (AssetNeutralMetaWheelCoordinatorV2.InitializeParams(
                                address(f),
                                address(manager),
                                address(bad),
                                address(usdc),
                                address(a),
                                1,
                                1,
                                0,
                                keccak256("invented")
                            ))
                    )
                );
            }
        }

        contract B1N443LBTCMetaWheelInvariant is StdInvariant, Test {
            MockERC20 usdc;
            MockERC20 lbtc;
            B1N443Manager handler;
            AssetNeutralMetaWheelCoordinatorV2 wheel;

            function setUp() public {
                usdc = new MockERC20("USDC", "USDC", 6);
                lbtc = new MockERC20("LBTC", "LBTC", 8);
                handler = new B1N443Manager(usdc);
                B1N443FundCode f = new B1N443FundCode();
                AccessManager a = new AccessManager(address(this));
                wheel = AssetNeutralMetaWheelCoordinatorV2(
                    address(
                        new ERC1967Proxy(
                            address(new AssetNeutralMetaWheelCoordinatorV2()),
                            abi.encodeCall(
                                AssetNeutralMetaWheelCoordinatorV2.initialize,
                                (AssetNeutralMetaWheelCoordinatorV2.InitializeParams(
                                        address(f),
                                        address(handler),
                                        address(lbtc),
                                        address(usdc),
                                        address(a),
                                        4,
                                        4,
                                        0,
                                        bytes32(0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180)
                                    ))
                            )
                        )
                    )
                );
                handler.bind(wheel);
                handler.managed(
                    WheelTypes.ManagedOperationClass.Configuration, WheelTypes.ManagedOperation.ResumeAllocations, ""
                );
                targetContract(address(handler));
                bytes4[] memory ss = new bytes4[](3);
                ss[0] = handler.queue.selector;
                ss[1] = handler.reserve.selector;
                ss[2] = handler.release.selector;
                targetSelector(FuzzSelector(address(handler), ss));
            }

            function invariant_idlePartitionsAndNativeBalancesConserveNav() public view {
                IWheel.SummaryV2 memory s = wheel.summaryV2();
                assertEq(
                    s.accountedSettlementAmount, s.pendingCspSettlementAmount + s.reservedRedemptionSettlementAmount
                );
                assertEq(usdc.balanceOf(address(wheel)), s.accountedSettlementAmount);
                assertEq(lbtc.balanceOf(address(wheel)), s.accountedUnderlyingAmount);
                uint256 pending;
                for (uint256 id = 1; id <= s.trancheCount; id++) {
                    IWheel.TrancheV2 memory t = wheel.trancheV2(id);
                    if (t.leg == IWheel.TrancheLeg.PendingCsp) pending += t.pendingSettlementAmount;
                }
                assertEq(pending, s.pendingCspSettlementAmount);
            }
        }
