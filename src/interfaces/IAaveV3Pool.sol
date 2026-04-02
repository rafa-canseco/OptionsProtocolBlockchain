// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Aave V3 Pool interface for MarginPool integration.
///         Only the functions needed for supply/withdraw/index queries.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
