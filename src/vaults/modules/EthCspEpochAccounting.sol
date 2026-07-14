// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library EthCspEpochAccounting {
    struct ClosePreview {
        uint256 reservedAssets;
        uint256 reservedUnderlying;
        uint256 withdrawalAssetsPerShare;
        uint256 withdrawalUnderlyingPerShare;
    }

    function previewClose(
        uint256 totalShares,
        uint256 pendingShares,
        uint256 availableIdleAssets,
        uint256 availableUnderlyingAssets
    ) internal pure returns (ClosePreview memory preview) {
        if (pendingShares == 0) return preview;

        preview.reservedAssets = (availableIdleAssets * pendingShares) / totalShares;
        preview.reservedUnderlying = (availableUnderlyingAssets * pendingShares) / totalShares;
        preview.withdrawalAssetsPerShare = (preview.reservedAssets * 1e18) / pendingShares;
        preview.withdrawalUnderlyingPerShare = (preview.reservedUnderlying * 1e18) / pendingShares;
    }
}
