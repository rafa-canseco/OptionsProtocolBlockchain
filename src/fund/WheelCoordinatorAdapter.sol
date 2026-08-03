// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {WheelTypes} from "./WheelTypes.sol";
import {IWheelChildLane} from "./interfaces/IWheelChildLane.sol";
import {IWheelCoordinatorAdapter} from "./interfaces/IWheelCoordinatorAdapter.sol";
import {IWheelCoveredCallChildLane} from "./interfaces/IWheelCoveredCallChildLane.sol";
import {IWheelCspChildLane} from "./interfaces/IWheelCspChildLane.sol";
import {IManagedStrategyAdapter} from "./interfaces/IManagedStrategyAdapter.sol";
import {WheelCoordinatorAdapterStorage} from "./storage/WheelCoordinatorAdapterStorage.sol";
import {WheelManagedOperationDispatcher} from "./libraries/WheelManagedOperationDispatcher.sol";
import {WheelCoordinatorPositionOperations} from "./libraries/WheelCoordinatorPositionOperations.sol";

/// @notice USDC strategy/custody boundary for the Meta Wheel parent Fund stack.
/// @dev It owns all dedicated child-lane positions; standalone CSP/CC funds cannot be registered.
contract WheelCoordinatorAdapter is
    FundUpgradeable,
    WheelCoordinatorAdapterStorage,
    IWheelCoordinatorAdapter,
    IManagedStrategyAdapter
{
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
    event WheelLaneRemoved(address indexed lane, WheelTypes.LaneKind indexed kind);
    event WheelLaneStatusSet(address indexed lane, bool active);
    event WheelTrancheQueued(
        uint256 indexed trancheId,
        bytes32 indexed allocationId,
        uint256 usdcAmount,
        uint256 pendingCspUsdc,
        bytes32 stateHash
    );
    event WheelSiblingTrancheQueued(
        uint256 indexed parentTrancheId,
        uint256 indexed siblingTrancheId,
        uint256 usdcAmount,
        uint256 principalUsdc,
        bytes32 stateHash
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
    event WheelRedemptionUsdcReserved(
        uint256 indexed trancheId,
        uint256 amount,
        uint256 principalReserved,
        uint256 remainingTrancheUsdc,
        uint256 remainingTranchePrincipal
    );
    event WheelRedemptionUsdcReleased(
        uint256 indexed trancheId, uint256 amount, uint256 principalRestored, bytes32 stateHash
    );
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

    modifier onlyManagedCaller() {
        if (msg.sender != address(this)) revert OnlyStrategyManager();
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
            reservedPrincipalUsdc: $.reservedPrincipalUsdc,
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
                $.reservedPrincipalUsdc,
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

    /// @notice Entry point invoked by StrategyManager inside its fund lock/NAV synchronization envelope.
    function executeManagedOperation(uint8 operationClass, bytes calldata data)
        external
        onlyStrategyManager
        returns (bytes memory result)
    {
        return WheelManagedOperationDispatcher.dispatch(operationClass, data);
    }

    function registerLane(address lane, WheelTypes.LaneKind kind) external onlyManagedCaller {
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

    function removeLane(address lane) external onlyManagedCaller {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        WheelTypes.LaneKind kind = $.lanes[lane].kind;
        if (
            kind == WheelTypes.LaneKind.None || $.activeLaneTranche[lane] != 0
                || IWheelChildLane(lane).childShares() != 0
        ) revert LaneInUse();
        uint256 length = $.registeredLanes.length;
        for (uint256 i; i < length; ++i) {
            if ($.registeredLanes[i] != lane) continue;
            if (i != length - 1) $.registeredLanes[i] = $.registeredLanes[length - 1];
            $.registeredLanes.pop();
            delete $.lanes[lane];
            _checkpoint($, keccak256(abi.encode("REMOVE_LANE", lane, kind)));
            emit WheelLaneRemoved(lane, kind);
            return;
        }
        revert InvalidLane();
    }

    function setLaneActive(address lane, bool active) external onlyManagedCaller {
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
        current.principalUsdc = amount;
        current.pendingUsdc = amount;
        _checkpointTranche($, trancheId, keccak256(abi.encode("QUEUE", allocationId, amount)));
        emit WheelTrancheQueued(trancheId, allocationId, amount, $.pendingCspUsdc, current.stateHash);
    }

    function openCspTranche(uint256 trancheId, address lane, bytes calldata openData)
        external
        onlyManagedCaller
        nonReentrant
    {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if ($.allocationsPaused) revert AllocationPaused();
        WheelCoordinatorPositionOperations.openCsp($, trancheId, lane, openData);
    }

    function settleCspTranche(uint256 trancheId) external onlyManagedCaller nonReentrant {
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

    function handoffCspTranche(uint256 trancheId) external onlyManagedCaller nonReentrant returns (uint256 lotId) {
        return WheelCoordinatorPositionOperations.handoffCsp(_getWheelCoordinatorAdapterStorage(), trancheId);
    }

    function openCoveredCallTranche(uint256 trancheId, address lane, bytes calldata openData)
        external
        onlyManagedCaller
        nonReentrant
    {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if ($.allocationsPaused) revert AllocationPaused();
        WheelCoordinatorPositionOperations.openCoveredCall($, trancheId, lane, openData);
    }

    function settleCoveredCallTranche(uint256 trancheId) external onlyManagedCaller nonReentrant {
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

    function handoffCoveredCallTranche(uint256 trancheId) external onlyManagedCaller nonReentrant {
        WheelCoordinatorPositionOperations.handoffCoveredCall(_getWheelCoordinatorAdapterStorage(), trancheId);
    }

    function reserveRedemptionUsdc(uint256 trancheId, uint256 amount) external onlyManagedCaller {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.PendingCsp);
        if (amount == 0 || amount > current.pendingUsdc || amount > $.pendingCspUsdc) revert InvalidAmount();
        uint256 principalReserved = _principalShare(current.principalUsdc, current.pendingUsdc, amount);
        current.pendingUsdc -= amount;
        current.principalUsdc -= principalReserved;
        if (current.pendingUsdc == 0) current.leg = WheelTypes.TrancheLeg.Closed;
        $.pendingCspUsdc -= amount;
        $.reservedRedemptionUsdc += amount;
        $.reservedPrincipalUsdc += principalReserved;
        _checkpointTranche(
            $,
            trancheId,
            keccak256(
                abi.encode("RESERVE_REDEMPTION", amount, principalReserved, current.pendingUsdc, current.principalUsdc)
            )
        );
        emit WheelRedemptionUsdcReserved(
            trancheId, amount, principalReserved, current.pendingUsdc, current.principalUsdc
        );
        emit WheelRedemptionReserveChanged($.reservedRedemptionUsdc, $.pendingCspUsdc);
    }

    function releaseRedemptionUsdc(uint256 amount) external onlyManagedCaller returns (uint256 trancheId) {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if (amount == 0 || amount > $.reservedRedemptionUsdc) revert InvalidAmount();
        uint256 principalRestored = _principalShare($.reservedPrincipalUsdc, $.reservedRedemptionUsdc, amount);
        $.reservedRedemptionUsdc -= amount;
        $.reservedPrincipalUsdc -= principalRestored;
        $.pendingCspUsdc += amount;
        trancheId = _createPendingTranche(
            $, amount, principalRestored, keccak256(abi.encode("RELEASE_REDEMPTION", amount, principalRestored))
        );
        emit WheelRedemptionUsdcReleased(trancheId, amount, principalRestored, $.tranches[trancheId].stateHash);
        emit WheelRedemptionReserveChanged($.reservedRedemptionUsdc, $.pendingCspUsdc);
    }

    /// @notice Splits a pending tranche so each CSP quote can stay within one lane's configured capacity.
    function splitPendingCspTranche(uint256 trancheId, uint256 amount)
        external
        onlyManagedCaller
        returns (uint256 siblingTrancheId)
    {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.PendingCsp);
        if (amount == 0 || amount >= current.pendingUsdc) revert InvalidAmount();
        uint256 principalMoved = _principalShare(current.principalUsdc, current.pendingUsdc, amount);
        current.pendingUsdc -= amount;
        current.principalUsdc -= principalMoved;
        bytes32 operationHash = keccak256(
            abi.encode(
                "SPLIT_PENDING_CSP", trancheId, amount, principalMoved, current.pendingUsdc, current.principalUsdc
            )
        );
        _checkpointTranche($, trancheId, operationHash);
        siblingTrancheId = _createPendingTranche($, amount, principalMoved, operationHash);
        emit WheelSiblingTrancheQueued(
            trancheId, siblingTrancheId, amount, principalMoved, $.tranches[siblingTrancheId].stateHash
        );
    }

    function deallocate(uint256 targetValue, uint256 minAccountingAssetsOut, bytes calldata)
        external
        onlyStrategyManager
        nonReentrant
        returns (uint256 accountingAssetsOut, uint256 principalReleased)
    {
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        if (targetValue == 0 || targetValue > $.reservedRedemptionUsdc || targetValue > $.accountedUsdc) {
            revert InvalidAmount();
        }
        accountingAssetsOut = targetValue;
        if (accountingAssetsOut < minAccountingAssetsOut) revert InvalidAmount();
        principalReleased = _principalShare($.reservedPrincipalUsdc, $.reservedRedemptionUsdc, accountingAssetsOut);
        $.reservedRedemptionUsdc -= accountingAssetsOut;
        $.reservedPrincipalUsdc -= principalReleased;
        $.accountedUsdc -= accountingAssetsOut;
        _checkpoint($, keccak256(abi.encode("RETURN_USDC", accountingAssetsOut, principalReleased)));
        _transferExact(IERC20($.usdc), $.fund, accountingAssetsOut);
        emit WheelAccountingAssetsReturned(accountingAssetsOut, accountingAssetsOut, 0);
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
        $.reservedPrincipalUsdc = 0;
        $.transitionWeth = 0;
        _checkpoint($, keccak256(abi.encode("EMERGENCY_IN_KIND", escrow, amounts)));
        _transferExact(IERC20($.usdc), escrow, amounts[0]);
        _transferExact(IERC20($.weth), escrow, amounts[1]);
    }

    function pauseAllocations() external onlyManagedCaller {
        _getWheelCoordinatorAdapterStorage().allocationsPaused = true;
        emit WheelAllocationPauseSet(true);
    }

    function resumeAllocations() external onlyManagedCaller {
        _getWheelCoordinatorAdapterStorage().allocationsPaused = false;
        emit WheelAllocationPauseSet(false);
    }

    function setPolicyHash(bytes32 newPolicyHash) external onlyManagedCaller {
        if (newPolicyHash == bytes32(0)) revert InvalidAmount();
        WheelCoordinatorAdapterStorageLayout storage $ = _getWheelCoordinatorAdapterStorage();
        bytes32 previous = $.policyHash;
        $.policyHash = newPolicyHash;
        _checkpoint($, keccak256(abi.encode("SET_POLICY_HASH", previous, newPolicyHash)));
        emit WheelPolicyHashSet(previous, newPolicyHash);
    }

    /// @notice Finalizes a buffer already applied to every registered CC lane by the curator.
    function setFloorBufferUsd8(uint256 newFloorBufferUsd8) external onlyManagedCaller {
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

    function _createPendingTranche(
        WheelCoordinatorAdapterStorageLayout storage $,
        uint256 amount,
        uint256 principalAmount,
        bytes32 operationHash
    ) private returns (uint256 trancheId) {
        trancheId = ++$.trancheCount;
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        current.leg = WheelTypes.TrancheLeg.PendingCsp;
        current.principalUsdc = principalAmount;
        current.pendingUsdc = amount;
        _checkpointTranche($, trancheId, operationHash);
    }

    function _principalShare(uint256 principal, uint256 totalAssets, uint256 assets) private pure returns (uint256) {
        if (assets == totalAssets) return principal;
        return Math.mulDiv(principal, assets, totalAssets);
    }

    function _requireLeg(WheelTypes.Tranche storage current, WheelTypes.TrancheLeg expected) private view {
        if (current.leg != expected) revert InvalidTrancheLeg();
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
                current.principalUsdc,
                current.pendingUsdc,
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
