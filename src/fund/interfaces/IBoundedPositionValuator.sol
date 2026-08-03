// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

/// @notice Constant-history valuation entrypoint for adapters constrained to one live position.
interface IBoundedPositionValuator {
    function valuePosition(address adapter, uint256 positionId, uint64 snapshotBlock, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory positionValue);
}
