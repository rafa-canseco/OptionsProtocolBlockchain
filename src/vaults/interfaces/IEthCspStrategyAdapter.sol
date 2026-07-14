// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../CspBatchSettler.sol";

interface IEthCspStrategyAdapter {
    struct OpenResult {
        uint256 protocolVaultId;
        uint256 premiumEarned;
    }

    function openCspBatch(
        address vaultOwner,
        address cspSettler,
        address addressBook,
        address usdc,
        CspBatchSettler.Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral
    ) external returns (OpenResult memory result);
}
