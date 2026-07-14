// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../core/AddressBook.sol";
import "../../core/BatchSettler.sol";
import "../../core/Controller.sol";
import "./EthCspVaultTypes.sol";

library EthCspSettlementModule {
    using SafeERC20 for IERC20;

    error BatchAlreadySettled();
    error CollateralAccountingMismatch();
    error InvalidAmount();
    error StrategyConstraint();

    struct SettlementResult {
        uint256 expectedPhysicalPayout;
        uint256 assignmentShortfall;
    }

    function requiredAssignedUnderlying(
        EthCspVaultTypes.CspBatch storage batch,
        IERC20 underlying,
        uint256 collateralReturned
    ) internal view returns (uint256) {
        if (collateralReturned == batch.collateral) return 0;

        uint8 underlyingDecimals = IERC20Metadata(address(underlying)).decimals();
        if (underlyingDecimals < 8 || underlyingDecimals > 18) revert StrategyConstraint();
        return batch.amount * (10 ** (underlyingDecimals - 8));
    }

    function settle(
        EthCspVaultTypes.CspBatch storage batch,
        AddressBook addressBook,
        IERC20 usdc,
        IERC20 underlying,
        address payoutReceiver,
        uint256 collateralReturned,
        uint256 underlyingReceived
    ) internal returns (SettlementResult memory result) {
        if (batch.protocolVaultId == 0) revert InvalidAmount();
        if (batch.settled) revert BatchAlreadySettled();
        if (collateralReturned > batch.collateral) revert CollateralAccountingMismatch();

        uint256 requiredUnderlyingReceived = requiredAssignedUnderlying(batch, underlying, collateralReturned);
        if (underlyingReceived != requiredUnderlyingReceived) revert CollateralAccountingMismatch();

        uint256 underlyingBefore = underlying.balanceOf(address(this));
        if (underlyingReceived > 0) {
            underlying.safeTransferFrom(payoutReceiver, address(this), underlyingReceived);
        }
        uint256 observedUnderlyingReceived = underlying.balanceOf(address(this)) - underlyingBefore;
        if (observedUnderlyingReceived != underlyingReceived) revert CollateralAccountingMismatch();

        result.expectedPhysicalPayout = batch.collateral - collateralReturned;
        uint256 usdcBefore = usdc.balanceOf(address(this));
        Controller(addressBook.controller()).settleVault(address(this), batch.protocolVaultId);
        uint256 observedCollateralReturned = usdc.balanceOf(address(this)) - usdcBefore;
        if (observedCollateralReturned != collateralReturned) revert CollateralAccountingMismatch();

        uint256 physicalPayout = BatchSettler(addressBook.batchSettler())
            .settleReservedPhysicalDelivery(batch.protocolVaultId, payoutReceiver, result.expectedPhysicalPayout);
        if (physicalPayout != result.expectedPhysicalPayout) revert CollateralAccountingMismatch();

        batch.settled = true;
        batch.collateralReturned = collateralReturned;
        result.assignmentShortfall = result.expectedPhysicalPayout;
    }
}
