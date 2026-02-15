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
    uint256 public batchNonce; // Incremented on each batchSettleVaults() call

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
    error EmptyArray();

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
        if (oToken == address(0)) revert InvalidAddress();
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
        if (owners.length == 0) revert EmptyArray();

        batchNonce++;
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
     *         contract for each oToken. For each item: pulls oTokens from caller,
     *         redeems via Controller, and forwards the payout to caller.
     *         Individual failures (bad approval, insufficient balance, redeem revert)
     *         emit RedeemFailed and continue — the batch never reverts due to one item.
     */
    function batchRedeem(address[] calldata oTokens, uint256[] calldata amounts) external {
        if (oTokens.length != amounts.length) revert LengthMismatch();
        if (oTokens.length == 0) revert EmptyArray();

        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < oTokens.length; i++) {
            if (amounts[i] == 0) continue;

            try this._redeemSingle(oTokens[i], amounts[i], msg.sender, ctrl) {
            } catch (bytes memory reason) {
                emit RedeemFailed(oTokens[i], amounts[i], reason);
            }
        }
    }

    /**
     * @notice Self-call target for batchRedeem — redeems a single oToken position.
     *         External so batchRedeem can wrap it in try/catch for full fault isolation.
     *         Any revert (pull, redeem, payout) is caught by the caller and rolled back
     *         atomically — no tokens can get stuck in this contract.
     */
    function _redeemSingle(
        address oToken,
        uint256 amount,
        address caller,
        Controller ctrl
    ) external {
        if (msg.sender != address(this)) revert InvalidAddress();

        IERC20(oToken).safeTransferFrom(caller, address(this), amount);

        address collateralAsset = OToken(oToken).collateralAsset();
        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));

        ctrl.redeem(oToken, amount);

        uint256 payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
        if (payout > 0) {
            IERC20(collateralAsset).safeTransfer(caller, payout);
        }
    }
}
