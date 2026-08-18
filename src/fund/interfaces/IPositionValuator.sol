// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

interface IPositionValuator {
    function interfaceVersion() external pure returns (uint64);
    function value(address adapter, uint64 snapshotBlock, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory positionValue);
}
