// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AddressBook.sol";
import "./Controller.sol";
import "./OToken.sol";
import "./Oracle.sol";
import "./PriceSheet.sol";
import "../interfaces/IFlashLoanSimple.sol";
import "../interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BatchSettler
 * @notice Handles option order execution and post-expiry settlement.
 *
 *         Primary flow (instant per-order):
 *         1. MM publishes quotes on PriceSheet (bid/ask + TTL + capacity)
 *         2. User (msg.sender) calls executeOrder() — atomic: vault, collateral, mint, oToken->MM, premium->user
 *         3. PriceSheet tracks filled capacity in oToken units; reverts when full
 *
 *         Post-expiry flow (physical settlement):
 *         - batchSettleVaults() settles expired vaults (ITM: user gets 0 back, OTM: full refund)
 *         - batchPhysicalRedeem() delivers contra-asset to ITM users via flash loan + DEX swap
 *         - batchRedeem() redeems remaining oTokens after expiry
 */
contract BatchSettler is ReentrancyGuard, IFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    AddressBook public addressBook;
    address public owner;
    address public operator; // The Market Maker (MM)
    uint256 public batchNonce; // Incremented on each batchSettleVaults() call

    // Protocol fee
    address public treasury;
    uint256 public protocolFeeBps; // basis points (400 = 4%, max 2000 = 20%)

    // Physical delivery infrastructure
    address public aavePool;
    address public swapRouter;
    uint24 public swapFeeTier; // Uniswap V3 fee tier in hundredths of a bps (e.g. 500 = 0.05%)

    event OrderExecuted(
        address indexed user,
        address indexed oToken,
        uint256 amount,
        uint256 grossPremium,
        uint256 netPremium,
        uint256 fee,
        uint256 collateral,
        uint256 vaultId
    );
    event VaultSettleFailed(address indexed vaultOwner, uint256 vaultId, bytes reason);
    event RedeemFailed(address indexed oToken, uint256 amount, bytes reason);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event PhysicalDelivery(
        address indexed oToken,
        address indexed user,
        uint256 contraAmount,
        uint256 collateralUsed
    );
    event PhysicalRedeemFailed(address indexed oToken, address indexed user, uint256 amount, bytes reason);

    error OnlyOwner();
    error OnlyOperator();
    error InvalidAddress();
    error InvalidAmount();
    error LengthMismatch();
    error PremiumTooSmall();
    error QuoteInvalid();
    error EmptyArray();
    error OptionNotExpired();
    error ExpiryPriceNotSet();
    error OptionNotITM();
    error AavePoolNotSet();
    error SwapRouterNotSet();
    error FlashLoanUnauthorized();
    error FeeTooHigh();
    error InvalidFeeTier();
    error RedeemReturnedZero();

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

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    function setProtocolFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > 2000) revert FeeTooHigh();
        protocolFeeBps = _feeBps;
    }

    function setAavePool(address _aavePool) external onlyOwner {
        if (_aavePool == address(0)) revert InvalidAddress();
        aavePool = _aavePool;
    }

    function setSwapRouter(address _swapRouter) external onlyOwner {
        if (_swapRouter == address(0)) revert InvalidAddress();
        swapRouter = _swapRouter;
    }

    function setSwapFeeTier(uint24 _feeTier) external onlyOwner {
        if (_feeTier != 100 && _feeTier != 500 && _feeTier != 3000 && _feeTier != 10000) {
            revert InvalidFeeTier();
        }
        swapFeeTier = _feeTier;
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

        // 8. Transfer premium from operator (MM) to user (minus protocol fee)
        _transferPremium(oToken, amount, premium, collateral, vaultId);
    }

    /**
     * @dev Transfer premium from operator to user, deducting protocol fee if configured.
     *      Extracted from executeOrder to avoid stack-too-deep.
     */
    function _transferPremium(
        address oToken,
        uint256 amount,
        uint256 premium,
        uint256 collateral,
        uint256 vaultId
    ) private {
        address premiumAsset = OToken(oToken).strikeAsset();
        uint256 fee = 0;
        if (protocolFeeBps > 0 && treasury != address(0)) {
            fee = (premium * protocolFeeBps) / 10000;
        }
        uint256 netPremium = premium - fee;

        IERC20(premiumAsset).safeTransferFrom(operator, msg.sender, netPremium);
        if (fee > 0) {
            IERC20(premiumAsset).safeTransferFrom(operator, treasury, fee);
        }

        emit OrderExecuted(msg.sender, oToken, amount, premium, netPremium, fee, collateral, vaultId);
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

    // ===== Physical Delivery (flash loan + DEX swap) =====

    /**
     * @notice Deliver the contra-asset to a user whose ITM option was physically settled.
     *         Uses an Aave V3 flash loan to borrow the contra-asset, delivers it to the user,
     *         redeems oTokens to get collateral from MarginPool, swaps collateral → contra-asset
     *         on Uniswap V3 to repay the flash loan, and sends surplus collateral to the operator.
     *
     *         Prerequisites:
     *         - Option must be expired and ITM (strictly: PUT expiryPrice < strike, CALL expiryPrice > strike)
     *         - Oracle expiry price must be set
     *         - Operator must have approved this contract for the oToken
     *         - aavePool and swapRouter must be configured
     *
     * @param oToken             The expired oToken
     * @param user               The address to receive the contra-asset (typically the vault owner
     *                           whose collateral was retained at settlement)
     * @param amount             Amount of oTokens to redeem (8 decimals)
     * @param maxCollateralSpent Maximum collateral to spend in the DEX swap (slippage protection)
     */
    function physicalRedeem(
        address oToken,
        address user,
        uint256 amount,
        uint256 maxCollateralSpent
    ) public onlyOperator nonReentrant {
        _executePhysicalRedeem(oToken, user, amount, maxCollateralSpent);
    }

    /**
     * @notice Aave V3 flash loan callback. Called by the Aave Pool after sending the flash-loaned asset.
     *         Handles: deliver contra-asset to user → redeem oTokens → swap collateral → repay flash loan.
     * @dev MUST NOT be called externally — only by the Aave Pool as part of flashLoanSimple.
     *      The `premium` parameter here is the Aave flash loan fee (NOT the option premium used elsewhere).
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        if (msg.sender != aavePool) revert FlashLoanUnauthorized();
        if (initiator != address(this)) revert FlashLoanUnauthorized();

        (address oToken, address user, uint256 oTokenAmount, uint256 maxCollateralSpent) =
            abi.decode(params, (address, address, uint256, uint256));

        // 1. Deliver contra-asset to user
        IERC20(asset).safeTransfer(user, amount);

        // 2. Pull oTokens from operator, redeem, swap, and repay
        uint256 collateralUsed = _redeemAndSwap(oToken, oTokenAmount, asset, amount + premium, maxCollateralSpent);

        // 3. Approve Aave Pool to pull repayment
        IERC20(asset).forceApprove(aavePool, amount + premium);

        emit PhysicalDelivery(oToken, user, amount, collateralUsed);

        return true;
    }

    /**
     * @dev Pull oTokens from operator, redeem for collateral, swap collateral → contra-asset,
     *      and sweep surplus to operator. Extracted to avoid stack-too-deep in executeOperation.
     */
    function _redeemAndSwap(
        address oToken,
        uint256 oTokenAmount,
        address contraAsset,
        uint256 repayAmount,
        uint256 maxCollateralSpent
    ) private returns (uint256 collateralUsed) {
        IERC20(oToken).safeTransferFrom(operator, address(this), oTokenAmount);

        Controller ctrl = Controller(addressBook.controller());
        address collateralAsset = OToken(oToken).collateralAsset();
        uint256 collateralBefore = IERC20(collateralAsset).balanceOf(address(this));

        ctrl.redeem(oToken, oTokenAmount);

        uint256 collateralReceived = IERC20(collateralAsset).balanceOf(address(this)) - collateralBefore;
        if (collateralReceived == 0) revert RedeemReturnedZero();

        // Swap collateral → contra-asset to repay flash loan
        IERC20(collateralAsset).forceApprove(swapRouter, collateralReceived);

        collateralUsed = ISwapRouter(swapRouter).exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: collateralAsset,
                tokenOut: contraAsset,
                fee: swapFeeTier,
                recipient: address(this),
                amountOut: repayAmount,
                amountInMaximum: maxCollateralSpent,
                sqrtPriceLimitX96: 0
            })
        );

        // Sweep surplus collateral to operator (MM's profit from ITM assignment)
        uint256 surplus = collateralReceived - collateralUsed;
        if (surplus > 0) {
            IERC20(collateralAsset).safeTransfer(operator, surplus);
        }

        // Clear leftover approval to prevent residual allowance from being exploited
        IERC20(collateralAsset).forceApprove(swapRouter, 0);
    }

    /**
     * @notice Batch physical delivery for multiple ITM users. Operator-only.
     *         Individual failures emit PhysicalRedeemFailed and continue.
     *
     *         Expected flow: call batchSettleVaults() first, then batchPhysicalRedeem().
     */
    function batchPhysicalRedeem(
        address[] calldata oTokens,
        address[] calldata users,
        uint256[] calldata amounts,
        uint256[] calldata maxCollateralSpents
    ) external onlyOperator {
        if (oTokens.length != users.length || users.length != amounts.length
            || amounts.length != maxCollateralSpents.length) revert LengthMismatch();
        if (oTokens.length == 0) revert EmptyArray();

        for (uint256 i = 0; i < oTokens.length; i++) {
            if (amounts[i] == 0) continue;

            try this._physicalRedeemSingle(oTokens[i], users[i], amounts[i], maxCollateralSpents[i]) {
            } catch (bytes memory reason) {
                emit PhysicalRedeemFailed(oTokens[i], users[i], amounts[i], reason);
            }
        }
    }

    /**
     * @notice Self-call target for batchPhysicalRedeem — delegates to shared _executePhysicalRedeem.
     *         External so the batch can catch individual failures without reverting the entire batch.
     *         Cannot call physicalRedeem directly because onlyOperator would fail (msg.sender is address(this)).
     */
    function _physicalRedeemSingle(
        address oToken,
        address user,
        uint256 amount,
        uint256 maxCollateralSpent
    ) external nonReentrant {
        if (msg.sender != address(this)) revert InvalidAddress();
        _executePhysicalRedeem(oToken, user, amount, maxCollateralSpent);
    }

    /**
     * @dev Shared implementation for physicalRedeem and _physicalRedeemSingle.
     *      Validates the option is expired + ITM, calculates contra-asset, and initiates flash loan.
     */
    function _executePhysicalRedeem(
        address oToken,
        address user,
        uint256 amount,
        uint256 maxCollateralSpent
    ) private {
        if (oToken == address(0)) revert InvalidAddress();
        if (user == address(0)) revert InvalidAddress();
        if (aavePool == address(0)) revert AavePoolNotSet();
        if (swapRouter == address(0)) revert SwapRouterNotSet();
        if (amount == 0) revert InvalidAmount();

        OToken ot = OToken(oToken);
        if (block.timestamp < ot.expiry()) revert OptionNotExpired();

        Oracle oracle = Oracle(addressBook.oracle());
        (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(ot.underlying(), ot.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 strike = ot.strikePrice();
        if (ot.isPut()) {
            if (expiryPrice >= strike) revert OptionNotITM();
        } else {
            if (expiryPrice <= strike) revert OptionNotITM();
        }

        address contraAsset;
        uint256 contraAmount;
        if (ot.isPut()) {
            contraAsset = ot.underlying();
            contraAmount = amount * 1e10; // oToken 8 dec → underlying 18 dec (assumes 18 dec underlying)
        } else {
            contraAsset = ot.strikeAsset();
            contraAmount = (amount * strike) / 1e10; // oToken 8 dec → USDC 6 dec (assumes 6 dec strike asset)
        }

        bytes memory params = abi.encode(oToken, user, amount, maxCollateralSpent);
        IPool(aavePool).flashLoanSimple(address(this), contraAsset, contraAmount, params, 0);
    }
}
