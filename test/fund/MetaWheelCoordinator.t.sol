// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {IWheelCoordinatorAdapter} from "../../src/fund/interfaces/IWheelCoordinatorAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {OToken} from "../../src/core/OToken.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {WheelManagedOperationDispatcher} from "../../src/fund/libraries/WheelManagedOperationDispatcher.sol";

contract WheelMockFund {}

contract WheelMockStrategyManager {
    function queue(WheelCoordinatorAdapter coordinator, IERC20 usdc, uint256 amount, bytes32 allocationId) external {
        usdc.transfer(address(coordinator), amount);
        coordinator.allocate(address(usdc), amount, abi.encode(allocationId));
    }

    function pull(WheelCoordinatorAdapter coordinator, uint256 amount)
        external
        returns (uint256 assetsOut, uint256 principalReleased)
    {
        return coordinator.deallocate(amount, amount, "");
    }

    function execute(
        WheelCoordinatorAdapter coordinator,
        WheelTypes.ManagedOperationClass operationClass,
        WheelTypes.ManagedOperation operation,
        bytes calldata arguments
    ) external returns (bytes memory result) {
        return coordinator.executeManagedOperation(uint8(operationClass), abi.encode(operation, arguments));
    }
}

abstract contract WheelMockLaneBase {
    address public immutable coordinator;
    address public immutable adapter;
    MockERC20 internal immutable _usdc;
    MockERC20 internal immutable _weth;
    WheelTypes.LaneState internal _state;
    uint64 internal _nonce;
    uint256 internal _shares;
    uint256 internal _trancheId;
    uint256 internal _positionId;
    bytes32 internal _hash;
    WheelTypes.SettlementKind internal _settlementKind;
    uint256 internal _configuredUsdc;
    uint256 internal _configuredWeth;
    bool internal _delayNextSettlement;
    uint256 internal _settlementAttempts;
    bytes32 internal _externalAdapterLifecycleHash;

    constructor(address coordinator_, MockERC20 usdc_, MockERC20 weth_) {
        coordinator = coordinator_;
        adapter = address(this);
        _usdc = usdc_;
        _weth = weth_;
        _hash = keccak256(abi.encode(address(this), uint256(0)));
    }

    function laneState() external view returns (WheelTypes.LaneState) {
        return _state;
    }

    function stateNonce() external view returns (uint64) {
        return _nonce;
    }

    function childShares() external view returns (uint256) {
        return _shares;
    }

    function activeTrancheId() external view returns (uint256) {
        return _trancheId;
    }

    function activePositionId() external view returns (uint256) {
        return _positionId;
    }

    function positionStateHash() external view returns (bytes32) {
        return keccak256(
            abi.encode(
                _hash, _externalAdapterLifecycleHash, _usdc.balanceOf(address(this)), _weth.balanceOf(address(this))
            )
        );
    }

    function executionStateHash() external view returns (bytes32) {
        return _hash;
    }

    function delayNextSettlement() external {
        _delayNextSettlement = true;
        _settlementAttempts = 0;
    }

    function simulateExternalAdapterLifecycle(bytes32 lifecycleHash) external {
        _externalAdapterLifecycleHash = lifecycleHash;
    }

    function _checkpoint(bytes32 operation) internal {
        ++_nonce;
        _hash = keccak256(
            abi.encode(
                _hash, _nonce, operation, _state, _shares, _trancheId, _positionId, _configuredUsdc, _configuredWeth
            )
        );
    }

    function _configureBasket(WheelTypes.SettlementKind kind, uint256 usdcAmount, uint256 wethAmount) internal {
        _settlementKind = kind;
        _configuredUsdc = usdcAmount;
        _configuredWeth = wethAmount;
        uint256 rawUsdc = _usdc.balanceOf(address(this));
        uint256 rawWeth = _weth.balanceOf(address(this));
        if (rawUsdc > usdcAmount) _usdc.transfer(address(0xdead), rawUsdc - usdcAmount);
        if (rawWeth > wethAmount) _weth.transfer(address(0xdead), rawWeth - wethAmount);
        if (rawUsdc < usdcAmount) _usdc.mint(address(this), usdcAmount - rawUsdc);
        if (rawWeth < wethAmount) _weth.mint(address(this), wethAmount - rawWeth);
    }

    function _handoff(bytes32 expectedPositionHash, bytes32 transitionHash, address receiver)
        internal
        returns (WheelTypes.LaneBasket memory basket)
    {
        require(_state == WheelTypes.LaneState.ReadyForHandoff, "NOT_READY");
        require(expectedPositionHash == _hash, "HASH");
        basket = WheelTypes.LaneBasket({
            settlementKind: _settlementKind,
            childSharesBurned: _shares,
            usdcAmount: _configuredUsdc,
            wethAmount: _configuredWeth,
            positionId: _positionId,
            literalAssignmentStrike8: 0,
            positionHash: _hash,
            transitionHash: transitionHash
        });
        _shares = 0;
        _state = WheelTypes.LaneState.Idle;
        _checkpoint(transitionHash);
        if (_configuredUsdc != 0) _usdc.transfer(receiver, _configuredUsdc);
        if (_configuredWeth != 0) _weth.transfer(receiver, _configuredWeth);
        _configuredUsdc = 0;
        _configuredWeth = 0;
    }
}

