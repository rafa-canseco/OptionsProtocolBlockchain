// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";
import {IFundStrategyAdapter} from "./IFundStrategyAdapter.sol";

interface IWheelCoordinatorAdapter is IFundStrategyAdapter {
    struct Summary {
        uint64 stateNonce;
        uint256 trancheCount;
        uint256 assignmentLotCount;
        uint256 pendingCspUsdc;
        uint256 reservedRedemptionUsdc;
        uint256 reservedPrincipalUsdc;
        uint256 transitionWeth;
        uint256 accountedUsdc;
        uint256 accountedWeth;
    }

    function weth() external view returns (address);
    function policyHash() external view returns (bytes32);
    function floorBufferUsd8() external view returns (uint256);
    function allocationsPaused() external view returns (bool);
    function laneCaps() external view returns (uint16 maxCspLanes, uint16 maxCoveredCallLanes);
    function summary() external view returns (Summary memory);
    function tranche(uint256 trancheId) external view returns (WheelTypes.Tranche memory);
    function assignmentLot(uint256 lotId) external view returns (WheelTypes.AssignmentLot memory);
    function registeredLaneCount() external view returns (uint256);
    function registeredLaneAt(uint256 index) external view returns (address lane, WheelTypes.LaneKind kind, bool active);
}
