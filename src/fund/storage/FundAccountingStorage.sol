// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

abstract contract FundAccountingStorage {
    struct ComponentState {
        address valuator;
        uint64 interfaceVersion;
        uint64 nonce;
        bytes32 positionStateHash;
        bool active;
    }

    /// @custom:storage-location erc7201:b1nary.storage.FundAccounting
    struct FundAccountingStorageLayout {
        address fund;
        uint64 compatibilityVersion;
        uint64 reporterSetVersion;
        uint64 lastReportNonce;
        uint16 reporterThreshold;
        bytes32[] activeComponentIds;
        address[] activeReporters;
        mapping(bytes32 componentId => ComponentState state) components;
        mapping(address reporter => bool active) reporters;
        FundTypes.FeeConfig feeConfig;
        FundTypes.FeeState feeState;
        uint64 activationDelay;
        uint64 maxSnapshotAge;
        uint64 maxWindowLength;
    }

    bytes32 internal constant FUND_ACCOUNTING_STORAGE_LOCATION =
        0x6474ad405c872fad56414fb52b104b146a40ea9bc4a4a24e367ebf792f16e500;

    function _getFundAccountingStorage() internal pure returns (FundAccountingStorageLayout storage $) {
        assembly {
            $.slot := FUND_ACCOUNTING_STORAGE_LOCATION
        }
    }
}
