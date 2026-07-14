// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library EthCspDepositQueue {
    error InsolventShareSupply();
    error InvalidAmount();
    error OpenBatches();

    function canActivate(uint256 activeBatches, uint256 totalPendingWithdrawalShares, uint256 availableUnderlying)
        internal
        pure
        returns (bool)
    {
        return activeBatches == 0 && totalPendingWithdrawalShares == 0 && availableUnderlying == 0;
    }

    function previewActiveShares(uint256 assets, uint256 totalShares, uint256 managedBefore)
        internal
        pure
        returns (uint256 mintedShares)
    {
        if (totalShares == 0) {
            mintedShares = assets;
        } else if (managedBefore == 0) {
            revert InsolventShareSupply();
        } else {
            mintedShares = (assets * totalShares) / managedBefore;
        }
    }

    function queue(
        mapping(address => uint256) storage pendingDepositAssets,
        address user,
        uint256 assets,
        uint256 totalPendingDepositAssets
    ) internal returns (uint256 newTotalPendingDepositAssets) {
        pendingDepositAssets[user] += assets;
        newTotalPendingDepositAssets = totalPendingDepositAssets + assets;
    }

    function cancel(
        mapping(address => uint256) storage pendingDepositAssets,
        address user,
        uint256 totalPendingDepositAssets
    ) internal returns (uint256 assets, uint256 newTotalPendingDepositAssets) {
        assets = pendingDepositAssets[user];
        if (assets == 0) revert InvalidAmount();

        pendingDepositAssets[user] = 0;
        newTotalPendingDepositAssets = totalPendingDepositAssets - assets;
    }

    function consume(
        mapping(address => uint256) storage pendingDepositAssets,
        address user,
        uint256 totalPendingDepositAssets,
        bool canActivate_
    ) internal returns (uint256 assets, uint256 newTotalPendingDepositAssets) {
        if (!canActivate_) revert OpenBatches();

        assets = pendingDepositAssets[user];
        if (assets == 0) revert InvalidAmount();

        pendingDepositAssets[user] = 0;
        newTotalPendingDepositAssets = totalPendingDepositAssets - assets;
    }
}
