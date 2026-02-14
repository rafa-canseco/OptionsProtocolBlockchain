// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AddressBook.sol";
import "./Controller.sol";
import "./OToken.sol";
import "./OTokenFactory.sol";
import "./Whitelist.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BatchSettler
 * @notice Our key differentiator from Rysk. Executes batch settlement of multiple
 *         accepted orders in a single transaction.
 *
 *         Flow:
 *         1. MM publishes prices off-chain (price sheet with TTL)
 *         2. Users accept prices → backend stores accepted orders
 *         3. Every 30-60 min, the keeper bot calls settleBatch() with all pending orders
 *         4. This contract: for each order, opens vault, deposits collateral, mints oTokens,
 *            transfers oTokens to MM, transfers premium from MM to user
 *
 *         Only the operator (MM / keeper bot) can call settleBatch.
 */
contract BatchSettler {
    AddressBook public addressBook;
    address public owner;
    address public operator; // The MM / keeper bot

    struct Order {
        address user;           // The option seller (deposits collateral, receives premium)
        address oToken;         // Which oToken to mint (must exist already)
        uint256 amount;         // Amount of oTokens to mint (8 decimals)
        uint256 premium;        // Premium in USDC to pay the user (6 decimals)
        uint256 collateral;     // Collateral amount (in collateral asset's decimals)
    }

    /// @notice Batch nonce to prevent replay
    uint256 public batchNonce;

    event BatchSettled(uint256 indexed batchId, uint256 ordersCount, uint256 totalPremiums);
    event OrderFilled(
        uint256 indexed batchId,
        address indexed user,
        address oToken,
        uint256 amount,
        uint256 premium,
        uint256 vaultId
    );
    event OrderFailed(uint256 indexed batchId, address indexed user, address oToken, bytes reason);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    error OnlyOwner();
    error OnlyOperator();
    error EmptyBatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    constructor(address _addressBook, address _operator) {
        addressBook = AddressBook(_addressBook);
        owner = msg.sender;
        operator = _operator;
    }

    function setOperator(address _operator) external onlyOwner {
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Settle a batch of orders.
     *         The operator (MM) must have approved this contract to spend USDC for premiums.
     *         Each user must have approved the MarginPool to spend their collateral.
     *
     *         If an individual order fails, it emits OrderFailed and continues.
     *         The batch does NOT revert if one order fails.
     *
     * @param orders Array of orders to settle
     * @param premiumAsset The asset used for premiums (USDC)
     */
    function settleBatch(Order[] calldata orders, address premiumAsset) external onlyOperator {
        if (orders.length == 0) revert EmptyBatch();

        uint256 batchId = batchNonce++;
        Controller ctrl = Controller(addressBook.controller());
        uint256 totalPremiums = 0;
        uint256 filledCount = 0;

        for (uint256 i = 0; i < orders.length; i++) {
            Order calldata order = orders[i];

            try this._executeOrder(ctrl, order, premiumAsset, batchId) returns (uint256 vaultId) {
                totalPremiums += order.premium;
                filledCount++;
                emit OrderFilled(
                    batchId, order.user, order.oToken, order.amount, order.premium, vaultId
                );
            } catch (bytes memory reason) {
                emit OrderFailed(batchId, order.user, order.oToken, reason);
            }
        }

        emit BatchSettled(batchId, filledCount, totalPremiums);
    }

    /**
     * @notice Execute a single order. External so we can use try/catch.
     *         Only callable by this contract itself.
     */
    function _executeOrder(
        Controller ctrl,
        Order calldata order,
        address premiumAsset,
        uint256 /* batchId */
    ) external returns (uint256 vaultId) {
        require(msg.sender == address(this), "only self");

        // 1. Open vault for user
        vaultId = ctrl.openVault(order.user);

        // 2. Deposit user's collateral into vault
        ctrl.depositCollateral(
            order.user,
            vaultId,
            OToken(order.oToken).collateralAsset(),
            order.collateral
        );

        // 3. Mint oTokens to user
        ctrl.mintOtoken(order.user, vaultId, order.oToken, order.amount);

        // 4. Transfer oTokens from user to operator (MM)
        //    User must have approved this contract
        IERC20(order.oToken).transferFrom(order.user, operator, order.amount);

        // 5. Transfer premium from operator (MM) to user
        IERC20(premiumAsset).transferFrom(operator, order.user, order.premium);

        return vaultId;
    }

    /**
     * @notice Settle multiple expired vaults in a single tx.
     *         Called by keeper bot after expiry + oracle price is set.
     */
    function batchSettleVaults(
        address[] calldata owners,
        uint256[] calldata vaultIds
    ) external onlyOperator {
        require(owners.length == vaultIds.length, "length mismatch");

        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < owners.length; i++) {
            try ctrl.settleVault(owners[i], vaultIds[i]) {} catch {}
        }
    }

    /**
     * @notice Redeem oTokens in batch (for the MM after expiry).
     */
    function batchRedeem(address[] calldata oTokens, uint256[] calldata amounts) external {
        require(oTokens.length == amounts.length, "length mismatch");

        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < oTokens.length; i++) {
            if (amounts[i] > 0) {
                ctrl.redeem(oTokens[i], amounts[i]);
            }
        }
    }
}
