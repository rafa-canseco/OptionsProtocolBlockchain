// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IStrategyAssetEscrow {
    event AssetReleasedToFund(address indexed asset, uint256 amount);

    error BalanceDeltaMismatch(address asset, uint256 expected, uint256 actual);
    error InvalidAddress();
    error InvalidAmount();

    function FUND() external view returns (address);
    function PURPOSE() external view returns (bytes32);
    function releaseToFund(address asset, uint256 amount) external;
}
