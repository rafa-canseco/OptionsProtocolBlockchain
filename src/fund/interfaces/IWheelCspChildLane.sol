// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";
import {IWheelChildLane} from "./IWheelChildLane.sol";

interface IWheelCspChildLane is IWheelChildLane {
    function openCsp(uint256 trancheId, bytes32 transitionHash, uint256 usdcAmount, bytes calldata openData)
        external
        returns (uint256 mintedChildShares, uint256 positionId, uint64 expiry, bytes32 positionHash);

    function settleCsp(uint256 trancheId, bytes32 expectedPositionHash)
        external
        returns (WheelTypes.SettlementKind settlementKind, bytes32 positionHash);

    function handoffCsp(uint256 trancheId, bytes32 expectedPositionHash, bytes32 transitionHash, address receiver)
        external
        returns (WheelTypes.LaneBasket memory basket);
}