contract WheelMockCspLane is WheelMockLaneBase {
    uint256 public literalStrike8;

    constructor(address coordinator_, MockERC20 usdc_, MockERC20 weth_) WheelMockLaneBase(coordinator_, usdc_, weth_) {}

    function laneKind() external pure returns (WheelTypes.LaneKind) {
        return WheelTypes.LaneKind.Csp;
    }

    function configureSettlement(
        WheelTypes.SettlementKind kind,
        uint256 usdcAmount,
        uint256 wethAmount,
        uint256 literalStrike
    ) external {
        literalStrike8 = literalStrike;
        _configureBasket(kind, usdcAmount, wethAmount);
    }

    function openCsp(uint256 trancheId, bytes32 transitionHash, uint256 usdcAmount, bytes calldata)
        external
        returns (uint256 mintedChildShares, uint256 positionId, uint64 expiry, bytes32 positionHash)
    {
        require(msg.sender == coordinator && _state == WheelTypes.LaneState.Idle, "OPEN");
        _usdc.transferFrom(msg.sender, address(this), usdcAmount);
        _trancheId = trancheId;
        _shares = usdcAmount;
        _positionId = 1;
        _state = WheelTypes.LaneState.Open;
        _checkpoint(transitionHash);
        return (_shares, _positionId, uint64(block.timestamp + 2 days), _hash);
    }

    function settleCsp(uint256 trancheId, bytes32 expectedPositionHash)
        external
        returns (WheelTypes.SettlementKind settlementKind, bytes32 positionHash)
    {
        require(msg.sender == coordinator && trancheId == _trancheId, "SETTLE");
        require(expectedPositionHash == _hash, "HASH");
        if (_delayNextSettlement && _settlementAttempts++ == 0) {
            _state = WheelTypes.LaneState.Settling;
            _checkpoint(keccak256("CSP_DELIVERY_PENDING"));
            return (WheelTypes.SettlementKind.None, _hash);
        }
        _state = WheelTypes.LaneState.ReadyForHandoff;
        _checkpoint(keccak256("CSP_SETTLED"));
        return (_settlementKind, _hash);
    }

    function handoffCsp(uint256 trancheId, bytes32 expectedPositionHash, bytes32 transitionHash, address receiver)
        external
        returns (WheelTypes.LaneBasket memory basket)
    {
        require(msg.sender == coordinator && trancheId == _trancheId, "HANDOFF");
        basket = _handoff(expectedPositionHash, transitionHash, receiver);
        basket.literalAssignmentStrike8 = literalStrike8;
    }
}

