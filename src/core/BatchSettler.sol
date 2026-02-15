// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AddressBook.sol";
import "./Controller.sol";
import "./OToken.sol";
import "./PriceSheet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BatchSettler
 * @notice Handles option order execution and post-expiry settlement.
 *
 *         Primary flow (instant per-order):
 *         1. MM publishes quotes on PriceSheet (bid/ask + TTL + capacity)
 *         2. User (msg.sender) calls executeOrder() — atomic: vault, collateral, mint, oToken->MM, premium->user
 *         3. PriceSheet tracks filled capacity in oToken units; reverts when full
 *
 *         Post-expiry flow:
 *         - batchSettleVaults() settles expired vaults in batch (only operator)
 *         - batchRedeem() redeems oTokens after expiry
 */
contract BatchSettler {
    using SafeERC20 for IERC20;

    AddressBook public addressBook;
    address public owner;
    address public operator; // The Market Maker (MM)

    event OrderExecuted(
        address indexed user,
        address indexed oToken,
        uint256 amount,
        uint256 premium,
        uint256 collateral,
        uint256 vaultId
    );
    event VaultSettleFailed(address indexed vaultOwner, uint256 vaultId, bytes reason);
    event RedeemFailed(address indexed oToken, uint256 amount, bytes reason);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    error OnlyOwner();
    error OnlyOperator();
    error InvalidAddress();
    error InvalidAmount();
    error LengthMismatch();
    error PremiumTooSmall();
    error QuoteInvalid();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    constructor(address _addressBook, address _operator) {
        if (_addressBook == address(0) || _operator == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
        owner = msg.sender;
        operator = _operator;
    }

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Execute a single order instantly. Permissionless — msg.sender is the user.
     *
     *         Prerequisites:
     *         - User has approved MarginPool for collateral asset
     *         - User has approved this contract for oToken transfers
     *         - MM (operator) has approved this contract for premium asset
     *         - A valid, non-expired quote exists on PriceSheet with remaining capacity
     *
     * @param oToken      The oToken to mint
     * @param amount      Amount of oTokens to mint (8 decimals)
     * @param collateral  Collateral to deposit (in collateral asset's decimals)
     * @return vaultId    The vault ID created for this order
     */
    function executeOrder(
        address oToken,
        uint256 amount,
        uint256 collateral
    ) external returns (uint256 vaultId) {
        if (amount == 0) revert InvalidAmount();

        PriceSheet ps = PriceSheet(addressBook.priceSheet());
        Controller ctrl = Controller(addressBook.controller());

        // 1. Read and validate quote
        (uint256 bidPrice, , , , bool isValid) = ps.getQuote(oToken);
        if (!isValid) revert QuoteInvalid();

        // 2. Calculate premium early to fail fast on truncation
        uint256 premium = (amount * bidPrice) / 1e8;
        if (premium == 0 && bidPrice > 0) revert PremiumTooSmall();

        // 3. Fill capacity on PriceSheet in oToken units (reverts if expired or exceeded)
        ps.fillQuote(oToken, amount);

        // 4. Open vault for user
        vaultId = ctrl.openVault(msg.sender);

        // 5. Deposit user's collateral
        address collateralAsset = OToken(oToken).collateralAsset();
        ctrl.depositCollateral(msg.sender, vaultId, collateralAsset, collateral);

        // 6. Mint oTokens to user
        ctrl.mintOtoken(msg.sender, vaultId, oToken, amount);

        // 7. Transfer oTokens from user to operator (MM)
        IERC20(oToken).safeTransferFrom(msg.sender, operator, amount);

        // 8. Transfer premium from operator (MM) to user
        address premiumAsset = OToken(oToken).strikeAsset();
        IERC20(premiumAsset).safeTransferFrom(operator, msg.sender, premium);

        emit OrderExecuted(msg.sender, oToken, amount, premium, collateral, vaultId);
    }

    /**
     * @notice Settle multiple expired vaults in a single tx. Only callable by operator.
     *         Called by keeper bot after expiry + oracle price is set.
     *         Individual failures are logged via VaultSettleFailed events.
     */
    function batchSettleVaults(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) external onlyOperator {
        if (owners.length != vaultIds.length) revert LengthMismatch();

        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < owners.length; i++) {
            try ctrl.settleVault(owners[i], vaultIds[i]) {}
            catch (bytes memory reason) {
                emit VaultSettleFailed(owners[i], vaultIds[i], reason);
            }
        }
    }

    /**
     * @notice Redeem oTokens in batch after expiry. Caller must have approved this
     *         contract for each oToken. Pulls oTokens from caller, redeems via
     *         Controller, and forwards the payout to caller.
     *         Individual failures return oTokens and emit RedeemFailed events.
     */
    function batchRedeem(address[] calldata oTokens, uint256[] calldata amounts) external {
        if (oTokens.length != amounts.length) revert LengthMismatch();

        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < oTokens.length; i++) {
            if (amounts[i] > 0) {
                // Pull oTokens from caller
                IERC20(oTokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);

                // Track collateral balance before redeem
                address collateralAsset = OToken(oTokens[i]).collateralAsset();
                uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));

                try ctrl.redeem(oTokens[i], amounts[i]) {
                    // Forward payout to caller
                    uint256 payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
                    if (payout > 0) {
                        IERC20(collateralAsset).safeTransfer(msg.sender, payout);
                    }
                } catch (bytes memory reason) {
                    // Return oTokens to caller since redemption failed
                    IERC20(oTokens[i]).safeTransfer(msg.sender, amounts[i]);
                    emit RedeemFailed(oTokens[i], amounts[i], reason);
                }
            }
        }
    }
}
