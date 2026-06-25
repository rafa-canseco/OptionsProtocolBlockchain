// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IEthCspOptionSelector {
    struct StrategyConfig {
        uint256 maxCollateralPerBatch;
        uint256 maxUtilizationBps;
        uint256 minPremiumBps;
        uint256 minExpiryDelay;
        uint256 maxExpiryDelay;
        uint256 minStrike;
        uint256 maxStrike;
    }

    function validateOption(
        address oToken,
        address ethUnderlying,
        address usdc,
        uint256 collateral,
        uint256 activeCollateral,
        uint256 totalManagedAssets
    ) external view;

    function validatePremium(uint256 collateral, uint256 premiumEarned) external view;
}
