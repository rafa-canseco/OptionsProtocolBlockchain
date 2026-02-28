// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IMarginVault
 * @notice Defines the vault structure for holding option positions.
 *         Each vault represents one user's position for one option series.
 *         Fully collateralized only — no naked margin, no liquidation.
 */
library MarginVault {
    struct Vault {
        address shortOtoken; // The oToken this vault has written (sold)
        address collateralAsset; // The ERC20 used as collateral
        uint256 shortAmount; // Amount of oTokens minted (8 decimals)
        uint256 collateralAmount; // Amount of collateral deposited (in collateral's decimals)
    }
}
