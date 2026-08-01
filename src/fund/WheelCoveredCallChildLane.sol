// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OToken} from "../core/OToken.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {WheelTypes} from "./WheelTypes.sol";
import {WheelCoveredCallFundAdapter} from "./WheelCoveredCallFundAdapter.sol";
import {ICoveredCallFundAdapter} from "./interfaces/ICoveredCallFundAdapter.sol";
import {IWheelCoveredCallChildLane} from "./interfaces/IWheelCoveredCallChildLane.sol";
import {WheelCoveredCallChildLaneStorage} from "./storage/WheelCoveredCallChildLaneStorage.sol";

/// @notice Dedicated single-position covered-call lane controlled only by one Meta Wheel coordinator.
contract WheelCoveredCallChildLane is FundUpgradeable, WheelCoveredCallChildLaneStorage, IWheelCoveredCallChildLane {
    using SafeERC20 for IERC20;

    bytes32 private constant INITIAL_POSITIONS_HASH = keccak256("b1nary Wheel Covered Call Child Lane");

    struct InitializeParams {
        address coordinator;
        address adapter;
        address usdc;
        address weth;
        address authority;
        uint256 maxAssets;
        uint256 executionCostBuffer8;
    }

    error AccountingDeficit(address asset, uint256 accounted, uint256 actual);
    error CallStrikeBelowFloor(uint256 callStrike8, uint256 requiredFloor8);
    error DuplicateTransition(bytes32 transitionHash);
    error InvalidAddress();
    error InvalidAmount();
    error InvalidLaneState(WheelTypes.LaneState expected, WheelTypes.LaneState actual);
    error InvalidPositionHash(bytes32 expected, bytes32 actual);
    error OnlyCoordinator();
    error TransferMismatch(address asset, uint256 expected, uint256 actual);

    event CoveredCallOpened(
        uint256 indexed trancheId,
        uint256 indexed lotId,
        uint256 indexed positionId,
        uint256 wethAmount,
        uint256 collateral,
        uint256 literalAssignmentStrike8,
        uint256 requiredFloor8,
        uint256 callStrike8,
        uint64 expiry,
        uint256 childShares,
        bytes32 positionHash
    );
    event CoveredCallSettlementAdvanced(
        uint256 indexed trancheId,
        uint256 indexed lotId,
        uint256 indexed positionId,
        WheelTypes.SettlementKind settlementKind,
        WheelTypes.LaneState laneState,
        uint256 observedUsdc,
        uint256 observedWeth,
        bytes32 positionHash
    );
    event CoveredCallBasketHandedOff(
        uint256 indexed trancheId,
        uint256 indexed lotId,
        bytes32 indexed transitionHash,
        address receiver,
        uint256 childSharesBurned,
        uint256 usdcAmount,
        uint256 wethAmount
    );
    event ExecutionCostBufferSet(uint256 previousBuffer8, uint256 newBuffer8);
    event LaneAllocationPauseSet(bool paused);
    event LaneMaxAssetsSet(uint256 maxAssets);
    event WheelPremiumAccrued(
        uint256 indexed trancheId,
        address indexed lane,
        uint256 indexed childPositionId,
        uint256 grossPremiumAssets,
        uint256 protocolFeeAssets,
        uint256 netPremiumAssets
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitializeParams calldata params) external initializer {
        if (
            params.coordinator == address(0) || params.adapter == address(0) || params.usdc == address(0)
                || params.weth == address(0) || params.coordinator.code.length == 0 || params.adapter.code.length == 0
                || params.usdc.code.length == 0 || params.weth.code.length == 0 || params.maxAssets == 0
        ) revert InvalidAddress();
        ICoveredCallFundAdapter adapter_ = ICoveredCallFundAdapter(params.adapter);
        if (
            adapter_.fund() != address(this) || adapter_.strategyManager() != address(this)
                || adapter_.accountingAsset() != params.weth || adapter_.usdc() != params.usdc
        ) revert InvalidAddress();
        __FundUpgradeable_init(params.authority);
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        $.coordinator = params.coordinator;
        $.adapter = params.adapter;
        $.usdc = params.usdc;
        $.weth = params.weth;
        $.maxAssets = params.maxAssets;
        $.executionCostBuffer8 = params.executionCostBuffer8;
        $.positionsHash = INITIAL_POSITIONS_HASH;
    }

    modifier onlyCoordinator() {
        _checkCoordinator();
        _;
    }

    function _checkCoordinator() private view {
        if (msg.sender != _getWheelCoveredCallChildLaneStorage().coordinator) revert OnlyCoordinator();
    }

    function coordinator() external view returns (address) {
        return _getWheelCoveredCallChildLaneStorage().coordinator;
    }

    function adapter() external view returns (address) {
        return _getWheelCoveredCallChildLaneStorage().adapter;
    }

    function laneKind() external pure returns (WheelTypes.LaneKind) {
        return WheelTypes.LaneKind.CoveredCall;
    }

    function laneState() external view returns (WheelTypes.LaneState) {
        return _getWheelCoveredCallChildLaneStorage().state;
    }

    function stateNonce() external view returns (uint64) {
        return _getWheelCoveredCallChildLaneStorage().stateNonce;
    }

    function childShares() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().childShares;
    }

    function activeTrancheId() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().activeTrancheId;
    }

    function activePositionId() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().activePositionId;
    }

    function consumedLotId() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().consumedLotId;
    }

    function requiredFloor8() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().requiredFloor8;
    }

    function executionCostBuffer8() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().executionCostBuffer8;
    }

    function maxAssets() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().maxAssets;
    }

    /// @notice WETH-denominated lane capital used by the composed CoveredCallFundAdapter utilization check.
    function totalAssets() external view returns (uint256) {
        return _getWheelCoveredCallChildLaneStorage().childShares;
    }

    function accountingState()
        external
        view
        returns (uint256 accountedUsdc, uint256 accountedWeth, uint256 literalFloor8, uint256 requiredFloorValue8)
    {
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        return ($.accountedUsdc, $.accountedWeth, $.literalAssignmentStrike8, $.requiredFloor8);
    }

    /// @notice Stable operational commitment; permissionless token transfers cannot invalidate it.
    function executionStateHash() public view returns (bytes32) {
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.stateNonce,
                $.state,
                $.settlementKind,
                $.activeTrancheId,
                $.activePositionId,
                $.consumedLotId,
                $.childShares,
                $.accountedUsdc,
                $.accountedWeth,
                $.literalAssignmentStrike8,
                $.requiredFloor8,
                $.expiry,
                $.positionsHash
            )
        );
    }

    /// @notice Balance-sensitive reconciliation commitment used by NAV reporters.
    function positionStateHash() public view returns (bytes32) {
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        return keccak256(
            abi.encode(
                executionStateHash(),
                ICoveredCallFundAdapter($.adapter).positionStateHash(),
                IERC20($.usdc).balanceOf(address(this)),
                IERC20($.weth).balanceOf(address(this))
            )
        );
    }

    function openCoveredCall(
        uint256 trancheId,
        bytes32 transitionHash,
        uint256 lotId,
        uint256 literalAssignmentStrike8,
        uint256 wethAmount,
        bytes calldata openData
    )
        external
        onlyCoordinator
        returns (uint256 mintedChildShares, uint256 positionId, uint64 expiry, bytes32 positionHash)
    {
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        if ($.allocationsPaused) revert InvalidLaneState(WheelTypes.LaneState.Idle, $.state);
        if ($.state != WheelTypes.LaneState.Idle) {
            revert InvalidLaneState(WheelTypes.LaneState.Idle, $.state);
        }
        if (
            trancheId == 0 || lotId == 0 || literalAssignmentStrike8 == 0 || transitionHash == bytes32(0)
                || wethAmount == 0 || wethAmount > $.maxAssets
        ) revert InvalidAmount();
        _consumeTransition($, transitionHash);

        ICoveredCallFundAdapter.OpenPositionData memory decoded =
            abi.decode(openData, (ICoveredCallFundAdapter.OpenPositionData));
        uint256 requiredFloorValue8 = literalAssignmentStrike8 + $.executionCostBuffer8;
        uint256 callStrike8 = OToken(decoded.quote.oToken).strikePrice();
        if (callStrike8 < requiredFloorValue8) revert CallStrikeBelowFloor(callStrike8, requiredFloorValue8);
        if (decoded.collateral == 0 || decoded.collateral > wethAmount) revert InvalidAmount();

        IERC20 wethToken = IERC20($.weth);
        uint256 laneBefore = wethToken.balanceOf(address(this));
        wethToken.safeTransferFrom(msg.sender, address(this), wethAmount);
        uint256 received = wethToken.balanceOf(address(this)) - laneBefore;
        if (received != wethAmount) revert TransferMismatch($.weth, wethAmount, received);

        $.state = WheelTypes.LaneState.Open;
        $.settlementKind = WheelTypes.SettlementKind.None;
        $.activeTrancheId = trancheId;
        $.consumedLotId = lotId;
        $.childShares = received;
        $.accountedWeth = received - decoded.collateral;
        $.literalAssignmentStrike8 = literalAssignmentStrike8;
        $.requiredFloor8 = requiredFloorValue8;

        uint256 adapterBefore = wethToken.balanceOf($.adapter);
        wethToken.safeTransfer($.adapter, decoded.collateral);
        uint256 adapterReceived = wethToken.balanceOf($.adapter) - adapterBefore;
        if (adapterReceived != decoded.collateral) {
            revert TransferMismatch($.weth, decoded.collateral, adapterReceived);
        }
        ICoveredCallFundAdapter coveredCall = ICoveredCallFundAdapter($.adapter);
        coveredCall.allocate($.weth, decoded.collateral, openData);
        ICoveredCallFundAdapter.AdapterState memory adapterState_ = coveredCall.adapterState();
        positionId = adapterState_.positionCount;
        ICoveredCallFundAdapter.Position memory opened = coveredCall.position(positionId);
        if (positionId == 0 || opened.lifecycle != ICoveredCallFundAdapter.Lifecycle.Open) revert InvalidAmount();
        expiry = uint64(OToken(opened.oToken).expiry());
        $.activePositionId = positionId;
        $.expiry = expiry;
        _checkpoint($, transitionHash);
        mintedChildShares = received;
        positionHash = executionStateHash();
        emit CoveredCallOpened(
            trancheId,
            lotId,
            positionId,
            received,
            decoded.collateral,
            literalAssignmentStrike8,
            requiredFloorValue8,
            callStrike8,
            expiry,
            mintedChildShares,
            positionHash
        );
        uint256 grossPremium = decoded.optionAmount * decoded.quote.bidPrice / 1e8;
        if (opened.premiumEarned > grossPremium) revert InvalidAmount();
        emit WheelPremiumAccrued(
            trancheId,
            address(this),
            positionId,
            grossPremium,
            grossPremium - opened.premiumEarned,
            opened.premiumEarned
        );
    }

    function settleCoveredCall(uint256 trancheId, bytes32 expectedPositionHash)
        external
        onlyCoordinator
        returns (WheelTypes.SettlementKind settlementKind, bytes32 positionHash)
    {
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        if (
            trancheId != $.activeTrancheId
                || ($.state != WheelTypes.LaneState.Open && $.state != WheelTypes.LaneState.Settling)
        ) revert InvalidLaneState(WheelTypes.LaneState.Open, $.state);
        bytes32 currentHash = executionStateHash();
        if (currentHash != expectedPositionHash) revert InvalidPositionHash(expectedPositionHash, currentHash);

        ICoveredCallFundAdapter coveredCall = ICoveredCallFundAdapter($.adapter);
        coveredCall.deallocate(
            type(uint256).max,
            0,
            abi.encode(
                ICoveredCallFundAdapter.DeallocateData({
                    action: ICoveredCallFundAdapter.DeallocateAction.Settle,
                    positionId: $.activePositionId,
                    amount: 0,
                    minAmountOut: 0
                })
            )
        );
        ICoveredCallFundAdapter.Position memory settled = coveredCall.position($.activePositionId);
        if (settled.lifecycle == ICoveredCallFundAdapter.Lifecycle.SettledOtm) {
            settlementKind = WheelTypes.SettlementKind.CallOtm;
        } else if (settled.lifecycle == ICoveredCallFundAdapter.Lifecycle.CalledAway) {
            settlementKind = WheelTypes.SettlementKind.CallAway;
        } else if (settled.lifecycle == ICoveredCallFundAdapter.Lifecycle.CashFallback) {
            settlementKind = WheelTypes.SettlementKind.WethFallback;
        } else if (settled.lifecycle == ICoveredCallFundAdapter.Lifecycle.AwaitingPhysicalDelivery) {
            $.state = WheelTypes.LaneState.Settling;
            _checkpoint($, keccak256(abi.encode("SETTLE_CALL_PENDING", trancheId, settled.lifecycleHash)));
            positionHash = executionStateHash();
            emit CoveredCallSettlementAdvanced(
                trancheId,
                $.consumedLotId,
                $.activePositionId,
                WheelTypes.SettlementKind.None,
                $.state,
                0,
                0,
                positionHash
            );
            return (WheelTypes.SettlementKind.None, positionHash);
        } else {
            revert InvalidAmount();
        }

        IERC20 usdcToken = IERC20($.usdc);
        IERC20 wethToken = IERC20($.weth);
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 wethBefore = wethToken.balanceOf(address(this));
        bytes32 adapterTransition =
            keccak256(abi.encode(block.chainid, address(this), trancheId, $.stateNonce + 1, settled.lifecycleHash));
        WheelCoveredCallFundAdapter($.adapter).wheelHandoff(adapterTransition, address(this));
        uint256 observedUsdc = usdcToken.balanceOf(address(this)) - usdcBefore;
        uint256 observedWeth = wethToken.balanceOf(address(this)) - wethBefore;
        $.accountedUsdc += observedUsdc;
        $.accountedWeth += observedWeth;
        $.settlementKind = settlementKind;
        $.state = WheelTypes.LaneState.ReadyForHandoff;
        _checkpoint($, keccak256(abi.encode("SETTLE_CALL", trancheId, settled.lifecycleHash, adapterTransition)));
        _requireNoDeficit($);
        positionHash = executionStateHash();
        emit CoveredCallSettlementAdvanced(
            trancheId,
            $.consumedLotId,
            $.activePositionId,
            settlementKind,
            $.state,
            observedUsdc,
            observedWeth,
            positionHash
        );
    }

    function handoffCoveredCall(
        uint256 trancheId,
        bytes32 expectedPositionHash,
        bytes32 transitionHash,
        address receiver
    ) external onlyCoordinator returns (WheelTypes.LaneBasket memory basket) {
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        if ($.state != WheelTypes.LaneState.ReadyForHandoff || trancheId != $.activeTrancheId) {
            revert InvalidLaneState(WheelTypes.LaneState.ReadyForHandoff, $.state);
        }
        bytes32 currentHash = executionStateHash();
        if (currentHash != expectedPositionHash) revert InvalidPositionHash(expectedPositionHash, currentHash);
        if (receiver == address(0)) revert InvalidAddress();
        _consumeTransition($, transitionHash);
        _requireNoDeficit($);

        uint256 lotId = $.consumedLotId;
        basket = WheelTypes.LaneBasket({
            settlementKind: $.settlementKind,
            childSharesBurned: $.childShares,
            usdcAmount: $.accountedUsdc,
            wethAmount: $.accountedWeth,
            positionId: $.activePositionId,
            literalAssignmentStrike8: $.literalAssignmentStrike8,
            positionHash: currentHash,
            transitionHash: transitionHash
        });

        $.state = WheelTypes.LaneState.Idle;
        $.settlementKind = WheelTypes.SettlementKind.None;
        $.activeTrancheId = 0;
        $.activePositionId = 0;
        $.consumedLotId = 0;
        $.childShares = 0;
        $.accountedUsdc = 0;
        $.accountedWeth = 0;
        $.literalAssignmentStrike8 = 0;
        $.requiredFloor8 = 0;
        $.expiry = 0;
        _checkpoint($, transitionHash);

        _transferExact(IERC20($.usdc), receiver, basket.usdcAmount);
        _transferExact(IERC20($.weth), receiver, basket.wethAmount);
        emit CoveredCallBasketHandedOff(
            trancheId, lotId, transitionHash, receiver, basket.childSharesBurned, basket.usdcAmount, basket.wethAmount
        );
    }

    function setExecutionCostBuffer8(uint256 newBuffer8) external restricted {
        WheelCoveredCallChildLaneStorageLayout storage $ = _getWheelCoveredCallChildLaneStorage();
        uint256 previous = $.executionCostBuffer8;
        $.executionCostBuffer8 = newBuffer8;
        emit ExecutionCostBufferSet(previous, newBuffer8);
    }

    function pauseAllocations() external restricted {
        _getWheelCoveredCallChildLaneStorage().allocationsPaused = true;
        emit LaneAllocationPauseSet(true);
    }

    function resumeAllocations() external restricted {
        _getWheelCoveredCallChildLaneStorage().allocationsPaused = false;
        emit LaneAllocationPauseSet(false);
    }

    function setMaxAssets(uint256 newMaxAssets) external restricted {
        if (newMaxAssets == 0) revert InvalidAmount();
        _getWheelCoveredCallChildLaneStorage().maxAssets = newMaxAssets;
        emit LaneMaxAssetsSet(newMaxAssets);
    }

    function storageLocation() external pure returns (bytes32) {
        return WHEEL_COVERED_CALL_CHILD_LANE_STORAGE_LOCATION;
    }

    function _consumeTransition(WheelCoveredCallChildLaneStorageLayout storage $, bytes32 transitionHash) private {
        if (transitionHash == bytes32(0) || $.consumedTransitions[transitionHash]) {
            revert DuplicateTransition(transitionHash);
        }
        $.consumedTransitions[transitionHash] = true;
        $.lastTransitionHash = transitionHash;
    }

    function _checkpoint(WheelCoveredCallChildLaneStorageLayout storage $, bytes32 operationHash) private {
        uint64 nonce = ++$.stateNonce;
        $.positionsHash = keccak256(
            abi.encode(
                $.positionsHash,
                nonce,
                operationHash,
                $.state,
                $.activeTrancheId,
                $.activePositionId,
                $.consumedLotId,
                $.childShares,
                $.accountedUsdc,
                $.accountedWeth,
                $.requiredFloor8
            )
        );
    }

    function _requireNoDeficit(WheelCoveredCallChildLaneStorageLayout storage $) private view {
        uint256 rawUsdc = IERC20($.usdc).balanceOf(address(this));
        uint256 rawWeth = IERC20($.weth).balanceOf(address(this));
        if (rawUsdc < $.accountedUsdc) revert AccountingDeficit($.usdc, $.accountedUsdc, rawUsdc);
        if (rawWeth < $.accountedWeth) revert AccountingDeficit($.weth, $.accountedWeth, rawWeth);
    }

    function _transferExact(IERC20 token, address receiver, uint256 amount) private {
        if (amount == 0) return;
        uint256 receiverBefore = token.balanceOf(receiver);
        token.safeTransfer(receiver, amount);
        uint256 received = token.balanceOf(receiver) - receiverBefore;
        if (received != amount) revert TransferMismatch(address(token), amount, received);
    }
}
