// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library EthCspAssignmentLedger {
    error AssignedUnderlyingTooLarge();
    error InvalidAmount();

    struct AllocationResult {
        uint256 distributed;
        uint256 swept;
        uint256 newAccountedUnderlyingAssets;
        uint256 newAllocatedUnderlyingAssets;
        uint256 newCumulativeUnderlyingPerShare;
    }

    function available(
        uint256 accountedUnderlyingAssets,
        uint256 reservedUnderlyingAssets,
        uint256 allocatedUnderlyingAssets
    ) internal pure returns (uint256) {
        uint256 unavailable = reservedUnderlyingAssets + allocatedUnderlyingAssets;
        if (accountedUnderlyingAssets <= unavailable) return 0;
        return accountedUnderlyingAssets - unavailable;
    }

    function allocate(
        uint256 amount,
        uint256 totalShares,
        uint256 accountedUnderlyingAssets,
        uint256 allocatedUnderlyingAssets,
        uint256 cumulativeUnderlyingPerShare,
        uint256 dustThreshold
    ) internal pure returns (AllocationResult memory result) {
        result.newAccountedUnderlyingAssets = accountedUnderlyingAssets;
        result.newAllocatedUnderlyingAssets = allocatedUnderlyingAssets;
        result.newCumulativeUnderlyingPerShare = cumulativeUnderlyingPerShare;

        if (amount == 0 || totalShares == 0) return result;

        uint256 delta = (amount * 1e18) / totalShares;
        if (delta == 0) {
            if (amount > dustThreshold) revert AssignedUnderlyingTooLarge();
            result.swept = amount;
            result.newAccountedUnderlyingAssets = accountedUnderlyingAssets - amount;
            return result;
        }

        result.distributed = (delta * totalShares) / 1e18;
        uint256 residual = amount - result.distributed;
        if (residual > 0) {
            if (residual > dustThreshold) revert AssignedUnderlyingTooLarge();
            result.swept = residual;
            result.newAccountedUnderlyingAssets = accountedUnderlyingAssets - residual;
        }

        result.newCumulativeUnderlyingPerShare = cumulativeUnderlyingPerShare + delta;
        result.newAllocatedUnderlyingAssets = allocatedUnderlyingAssets + result.distributed;
    }

    function accrue(
        mapping(address => uint256) storage underlyingPerSharePaid,
        mapping(address => uint256) storage claimableAssignedUnderlying,
        mapping(address => uint256) storage sharesOf,
        address user,
        uint256 cumulativeUnderlyingPerShare
    ) internal {
        uint256 paid = underlyingPerSharePaid[user];
        if (paid == cumulativeUnderlyingPerShare) return;

        uint256 userShares = sharesOf[user];
        if (userShares > 0) {
            uint256 accrued = (userShares * (cumulativeUnderlyingPerShare - paid)) / 1e18;
            if (accrued > 0) {
                claimableAssignedUnderlying[user] += accrued;
            }
        }
        underlyingPerSharePaid[user] = cumulativeUnderlyingPerShare;
    }

    function consumeClaim(mapping(address => uint256) storage claimableAssignedUnderlying, address user)
        internal
        returns (uint256 amount)
    {
        amount = claimableAssignedUnderlying[user];
        if (amount == 0) revert InvalidAmount();
        claimableAssignedUnderlying[user] = 0;
    }
}
