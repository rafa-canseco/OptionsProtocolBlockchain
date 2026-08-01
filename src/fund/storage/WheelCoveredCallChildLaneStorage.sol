// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";

abstract contract WheelCoveredCallChildLaneStorage {
    /// @custom:storage-location erc7201:b1nary.storage.WheelCoveredCallChildLane
    struct WheelCoveredCallChildLaneStorageLayout {
        address coordinator;
        address adapter;
        address usdc;
        address weth;
        uint64 stateNonce;
        bool allocationsPaused;
        WheelTypes.LaneState state;
        WheelTypes.SettlementKind settlementKind;
        uint256 maxAssets;
        uint256 executionCostBuffer8;
        uint256 activeTrancheId;
        uint256 activePositionId;
        uint256 consumedLotId;
        uint256 childShares;
        uint256 accountedUsdc;
        uint256 accountedWeth;
        uint256 literalAssignmentStrike8;
        uint256 requiredFloor8;
        uint64 expiry;
        bytes32 positionsHash;
        bytes32 lastTransitionHash;
        mapping(bytes32 transitionHash => bool consumed) consumedTransitions;
    }

    bytes32 internal constant WHEEL_COVERED_CALL_CHILD_LANE_STORAGE_LOCATION =
        0xea0502a16655f4c2cbe69d41fbd44b44d8675305bc5edb38d2bf62a9478d4200;

    function _getWheelCoveredCallChildLaneStorage()
        internal
        pure
        returns (WheelCoveredCallChildLaneStorageLayout storage $)
    {
        assembly {
            $.slot := WHEEL_COVERED_CALL_CHILD_LANE_STORAGE_LOCATION
        }
    }
}