contract WheelMockCallLane is WheelMockLaneBase {
    uint256 public immutable executionCostBuffer8;
    uint256 public literalAssignmentStrike8;
    uint256 public protectedBaseFloor8;
    uint256 public requiredFloor8;
    uint256 public consumedLotId;

    constructor(address coordinator_, MockERC20 usdc_, MockERC20 weth_, uint256 buffer8_)
        WheelMockLaneBase(coordinator_, usdc_, weth_)
    {
        executionCostBuffer8 = buffer8_;
    }

    function laneKind() external pure returns (WheelTypes.LaneKind) {
        return WheelTypes.LaneKind.CoveredCall;
    }

    function configureSettlement(WheelTypes.SettlementKind kind, uint256 usdcAmount, uint256 wethAmount) external {
        _configureBasket(kind, usdcAmount, wethAmount);
    }

    function openCoveredCall(
        uint256 trancheId,
        bytes32 transitionHash,
        uint256 lotId,
        uint256 literalAssignmentStrike8_,
        uint256 protectedBaseFloor8_,
        uint256 wethAmount,
        bytes calldata openData
    ) external returns (uint256 mintedChildShares, uint256 positionId, uint64 expiry, bytes32 positionHash) {
        require(msg.sender == coordinator && _state == WheelTypes.LaneState.Idle, "OPEN");
        ICoveredCallFundAdapter.OpenPositionData memory decoded =
            abi.decode(openData, (ICoveredCallFundAdapter.OpenPositionData));
        require(protectedBaseFloor8_ >= literalAssignmentStrike8_, "PROTECTED_FLOOR");
        literalAssignmentStrike8 = literalAssignmentStrike8_;
        protectedBaseFloor8 = protectedBaseFloor8_;
        requiredFloor8 = protectedBaseFloor8_ + executionCostBuffer8;
        require(OToken(decoded.quote.oToken).strikePrice() >= requiredFloor8, "FLOOR");
        _weth.transferFrom(msg.sender, address(this), wethAmount);
        _trancheId = trancheId;
        consumedLotId = lotId;
        _shares = wethAmount;
        _positionId = 1;
        _state = WheelTypes.LaneState.Open;
        _checkpoint(transitionHash);
        return (_shares, _positionId, uint64(block.timestamp + 2 days), _hash);
    }

    function settleCoveredCall(uint256 trancheId, bytes32 expectedPositionHash)
        external
        returns (WheelTypes.SettlementKind settlementKind, bytes32 positionHash)
    {
        require(msg.sender == coordinator && trancheId == _trancheId, "SETTLE");
        require(expectedPositionHash == _hash, "HASH");
        if (_delayNextSettlement && _settlementAttempts++ == 0) {
            _state = WheelTypes.LaneState.Settling;
            _checkpoint(keccak256("CALL_DELIVERY_PENDING"));
            return (WheelTypes.SettlementKind.None, _hash);
        }
        _state = WheelTypes.LaneState.ReadyForHandoff;
        _checkpoint(keccak256("CALL_SETTLED"));
        return (_settlementKind, _hash);
    }

    function handoffCoveredCall(
        uint256 trancheId,
        bytes32 expectedPositionHash,
        bytes32 transitionHash,
        address receiver
    ) external returns (WheelTypes.LaneBasket memory basket) {
        require(msg.sender == coordinator && trancheId == _trancheId, "HANDOFF");
        basket = _handoff(expectedPositionHash, transitionHash, receiver);
    }
}

