// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library WheelTypes {
    enum LaneKind {
        None,
        Csp,
        CoveredCall
    }

    enum LaneState {
        Idle,
        Open,
        Settling,
        ReadyForHandoff
    }

    enum TrancheLeg {
        None,
        PendingCsp,
        CspOpen,
        CspSettling,
        WethTransition,
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
        WethFallback
    }

    enum ManagedOperationClass {
        None,
        Allocation,
        Processing,
        Guardian,
        Configuration
    }

    enum ManagedOperation {
        None,
        OpenCsp,
        OpenCoveredCall,
        SplitPendingCsp,
        SettleCsp,
        HandoffCsp,
        SettleCoveredCall,
        HandoffCoveredCall,
        ReserveRedemption,
        ReleaseRedemption,
        PauseAllocations,
        RegisterLane,
        RemoveLane,
        SetLaneActive,
        SetPolicyHash,
        SetFloorBuffer,
        ResumeAllocations
    }

    struct Tranche {
        TrancheLeg leg;
        address childLane;
        uint64 stateNonce;
        uint64 expiry;
        uint256 principalUsdc;
        uint256 pendingUsdc;
        uint256 childShares;
        uint256 childPositionId;
        uint256 assignmentLotId;
        bytes32 childPositionHash;
        bytes32 stateHash;
    }

    struct AssignmentLot {
        address originCspLane;
        uint64 createdAt;
        LotStatus status;
        uint256 trancheId;
        uint256 originCspPositionId;
        uint256 wethReceived;
        uint256 remainingWeth;
        uint256 literalAssignmentStrike8;
    }

    struct LaneBasket {
        SettlementKind settlementKind;
        uint256 childSharesBurned;
        uint256 usdcAmount;
        uint256 wethAmount;
        uint256 positionId;
        uint256 literalAssignmentStrike8;
        bytes32 positionHash;
        bytes32 transitionHash;
    }

    struct LaneValuation {
        address lane;
        uint64 snapshotBlock;
        uint256 childShares;
        bytes32 positionHash;
        bytes valuationData;
    }
}
