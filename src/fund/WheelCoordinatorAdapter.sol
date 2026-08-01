// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OToken} from "../core/OToken.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {WheelTypes} from "./WheelTypes.sol";
import {ICoveredCallFundAdapter} from "./interfaces/ICoveredCallFundAdapter.sol";
import {IWheelChildLane} from "./interfaces/IWheelChildLane.sol";
import {IWheelCoordinatorAdapter} from "./interfaces/IWheelCoordinatorAdapter.sol";
import {IWheelCoveredCallChildLane} from "./interfaces/IWheelCoveredCallChildLane.sol";
import {IWheelCspChildLane} from "./interfaces/IWheelCspChildLane.sol";
import {WheelCoordinatorAdapterStorage} from "./storage/WheelCoordinatorAdapterStorage.sol";

/// @notice USDC strategy/custody boundary for the Meta Wheel parent Fund stack.
/// @dev It owns all dedicated child-lane positions; standalone CSP/CC funds cannot be registered.
contract WheelCoordinatorAdapter is FundUpgradeable, WheelCoordinatorAdapterStorage, IWheelCoordinatorAdapter {
    using SafeERC20 for IERC20;

    bytes32 private constant INITIAL_POSITIONS_HASH = keccak256("b1nary Meta Wheel Positions");

    struct InitializeParams {
        address fund;
        address strategyManager;
        address usdc;
        address weth;
        address authority;
        uint16 maxCspLanes;
        uint16 maxCoveredCallLanes;
        uint256 floorBufferUsd8;
        bytes32 policyHash;
    }

    error AccountingDeficit();
    error AllocationPaused();
    error CallStrikeBelowFloor();
    error ChildShareMismatch();
    error DuplicateTransition(bytes32 transitionHash);
    error InKindRedemptionDisabled();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidLane();
    error InvalidSettlement();
    error InvalidTrancheLeg();
    error LaneCapacityExceeded();
    error LaneInUse();
    error OnlyStrategyManager();
    error ReentrantOperation();
    error TransferMismatch();

    event WheelLaneRegistered(address indexed lane, WheelTypes.LaneKind indexed kind);
    event WheelLaneStatusSet(address indexed lane, bool active);
    event WheelTrancheQueued(
        uint256 indexed trancheId,
        bytes32 indexed allocationId,
        uint256 usdcAmount,
        uint256 pendingCspUsdc,
        bytes32 stateHash
    );
    event WheelSiblingTrancheQueued(
        uint256 indexed parentTrancheId, uint256 indexed siblingTrancheId, uint256 usdcAmount, bytes32 stateHash
    );
    event WheelTrancheOpened(
        uint256 indexed trancheId,
        address indexed lane,
        WheelTypes.TrancheLeg leg,
        uint256 childPositionId,
        uint256 childShares,
        uint64 expiry,
        bytes32 childPositionHash
    );
    event WheelTrancheSettlementAdvanced(
        uint256 indexed trancheId,
        address indexed lane,
        WheelTypes.TrancheLeg leg,
        WheelTypes.SettlementKind settlementKind,
        bytes32 childPositionHash
    );
    event WheelChildHandoff(
        uint256 indexed trancheId,
        address indexed lane,
        bytes32 indexed transitionHash,
        WheelTypes.SettlementKind settlementKind,
        uint256 childSharesBurned,
        uint256 usdcAmount,
        uint256 wethAmount
    );
    event WheelAssignmentLotCreated(
        uint256 indexed lotId,
        uint256 indexed trancheId,
        address indexed originCspLane,
        uint256 originCspPositionId,
        uint256 wethReceived,
        uint256 literalAssignmentStrike8
    );
    event WheelCoveredCallFloorEnforced(
        uint256 indexed trancheId,
        uint256 indexed lotId,
        address indexed lane,
        uint256 literalAssignmentStrike8,
        uint256 executionCostBuffer8,
        uint256 requiredFloor8,
        uint256 callStrike8
    );
    event WheelLotStatusChanged(
        uint256 indexed lotId, WheelTypes.LotStatus status, uint256 remainingWeth, uint256 trancheId
    );
    event WheelRedemptionReserveChanged(uint256 reservedRedemptionUsdc, uint256 pendingCspUsdc);
    event WheelAccountingAssetsReturned(uint256 usdcAmount, uint256 reservedConsumed, uint256 pendingConsumed);
    event WheelAllocationPauseSet(bool paused);
    event WheelPolicyHashSet(bytes32 indexed previousPolicyHash, bytes32 indexed newPolicyHash);
    event WheelFloorBufferSet(uint256 previousFloorBufferUsd8, uint256 newFloorBufferUsd8);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitializeParams calldata params) external initializer {
        if (
            params.fund == address(0) || params.strategyManager == address(0) || params.usdc == address(0)
                || params.weth == address(0) || params.fund.code.length == 0 || params.strategyManager.code.length == 0
                || params.usdc.code.length == 0 || params.weth.code.length == 0 || params.maxCspLanes == 0
                || params.maxCoveredCallLanes == 0 || params.maxCspLanes > 32 || params.maxCoveredCallLanes > 32
                || params.policyHash == bytes32(0)
        ) revert InvalidAddress();
        __FundUpgradeable_init(params.authority);
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        $.fund = params.fund;
        $.strategyManager = params.strategyManager;
        $.usdc = params.usdc;
        $.weth = params.weth;
        $.maxCspLanes = params.maxCspLanes;
        $.maxCoveredCallLanes = params.maxCoveredCallLanes;
        $.floorBufferUsd8 = params.floorBufferUsd8;
        $.policyHash = params.policyHash;
        $.positionsHash = INITIAL_POSITIONS_HASH;
    }

    modifier onlyStrategyManager() {
        _checkStrategyManager();
        _;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _getWheelCoordinatorAdapterStorage().executing = false;
    }

    function _checkStrategyManager() private view {
        if (msg.sender != _getWheelCoordinatorAdapterStorage().strategyManager) revert OnlyStrategyManager();
    }

    function _nonReentrantBefore() private {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if ($.executing) revert ReentrantOperation();
        $.executing = true;
    }

    function fund() external view returns (address) {
        return _getWheelCoordinatorAdapterStorage().fund;
    }

    function accountingAsset() external view returns (address) {
        return _getWheelCoordinatorAdapterStorage().usdc;
    }

    function weth() external view returns (address) {
        return _getWheelCoordinatorAdapterStorage().weth;
    }

    function policyHash() external view returns (bytes32) {
        return _getWheelCoordinatorAdapterStorage().policyHash;
    }

    function floorBufferUsd8() external view returns (uint256) {
        return _getWheelCoordinatorAdapterStorage().floorBufferUsd8;
    }

    function laneCaps() external view returns (uint16 maxCspLanes, uint16 maxCoveredCallLanes) {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        return ($.maxCspLanes, $.maxCoveredCallLanes);
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function deallocationInterfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function summary() external view returns (Summary memory state) {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        state = Summary({
            stateNonce: $.stateNonce,
            trancheCount: $.trancheCount,
            assignmentLotCount: $.assignmentLotCount,
            pendingCspUsdc: $.pendingCspUsdc,
            reservedRedemptionUsdc: $.reservedRedemptionUsdc,
            transitionWeth: $.transitionWeth,
            accountedUsdc: $.accountedUsdc,
            accountedWeth: $.accountedWeth
        });
    }

    function tranche(uint256 trancheId) external view returns (WheelTypes.Tranche memory) {
        return _getWheelCoordinatorAdapterStorage().tranches[trancheId];
    }

    function assignmentLot(uint256 lotId) external view returns (WheelTypes.AssignmentLot memory) {
        return _getWheelCoordinatorAdapterStorage().lots[lotId];
    }

    function registeredLaneCount() external view returns (uint256) {
        return _getWheelCoordinatorAdapterStorage().registeredLanes.length;
    }

    function registeredLaneAt(uint256 index)
        external
        view
        returns (address lane, WheelTypes.LaneKind kind, bool active)
    {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        lane = $.registeredLanes[index];
        LaneConfig storage config = $.lanes[lane];
        return (lane, config.kind, config.active);
    }

    function positionStateHash() public view returns (bytes32) {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.fund,
                $.stateNonce,
                $.positionsHash,
                $.trancheCount,
                $.assignmentLotCount,
                $.pendingCspUsdc,
                $.reservedRedemptionUsdc,
                $.transitionWeth,
                $.accountedUsdc,
                $.accountedWeth,
                $.floorBufferUsd8,
                $.policyHash,
                IERC20($.usdc).balanceOf(address(this)),
                IERC20($.weth).balanceOf(address(this))
            )
        );
    }

    function freeAssets(address asset) external view returns (uint256) {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if (asset == $.usdc) {
            return Math.min($.accountedUsdc, IERC20(asset).balanceOf(address(this)));
        }
        if (asset == $.weth) {
            return Math.min($.accountedWeth, IERC20(asset).balanceOf(address(this)));
        }
        return 0;
    }

    function registerLane(address lane, WheelTypes.LaneKind kind) external restricted {
        if (
            lane == address(0) || lane.code.length == 0
                || (kind != WheelTypes.LaneKind.Csp && kind != WheelTypes.LaneKind.CoveredCall)
                || IWheelChildLane(lane).coordinator() != address(this) || IWheelChildLane(lane).laneKind() != kind
        ) revert InvalidLane();
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if (
            kind == WheelTypes.LaneKind.CoveredCall
                && IWheelCoveredCallChildLane(lane).executionCostBuffer8() != $.floorBufferUsd8
        ) revert InvalidLane();
        if ($.lanes[lane].kind != WheelTypes.LaneKind.None) revert InvalidLane();

        uint256 sameKind;
        for (uint256 i; i < $.registeredLanes.length; ++i) {
            if ($.lanes[$.registeredLanes[i]].kind == kind) ++sameKind;
        }
        uint256 maximum = kind == WheelTypes.LaneKind.Csp ? $.maxCspLanes : $.maxCoveredCallLanes;
        if (sameKind >= maximum) revert LaneCapacityExceeded();
        $.lanes[lane] = LaneConfig({kind: kind, active: true});
        $.registeredLanes.push(lane);
        _checkpoint($, keccak256(abi.encode("REGISTER_LANE", lane, kind)));
        emit WheelLaneRegistered(lane, kind);
    }

    function setLaneActive(address lane, bool active) external restricted {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if ($.lanes[lane].kind == WheelTypes.LaneKind.None) {
            revert InvalidLane();
        }
        if (!active && $.activeLaneTranche[lane] != 0) revert LaneInUse();
        $.lanes[lane].active = active;
        _checkpoint($, keccak256(abi.encode("SET_LANE_ACTIVE", lane, active)));
        emit WheelLaneStatusSet(lane, active);
    }

    function allocate(address asset, uint256 amount, bytes calldata data) external onlyStrategyManager nonReentrant {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if ($.allocationsPaused) revert AllocationPaused();
        if (asset != $.usdc || amount == 0 || IERC20($.usdc).balanceOf(address(this)) < $.accountedUsdc + amount) {
            revert InvalidAmount();
        }
        bytes32 allocationId;
        if (data.length == 32) allocationId = abi.decode(data, (bytes32));
        else if (data.length != 0) revert InvalidAmount();
        if (allocationId == bytes32(0)) {
            allocationId = keccak256(abi.encode(block.chainid, address(this), $.trancheCount + 1, amount, $.stateNonce));
        }

        uint256 trancheId = ++$.trancheCount;
        $.accountedUsdc += amount;
        $.pendingCspUsdc += amount;
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        current.leg = WheelTypes.TrancheLeg.PendingCsp;
        current.pendingUsdc = amount;
        _checkpointTranche($, trancheId, keccak256(abi.encode("QUEUE", allocationId, amount)));
        emit WheelTrancheQueued(trancheId, allocationId, amount, $.pendingCspUsdc, current.stateHash);
    }

    function openCspTranche(uint256 trancheId, address lane, bytes calldata openData) external restricted nonReentrant {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if ($.allocationsPaused) revert AllocationPaused();
        _requireLane($, lane, WheelTypes.LaneKind.Csp);
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.PendingCsp);
        if ($.activeLaneTranche[lane] != 0) revert LaneInUse();
        uint256 amount = current.pendingUsdc;
        if (amount == 0 || amount > $.pendingCspUsdc || amount > $.accountedUsdc) revert InvalidAmount();

        bytes32 transitionHash = _consumeNextTransition($, trancheId, "OPEN_CSP", lane);
        IERC20 usdcToken = IERC20($.usdc);
        uint256 beforeBalance = usdcToken.balanceOf(address(this));
        usdcToken.forceApprove(lane, amount);
        (uint256 shares, uint256 positionId, uint64 expiry, bytes32 childHash) =
            IWheelCspChildLane(lane).openCsp(trancheId, transitionHash, amount, openData);
        usdcToken.forceApprove(lane, 0);
        uint256 spent = beforeBalance - usdcToken.balanceOf(address(this));
        if (spent != amount) revert TransferMismatch();
        if (shares == 0) revert ChildShareMismatch();

        $.accountedUsdc -= spent;
        $.pendingCspUsdc -= spent;
        $.activeLaneTranche[lane] = trancheId;
        current.leg = WheelTypes.TrancheLeg.CspOpen;
        current.childLane = lane;
        current.pendingUsdc = 0;
        current.childShares = shares;
        current.childPositionId = positionId;
        current.expiry = expiry;
        current.childPositionHash = childHash;
        _checkpointTranche($, trancheId, transitionHash);
        emit WheelTrancheOpened(trancheId, lane, current.leg, positionId, shares, expiry, childHash);
    }

    function settleCspTranche(uint256 trancheId) external restricted nonReentrant {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        if (current.leg != WheelTypes.TrancheLeg.CspOpen && current.leg != WheelTypes.TrancheLeg.CspSettling) {
            revert InvalidTrancheLeg();
        }
        (WheelTypes.SettlementKind kind, bytes32 childHash) =
            IWheelCspChildLane(current.childLane).settleCsp(trancheId, current.childPositionHash);
        current.leg = WheelTypes.TrancheLeg.CspSettling;
        current.childPositionHash = childHash;
        _checkpointTranche($, trancheId, keccak256(abi.encode("SETTLE_CSP", kind, childHash)));
        emit WheelTrancheSettlementAdvanced(trancheId, current.childLane, current.leg, kind, childHash);
    }

    function handoffCspTranche(uint256 trancheId) external restricted nonReentrant returns (uint256 lotId) {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.CspSettling);
        address lane = current.childLane;
        bytes32 transitionHash = _consumeNextTransition($, trancheId, "HANDOFF_CSP", lane);
        uint256 usdcBefore = IERC20($.usdc).balanceOf(address(this));
        uint256 wethBefore = IERC20($.weth).balanceOf(address(this));
        WheelTypes.LaneBasket memory basket =
            IWheelCspChildLane(lane).handoffCsp(trancheId, current.childPositionHash, transitionHash, address(this));
        _validateBasketDelta($, basket, usdcBefore, wethBefore, current.childShares, transitionHash);
        if (basket.settlementKind == WheelTypes.SettlementKind.None) {
            revert InvalidSettlement();
        }

        $.activeLaneTranche[lane] = 0;
        $.accountedUsdc += basket.usdcAmount;
        $.accountedWeth += basket.wethAmount;
        $.pendingCspUsdc += basket.usdcAmount;
        current.childLane = address(0);
        current.childShares = 0;
        current.childPositionHash = bytes32(0);
        if (basket.wethAmount != 0) {
            if (basket.literalAssignmentStrike8 == 0) revert InvalidAmount();
            _splitPendingUsdc($, current, trancheId, basket.usdcAmount, transitionHash);
            lotId = ++$.assignmentLotCount;
            $.lots[lotId] = WheelTypes.AssignmentLot({
                originCspLane: lane,
                createdAt: uint64(block.timestamp),
                status: WheelTypes.LotStatus.Available,
                trancheId: trancheId,
                originCspPositionId: basket.positionId,
                wethReceived: basket.wethAmount,
                remainingWeth: basket.wethAmount,
                literalAssignmentStrike8: basket.literalAssignmentStrike8
            });
            $.transitionWeth += basket.wethAmount;
            current.assignmentLotId = lotId;
            current.leg = WheelTypes.TrancheLeg.WethTransition;
            emit WheelAssignmentLotCreated(
                lotId, trancheId, lane, basket.positionId, basket.wethAmount, basket.literalAssignmentStrike8
            );
            emit WheelLotStatusChanged(lotId, WheelTypes.LotStatus.Available, basket.wethAmount, trancheId);
        } else {
            current.pendingUsdc = basket.usdcAmount;
            current.leg = WheelTypes.TrancheLeg.PendingCsp;
        }
        _checkpointTranche($, trancheId, transitionHash);
        _requireNoDeficit($);
        emit WheelChildHandoff(
            trancheId,
            lane,
            transitionHash,
            basket.settlementKind,
            basket.childSharesBurned,
            basket.usdcAmount,
            basket.wethAmount
        );
    }

    function openCoveredCallTranche(uint256 trancheId, address lane, bytes calldata openData)
        external
        restricted
        nonReentrant
    {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if ($.allocationsPaused) revert AllocationPaused();
        _requireLane($, lane, WheelTypes.LaneKind.CoveredCall);
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.WethTransition);
        if ($.activeLaneTranche[lane] != 0) revert LaneInUse();
        WheelTypes.AssignmentLot storage lot = $.lots[current.assignmentLotId];
        if (lot.status != WheelTypes.LotStatus.Available || lot.remainingWeth == 0) revert InvalidAmount();

        ICoveredCallFundAdapter.OpenPositionData memory decoded =
            abi.decode(openData, (ICoveredCallFundAdapter.OpenPositionData));
        uint256 buffer8 = IWheelCoveredCallChildLane(lane).executionCostBuffer8();
        if (buffer8 != $.floorBufferUsd8) revert InvalidLane();
        uint256 requiredFloor8 = lot.literalAssignmentStrike8 + buffer8;
        uint256 callStrike8 = OToken(decoded.quote.oToken).strikePrice();
        if (callStrike8 < requiredFloor8) revert CallStrikeBelowFloor();

        uint256 amount = lot.remainingWeth;
        bytes32 transitionHash = _consumeNextTransition($, trancheId, "OPEN_CALL", lane);
        IERC20 wethToken = IERC20($.weth);
        uint256 beforeBalance = wethToken.balanceOf(address(this));
        wethToken.forceApprove(lane, amount);
        (uint256 shares, uint256 positionId, uint64 expiry, bytes32 childHash) = IWheelCoveredCallChildLane(lane)
            .openCoveredCall(
                trancheId, transitionHash, current.assignmentLotId, lot.literalAssignmentStrike8, amount, openData
            );
        wethToken.forceApprove(lane, 0);
        uint256 spent = beforeBalance - wethToken.balanceOf(address(this));
        if (spent != amount) revert TransferMismatch();
        if (shares != amount) revert ChildShareMismatch();

        $.accountedWeth -= spent;
        $.transitionWeth -= spent;
        $.activeLaneTranche[lane] = trancheId;
        lot.status = WheelTypes.LotStatus.InCall;
        current.leg = WheelTypes.TrancheLeg.CallOpen;
        current.childLane = lane;
        current.childShares = shares;
        current.childPositionId = positionId;
        current.expiry = expiry;
        current.childPositionHash = childHash;
        _checkpointTranche($, trancheId, transitionHash);
        emit WheelCoveredCallFloorEnforced(
            trancheId, current.assignmentLotId, lane, lot.literalAssignmentStrike8, buffer8, requiredFloor8, callStrike8
        );
        emit WheelLotStatusChanged(current.assignmentLotId, lot.status, lot.remainingWeth, trancheId);
        emit WheelTrancheOpened(trancheId, lane, current.leg, positionId, shares, expiry, childHash);
    }

    function settleCoveredCallTranche(uint256 trancheId) external restricted nonReentrant {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        if (current.leg != WheelTypes.TrancheLeg.CallOpen && current.leg != WheelTypes.TrancheLeg.CallSettling) {
            revert InvalidTrancheLeg();
        }
        (WheelTypes.SettlementKind kind, bytes32 childHash) =
            IWheelCoveredCallChildLane(current.childLane).settleCoveredCall(trancheId, current.childPositionHash);
        current.leg = WheelTypes.TrancheLeg.CallSettling;
        current.childPositionHash = childHash;
        _checkpointTranche($, trancheId, keccak256(abi.encode("SETTLE_CALL", kind, childHash)));
        emit WheelTrancheSettlementAdvanced(trancheId, current.childLane, current.leg, kind, childHash);
    }

    function handoffCoveredCallTranche(uint256 trancheId) external restricted nonReentrant {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.CallSettling);
        address lane = current.childLane;
        bytes32 transitionHash = _consumeNextTransition($, trancheId, "HANDOFF_CALL", lane);
        uint256 usdcBefore = IERC20($.usdc).balanceOf(address(this));
        uint256 wethBefore = IERC20($.weth).balanceOf(address(this));
        WheelTypes.LaneBasket memory basket = IWheelCoveredCallChildLane(lane)
            .handoffCoveredCall(trancheId, current.childPositionHash, transitionHash, address(this));
        _validateBasketDelta($, basket, usdcBefore, wethBefore, current.childShares, transitionHash);
        if (basket.settlementKind == WheelTypes.SettlementKind.None) {
            revert InvalidSettlement();
        }

        uint256 lotId = current.assignmentLotId;
        WheelTypes.AssignmentLot storage lot = $.lots[lotId];
        $.activeLaneTranche[lane] = 0;
        $.accountedUsdc += basket.usdcAmount;
        $.accountedWeth += basket.wethAmount;
        $.pendingCspUsdc += basket.usdcAmount;
        $.transitionWeth += basket.wethAmount;
        current.childLane = address(0);
        current.childShares = 0;
        current.childPositionHash = bytes32(0);
        lot.remainingWeth = basket.wethAmount;
        if (basket.wethAmount == 0) {
            lot.status = WheelTypes.LotStatus.CalledAway;
            current.pendingUsdc += basket.usdcAmount;
            current.leg = WheelTypes.TrancheLeg.PendingCsp;
        } else {
            lot.status = WheelTypes.LotStatus.Available;
            _splitPendingUsdc($, current, trancheId, basket.usdcAmount, transitionHash);
            current.leg = WheelTypes.TrancheLeg.WethTransition;
        }
        _checkpointTranche($, trancheId, transitionHash);
        _requireNoDeficit($);
        emit WheelLotStatusChanged(lotId, lot.status, lot.remainingWeth, trancheId);
        emit WheelChildHandoff(
            trancheId,
            lane,
            transitionHash,
            basket.settlementKind,
            basket.childSharesBurned,
            basket.usdcAmount,
            basket.wethAmount
        );
    }

    function reserveRedemptionUsdc(uint256 amount) external restricted {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if (amount == 0 || amount > $.pendingCspUsdc) revert InvalidAmount();
        $.pendingCspUsdc -= amount;
        $.reservedRedemptionUsdc += amount;
        _checkpoint($, keccak256(abi.encode("RESERVE_REDEMPTION", amount)));
        emit WheelRedemptionReserveChanged($.reservedRedemptionUsdc, $.pendingCspUsdc);
    }

    function releaseRedemptionUsdc(uint256 amount) external restricted {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if (amount == 0 || amount > $.reservedRedemptionUsdc) revert InvalidAmount();
        $.reservedRedemptionUsdc -= amount;
        $.pendingCspUsdc += amount;
        _checkpoint($, keccak256(abi.encode("RELEASE_REDEMPTION", amount)));
        emit WheelRedemptionReserveChanged($.reservedRedemptionUsdc, $.pendingCspUsdc);
    }

    function deallocate(uint256 targetValue, uint256 minAccountingAssetsOut, bytes calldata)
        external
        onlyStrategyManager
        nonReentrant
        returns (uint256 accountingAssetsOut, uint256 principalReleased)
    {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        uint256 available = $.reservedRedemptionUsdc + $.pendingCspUsdc;
        if (targetValue == 0 || targetValue > available || targetValue > $.accountedUsdc) revert InvalidAmount();
        accountingAssetsOut = targetValue;
        if (accountingAssetsOut < minAccountingAssetsOut) revert InvalidAmount();
        uint256 reservedConsumed = Math.min($.reservedRedemptionUsdc, accountingAssetsOut);
        uint256 pendingConsumed = accountingAssetsOut - reservedConsumed;
        $.reservedRedemptionUsdc -= reservedConsumed;
        $.pendingCspUsdc -= pendingConsumed;
        $.accountedUsdc -= accountingAssetsOut;
        principalReleased = accountingAssetsOut;
        _checkpoint($, keccak256(abi.encode("RETURN_USDC", accountingAssetsOut, reservedConsumed, pendingConsumed)));
        _transferExact(IERC20($.usdc), $.fund, accountingAssetsOut);
        emit WheelAccountingAssetsReturned(accountingAssetsOut, reservedConsumed, pendingConsumed);
    }

    function deallocateInKind(uint256, address, bytes calldata)
        external
        pure
        returns (address[] memory, uint256[] memory)
    {
        revert InKindRedemptionDisabled();
    }

    function emergencyExit(address escrow, bytes calldata)
        external
        onlyStrategyManager
        nonReentrant
        returns (address[] memory assets, uint256[] memory amounts)
    {
        if (escrow == address(0)) revert InvalidAddress();
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        for (uint256 i; i < $.registeredLanes.length; ++i) {
            if (IWheelChildLane($.registeredLanes[i]).childShares() != 0) revert LaneInUse();
        }
        _requireNoDeficit($);
        assets = new address[](2);
        amounts = new uint256[](2);
        assets[0] = $.usdc;
        assets[1] = $.weth;
        amounts[0] = $.accountedUsdc;
        amounts[1] = $.accountedWeth;
        $.accountedUsdc = 0;
        $.accountedWeth = 0;
        $.pendingCspUsdc = 0;
        $.reservedRedemptionUsdc = 0;
        $.transitionWeth = 0;
        _checkpoint($, keccak256(abi.encode("EMERGENCY_IN_KIND", escrow, amounts)));
        _transferExact(IERC20($.usdc), escrow, amounts[0]);
        _transferExact(IERC20($.weth), escrow, amounts[1]);
    }

    function pauseAllocations() external restricted {
        _getWheelCoordinatorAdapterStorage().allocationsPaused = true;
        emit WheelAllocationPauseSet(true);
    }

    function resumeAllocations() external restricted {
        _getWheelCoordinatorAdapterStorage().allocationsPaused = false;
        emit WheelAllocationPauseSet(false);
    }

    function setPolicyHash(bytes32 newPolicyHash) external restricted {
        if (newPolicyHash == bytes32(0)) revert InvalidAmount();
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        bytes32 previous = $.policyHash;
        $.policyHash = newPolicyHash;
        _checkpoint($, keccak256(abi.encode("SET_POLICY_HASH", previous, newPolicyHash)));
        emit WheelPolicyHashSet(previous, newPolicyHash);
    }

    /// @notice Finalizes a buffer already applied to every registered CC lane by the curator.
    function setFloorBufferUsd8(uint256 newFloorBufferUsd8) external restricted {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        for (uint256 i; i < $.registeredLanes.length; ++i) {
            address lane = $.registeredLanes[i];
            if (
                $.lanes[lane].kind == WheelTypes.LaneKind.CoveredCall
                    && IWheelCoveredCallChildLane(lane).executionCostBuffer8() != newFloorBufferUsd8
            ) revert InvalidLane();
        }
        uint256 previous = $.floorBufferUsd8;
        $.floorBufferUsd8 = newFloorBufferUsd8;
        _checkpoint($, keccak256(abi.encode("SET_FLOOR_BUFFER", previous, newFloorBufferUsd8)));
        emit WheelFloorBufferSet(previous, newFloorBufferUsd8);
    }

    function _requireLane(
        WheelCoordinatorAdapterStorageLayout storage $,
        address lane,
        WheelTypes.LaneKind expectedKind
    ) private view {
        LaneConfig storage config = $.lanes[lane];
        if (!config.active || config.kind != expectedKind || IWheelChildLane(lane).coordinator() != address(this)) {
            revert InvalidLane();
        }
    }

    function _splitPendingUsdc(
        WheelCoordinatorAdapterStorageLayout storage $,
        WheelTypes.Tranche storage parent,
        uint256 parentTrancheId,
        uint256 returnedUsdc,
        bytes32 transitionHash
    ) private {
        uint256 siblingUsdc = parent.pendingUsdc + returnedUsdc;
        parent.pendingUsdc = 0;
        if (siblingUsdc == 0) return;

        uint256 siblingTrancheId = ++$.trancheCount;
        WheelTypes.Tranche storage sibling = $.tranches[siblingTrancheId];
        sibling.leg = WheelTypes.TrancheLeg.PendingCsp;
        sibling.pendingUsdc = siblingUsdc;
        _checkpointTranche(
            $, siblingTrancheId, keccak256(abi.encode("SPLIT_USDC", parentTrancheId, transitionHash, siblingUsdc))
        );
        emit WheelSiblingTrancheQueued(parentTrancheId, siblingTrancheId, siblingUsdc, sibling.stateHash);
    }

    function _requireLeg(WheelTypes.Tranche storage current, WheelTypes.TrancheLeg expected) private view {
        if (current.leg != expected) revert InvalidTrancheLeg();
    }

    function _consumeNextTransition(
        WheelCoordinatorAdapterStorageLayout storage $,
        uint256 trancheId,
        bytes32 action,
        address lane
    ) private returns (bytes32 transitionHash) {
        transitionHash = keccak256(
            abi.encode(block.chainid, address(this), trancheId, $.stateNonce + 1, action, lane, $.positionsHash)
        );
        if ($.consumedTransitions[transitionHash]) revert DuplicateTransition(transitionHash);
        $.consumedTransitions[transitionHash] = true;
    }

    function _checkpointTranche(
        WheelCoordinatorAdapterStorageLayout storage $,
        uint256 trancheId,
        bytes32 operationHash
    ) private {
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        uint64 nonce = ++$.stateNonce;
        current.stateNonce++;
        current.stateHash = keccak256(
            abi.encode(
                current.stateHash,
                current.stateNonce,
                trancheId,
                current.leg,
                current.childLane,
                current.childShares,
                current.childPositionId,
                current.assignmentLotId,
                current.childPositionHash,
                operationHash
            )
        );
        $.positionsHash = keccak256(abi.encode($.positionsHash, nonce, trancheId, current.stateHash));
    }

    function _checkpoint(WheelCoordinatorAdapterStorageLayout storage $, bytes32 operationHash) private {
        uint64 nonce = ++$.stateNonce;
        $.positionsHash = keccak256(abi.encode($.positionsHash, nonce, operationHash));
    }

    function _validateBasketDelta(
        WheelCoordinatorAdapterStorageLayout storage $,
        WheelTypes.LaneBasket memory basket,
        uint256 usdcBefore,
        uint256 wethBefore,
        uint256 expectedShares,
        bytes32 transitionHash
    ) private view {
        if (basket.transitionHash != transitionHash) {
            revert DuplicateTransition(basket.transitionHash);
        }
        if (basket.childSharesBurned != expectedShares) {
            revert ChildShareMismatch();
        }
        uint256 observedUsdc = IERC20($.usdc).balanceOf(address(this)) - usdcBefore;
        uint256 observedWeth = IERC20($.weth).balanceOf(address(this)) - wethBefore;
        if (observedUsdc != basket.usdcAmount) revert TransferMismatch();
        if (observedWeth != basket.wethAmount) revert TransferMismatch();
    }

    function _requireNoDeficit(WheelCoordinatorAdapterStorageLayout storage $) private view {
        uint256 rawUsdc = IERC20($.usdc).balanceOf(address(this));
        uint256 rawWeth = IERC20($.weth).balanceOf(address(this));
        if (rawUsdc < $.accountedUsdc) revert AccountingDeficit();
        if (rawWeth < $.accountedWeth) revert AccountingDeficit();
    }

    function _transferExact(IERC20 token, address receiver, uint256 amount) private {
        if (amount == 0) return;
        uint256 receiverBefore = token.balanceOf(receiver);
        token.safeTransfer(receiver, amount);
        uint256 received = token.balanceOf(receiver) - receiverBefore;
        if (received != amount) revert TransferMismatch();
    }
}
