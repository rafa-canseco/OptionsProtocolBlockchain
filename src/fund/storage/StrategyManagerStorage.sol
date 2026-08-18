// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

abstract contract StrategyManagerStorage {
    /// @custom:storage-location erc7201:b1nary.storage.StrategyManager
    struct StrategyManagerStorageLayout {
        address fund;
        uint64 compatibilityVersion;
        uint16 minimumIdleBps;
        bytes32 positionsHash;
        address[] activeAdapters;
        mapping(address adapter => FundTypes.StrategyConfig config) strategies;
        mapping(address adapter => uint64 nonce) positionNonces;
        mapping(address asset => bool allowed) allowedAssets;
        mapping(address asset => uint256 amount) totalAllocated;
        mapping(address adapter => mapping(address asset => uint256 amount)) adapterAllocated;
        mapping(address adapter => uint48 timestamp) lastOperationAt;
        mapping(address adapter => uint64 nonce) allocationPauseNonces;
    }

    bytes32 internal constant STRATEGY_MANAGER_STORAGE_LOCATION =
        0x25887ea3e5e75cc13395c4a56dac59490fcb6528f03e6c5e7b324f5c7afd6b00;

    function _getStrategyManagerStorage() internal pure returns (StrategyManagerStorageLayout storage $) {
        assembly {
            $.slot := STRATEGY_MANAGER_STORAGE_LOCATION
        }
    }
}
