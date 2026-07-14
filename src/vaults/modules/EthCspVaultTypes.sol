// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library EthCspVaultTypes {
    struct Epoch {
        uint64 startedAt;
        uint64 endedAt;
        uint256 deposits;
        uint256 withdrawals;
        uint256 committedCollateral;
        uint256 returnedCollateral;
        uint256 premiumEarned;
        uint256 assignmentShortfall;
        uint256 performanceFee;
        uint256 withdrawalAssetsPerShare;
        uint256 withdrawalAssetsRemaining;
        uint256 remainingWithdrawalClaims;
        bool closed;
    }

    struct CspBatch {
        uint256 epochId;
        address oToken;
        uint256 protocolVaultId;
        uint256 amount;
        uint256 collateral;
        uint256 premiumEarned;
        uint256 collateralReturned;
        bool settled;
    }
}
