// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

abstract contract FundFlowManagerStorage {
    struct OutflowWindow {
        uint256 eligibleSupply;
        uint256 processedShares;
    }

    struct StrategyInKindBatch {
        address adapter;
        address escrow;
        uint64 validUntil;
        bool consumed;
        uint256 fractionWad;
    }

    /// @custom:storage-location erc7201:b1nary.storage.FundFlowManager
    struct FundFlowManagerStorageLayout {
        address fund;
        address claimEscrow;
        uint64 compatibilityVersion;
        uint64 nextProcessBatchId;
        uint64 openBatchId;
        uint256 totalPendingShares;
        uint256 totalClaimableShares;
        uint256 totalReservedAssets;
        mapping(address controller => mapping(address operator => bool approved)) operators;
        mapping(address controller => FundTypes.RedemptionState state) redemptions;
        mapping(uint64 batchId => FundTypes.RedemptionBatch batch) batches;
        mapping(uint64 batchId => address[] controllers) batchControllers;
        mapping(uint64 batchId => mapping(address controller => FundTypes.RedemptionAccount account)) batchAccounts;
        uint16 maxExitFeeBps;
        uint16 maxWindowOutflowBps;
        mapping(uint64 reportNonce => OutflowWindow window) outflowWindows;
        address strategyInKindEscrow;
        address strategyEmergencyEscrow;
        mapping(bytes32 batchId => StrategyInKindBatch batch) strategyInKindBatches;
    }

    bytes32 internal constant FUND_FLOW_MANAGER_STORAGE_LOCATION =
        0xa2150758e26bb44e0a441458c3c47420e0cafabeb20258a8fa06803a087dec00;

    function _getFundFlowManagerStorage() internal pure returns (FundFlowManagerStorageLayout storage $) {
        assembly {
            $.slot := FUND_FLOW_MANAGER_STORAGE_LOCATION
        }
    }
}
