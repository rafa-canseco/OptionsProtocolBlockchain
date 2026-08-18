// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";

abstract contract WheelCoordinatorAdapterStorage {
    struct LaneConfig {
        WheelTypes.LaneKind kind;
        bool active;
    }

    /// @custom:storage-location erc7201:b1nary.storage.WheelCoordinatorAdapter
    struct WheelCoordinatorAdapterStorageLayout {
        address fund;
        address strategyManager;
        address usdc;
        address weth;
        uint64 stateNonce;
        uint16 maxCspLanes;
        uint16 maxCoveredCallLanes;
        uint256 floorBufferUsd8;
        bytes32 policyHash;
        bool allocationsPaused;
        bool executing;
        uint256 trancheCount;
        uint256 assignmentLotCount;
        uint256 pendingCspUsdc;
        uint256 reservedRedemptionUsdc;
        uint256 reservedPrincipalUsdc;
        uint256 transitionWeth;
        uint256 accountedUsdc;
        uint256 accountedWeth;
        bytes32 positionsHash;
        address[] registeredLanes;
        mapping(address lane => LaneConfig config) lanes;
        mapping(address lane => uint256 trancheId) activeLaneTranche;
        mapping(uint256 trancheId => WheelTypes.Tranche tranche) tranches;
        mapping(uint256 lotId => WheelTypes.AssignmentLot lot) lots;
        mapping(bytes32 transitionHash => bool consumed) consumedTransitions;
    }

    bytes32 internal constant WHEEL_COORDINATOR_ADAPTER_STORAGE_LOCATION =
        0xfbe4667ece6e30e8cdc1b0ad01597c5c664e103f49ad6c3df8267d18256d1000;

    function _getWheelCoordinatorAdapterStorage()
        internal
        pure
        returns (WheelCoordinatorAdapterStorageLayout storage $)
    {
        assembly {
            $.slot := WHEEL_COORDINATOR_ADAPTER_STORAGE_LOCATION
        }
    }
}
