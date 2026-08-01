// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";

interface IWheelChildLane {
    function coordinator() external view returns (address);
    function adapter() external view returns (address);
    function laneKind() external pure returns (WheelTypes.LaneKind);
    function laneState() external view returns (WheelTypes.LaneState);
    function stateNonce() external view returns (uint64);
    function childShares() external view returns (uint256);
    function activeTrancheId() external view returns (uint256);
    function activePositionId() external view returns (uint256);
    function positionStateHash() external view returns (bytes32);
}
