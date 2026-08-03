// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";

interface IWheelCoordinatorManagedActions {
    function openCspTranche(uint256 trancheId, address lane, bytes calldata openData) external;
    function openCoveredCallTranche(uint256 trancheId, address lane, bytes calldata openData) external;
    function splitPendingCspTranche(uint256 trancheId, uint256 amount) external returns (uint256 siblingTrancheId);
    function settleCspTranche(uint256 trancheId) external;
    function handoffCspTranche(uint256 trancheId) external returns (uint256 lotId);
    function settleCoveredCallTranche(uint256 trancheId) external;
    function handoffCoveredCallTranche(uint256 trancheId) external;
    function reserveRedemptionUsdc(uint256 trancheId, uint256 amount) external;
    function releaseRedemptionUsdc(uint256 amount) external returns (uint256 trancheId);
    function pauseAllocations() external;
    function registerLane(address lane, WheelTypes.LaneKind kind) external;
    function removeLane(address lane) external;
    function setLaneActive(address lane, bool active) external;
    function setPolicyHash(bytes32 newPolicyHash) external;
    function setFloorBufferUsd8(uint256 newFloorBufferUsd8) external;
    function resumeAllocations() external;
}
