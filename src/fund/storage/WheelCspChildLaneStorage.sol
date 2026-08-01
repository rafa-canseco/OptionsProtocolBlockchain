// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";

abstract contract WheelCspChildLaneStorage {
    /// @custom:storage-location erc7201:b1nary.storage.WheelCspChildLane
    struct WheelCspChildLaneStorageLayout {
        address coordinator;
        address adapter;
        address usdc;
        address weth;
        uint64 stateNonce;
        bool allocationsPaused;
        WheelTypes.LaneState state;
        WheelTypes.SettlementKind settlementKind;
        uint256 maxAssets;
        uint256 activeTrancheId;
        uint256 activePositionId;
        uint256 childShares;
        uint256 accountedUsdc;
        uint256 accountedWeth;
        uint256 literalAssignmentStrike8;
        uint64 expiry;
        bytes32 positionsHash;
        bytes32 lastTransitionHash;
        mapping(bytes32 transitionHash => bool consumed) consumedTransitions;
    }

    bytes32 internal constant WHEEL_CSP_CHILD_LANE_STORAGE_LOCATION =
        0x5b5c8172478fcf27d4908b13c5cb8d71b9818397a4e3de117df8675237f3a100;

    function _getWheelCspChildLaneStorage() internal pure returns (WheelCspChildLaneStorageLayout storage $) {
        assembly {
            $.slot := WHEEL_CSP_CHILD_LANE_STORAGE_LOCATION
        }
    }
}
