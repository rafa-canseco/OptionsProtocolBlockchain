// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IFundStrategyAdapter} from "./IFundStrategyAdapter.sol";

/// @notice Version-2 asset-neutral DTO and event boundary for a Meta Wheel coordinator.
/// @dev Implementations MUST return 2 from interfaceVersion(). No WETH-named v1 field is aliased.
interface IAssetNeutralWheelV2 is IFundStrategyAdapter {
    enum LaneKind {
        None,
        Csp,
        CoveredCall
    }

    enum TrancheLeg {
        None,
        PendingCsp,
        CspOpen,
        CspSettling,
        UnderlyingTransition,
        CallOpen,
        CallSettling,
        Closed
    }

    enum LotStatus {
        None,
        Available,
        InCall,
        CalledAway,
        EmergencyExited
    }

    enum SettlementKind {
        None,
        CspOtm,
        CspAssigned,
        CallOtm,
        CallAway,
        UnderlyingFallback
    }

    struct AssetConfigV2 {
        address underlyingAsset;
        address settlementAsset;
        uint8 oTokenDecimals;
        uint8 underlyingDecimals;
        uint8 priceDecimals;
        uint8 settlementDecimals;
    }

    struct SummaryV2 {
        uint64 stateNonce;
        uint256 trancheCount;
        uint256 assignmentLotCount;
        uint256 pendingCspSettlementAmount;
        uint256 reservedRedemptionSettlementAmount;
        uint256 reservedPrincipalSettlementAmount;
        uint256 transitionUnderlyingAmount;
        uint256 accountedSettlementAmount;
        uint256 accountedUnderlyingAmount;
    }

    struct TrancheV2 {
        TrancheLeg leg;
        address childLane;
        uint64 stateNonce;
        uint64 expiry;
        uint256 principalSettlementAmount;
        uint256 pendingSettlementAmount;
        uint256 childShares;
        uint256 childPositionId;
        uint256 assignmentLotId;
        bytes32 childPositionHash;
        bytes32 stateHash;
    }

    struct AssignmentLotV2 {
        address originCspLane;
        uint64 createdAt;
        LotStatus status;
        uint256 trancheId;
        uint256 originCspPositionId;
        uint256 underlyingReceivedAmount;
        uint256 remainingUnderlyingAmount;
        uint256 literalAssignmentStrikeUsd8;
    }

    struct LaneBasketV2 {
        SettlementKind settlementKind;
        uint256 childSharesBurned;
        uint256 settlementAmount;
        uint256 underlyingAmount;
        uint256 positionId;
        uint256 literalAssignmentStrikeUsd8;
        bytes32 positionHash;
        bytes32 transitionHash;
    }

    struct LaneValuationV2 {
        address lane;
        uint64 snapshotBlock;
        uint256 childShares;
        bytes32 positionHash;
        bytes valuationData;
    }

    event AssetNeutralWheelChildHandoffV2(
        uint256 indexed trancheId,
        address indexed lane,
        bytes32 indexed transitionHash,
        SettlementKind settlementKind,
        uint256 childSharesBurned,
        uint256 settlementAmount,
        uint256 underlyingAmount
    );
    event AssetNeutralWheelAssignmentLotCreatedV2(
        uint256 indexed lotId,
        uint256 indexed trancheId,
        address indexed originCspLane,
        uint256 originCspPositionId,
        uint256 underlyingReceivedAmount,
        uint256 literalAssignmentStrikeUsd8
    );
    event AssetNeutralWheelLotStatusChangedV2(
        uint256 indexed lotId, LotStatus status, uint256 remainingUnderlyingAmount, uint256 trancheId
    );

    function underlyingAsset() external view returns (address);
    function settlementAsset() external view returns (address);
    function assetConfigV2() external view returns (AssetConfigV2 memory);
    function policyHash() external view returns (bytes32);
    function summaryV2() external view returns (SummaryV2 memory);
    function trancheV2(uint256 trancheId) external view returns (TrancheV2 memory);
    function assignmentLotV2(uint256 lotId) external view returns (AssignmentLotV2 memory);
    function registeredLaneCount() external view returns (uint256);
    function registeredLaneAt(uint256 index) external view returns (address lane, LaneKind kind, bool active);
    function laneValuator(address lane) external view returns (address);
}
