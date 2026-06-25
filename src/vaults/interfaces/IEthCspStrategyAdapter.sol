// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../core/BatchSettler.sol";

interface IEthCspStrategyAdapter {
    struct OpenResult {
        uint256 protocolVaultId;
        uint256 premiumEarned;
    }

    struct SettleResult {
        uint256 collateralReturned;
    }

    function openCspBatch(
        address vaultOwner,
        address addressBook,
        address usdc,
        BatchSettler.Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral
    ) external returns (OpenResult memory result);

    function settleCspBatch(
        address vaultOwner,
        address addressBook,
        address usdc,
        uint256 protocolVaultId,
        uint256 expectedCollateralReturned
    ) external returns (SettleResult memory result);
}
