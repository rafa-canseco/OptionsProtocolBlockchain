// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OToken} from "../../core/OToken.sol";
import {WheelTypes} from "../WheelTypes.sol";
import {ICoveredCallFundAdapter} from "../interfaces/ICoveredCallFundAdapter.sol";
import {IWheelChildLane} from "../interfaces/IWheelChildLane.sol";
import {IWheelCoveredCallChildLane} from "../interfaces/IWheelCoveredCallChildLane.sol";
import {IWheelCspChildLane} from "../interfaces/IWheelCspChildLane.sol";
import {WheelCoordinatorAdapterStorage} from "../storage/WheelCoordinatorAdapterStorage.sol";

/// @notice Linked execution module for Wheel option opens and asset handoffs.
/// @dev Public library calls use DELEGATECALL, preserving coordinator custody and storage.
library WheelCoordinatorPositionOperations {
    using SafeERC20 for IERC20;

    error AccountingDeficit();
    error CallStrikeBelowFloor();
    error ChildShareMismatch();
    error DuplicateTransition(bytes32 transitionHash);
    error InvalidAmount();
    error InvalidLane();
    error InvalidSettlement();
    error InvalidTrancheLeg();
    error LaneInUse();
    error TransferMismatch();

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

    function openCsp(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
        uint256 trancheId,
        address lane,
        bytes calldata openData
    ) public {
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

    function handoffCsp(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
        uint256 trancheId
    ) public returns (uint256 lotId) {
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.CspSettling);
        address lane = current.childLane;
        bytes32 transitionHash = _consumeNextTransition($, trancheId, "HANDOFF_CSP", lane);
        uint256 usdcBefore = IERC20($.usdc).balanceOf(address(this));
        uint256 wethBefore = IERC20($.weth).balanceOf(address(this));
        WheelTypes.LaneBasket memory basket =
            IWheelCspChildLane(lane).handoffCsp(trancheId, current.childPositionHash, transitionHash, address(this));
        _validateBasketDelta($, basket, usdcBefore, wethBefore, current.childShares, transitionHash);
        if (basket.settlementKind == WheelTypes.SettlementKind.None) revert InvalidSettlement();

        $.activeLaneTranche[lane] = 0;
        $.accountedUsdc += basket.usdcAmount;
        $.accountedWeth += basket.wethAmount;
        $.pendingCspUsdc += basket.usdcAmount;
        current.childLane = address(0);
        current.childShares = 0;
        current.childPositionHash = bytes32(0);
        if (basket.wethAmount != 0) {
            if (basket.literalAssignmentStrike8 == 0) revert InvalidAmount();
            uint256 wethPrincipal =
                Math.min(current.principalUsdc, Math.mulDiv(basket.wethAmount, basket.literalAssignmentStrike8, 1e20));
            uint256 siblingPrincipal = basket.usdcAmount == 0 ? 0 : current.principalUsdc - wethPrincipal;
            current.principalUsdc -= siblingPrincipal;
            _splitPendingUsdc($, current, trancheId, basket.usdcAmount, siblingPrincipal, transitionHash);
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

    function openCoveredCall(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
        uint256 trancheId,
        address lane,
        bytes calldata openData
    ) public {
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

    function handoffCoveredCall(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
        uint256 trancheId
    ) public {
        WheelTypes.Tranche storage current = $.tranches[trancheId];
        _requireLeg(current, WheelTypes.TrancheLeg.CallSettling);
        address lane = current.childLane;
        bytes32 transitionHash = _consumeNextTransition($, trancheId, "HANDOFF_CALL", lane);
        uint256 usdcBefore = IERC20($.usdc).balanceOf(address(this));
        uint256 wethBefore = IERC20($.weth).balanceOf(address(this));
        WheelTypes.LaneBasket memory basket = IWheelCoveredCallChildLane(lane)
            .handoffCoveredCall(trancheId, current.childPositionHash, transitionHash, address(this));
        _validateBasketDelta($, basket, usdcBefore, wethBefore, current.childShares, transitionHash);
        if (basket.settlementKind == WheelTypes.SettlementKind.None) revert InvalidSettlement();

        uint256 callCollateralWeth = current.childShares;
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
            if (basket.wethAmount > callCollateralWeth) revert InvalidSettlement();
            lot.status = WheelTypes.LotStatus.Available;
            uint256 consumedPrincipal;
            if (basket.settlementKind == WheelTypes.SettlementKind.CallAway) {
                consumedPrincipal =
                    _principalShare(current.principalUsdc, callCollateralWeth, callCollateralWeth - basket.wethAmount);
            }
            current.principalUsdc -= consumedPrincipal;
            _splitPendingUsdc($, current, trancheId, basket.usdcAmount, consumedPrincipal, transitionHash);
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

    function _requireLane(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
        address lane,
        WheelTypes.LaneKind expectedKind
    ) private view {
        WheelCoordinatorAdapterStorage.LaneConfig storage config = $.lanes[lane];
        if (!config.active || config.kind != expectedKind || IWheelChildLane(lane).coordinator() != address(this)) {
            revert InvalidLane();
        }
    }

    function _requireLeg(WheelTypes.Tranche storage current, WheelTypes.TrancheLeg expected) private view {
        if (current.leg != expected) revert InvalidTrancheLeg();
    }

    function _consumeNextTransition(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
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

    function _splitPendingUsdc(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
        WheelTypes.Tranche storage parent,
        uint256 parentTrancheId,
        uint256 returnedUsdc,
        uint256 siblingPrincipal,
        bytes32 transitionHash
    ) private {
        if (parent.pendingUsdc != 0) revert InvalidTrancheLeg();
        if (returnedUsdc == 0) {
            if (siblingPrincipal != 0) revert InvalidAmount();
            return;
        }
        uint256 siblingTrancheId = ++$.trancheCount;
        WheelTypes.Tranche storage sibling = $.tranches[siblingTrancheId];
        sibling.leg = WheelTypes.TrancheLeg.PendingCsp;
        sibling.principalUsdc = siblingPrincipal;
        sibling.pendingUsdc = returnedUsdc;
        _checkpointTranche(
            $,
            siblingTrancheId,
            keccak256(abi.encode("SPLIT_USDC", parentTrancheId, transitionHash, returnedUsdc, siblingPrincipal))
        );
        emit WheelSiblingTrancheQueued(
            parentTrancheId, siblingTrancheId, returnedUsdc, siblingPrincipal, sibling.stateHash
        );
    }

    function _principalShare(uint256 principal, uint256 totalAssets, uint256 assets) private pure returns (uint256) {
        if (assets == totalAssets) return principal;
        return Math.mulDiv(principal, assets, totalAssets);
    }

    function _checkpointTranche(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
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

    function _validateBasketDelta(
        WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $,
        WheelTypes.LaneBasket memory basket,
        uint256 usdcBefore,
        uint256 wethBefore,
        uint256 expectedShares,
        bytes32 transitionHash
    ) private view {
        if (
            basket.transitionHash != transitionHash || basket.childSharesBurned != expectedShares
                || IERC20($.usdc).balanceOf(address(this)) - usdcBefore != basket.usdcAmount
                || IERC20($.weth).balanceOf(address(this)) - wethBefore != basket.wethAmount
        ) revert TransferMismatch();
    }

    function _requireNoDeficit(WheelCoordinatorAdapterStorage.WheelCoordinatorAdapterStorageLayout storage $)
        private
        view
    {
        if (
            IERC20($.usdc).balanceOf(address(this)) < $.accountedUsdc
                || IERC20($.weth).balanceOf(address(this)) < $.accountedWeth
        ) revert AccountingDeficit();
    }
}
