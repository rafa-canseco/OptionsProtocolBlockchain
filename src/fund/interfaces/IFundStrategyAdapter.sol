// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IFundStrategyAdapter {
    function fund() external view returns (address);
    function accountingAsset() external view returns (address);
    function interfaceVersion() external pure returns (uint64);
    function positionStateHash() external view returns (bytes32);
    function freeAssets(address asset) external view returns (uint256);

    function allocate(address asset, uint256 amount, bytes calldata data) external;
    function deallocate(uint256 targetValue, uint256 minAccountingAssetsOut, bytes calldata data)
        external
        returns (uint256 accountingAssetsOut);
    function deallocateInKind(uint256 fractionWad, address escrow, bytes calldata data)
        external
        returns (address[] memory assets, uint256[] memory amounts);
    function emergencyExit(address escrow, bytes calldata data)
        external
        returns (address[] memory assets, uint256[] memory amounts);
}
