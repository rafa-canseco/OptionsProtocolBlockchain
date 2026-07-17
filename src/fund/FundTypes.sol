// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library FundTypes {
    enum RequestMode {
        AccountingAsset,
        InKind
    }

    struct ComponentReport {
        address fund;
        bytes32 componentId;
        uint256 chainId;
        uint64 snapshotBlock;
        bytes32 snapshotBlockHash;
        uint64 validAfterBlock;
        uint64 validUntilBlock;
        uint64 reporterSetVersion;
        uint64 componentNonce;
        bytes32 positionStateHash;
        uint256 grossAssets;
        uint256 liabilities;
        uint256 liquidAccountingAssets;
        uint256 baseExitCost;
        bytes32 dataHash;
    }

    struct NavCommit {
        uint256 grossAssets;
        uint256 liabilities;
        uint256 netAssets;
        uint256 liquidAccountingAssets;
        uint256 baseExitCost;
        uint64 snapshotBlock;
        uint64 validAfterBlock;
        uint64 validUntilBlock;
        uint64 reporterSetVersion;
        uint64 reportNonce;
        bytes32 positionsHash;
        bytes32 reportHash;
        bytes32 signaturesHash;
    }

    struct FeeConfig {
        uint64 managementFeeWad;
        uint16 performanceFeeBps;
        uint16 maxManagementFeeBps;
        uint16 maxPerformanceFeeBps;
        uint32 maxAccrualInterval;
        uint32 crystallizationPeriod;
        address feeRecipient;
    }

    struct FeeState {
        uint48 lastManagementAccrual;
        uint48 lastCrystallization;
        uint256 highWaterMark;
        uint256 distributionRemainder;
        uint256 distributionRemainderSupply;
    }

    struct RedemptionState {
        uint256 pendingShares;
        uint256 pendingMinAssetsOut;
        uint256 claimableShares;
        uint256 claimableAssets;
        uint64 latestBatchId;
        bool unwindCommitted;
    }

    struct RedemptionAccount {
        uint256 pendingShares;
        uint256 pendingMinAssetsOut;
        uint16 indexPlusOne;
    }

    struct RedemptionBatch {
        uint256 totalPendingShares;
        uint256 processedShares;
        uint256 reservedAssets;
        uint256 marginalExitCost;
        uint256 processingNav;
        uint256 eligibleSupply;
        uint256 roundPendingShares;
        uint256 roundTargetShares;
        uint256 roundCumulativeShares;
        uint256 roundAllocatedShares;
        uint256 roundAssetBudget;
        uint256 roundAllocatedAssets;
        bytes32 processingPositionsHash;
        uint64 processingBlock;
        uint64 processingReportNonce;
        uint64 processingValidUntilBlock;
        uint16 processingCursor;
        RequestMode mode;
        bool isSealed;
        bool processing;
        bool unwindCommitted;
        bool isReleased;
    }

    struct StrategyConfig {
        bool active;
        uint16 maxAllocationBps;
        uint16 maxLossBps;
        uint32 cooldown;
        uint64 interfaceVersion;
        address valuator;
        uint256 absoluteCap;
    }

    struct PositionValue {
        uint256 grossAssets;
        uint256 liabilities;
        uint256 liquidAccountingAssets;
        uint256 baseExitCost;
        bytes32 dataHash;
    }
}
