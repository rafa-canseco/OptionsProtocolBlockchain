// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IFundVaultModuleCallbacks {
    function escrowShares(address owner, uint256 shares) external;
    function returnEscrowedShares(address receiver, uint256 shares) external;
    function reserveAccountingAssets(uint256 assets) external;
    function releaseClaimReserve(uint256 assets) external;
    function recordStrategyReturn(address asset, uint256 balanceBefore) external returns (uint256 received);
    function invalidateNav() external;
    function restoreNavWindow(uint64 reportNonce, uint64 validUntilBlock, bytes32 positionsHash) external;
    function recordStrategyPositions(bytes32 positionsHash) external;
    function accountedIdleAssets() external view returns (uint256);
    function unaccountedBalance(address asset) external view returns (uint256);
    function executionLockOwner() external view returns (address);
}

interface IFundAccountingModuleCallbacks {
    function syncStrategyComponent(address adapter, uint64 nonce, bytes32 positionStateHash) external;
}
