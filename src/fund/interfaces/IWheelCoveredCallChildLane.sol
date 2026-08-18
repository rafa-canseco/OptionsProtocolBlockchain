// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";
import {IWheelChildLane} from "./IWheelChildLane.sol";

interface IWheelCoveredCallChildLane is IWheelChildLane {
    function requiredFloor8() external view returns (uint256);
    function executionCostBuffer8() external view returns (uint256);
    function consumedLotId() external view returns (uint256);

    function openCoveredCall(
        uint256 trancheId,
        bytes32 transitionHash,
        uint256 lotId,
        uint256 literalAssignmentStrike8,
        uint256 protectedBaseFloor8,
        uint256 wethAmount,
        bytes calldata openData
    ) external returns (uint256 mintedChildShares, uint256 positionId, uint64 expiry, bytes32 positionHash);

    function settleCoveredCall(uint256 trancheId, bytes32 expectedPositionHash)
        external
        returns (WheelTypes.SettlementKind settlementKind, bytes32 positionHash);

    function handoffCoveredCall(
        uint256 trancheId,
        bytes32 expectedPositionHash,
        bytes32 transitionHash,
        address receiver
    ) external returns (WheelTypes.LaneBasket memory basket);
}