contract MetaWheelCoordinatorTest is Test {
    uint256 internal constant FLOOR_BUFFER_8 = 10e8;
    bytes32 internal constant POLICY_HASH = keccak256("wheel-policy-v1");

    event WheelCoveredCallFloorEnforced(
        uint256 indexed trancheId,
        uint256 indexed lotId,
        address indexed lane,
        uint256 literalAssignmentStrike8,
        uint256 executionCostBuffer8,
        uint256 requiredFloor8,
        uint256 callStrike8
    );

    MockERC20 internal usdc;
    MockERC20 internal weth;
    WheelMockFund internal fund;
    WheelMockStrategyManager internal strategy;
    FundAccessManager internal accessManager;
    WheelCoordinatorAdapter internal coordinator;
    WheelMockCspLane internal cspLane;
    WheelMockCallLane internal callLane;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        fund = new WheelMockFund();
        strategy = new WheelMockStrategyManager();
        accessManager = new FundAccessManager(address(this));
        WheelCoordinatorAdapter implementation = new WheelCoordinatorAdapter();
        coordinator = WheelCoordinatorAdapter(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        WheelCoordinatorAdapter.initialize,
                        (WheelCoordinatorAdapter.InitializeParams({
                                fund: address(fund),
                                strategyManager: address(strategy),
                                usdc: address(usdc),
                                weth: address(weth),
                                authority: address(accessManager),
                                maxCspLanes: 4,
                                maxCoveredCallLanes: 4,
                                floorBufferUsd8: FLOOR_BUFFER_8,
                                policyHash: POLICY_HASH
                            }))
                    )
                )
            )
        );
        cspLane = new WheelMockCspLane(address(coordinator), usdc, weth);
        callLane = new WheelMockCallLane(address(coordinator), usdc, weth, FLOOR_BUFFER_8);
        _configure(WheelTypes.ManagedOperation.RegisterLane, abi.encode(address(cspLane), WheelTypes.LaneKind.Csp));
        _configure(
            WheelTypes.ManagedOperation.RegisterLane, abi.encode(address(callLane), WheelTypes.LaneKind.CoveredCall)
        );
    }

    function test_assignmentCallAwayCycleTracksLiteralFloorAndQueuesReturnedUsdc() public {
        uint256 deposit = 20_000e6;
        _queue(deposit);
        _openCsp(1, _cspOpenData());

        uint256 assignmentStrike8 = 2_000e8;
        uint256 assignedWeth = 10e18;
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 100e6, assignedWeth, assignmentStrike8);
        _settleCsp(1);
        uint256 lotId = _handoffCsp(1);
        WheelTypes.AssignmentLot memory lot = coordinator.assignmentLot(lotId);
        WheelTypes.Tranche memory assignedTranche = coordinator.tranche(1);
        WheelTypes.Tranche memory residualTranche = coordinator.tranche(2);
        assertEq(lot.literalAssignmentStrike8, assignmentStrike8);
        assertEq(lot.wethReceived, assignedWeth);
        assertEq(uint256(lot.status), uint256(WheelTypes.LotStatus.Available));
        assertEq(assignedTranche.pendingUsdc, 0);
        assertEq(uint256(assignedTranche.leg), uint256(WheelTypes.TrancheLeg.WethTransition));
        assertEq(assignedTranche.principalUsdc, deposit);
        assertEq(residualTranche.pendingUsdc, 100e6);
        assertEq(residualTranche.principalUsdc, 0);
        assertEq(uint256(residualTranche.leg), uint256(WheelTypes.TrancheLeg.PendingCsp));

        bytes memory belowFloor = _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8 - 1);
        vm.expectRevert(WheelCoordinatorAdapter.CallStrikeBelowFloor.selector);
        _openCall(1, belowFloor);

        _openCall(1, _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8));
        _openCsp(2, _cspOpenData());
        assertEq(uint256(callLane.laneState()), uint256(WheelTypes.LaneState.Open));
        assertEq(uint256(cspLane.laneState()), uint256(WheelTypes.LaneState.Open));
        callLane.configureSettlement(WheelTypes.SettlementKind.CallAway, 20_500e6, 0);
        _settleCall(1);
        _handoffCall(1);

        lot = coordinator.assignmentLot(lotId);
        assertEq(uint256(lot.status), uint256(WheelTypes.LotStatus.CalledAway));
        assertEq(lot.remainingWeth, 0);
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.pendingCspUsdc, 20_500e6);
        assertEq(state.accountedUsdc, 20_500e6);
        assertEq(state.accountedWeth, 0);
        assertEq(state.transitionWeth, 0);
        assertEq(coordinator.tranche(1).principalUsdc, deposit);

        vm.expectRevert(WheelCoordinatorAdapter.InvalidTrancheLeg.selector);
        _handoffCall(1);
    }

    function test_callOtmSplitsPremiumIntoSiblingWhileLotImmediatelyReopens() public {
        _queue(20_000e6);
        _openCsp(1, _cspOpenData());
        uint256 assignmentStrike8 = 2_000e8;
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 100e6, 10e18, assignmentStrike8);
        _settleCsp(1);
        _handoffCsp(1);
        _openCall(1, _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8));

        callLane.configureSettlement(WheelTypes.SettlementKind.CallOtm, 50e6, 10e18);
        _settleCall(1);
        _handoffCall(1);

        WheelTypes.Tranche memory callTranche = coordinator.tranche(1);
        WheelTypes.Tranche memory premiumTranche = coordinator.tranche(3);
        assertEq(uint256(callTranche.leg), uint256(WheelTypes.TrancheLeg.WethTransition));
        assertEq(callTranche.pendingUsdc, 0);
        assertEq(callTranche.principalUsdc, 20_000e6);
        assertEq(uint256(premiumTranche.leg), uint256(WheelTypes.TrancheLeg.PendingCsp));
        assertEq(premiumTranche.pendingUsdc, 50e6);
        assertEq(premiumTranche.principalUsdc, 0);

        _openCall(1, _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8));
        _openCsp(3, _cspOpenData());
        assertEq(uint256(callLane.laneState()), uint256(WheelTypes.LaneState.Open));
        assertEq(uint256(cspLane.laneState()), uint256(WheelTypes.LaneState.Open));
    }

    function test_redemptionReserveIsConsumedBeforePendingCspLiquidity() public {
        _queue(1_000e6);
        vm.expectRevert(WheelCoordinatorAdapter.InvalidAmount.selector);
        strategy.pull(coordinator, 1e6);
        _reserve(1, 400e6);
        (uint256 assetsOut, uint256 principalReleased) = strategy.pull(coordinator, 400e6);
        assertEq(assetsOut, 400e6);
        assertEq(principalReleased, 400e6);
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.reservedRedemptionUsdc, 0);
        assertEq(state.reservedPrincipalUsdc, 0);
        assertEq(state.pendingCspUsdc, 600e6);
        assertEq(state.accountedUsdc, 600e6);
        assertEq(usdc.balanceOf(address(fund)), 400e6);
        assertEq(coordinator.tranche(1).pendingUsdc, 600e6);
    }

    function test_fullReserveAndDeallocateClosesExactTranche() public {
        _queue(1_000e6);
        _reserve(1, 1_000e6);
        WheelTypes.Tranche memory reserved = coordinator.tranche(1);
        assertEq(reserved.pendingUsdc, 0);
        assertEq(uint256(reserved.leg), uint256(WheelTypes.TrancheLeg.Closed));

        strategy.pull(coordinator, 1_000e6);
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.accountedUsdc, 0);
        assertEq(state.pendingCspUsdc, 0);
        assertEq(state.reservedRedemptionUsdc, 0);
    }

    function test_releaseCreatesExactNewPendingTrancheWithoutRestoringClosedSource() public {
        _queue(1_000e6);
        _reserve(1, 400e6);
        uint256 releasedTrancheId = _release(250e6);
        assertEq(releasedTrancheId, 2);
        assertEq(coordinator.tranche(1).pendingUsdc, 600e6);
        assertEq(coordinator.tranche(1).principalUsdc, 600e6);
        WheelTypes.Tranche memory released = coordinator.tranche(releasedTrancheId);
        assertEq(released.pendingUsdc, 250e6);
        assertEq(released.principalUsdc, 250e6);
        assertEq(uint256(released.leg), uint256(WheelTypes.TrancheLeg.PendingCsp));

        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.pendingCspUsdc, 850e6);
        assertEq(state.reservedRedemptionUsdc, 150e6);
        assertEq(state.reservedPrincipalUsdc, 150e6);
    }

    function test_partialCallAwaySplitsPrincipalByConsumedCollateral() public {
        _queue(20_000e6);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 10e18, 2_000e8);
        _settleCsp(1);
        _handoffCsp(1);
        _openCall(1, _callOpenData(2_000e8 + FLOOR_BUFFER_8));

        callLane.configureSettlement(WheelTypes.SettlementKind.CallAway, 10_500e6, 5e18);
        _settleCall(1);
        _handoffCall(1);

        WheelTypes.Tranche memory wethTranche = coordinator.tranche(1);
        WheelTypes.Tranche memory usdcTranche = coordinator.tranche(2);
        assertEq(wethTranche.principalUsdc, 10_000e6);
        assertEq(wethTranche.pendingUsdc, 0);
        assertEq(usdcTranche.principalUsdc, 10_000e6);
        assertEq(usdcTranche.pendingUsdc, 10_500e6);
    }

    function test_purePremiumReturnDoesNotReleasePrincipal() public {
        _queue(20_000e6);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 10e18, 2_000e8);
        _settleCsp(1);
        _handoffCsp(1);
        _openCall(1, _callOpenData(2_000e8 + FLOOR_BUFFER_8));
        callLane.configureSettlement(WheelTypes.SettlementKind.CallOtm, 50e6, 10e18);
        _settleCall(1);
        _handoffCall(1);

        _reserve(2, 50e6);
        (uint256 assetsOut, uint256 principalReleased) = strategy.pull(coordinator, 50e6);
        assertEq(assetsOut, 50e6);
        assertEq(principalReleased, 0);
        assertEq(coordinator.summary().reservedPrincipalUsdc, 0);
        assertEq(coordinator.tranche(1).principalUsdc, 20_000e6);
    }

    function test_wethFallbackRebasesNextCallFloorAndKeepsLiteralStrike() public {
        _queue(20_000e6);
        _openCsp(1, _cspOpenData());
        uint256 literalStrike8 = 2_000e8;
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 10e18, literalStrike8);
        _settleCsp(1);
        _handoffCsp(1);
        _openCall(1, _callOpenData(literalStrike8 + FLOOR_BUFFER_8));

        callLane.configureSettlement(WheelTypes.SettlementKind.WethFallback, 50e6, 9e18);
        _settleCall(1);
        _handoffCall(1);

        WheelTypes.Tranche memory wethTranche = coordinator.tranche(1);
        WheelTypes.Tranche memory premiumTranche = coordinator.tranche(2);
        assertEq(wethTranche.principalUsdc, 20_000e6);
        assertEq(premiumTranche.pendingUsdc, 50e6);
        assertEq(premiumTranche.principalUsdc, 0);

        bytes memory staleFloorOpenData = _callOpenData(literalStrike8 + FLOOR_BUFFER_8);
        vm.expectRevert(WheelCoordinatorAdapter.CallStrikeBelowFloor.selector);
        _openCall(1, staleFloorOpenData);

        uint256 protectedBaseFloor8 = Math.mulDiv(20_000e6, 1e20, 9e18, Math.Rounding.Ceil);
        assertGt(protectedBaseFloor8, literalStrike8);
        assertGt(mulmod(20_000e6, 1e20, 9e18), 0);
        uint256 requiredFloor8 = protectedBaseFloor8 + FLOOR_BUFFER_8;
        bytes memory protectedFloorOpenData = _callOpenData(requiredFloor8);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit WheelCoveredCallFloorEnforced(
            1, 1, address(callLane), literalStrike8, FLOOR_BUFFER_8, requiredFloor8, requiredFloor8
        );
        _openCall(1, protectedFloorOpenData);
        assertEq(callLane.literalAssignmentStrike8(), literalStrike8);
        assertEq(callLane.protectedBaseFloor8(), protectedBaseFloor8);
        assertEq(callLane.requiredFloor8(), requiredFloor8);

        _reserve(2, 50e6);
        (uint256 assetsOut, uint256 principalReleased) = strategy.pull(coordinator, 50e6);
        assertEq(assetsOut, 50e6);
        assertEq(principalReleased, 0);
    }

    function test_partialCallAwayAfterFallbackPreservesConcentratedBasisRatio() public {
        uint256 startingPrincipal = 20_000e6;
        uint256 literalStrike8 = 2_000e8;
        _queue(startingPrincipal);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 10e18, literalStrike8);
        _settleCsp(1);
        uint256 lotId = _handoffCsp(1);
        _openCall(1, _callOpenData(literalStrike8 + FLOOR_BUFFER_8));

        callLane.configureSettlement(WheelTypes.SettlementKind.WethFallback, 0, 9e18);
        _settleCall(1);
        _handoffCall(1);
        uint256 firstProtectedFloor8 = Math.mulDiv(startingPrincipal, 1e20, 9e18, Math.Rounding.Ceil);
        _openCall(1, _callOpenData(firstProtectedFloor8 + FLOOR_BUFFER_8));

        callLane.configureSettlement(WheelTypes.SettlementKind.CallAway, 9_000e6, 5e18);
        _settleCall(1);
        _handoffCall(1);

        uint256 consumedPrincipal = Math.mulDiv(startingPrincipal, 4e18, 9e18);
        uint256 remainingPrincipal = startingPrincipal - consumedPrincipal;
        WheelTypes.Tranche memory current = coordinator.tranche(1);
        WheelTypes.AssignmentLot memory lot = coordinator.assignmentLot(lotId);
        assertEq(current.principalUsdc, remainingPrincipal);
        assertEq(lot.remainingWeth, 5e18);
        uint256 nextProtectedFloor8 = Math.mulDiv(remainingPrincipal, 1e20, 5e18, Math.Rounding.Ceil);
        assertGe(nextProtectedFloor8, firstProtectedFloor8);
        assertGe(Math.mulDiv(nextProtectedFloor8, lot.remainingWeth, 1e20), remainingPrincipal);
        bytes memory belowNextFloorOpenData = _callOpenData(nextProtectedFloor8 + FLOOR_BUFFER_8 - 1);
        vm.expectRevert(WheelCoordinatorAdapter.CallStrikeBelowFloor.selector);
        _openCall(1, belowNextFloorOpenData);
        _openCall(1, _callOpenData(nextProtectedFloor8 + FLOOR_BUFFER_8));
        assertEq(callLane.literalAssignmentStrike8(), literalStrike8);
        assertEq(callLane.requiredFloor8(), nextProtectedFloor8 + FLOOR_BUFFER_8);
    }

    function test_protectedFloorOverflowRevertsClosed() public {
        _queue(type(uint256).max);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 1, 1);
        _settleCsp(1);
        _handoffCsp(1);

        bytes memory openData = _callOpenData(type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        _openCall(1, openData);
        assertEq(uint256(callLane.laneState()), uint256(WheelTypes.LaneState.Idle));
        assertEq(uint256(coordinator.assignmentLot(1).status), uint256(WheelTypes.LotStatus.Available));
    }

    function test_lossReturnReleasesFullBasisWithoutLeavingAllocationGhost() public {
        _queue(20_000e6);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspOtm, 18_000e6, 0, 0);
        _settleCsp(1);
        _handoffCsp(1);
        assertEq(coordinator.tranche(1).principalUsdc, 20_000e6);
        assertEq(coordinator.tranche(1).pendingUsdc, 18_000e6);

        _reserve(1, 18_000e6);
        assertEq(coordinator.summary().reservedPrincipalUsdc, 20_000e6);
        (uint256 assetsOut, uint256 principalReleased) = strategy.pull(coordinator, 18_000e6);
        assertEq(assetsOut, 18_000e6);
        assertEq(principalReleased, 20_000e6);
        assertEq(coordinator.summary().reservedPrincipalUsdc, 0);
    }

    function test_splitPendingCspTrancheMovesAssetsAndBasisProportionally() public {
        _queue(1_000e6);
        uint256 siblingId = _split(1, 400e6);
        assertEq(siblingId, 2);
        assertEq(coordinator.tranche(1).pendingUsdc, 600e6);
        assertEq(coordinator.tranche(1).principalUsdc, 600e6);
        assertEq(coordinator.tranche(2).pendingUsdc, 400e6);
        assertEq(coordinator.tranche(2).principalUsdc, 400e6);
        assertEq(coordinator.summary().pendingCspUsdc, 1_000e6);
    }

    function test_directLifecycleSelectorsCannotBypassManagedEnvelope() public {
        _queue(1_000e6);
        vm.expectRevert(WheelCoordinatorAdapter.OnlyStrategyManager.selector);
        coordinator.openCspTranche(1, address(cspLane), _cspOpenData());
        vm.expectRevert(WheelCoordinatorAdapter.OnlyStrategyManager.selector);
        coordinator.reserveRedemptionUsdc(1, 1e6);
    }

    function test_managedOperationClassMismatchRevertsClosed() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                WheelManagedOperationDispatcher.InvalidManagedOperation.selector,
                uint8(WheelTypes.ManagedOperationClass.Allocation),
                WheelTypes.ManagedOperation.SettleCsp
            )
        );
        strategy.execute(
            coordinator,
            WheelTypes.ManagedOperationClass.Allocation,
            WheelTypes.ManagedOperation.SettleCsp,
            abi.encode(uint256(1))
        );
    }

    function test_idleLaneCanBeRemovedAndReplacedWithoutConsumingCapacity() public {
        _configure(WheelTypes.ManagedOperation.RemoveLane, abi.encode(address(cspLane)));
        WheelMockCspLane replacement = new WheelMockCspLane(address(coordinator), usdc, weth);
        _configure(WheelTypes.ManagedOperation.RegisterLane, abi.encode(address(replacement), WheelTypes.LaneKind.Csp));

        assertEq(coordinator.registeredLaneCount(), 2);
        bool foundReplacement;
        for (uint256 i; i < coordinator.registeredLaneCount(); ++i) {
            (address lane, WheelTypes.LaneKind kind,) = coordinator.registeredLaneAt(i);
            if (lane == address(replacement)) {
                foundReplacement = true;
                assertEq(uint256(kind), uint256(WheelTypes.LaneKind.Csp));
            }
            assertTrue(lane != address(cspLane));
        }
        assertTrue(foundReplacement);
    }

    function test_cspDelayedDeliveryAndDustCannotInvalidateExecutionCommitment() public {
        _queue(20_000e6);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 100e6, 10e18, 2_000e8);
        cspLane.delayNextSettlement();

        bytes32 expectedExecutionHash = coordinator.tranche(1).childPositionHash;
        bytes32 reconciliationBefore = cspLane.positionStateHash();
        usdc.mint(address(cspLane), 1);
        cspLane.simulateExternalAdapterLifecycle(keccak256("CSP_PHYSICAL_DELIVERY"));
        assertEq(cspLane.executionStateHash(), expectedExecutionHash);
        assertTrue(cspLane.positionStateHash() != reconciliationBefore);

        _settleCsp(1);
        expectedExecutionHash = coordinator.tranche(1).childPositionHash;
        weth.mint(address(cspLane), 1);
        cspLane.simulateExternalAdapterLifecycle(keccak256("CSP_DELIVERY_FINALIZED"));
        assertEq(cspLane.executionStateHash(), expectedExecutionHash);
        _settleCsp(1);
        _handoffCsp(1);
    }

    function test_callDelayedDeliveryAndDustCannotInvalidateExecutionCommitment() public {
        _queue(20_000e6);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 10e18, 2_000e8);
        _settleCsp(1);
        _handoffCsp(1);
        _openCall(1, _callOpenData(2_000e8 + FLOOR_BUFFER_8));
        callLane.configureSettlement(WheelTypes.SettlementKind.CallAway, 20_500e6, 0);
        callLane.delayNextSettlement();

        bytes32 expectedExecutionHash = coordinator.tranche(1).childPositionHash;
        bytes32 reconciliationBefore = callLane.positionStateHash();
        weth.mint(address(callLane), 1);
        callLane.simulateExternalAdapterLifecycle(keccak256("CALL_PHYSICAL_DELIVERY"));
        assertEq(callLane.executionStateHash(), expectedExecutionHash);
        assertTrue(callLane.positionStateHash() != reconciliationBefore);

        _settleCall(1);
        expectedExecutionHash = coordinator.tranche(1).childPositionHash;
        usdc.mint(address(callLane), 1);
        callLane.simulateExternalAdapterLifecycle(keccak256("CALL_DELIVERY_FINALIZED"));
        assertEq(callLane.executionStateHash(), expectedExecutionHash);
        _settleCall(1);
        _handoffCall(1);
    }

    function testFuzz_callFloorNeverAcceptsBelowProtectedBasisPlusBuffer(uint96 rawDeposit, uint64 rawStrike) public {
        uint256 deposit = bound(uint256(rawDeposit), 1e6, 1_000_000e6);
        uint256 strike8 = bound(uint256(rawStrike), 100e8, 100_000e8);
        _queue(deposit);
        _openCsp(1, _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 1e18, strike8);
        _settleCsp(1);
        _handoffCsp(1);

        WheelTypes.Tranche memory current = coordinator.tranche(1);
        WheelTypes.AssignmentLot memory lot = coordinator.assignmentLot(current.assignmentLotId);
        uint256 protectedBaseFloor8 =
            Math.max(strike8, Math.mulDiv(current.principalUsdc, 1e20, lot.remainingWeth, Math.Rounding.Ceil));
        bytes memory belowFloor = _callOpenData(protectedBaseFloor8 + FLOOR_BUFFER_8 - 1);
        vm.expectRevert(WheelCoordinatorAdapter.CallStrikeBelowFloor.selector);
        _openCall(1, belowFloor);

        _openCall(1, _callOpenData(protectedBaseFloor8 + FLOOR_BUFFER_8));
        assertEq(callLane.literalAssignmentStrike8(), strike8);
        assertEq(callLane.requiredFloor8(), protectedBaseFloor8 + FLOOR_BUFFER_8);
    }

    function test_runtimeBudgetLeavesUpgradeHeadroom() public view {
        bytes memory runtime = vm.getDeployedCode("src/fund/WheelCoordinatorAdapter.sol:WheelCoordinatorAdapter");
        assertLe(runtime.length, 22_500);
    }

    function _configure(WheelTypes.ManagedOperation operation, bytes memory arguments) private returns (bytes memory) {
        return strategy.execute(coordinator, WheelTypes.ManagedOperationClass.Configuration, operation, arguments);
    }

    function _allocateOperation(WheelTypes.ManagedOperation operation, bytes memory arguments)
        private
        returns (bytes memory)
    {
        return strategy.execute(coordinator, WheelTypes.ManagedOperationClass.Allocation, operation, arguments);
    }

    function _process(WheelTypes.ManagedOperation operation, bytes memory arguments) private returns (bytes memory) {
        return strategy.execute(coordinator, WheelTypes.ManagedOperationClass.Processing, operation, arguments);
    }

    function _openCsp(uint256 trancheId, bytes memory openData) private {
        _allocateOperation(WheelTypes.ManagedOperation.OpenCsp, abi.encode(trancheId, address(cspLane), openData));
    }

    function _openCall(uint256 trancheId, bytes memory openData) private {
        _allocateOperation(
            WheelTypes.ManagedOperation.OpenCoveredCall, abi.encode(trancheId, address(callLane), openData)
        );
    }

    function _settleCsp(uint256 trancheId) private {
        _process(WheelTypes.ManagedOperation.SettleCsp, abi.encode(trancheId));
    }

    function _handoffCsp(uint256 trancheId) private returns (uint256 lotId) {
        return abi.decode(_process(WheelTypes.ManagedOperation.HandoffCsp, abi.encode(trancheId)), (uint256));
    }

    function _settleCall(uint256 trancheId) private {
        _process(WheelTypes.ManagedOperation.SettleCoveredCall, abi.encode(trancheId));
    }

    function _handoffCall(uint256 trancheId) private {
        _process(WheelTypes.ManagedOperation.HandoffCoveredCall, abi.encode(trancheId));
    }

    function _reserve(uint256 trancheId, uint256 amount) private {
        _process(WheelTypes.ManagedOperation.ReserveRedemption, abi.encode(trancheId, amount));
    }

    function _release(uint256 amount) private returns (uint256 trancheId) {
        return abi.decode(_process(WheelTypes.ManagedOperation.ReleaseRedemption, abi.encode(amount)), (uint256));
    }

    function _split(uint256 trancheId, uint256 amount) private returns (uint256 siblingTrancheId) {
        return abi.decode(
            _allocateOperation(WheelTypes.ManagedOperation.SplitPendingCsp, abi.encode(trancheId, amount)), (uint256)
        );
    }

    function _queue(uint256 amount) private {
        usdc.mint(address(strategy), amount);
        strategy.queue(coordinator, usdc, amount, keccak256(abi.encode("allocation", amount)));
    }

    function _cspOpenData() private pure returns (bytes memory) {
        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: address(0xC5F),
            bidPrice: 10e8,
            deadline: type(uint256).max,
            quoteId: 1,
            maxAmount: 1e8,
            makerNonce: 0
        });
        return
            abi.encode(
                ICspFundAdapter.OpenPositionData({quote: quote, signature: "", optionAmount: 1e8, collateral: 0})
            );
    }

    function _callOpenData(uint256 strike8) private returns (bytes memory) {
        OToken oToken = new OToken();
        oToken.init(
            address(weth), address(usdc), address(weth), strike8, block.timestamp + 2 days, false, address(this)
        );
        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: address(oToken),
            bidPrice: 10e8,
            deadline: type(uint256).max,
            quoteId: 2,
            maxAmount: 1e8,
            makerNonce: 0
        });
        return abi.encode(
            ICoveredCallFundAdapter.OpenPositionData({quote: quote, signature: "", optionAmount: 1e8, collateral: 1e18})
        );
    }
}
