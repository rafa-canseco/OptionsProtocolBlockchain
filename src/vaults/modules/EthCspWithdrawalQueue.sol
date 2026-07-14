// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library EthCspWithdrawalQueue {
    error EpochNotClosed();
    error InsufficientShares();
    error InvalidAmount();
    error PendingWithdrawal();

    struct ClaimPreview {
        uint256 usdcAmount;
        uint256 underlyingAmount;
    }

    function request(
        mapping(address => uint256) storage sharesOf,
        mapping(address => uint256) storage pendingWithdrawalEpoch,
        mapping(address => uint256) storage pendingWithdrawalShares,
        address user,
        uint256 shares,
        uint256 currentEpoch,
        uint256 totalPendingWithdrawalShares,
        uint256 totalPendingWithdrawalClaims
    ) internal returns (uint256 newTotalPendingWithdrawalShares, uint256 newTotalPendingWithdrawalClaims) {
        if (shares == 0) revert InvalidAmount();
        if (pendingWithdrawalShares[user] != 0) revert PendingWithdrawal();
        if (sharesOf[user] < shares) revert InsufficientShares();

        sharesOf[user] -= shares;
        pendingWithdrawalEpoch[user] = currentEpoch;
        pendingWithdrawalShares[user] = shares;
        newTotalPendingWithdrawalShares = totalPendingWithdrawalShares + shares;
        newTotalPendingWithdrawalClaims = totalPendingWithdrawalClaims + 1;
    }

    function previewClaim(
        uint256 shares,
        bool epochClosed,
        uint256 remainingClaims,
        uint256 withdrawalAssetsPerShare,
        uint256 withdrawalAssetsRemaining,
        uint256 withdrawalUnderlyingPerShare,
        uint256 withdrawalUnderlyingRemaining
    ) internal pure returns (ClaimPreview memory preview) {
        if (shares == 0) revert InvalidAmount();
        if (!epochClosed) revert EpochNotClosed();
        if (remainingClaims == 0) revert InvalidAmount();

        if (remainingClaims == 1) {
            preview.usdcAmount = withdrawalAssetsRemaining;
            preview.underlyingAmount = withdrawalUnderlyingRemaining;
        } else {
            preview.usdcAmount = (shares * withdrawalAssetsPerShare) / 1e18;
            preview.underlyingAmount = (shares * withdrawalUnderlyingPerShare) / 1e18;
        }
    }

    function clearClaim(
        mapping(address => uint256) storage pendingWithdrawalEpoch,
        mapping(address => uint256) storage pendingWithdrawalShares,
        address user
    ) internal {
        pendingWithdrawalEpoch[user] = 0;
        pendingWithdrawalShares[user] = 0;
    }
}
