// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../core/AddressBook.sol";
import "../core/BatchSettler.sol";
import "../core/MarginPool.sol";
import "./interfaces/IEthCspStrategyAdapter.sol";

contract EthCspStrategyAdapter is IEthCspStrategyAdapter {
    using SafeERC20 for IERC20;

    error CollateralAccountingMismatch();
    error InvalidAddress();
    error PremiumAccountingMismatch();
    error Unauthorized();

    function openCspBatch(
        address vaultOwner,
        address addressBook_,
        address usdc,
        BatchSettler.Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral
    ) external returns (OpenResult memory result) {
        if (vaultOwner == address(0) || addressBook_ == address(0) || usdc == address(0)) {
            revert InvalidAddress();
        }
        if (msg.sender != vaultOwner) revert Unauthorized();

        AddressBook book = AddressBook(addressBook_);
        address marginPool = book.marginPool();
        uint256 poolBalanceBefore = MarginPool(marginPool).getStoredBalance(usdc);
        uint256 balanceBefore = IERC20(usdc).balanceOf(vaultOwner);

        result.protocolVaultId =
            BatchSettler(book.batchSettler()).executeOrderFor(vaultOwner, quote, signature, amount, collateral);

        uint256 balanceAfter = IERC20(usdc).balanceOf(vaultOwner);
        uint256 poolBalanceAfter = MarginPool(marginPool).getStoredBalance(usdc);
        if (poolBalanceAfter < poolBalanceBefore || poolBalanceAfter - poolBalanceBefore != collateral) {
            revert CollateralAccountingMismatch();
        }

        uint256 premiumEarnedWithCollateral = balanceAfter + collateral;
        if (premiumEarnedWithCollateral < balanceBefore) revert PremiumAccountingMismatch();
        result.premiumEarned = premiumEarnedWithCollateral - balanceBefore;
    }
}
