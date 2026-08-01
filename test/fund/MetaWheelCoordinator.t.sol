// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
        return _hash;
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
        uint256 literalAssignmentStrike8,
        uint256 wethAmount,
        bytes calldata openData
    ) external returns (uint256 mintedChildShares, uint256 positionId, uint64 expiry, bytes32 positionHash) {
        require(msg.sender == coordinator && _state == WheelTypes.LaneState.Idle, "OPEN");
        ICoveredCallFundAdapter.OpenPositionData memory decoded =
            abi.decode(openData, (ICoveredCallFundAdapter.OpenPositionData));
        requiredFloor8 = literalAssignmentStrike8 + executionCostBuffer8;
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
        coordinator.registerLane(address(cspLane), WheelTypes.LaneKind.Csp);
        coordinator.registerLane(address(callLane), WheelTypes.LaneKind.CoveredCall);
    }

    function test_assignmentCallAwayCycleTracksLiteralFloorAndQueuesReturnedUsdc() public {
        uint256 deposit = 20_000e6;
        _queue(deposit);
        coordinator.openCspTranche(1, address(cspLane), _cspOpenData());

        uint256 assignmentStrike8 = 2_000e8;
        uint256 assignedWeth = 10e18;
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 100e6, assignedWeth, assignmentStrike8);
        coordinator.settleCspTranche(1);
        uint256 lotId = coordinator.handoffCspTranche(1);
        WheelTypes.AssignmentLot memory lot = coordinator.assignmentLot(lotId);
        WheelTypes.Tranche memory assignedTranche = coordinator.tranche(1);
        WheelTypes.Tranche memory residualTranche = coordinator.tranche(2);
        assertEq(lot.literalAssignmentStrike8, assignmentStrike8);
        assertEq(lot.wethReceived, assignedWeth);
        assertEq(uint256(lot.status), uint256(WheelTypes.LotStatus.Available));
        assertEq(assignedTranche.pendingUsdc, 0);
        assertEq(uint256(assignedTranche.leg), uint256(WheelTypes.TrancheLeg.WethTransition));
        assertEq(residualTranche.pendingUsdc, 100e6);
        assertEq(uint256(residualTranche.leg), uint256(WheelTypes.TrancheLeg.PendingCsp));

        bytes memory belowFloor = _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8 - 1);
        vm.expectRevert(WheelCoordinatorAdapter.CallStrikeBelowFloor.selector);
        coordinator.openCoveredCallTranche(1, address(callLane), belowFloor);

        coordinator.openCoveredCallTranche(1, address(callLane), _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8));
        coordinator.openCspTranche(2, address(cspLane), _cspOpenData());
        assertEq(uint256(callLane.laneState()), uint256(WheelTypes.LaneState.Open));
        assertEq(uint256(cspLane.laneState()), uint256(WheelTypes.LaneState.Open));
        callLane.configureSettlement(WheelTypes.SettlementKind.CallAway, 20_500e6, 0);
        coordinator.settleCoveredCallTranche(1);
        coordinator.handoffCoveredCallTranche(1);

        lot = coordinator.assignmentLot(lotId);
        assertEq(uint256(lot.status), uint256(WheelTypes.LotStatus.CalledAway));
        assertEq(lot.remainingWeth, 0);
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.pendingCspUsdc, 20_500e6);
        assertEq(state.accountedUsdc, 20_500e6);
        assertEq(state.accountedWeth, 0);
        assertEq(state.transitionWeth, 0);

        vm.expectRevert(WheelCoordinatorAdapter.InvalidTrancheLeg.selector);
        coordinator.handoffCoveredCallTranche(1);
    }

    function test_callOtmSplitsPremiumIntoSiblingWhileLotImmediatelyReopens() public {
        _queue(20_000e6);
        coordinator.openCspTranche(1, address(cspLane), _cspOpenData());
        uint256 assignmentStrike8 = 2_000e8;
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 100e6, 10e18, assignmentStrike8);
        coordinator.settleCspTranche(1);
        coordinator.handoffCspTranche(1);
        coordinator.openCoveredCallTranche(1, address(callLane), _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8));

        callLane.configureSettlement(WheelTypes.SettlementKind.CallOtm, 50e6, 10e18);
        coordinator.settleCoveredCallTranche(1);
        coordinator.handoffCoveredCallTranche(1);

        WheelTypes.Tranche memory callTranche = coordinator.tranche(1);
        WheelTypes.Tranche memory premiumTranche = coordinator.tranche(3);
        assertEq(uint256(callTranche.leg), uint256(WheelTypes.TrancheLeg.WethTransition));
        assertEq(callTranche.pendingUsdc, 0);
        assertEq(uint256(premiumTranche.leg), uint256(WheelTypes.TrancheLeg.PendingCsp));
        assertEq(premiumTranche.pendingUsdc, 50e6);

        coordinator.openCoveredCallTranche(1, address(callLane), _callOpenData(assignmentStrike8 + FLOOR_BUFFER_8));
        coordinator.openCspTranche(3, address(cspLane), _cspOpenData());
        assertEq(uint256(callLane.laneState()), uint256(WheelTypes.LaneState.Open));
        assertEq(uint256(cspLane.laneState()), uint256(WheelTypes.LaneState.Open));
    }

    function test_redemptionReserveIsConsumedBeforePendingCspLiquidity() public {
        _queue(1_000e6);
        coordinator.reserveRedemptionUsdc(400e6);
        strategy.pull(coordinator, 500e6);
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.reservedRedemptionUsdc, 0);
        assertEq(state.pendingCspUsdc, 500e6);
        assertEq(state.accountedUsdc, 500e6);
        assertEq(usdc.balanceOf(address(fund)), 500e6);
    }

    function testFuzz_callFloorNeverAcceptsBelowLiteralPlusBuffer(uint96 rawDeposit, uint64 rawStrike) public {
        uint256 deposit = bound(uint256(rawDeposit), 1e6, 1_000_000e6);
        uint256 strike8 = bound(uint256(rawStrike), 100e8, 100_000e8);
        _queue(deposit);
        coordinator.openCspTranche(1, address(cspLane), _cspOpenData());
        cspLane.configureSettlement(WheelTypes.SettlementKind.CspAssigned, 0, 1e18, strike8);
        coordinator.settleCspTranche(1);
        coordinator.handoffCspTranche(1);

        bytes memory belowFloor = _callOpenData(strike8 + FLOOR_BUFFER_8 - 1);
        vm.expectRevert(WheelCoordinatorAdapter.CallStrikeBelowFloor.selector);
        coordinator.openCoveredCallTranche(1, address(callLane), belowFloor);
    }

    function test_runtimeBudgetLeavesUpgradeHeadroom() public view {
        bytes memory runtime = vm.getDeployedCode("src/fund/WheelCoordinatorAdapter.sol:WheelCoordinatorAdapter");
        assertLe(runtime.length, 22_500);
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
