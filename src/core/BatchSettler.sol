// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./AddressBook.sol";
import "./Controller.sol";
import "./OToken.sol";
import "./Oracle.sol";
import "../interfaces/IFlashLoanSimple.sol";
import "../interfaces/IMarginVault.sol";
import "../interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BatchSettler
 * @notice Handles option order execution and post-expiry settlement.
 *
 *         Primary flow (instant per-order):
 *         1. MM signs EIP-712 quotes off-chain (bidPrice, deadline, quoteId, maxAmount, makerNonce)
 *         2. User calls executeOrder() with the signed quote + signature
 *         3. Contract recovers MM address via ECDSA, verifies whitelist, checks fills
 *         4. Atomic: vault, collateral, mint oTokens→settler (custodied for MM), premium→user
 *
 *         Post-expiry flow (physical settlement):
 *         - batchSettleVaults() settles expired vaults (returns collateral minus intrinsic value)
 *         - batchPhysicalRedeem() delivers contra-asset to ITM users via flash loan + DEX swap
 *         - batchRedeem() redeems remaining oTokens after expiry
 */
contract BatchSettler is Initializable, UUPSUpgradeable, ReentrancyGuard, IFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    // ===== EIP-712 =====

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("b1nary");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    // Cached domain separator (storage vars, not immutable — proxy-compatible)
    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;

    struct Quote {
        address oToken;
        uint256 bidPrice; // premium per oToken (1e8 scale, in strike asset units)
        uint256 deadline; // unix timestamp
        uint256 quoteId; // unique per MM, for fill tracking + cancellation
        uint256 maxAmount; // max oTokens fillable (8 decimals)
        uint256 makerNonce; // must match current makerNonce[signer]
    }

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address oToken,uint256 bidPrice,uint256 deadline,uint256 quoteId,uint256 maxAmount,uint256 makerNonce)"
    );

    uint256 private constant CANCEL_BIT = 1 << 255;

    // ===== Storage =====

    AddressBook public addressBook;
    address public owner;
    address public operator; // Settlement bot (batchSettleVaults, physicalRedeem)
    uint256 public batchNonce;

    // Protocol fee
    address public treasury;
    uint256 public protocolFeeBps; // basis points (400 = 4%, max 2000 = 20%)

    // Physical delivery infrastructure
    address public aavePool;
    address public swapRouter;
    uint24 public swapFeeTier;

    // EIP-712 signed quotes
    /// @notice Per-MM fill tracking. Lower 255 bits = filled amount, bit 255 = cancelled.
    mapping(address => mapping(bytes32 => uint256)) public quoteState;
    /// @notice Global nonce per MM for bulk cancellation (circuit breaker).
    mapping(address => uint256) public makerNonce;
    /// @notice Whitelisted market makers.
    mapping(address => bool) public whitelistedMMs;

    /// @notice oToken balances custodied per MM (mm => oToken => balance).
    mapping(address => mapping(address => uint256)) public mmOTokenBalance;

    /// @notice Vault-to-MM mapping for emergency withdrawal ledger clearance.
    /// @dev    Set during executeOrder. For pre-migration vaults, returns
    ///         address(0) — clearMMBalanceForVault becomes a safe no-op.
    mapping(address => mapping(uint256 => address)) public vaultMM;

    /// @notice Delay after expiry before MM can self-redeem (escape hatch).
    uint256 public escapeDelay;

    // ===== Events =====

    event OrderExecuted(
        address indexed user,
        address indexed oToken,
        address indexed mm,
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
    event PhysicalDelivery(address indexed oToken, address indexed user, uint256 contraAmount, uint256 collateralUsed);
    event PhysicalRedeemFailed(address indexed oToken, address indexed user, uint256 amount, bytes reason);
    event QuoteCancelled(address indexed mm, bytes32 indexed quoteHash);
    event QuoteCancelSkipped(address indexed mm, bytes32 indexed quoteHash);
    event MakerNonceIncremented(address indexed mm, uint256 newNonce);
    event MMWhitelisted(address indexed mm, bool status);
    event MMSelfRedeem(address indexed mm, address indexed oToken, uint256 amount, uint256 payout);
    event EscapeDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event MMBalanceCleared(address indexed mm, address indexed oToken, uint256 amount);
    event ProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event SwapFeeTierUpdated(uint24 oldFeeTier, uint24 newFeeTier);
    event AssetSwapFeeTierUpdated(address indexed asset, uint24 oldFeeTier, uint24 newFeeTier);
    event OrderExecutorUpdated(address indexed owner, address indexed executor, bool status);
    event PhysicalDeliveryVaultUpdated(address indexed vault, bool status);
    event PhysicalDeliveryReserved(
        address indexed owner, uint256 indexed vaultId, address indexed mm, address oToken, uint256 amount
    );
    event PhysicalDeliveryReleased(
        address indexed owner, uint256 indexed vaultId, address indexed mm, address oToken, uint256 amount
    );
    event PhysicalDeliverySettled(
        address indexed owner,
        uint256 indexed vaultId,
        address indexed mm,
        address oToken,
        uint256 amount,
        address payoutReceiver,
        uint256 payout
    );
    event SettlementExecutorUpdated(address indexed owner, address indexed executor, bool status);

    // ===== Errors =====

    error OnlyOwner();
    error OnlyOperator();
    error InvalidAddress();
    error InvalidAmount();
    error LengthMismatch();
    error PremiumTooSmall();
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
    error InsufficientMMBalance();
    error InvalidSignature();
    error MMNotWhitelisted();
    error QuoteExpired();
    error CapacityExceeded();
    error StaleNonce();
    error QuoteAlreadyCancelled();
    error EscapeNotReady();
    error EscapeDelayTooShort();
    error OnlyController();
    error InsufficientSwapOutput();
    error UnsupportedDecimals();
    error OrderExecutorNotAuthorized();
    error ReservedPhysicalDelivery();
    error PhysicalDeliveryVaultNotAuthorized();
    error SettlementExecutorNotAuthorized();
    error RedeemPayoutMismatch();
    error VaultLedgerMismatch();
    error PhysicalDeliveryRequired();
    error VaultNotSettled();

    // Panic(uint256) selector: 0x4e487b71
    bytes4 private constant _PANIC_SELECTOR = 0x4e487b71;

    // ===== Modifiers =====

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressBook, address _operator, address _owner) external initializer {
        if (_addressBook == address(0) || _operator == address(0) || _owner == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
        owner = _owner;
        operator = _operator;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    function _domainSeparator() private view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    // ===== Owner setters =====

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
        emit ProtocolFeeBpsUpdated(protocolFeeBps, _feeBps);
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
        emit SwapFeeTierUpdated(swapFeeTier, _feeTier);
        swapFeeTier = _feeTier;
    }

    function setAssetSwapFeeTier(address _asset, uint24 _feeTier) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();
        if (_feeTier != 0 && _feeTier != 100 && _feeTier != 500 && _feeTier != 3000 && _feeTier != 10000) {
            revert InvalidFeeTier();
        }
        emit AssetSwapFeeTierUpdated(_asset, assetSwapFeeTier[_asset], _feeTier);
        assetSwapFeeTier[_asset] = _feeTier;
    }

    function setOrderExecutor(address executor, bool status) external {
        if (executor == address(0)) revert InvalidAddress();
        orderExecutor[msg.sender][executor] = status;
        emit OrderExecutorUpdated(msg.sender, executor, status);
    }

    function setSettlementExecutor(address executor, bool status) external {
        if (executor == address(0)) revert InvalidAddress();
        settlementExecutor[msg.sender][executor] = status;
        emit SettlementExecutorUpdated(msg.sender, executor, status);
    }

    function setPhysicalDeliveryVault(address vault, bool status) external onlyOwner {
        if (vault == address(0)) revert InvalidAddress();
        authorizedPhysicalDeliveryVault[vault] = status;
        emit PhysicalDeliveryVaultUpdated(vault, status);
    }

    uint256 public constant MIN_ESCAPE_DELAY = 3 days;

    function setEscapeDelay(uint256 _delay) external onlyOwner {
        if (_delay < MIN_ESCAPE_DELAY) revert EscapeDelayTooShort();
        emit EscapeDelayUpdated(escapeDelay, _delay);
        escapeDelay = _delay;
    }

    function setWhitelistedMM(address _mm, bool _status) external onlyOwner {
        if (_mm == address(0)) revert InvalidAddress();
        whitelistedMMs[_mm] = _status;
        if (!_status) {
            uint256 newNonce = ++makerNonce[_mm];
            emit MakerNonceIncremented(_mm, newNonce);
        }
        emit MMWhitelisted(_mm, _status);
    }

    // ===== EIP-712 Quote Helpers =====

    /// @notice Compute the EIP-712 digest for a Quote struct.
    function hashQuote(Quote calldata quote) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                quote.oToken,
                quote.bidPrice,
                quote.deadline,
                quote.quoteId,
                quote.maxAmount,
                quote.makerNonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @notice Returns the EIP-712 domain separator (recomputed if chain forked).
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @notice Read fill state for a quote.
    function getQuoteState(address mm, bytes32 quoteHash)
        external
        view
        returns (uint256 filledAmount, bool isCancelled)
    {
        uint256 state = quoteState[mm][quoteHash];
        filledAmount = state & ~CANCEL_BIT;
        isCancelled = state & CANCEL_BIT != 0;
    }

    // ===== Quote Cancellation =====

    /// @notice Cancel a single quote. Only affects msg.sender's quotes.
    function cancelQuote(bytes32 quoteHash) external {
        uint256 state = quoteState[msg.sender][quoteHash];
        if (state & CANCEL_BIT != 0) revert QuoteAlreadyCancelled();
        quoteState[msg.sender][quoteHash] = state | CANCEL_BIT;
        emit QuoteCancelled(msg.sender, quoteHash);
    }

    /// @notice Cancel multiple quotes. Only affects msg.sender's quotes.
    ///         Unlike cancelQuote(), already-cancelled quotes are skipped (not reverted)
    ///         to avoid a single duplicate aborting the entire batch.
    function cancelQuotes(bytes32[] calldata quoteHashes) external {
        for (uint256 i = 0; i < quoteHashes.length; i++) {
            uint256 state = quoteState[msg.sender][quoteHashes[i]];
            if (state & CANCEL_BIT != 0) {
                emit QuoteCancelSkipped(msg.sender, quoteHashes[i]);
                continue;
            }
            quoteState[msg.sender][quoteHashes[i]] = state | CANCEL_BIT;
            emit QuoteCancelled(msg.sender, quoteHashes[i]);
        }
    }

    /// @notice Increment maker nonce — invalidates ALL outstanding quotes (circuit breaker).
    function incrementMakerNonce() external returns (uint256 newNonce) {
        newNonce = ++makerNonce[msg.sender];
        emit MakerNonceIncremented(msg.sender, newNonce);
    }

    // ===== Order Execution =====

    function executeOrder(Quote calldata quote, bytes calldata signature, uint256 amount, uint256 collateral)
        external
        nonReentrant
        returns (uint256 vaultId)
    {
        vaultId = _executeOrder(msg.sender, quote, signature, amount, collateral);
    }

    function executeOrderFor(
        address owner_,
        Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral
    ) external nonReentrant returns (uint256 vaultId) {
        if (owner_ == address(0)) revert InvalidAddress();
        if (!orderExecutor[owner_][msg.sender]) revert OrderExecutorNotAuthorized();
        vaultId = _executeOrder(owner_, quote, signature, amount, collateral);
    }

    function settleVaultFor(address owner_, uint256 vaultId) external nonReentrant {
        if (owner_ == address(0)) revert InvalidAddress();
        if (!settlementExecutor[owner_][msg.sender]) revert SettlementExecutorNotAuthorized();
        if (physicalDeliveryReservedVault[owner_][vaultId]) revert ReservedPhysicalDelivery();
        Controller(addressBook.controller()).settleVault(owner_, vaultId);
    }

    function reservePhysicalDelivery(uint256 vaultId) external nonReentrant {
        if (!authorizedPhysicalDeliveryVault[msg.sender]) revert PhysicalDeliveryVaultNotAuthorized();
        _reservePhysicalDelivery(msg.sender, vaultId);
    }

    function releasePhysicalDelivery(uint256 vaultId) external nonReentrant {
        if (!authorizedPhysicalDeliveryVault[msg.sender] && !physicalDeliveryReservedVault[msg.sender][vaultId]) {
            revert PhysicalDeliveryVaultNotAuthorized();
        }
        _releasePhysicalDelivery(msg.sender, vaultId);
    }

    function settleReservedPhysicalDelivery(uint256 vaultId, address payoutReceiver, uint256 expectedPayout)
        external
        nonReentrant
        returns (uint256 payout)
    {
        if (!authorizedPhysicalDeliveryVault[msg.sender] && !physicalDeliveryReservedVault[msg.sender][vaultId]) {
            revert PhysicalDeliveryVaultNotAuthorized();
        }
        if (payoutReceiver == address(0)) revert InvalidAddress();
        payout = _settleReservedPhysicalDelivery(msg.sender, vaultId, payoutReceiver, expectedPayout);
    }

    function settleReservedVaultFor(address owner_, uint256 vaultId, address payoutReceiver, uint256 expectedPayout)
        external
        nonReentrant
        returns (uint256 payout)
    {
        if (owner_ == address(0) || payoutReceiver == address(0)) revert InvalidAddress();
        if (!settlementExecutor[owner_][msg.sender]) revert SettlementExecutorNotAuthorized();
        if (!physicalDeliveryReservedVault[owner_][vaultId]) revert ReservedPhysicalDelivery();

        Controller(addressBook.controller()).settleVault(owner_, vaultId);
        payout = _settleReservedPhysicalDelivery(owner_, vaultId, payoutReceiver, expectedPayout);
    }

    function _executeOrder(
        address owner_,
        Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral
    ) internal returns (uint256 vaultId) {
        if (quote.oToken == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        // 1. Recover MM from EIP-712 signature
        bytes32 digest = hashQuote(quote);
        (address mm, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || mm == address(0)) revert InvalidSignature();
        if (!whitelistedMMs[mm]) revert MMNotWhitelisted();

        // 2. Validate quote liveness
        if (block.timestamp > quote.deadline) revert QuoteExpired();
        if (quote.makerNonce != makerNonce[mm]) revert StaleNonce();

        // 3. Check and update fill state (packed: lower 255 bits = filled, bit 255 = cancelled)
        uint256 state = quoteState[mm][digest];
        if (state & CANCEL_BIT != 0) revert QuoteAlreadyCancelled();
        uint256 filled = state & ~CANCEL_BIT;
        if (filled + amount > quote.maxAmount) revert CapacityExceeded();
        quoteState[mm][digest] = filled + amount; // cancel bit stays 0

        // 4. Calculate premium
        uint256 premium = (amount * quote.bidPrice) / 1e8;
        if (premium == 0 && quote.bidPrice > 0) revert PremiumTooSmall();

        // 5. Open vault for user
        Controller ctrl = Controller(addressBook.controller());
        vaultId = ctrl.openVault(owner_);
        vaultMM[owner_][vaultId] = mm;

        // 6. Deposit user's collateral
        address collateralAsset = OToken(quote.oToken).collateralAsset();
        ctrl.depositCollateral(owner_, vaultId, collateralAsset, collateral);

        // 7. Mint oTokens to this contract (custodied for MM)
        ctrl.mintOtoken(owner_, vaultId, quote.oToken, amount, address(this));
        mmOTokenBalance[mm][quote.oToken] += amount;
        vaultOTokenBalance[owner_][vaultId] = amount;
        attributedMMOTokenBalance[mm][quote.oToken] += amount;

        // 8. Transfer premium from MM to user (minus protocol fee)
        _transferPremium(owner_, quote.oToken, amount, premium, collateral, vaultId, mm);
    }

    function _transferPremium(
        address owner_,
        address oToken,
        uint256 amount,
        uint256 premium,
        uint256 collateral,
        uint256 vaultId,
        address mm
    ) private {
        address premiumAsset = OToken(oToken).strikeAsset();
        uint256 fee = 0;
        if (protocolFeeBps > 0 && treasury != address(0)) {
            fee = (premium * protocolFeeBps) / 10000;
        }
        uint256 netPremium = premium - fee;

        IERC20(premiumAsset).safeTransferFrom(mm, owner_, netPremium);
        if (fee > 0) {
            IERC20(premiumAsset).safeTransferFrom(mm, treasury, fee);
        }

        emit OrderExecuted(owner_, oToken, mm, amount, premium, netPremium, fee, collateral, vaultId);
    }

    // ===== Post-Expiry Settlement =====

    function batchSettleVaults(address[] calldata owners, uint256[] calldata vaultIds) external onlyOperator {
        if (owners.length != vaultIds.length) revert LengthMismatch();
        if (owners.length == 0) revert EmptyArray();

        batchNonce++;
        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < owners.length; i++) {
            if (physicalDeliveryReservedVault[owners[i]][vaultIds[i]]) {
                emit VaultSettleFailed(
                    owners[i], vaultIds[i], abi.encodeWithSelector(ReservedPhysicalDelivery.selector)
                );
                continue;
            }
            try ctrl.settleVault(owners[i], vaultIds[i]) {}
            catch (bytes memory reason) {
                _revertOnPanic(reason);
                emit VaultSettleFailed(owners[i], vaultIds[i], reason);
            }
        }
    }

    function batchRedeem(address[] calldata oTokens, uint256[] calldata amounts) external {
        if (oTokens.length != amounts.length) revert LengthMismatch();
        if (oTokens.length == 0) revert EmptyArray();

        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < oTokens.length; i++) {
            if (amounts[i] == 0) continue;

            try this._redeemSingle(oTokens[i], amounts[i], msg.sender, ctrl) {}
            catch (bytes memory reason) {
                _revertOnPanic(reason);
                emit RedeemFailed(oTokens[i], amounts[i], reason);
            }
        }
    }

    function _redeemSingle(address oToken, uint256 amount, address caller, Controller ctrl) external {
        if (msg.sender != address(this)) revert InvalidAddress();

        IERC20(oToken).safeTransferFrom(caller, address(this), amount);

        address collateralAsset = OToken(oToken).collateralAsset();
        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));
        uint256 expectedPayout = _expectedPayout(OToken(oToken), amount);

        ctrl.redeem(oToken, amount);

        uint256 payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
        if (payout != expectedPayout) revert RedeemPayoutMismatch();
        if (payout > 0) {
            IERC20(collateralAsset).safeTransfer(caller, payout);
        }
    }

    // ===== Physical Delivery (flash loan + DEX swap) =====

    function physicalRedeem(address oToken, address user, uint256 amount, uint256 slippageParam, address mm)
        public
        onlyOperator
        nonReentrant
    {
        _executePhysicalRedeem(oToken, user, amount, slippageParam, mm);
    }

    function executeOperation(
        address, /* asset */
        uint256, /* amount */
        uint256, /* premium */
        address initiator,
        bytes calldata /* params */
    )
        external
        override
        returns (bool)
    {
        if (msg.sender != aavePool) revert FlashLoanUnauthorized();
        if (initiator != address(this)) revert FlashLoanUnauthorized();
        revert FlashLoanUnauthorized();
    }

    function _redeemAndSwap(
        address oToken,
        address user,
        uint256 oTokenAmount,
        address contraAsset,
        uint256 contraAmount,
        uint256 slippageParam,
        address mm,
        bool debitMMBalance
    ) private returns (uint256 collateralUsed) {
        if (debitMMBalance) {
            // CEI: decrement MM balance before external calls.
            mmOTokenBalance[mm][oToken] -= oTokenAmount;
        }

        (address collateralAsset, uint256 collateralReceived) = _redeemCustodiedOTokens(oToken, oTokenAmount);
        if (collateralReceived == 0) revert RedeemReturnedZero();

        IERC20(collateralAsset).forceApprove(swapRouter, collateralReceived);

        address underlying = OToken(oToken).underlying();
        uint24 feeTier = assetSwapFeeTier[underlying];
        if (feeTier == 0) feeTier = swapFeeTier;
        if (feeTier == 0) revert InvalidFeeTier();

        bool isPut = OToken(oToken).isPut();
        if (isPut) {
            // Put: collateral=USDC, contra=WETH. Buy the exact underlying
            // owed to the user and route leftover collateral to the MM.
            collateralUsed = ISwapRouter(swapRouter)
                .exactOutputSingle(
                    ISwapRouter.ExactOutputSingleParams({
                        tokenIn: collateralAsset,
                        tokenOut: contraAsset,
                        fee: feeTier,
                        recipient: user,
                        amountOut: contraAmount,
                        amountInMaximum: slippageParam,
                        sqrtPriceLimitX96: 0
                    })
                );

            uint256 surplus = collateralReceived - collateralUsed;
            if (surplus > 0) {
                IERC20(collateralAsset).safeTransfer(mm, surplus);
            }
        } else {
            // Call: collateral=WETH, contra=USDC. Swap all redeemed
            // collateral, pay the exact strike amount owed to the user,
            // and route surplus proceeds to the MM.
            collateralUsed = collateralReceived;
            uint256 amountOut = ISwapRouter(swapRouter)
                .exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: collateralAsset,
                        tokenOut: contraAsset,
                        fee: feeTier,
                        recipient: address(this),
                        amountIn: collateralReceived,
                        amountOutMinimum: slippageParam,
                        sqrtPriceLimitX96: 0
                    })
                );

            if (amountOut < contraAmount) revert InsufficientSwapOutput();
            IERC20(contraAsset).safeTransfer(user, contraAmount);
            uint256 surplus = amountOut - contraAmount;
            if (surplus > 0) {
                IERC20(contraAsset).safeTransfer(mm, surplus);
            }
        }

        IERC20(collateralAsset).forceApprove(swapRouter, 0);
    }

    function _redeemCustodiedOTokens(address oToken, uint256 amount)
        private
        returns (address collateralAsset, uint256 payout)
    {
        OToken ot = OToken(oToken);
        collateralAsset = ot.collateralAsset();
        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));
        uint256 expectedPayout = _expectedPayout(ot, amount);

        Controller(addressBook.controller()).redeem(oToken, amount);

        payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
        if (payout != expectedPayout) revert RedeemPayoutMismatch();
    }

    function batchPhysicalRedeem(
        address[] calldata oTokens,
        address[] calldata users,
        uint256[] calldata amounts,
        uint256[] calldata slippageParams,
        address[] calldata mms
    ) external onlyOperator {
        if (
            oTokens.length != users.length || users.length != amounts.length || amounts.length != slippageParams.length
                || amounts.length != mms.length
        ) revert LengthMismatch();
        if (oTokens.length == 0) revert EmptyArray();

        for (uint256 i = 0; i < oTokens.length; i++) {
            if (amounts[i] == 0) continue;

            try this._physicalRedeemSingle(oTokens[i], users[i], amounts[i], slippageParams[i], mms[i]) {}
            catch (bytes memory reason) {
                _revertOnPanic(reason);
                emit PhysicalRedeemFailed(oTokens[i], users[i], amounts[i], reason);
            }
        }
    }

    function _physicalRedeemSingle(address oToken, address user, uint256 amount, uint256 slippageParam, address mm)
        external
        nonReentrant
    {
        if (msg.sender != address(this)) revert InvalidAddress();
        _executePhysicalRedeem(oToken, user, amount, slippageParam, mm);
    }

    function _executePhysicalRedeem(address oToken, address user, uint256 amount, uint256 slippageParam, address mm)
        private
    {
        if (oToken == address(0)) revert InvalidAddress();
        if (user == address(0)) revert InvalidAddress();
        if (mm == address(0)) revert InvalidAddress();
        if (swapRouter == address(0)) revert SwapRouterNotSet();
        if (amount == 0) revert InvalidAmount();
        if (mmOTokenBalance[mm][oToken] < amount) revert InsufficientMMBalance();

        OToken ot = OToken(oToken);
        (address contraAsset, uint256 contraAmount) = _physicalDeliveryTerms(ot, amount);
        if (_availableMMBalance(mm, oToken) < amount) revert ReservedPhysicalDelivery();

        uint256 collateralUsed =
            _redeemAndSwap(oToken, user, amount, contraAsset, contraAmount, slippageParam, mm, true);
        emit PhysicalDelivery(oToken, user, contraAmount, collateralUsed);
    }

    function operatorPhysicalRedeemVault(address owner_, uint256 vaultId, uint256 slippageParam)
        external
        onlyOperator
        nonReentrant
        returns (uint256 collateralUsed)
    {
        if (owner_ == address(0)) revert InvalidAddress();
        if (physicalDeliveryReservedVault[owner_][vaultId]) revert ReservedPhysicalDelivery();

        Controller ctrl = Controller(addressBook.controller());
        if (!ctrl.vaultSettled(owner_, vaultId)) revert VaultNotSettled();

        MarginVault.Vault memory vault = ctrl.getVault(owner_, vaultId);
        if (vault.shortOtoken == address(0) || vault.shortAmount == 0) revert InvalidAmount();
        uint256 amount = vaultOTokenBalance[owner_][vaultId];
        if (amount == 0 || amount != vault.shortAmount) revert VaultLedgerMismatch();

        address mm = vaultMM[owner_][vaultId];
        if (mm == address(0)) revert InvalidAddress();

        (address contraAsset, uint256 contraAmount) = _physicalDeliveryTerms(OToken(vault.shortOtoken), amount);
        _clearVaultLedger(owner_, vaultId, mm, vault.shortOtoken, amount);

        collateralUsed =
            _redeemAndSwap(vault.shortOtoken, owner_, amount, contraAsset, contraAmount, slippageParam, mm, false);
        emit PhysicalDelivery(vault.shortOtoken, owner_, contraAmount, collateralUsed);
    }

    function _physicalDeliveryTerms(OToken ot, uint256 amount)
        private
        view
        returns (address contraAsset, uint256 contraAmount)
    {
        if (block.timestamp < ot.expiry()) revert OptionNotExpired();

        Oracle oracle = Oracle(addressBook.oracle());
        (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(ot.underlying(), ot.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 strike = ot.strikePrice();
        if (ot.isPut()) {
            if (expiryPrice >= strike) revert OptionNotITM();
            contraAsset = ot.underlying();
            uint256 ud = IERC20Metadata(contraAsset).decimals();
            if (ud < 8 || ud > 18) revert UnsupportedDecimals();
            contraAmount = amount * (10 ** (ud - 8));
        } else {
            if (expiryPrice <= strike) revert OptionNotITM();
            contraAsset = ot.strikeAsset();
            uint256 sd = IERC20Metadata(contraAsset).decimals();
            if (sd < 6 || sd > 16) revert UnsupportedDecimals();
            contraAmount = (amount * strike) / (10 ** (16 - sd));
        }
        if (contraAmount == 0) revert InvalidAmount();
    }

    // ===== Operator-Triggered MM Redemption (cash settlement) =====

    function operatorRedeemForMM(address mm, address[] calldata oTokens, uint256[] calldata amounts)
        external
        onlyOperator
    {
        if (oTokens.length != amounts.length) revert LengthMismatch();
        if (oTokens.length == 0) revert EmptyArray();
        if (mm == address(0)) revert InvalidAddress();

        Controller ctrl = Controller(addressBook.controller());

        for (uint256 i = 0; i < oTokens.length; i++) {
            if (amounts[i] == 0) continue;

            try this._redeemForMM(mm, oTokens[i], amounts[i], ctrl) {}
            catch (bytes memory reason) {
                _revertOnPanic(reason);
                emit RedeemFailed(oTokens[i], amounts[i], reason);
            }
        }
    }

    function _redeemForMM(address mm, address oToken, uint256 amount, Controller ctrl) external {
        if (msg.sender != address(this)) revert InvalidAddress();

        // CEI: decrement balance before external calls
        if (mmOTokenBalance[mm][oToken] < amount) revert InsufficientMMBalance();
        if (_availableMMBalance(mm, oToken) < amount) revert ReservedPhysicalDelivery();
        if (_expectedPayout(OToken(oToken), amount) != 0) revert PhysicalDeliveryRequired();
        mmOTokenBalance[mm][oToken] -= amount;

        address collateralAsset = OToken(oToken).collateralAsset();
        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));

        ctrl.redeem(oToken, amount);

        uint256 payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
        if (payout != 0) revert RedeemPayoutMismatch();
        if (payout > 0) {
            IERC20(collateralAsset).safeTransfer(mm, payout);
        }
    }

    // ===== Escape Hatch: MM Self-Redeem =====

    /// @notice Allows a whitelisted MM to redeem their custodied oTokens
    ///         after expiry + escapeDelay, bypassing the operator.
    function mmSelfRedeem(address oToken, uint256 amount) external nonReentrant {
        if (!whitelistedMMs[msg.sender]) revert MMNotWhitelisted();
        if (amount == 0) revert InvalidAmount();
        if (escapeDelay == 0) revert EscapeNotReady();

        OToken ot = OToken(oToken);
        uint256 expiry = ot.expiry();
        if (block.timestamp < expiry + escapeDelay) revert EscapeNotReady();

        if (mmOTokenBalance[msg.sender][oToken] < amount) {
            revert InsufficientMMBalance();
        }
        if (_availableMMBalance(msg.sender, oToken) < amount) revert ReservedPhysicalDelivery();
        if (_expectedPayout(ot, amount) != 0) revert PhysicalDeliveryRequired();
        mmOTokenBalance[msg.sender][oToken] -= amount;

        Controller ctrl = Controller(addressBook.controller());
        address collateralAsset = ot.collateralAsset();
        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));

        ctrl.redeem(oToken, amount);

        uint256 payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
        if (payout != 0) revert RedeemPayoutMismatch();
        if (payout > 0) {
            IERC20(collateralAsset).safeTransfer(msg.sender, payout);
        }

        emit MMSelfRedeem(msg.sender, oToken, amount, payout);
    }

    function operatorRedeemVaultForMM(address owner_, uint256 vaultId, address payoutReceiver)
        external
        onlyOperator
        nonReentrant
        returns (uint256 payout)
    {
        if (owner_ == address(0) || payoutReceiver == address(0)) revert InvalidAddress();
        if (physicalDeliveryReservedVault[owner_][vaultId]) revert ReservedPhysicalDelivery();
        address mm = vaultMM[owner_][vaultId];
        if (mm == address(0) || payoutReceiver != mm) revert InvalidAddress();
        payout = _redeemAttributedVault(owner_, vaultId, payoutReceiver);
    }

    function mmSelfRedeemVault(address owner_, uint256 vaultId) external nonReentrant returns (uint256 payout) {
        if (!whitelistedMMs[msg.sender]) revert MMNotWhitelisted();
        if (escapeDelay == 0) revert EscapeNotReady();
        if (owner_ == address(0)) revert InvalidAddress();
        if (physicalDeliveryReservedVault[owner_][vaultId]) revert ReservedPhysicalDelivery();

        MarginVault.Vault memory vault = Controller(addressBook.controller()).getVault(owner_, vaultId);
        if (vault.shortOtoken == address(0) || vault.shortAmount == 0) revert InvalidAmount();
        uint256 expiry = OToken(vault.shortOtoken).expiry();
        if (block.timestamp < expiry + escapeDelay) revert EscapeNotReady();

        address mm = vaultMM[owner_][vaultId];
        if (mm != msg.sender) revert OrderExecutorNotAuthorized();
        payout = _redeemAttributedVault(owner_, vaultId, msg.sender);
    }

    function _redeemAttributedVault(address owner_, uint256 vaultId, address payoutReceiver)
        private
        returns (uint256 payout)
    {
        MarginVault.Vault memory vault = Controller(addressBook.controller()).getVault(owner_, vaultId);
        if (vault.shortOtoken == address(0) || vault.shortAmount == 0) revert InvalidAmount();
        uint256 amount = vaultOTokenBalance[owner_][vaultId];
        if (amount == 0) revert InvalidAmount();

        address mm = vaultMM[owner_][vaultId];
        if (mm == address(0)) revert InvalidAddress();
        if (_expectedPayout(OToken(vault.shortOtoken), amount) != 0) revert PhysicalDeliveryRequired();
        _clearVaultLedger(owner_, vaultId, mm, vault.shortOtoken, amount);

        address collateralAsset = OToken(vault.shortOtoken).collateralAsset();
        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));

        Controller(addressBook.controller()).redeem(vault.shortOtoken, amount);

        payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
        if (payout != 0) revert RedeemPayoutMismatch();
        if (payout > 0) {
            IERC20(collateralAsset).safeTransfer(payoutReceiver, payout);
        }

        emit MMBalanceCleared(mm, vault.shortOtoken, amount);
    }

    function _reservePhysicalDelivery(address owner_, uint256 vaultId) private {
        if (vaultId == 0) revert InvalidAmount();
        if (physicalDeliveryReservedVault[owner_][vaultId]) return;

        MarginVault.Vault memory vault = Controller(addressBook.controller()).getVault(owner_, vaultId);
        if (vault.shortOtoken == address(0) || vault.shortAmount == 0) revert InvalidAmount();

        address mm = vaultMM[owner_][vaultId];
        if (mm == address(0)) revert InvalidAddress();
        if (mmOTokenBalance[mm][vault.shortOtoken] < vault.shortAmount) revert InsufficientMMBalance();
        if (vaultOTokenBalance[owner_][vaultId] < vault.shortAmount) revert VaultLedgerMismatch();

        physicalDeliveryReservedVault[owner_][vaultId] = true;
        physicalDeliveryReservedAmount[owner_][vaultId] = vault.shortAmount;
        reservedPhysicalDeliveryBalance[mm][vault.shortOtoken] += vault.shortAmount;
        emit PhysicalDeliveryReserved(owner_, vaultId, mm, vault.shortOtoken, vault.shortAmount);
    }

    function _settleReservedPhysicalDelivery(
        address owner_,
        uint256 vaultId,
        address payoutReceiver,
        uint256 expectedPayout
    ) private returns (uint256 payout) {
        if (!physicalDeliveryReservedVault[owner_][vaultId]) revert ReservedPhysicalDelivery();

        MarginVault.Vault memory vault = Controller(addressBook.controller()).getVault(owner_, vaultId);
        if (vault.shortOtoken == address(0) || vault.shortAmount == 0) revert InvalidAmount();

        address mm = vaultMM[owner_][vaultId];
        if (mm == address(0)) revert InvalidAddress();
        uint256 amount = physicalDeliveryReservedAmount[owner_][vaultId];
        if (amount == 0 || amount != vault.shortAmount) revert VaultLedgerMismatch();

        _releasePhysicalDelivery(owner_, vaultId);
        _clearVaultLedger(owner_, vaultId, mm, vault.shortOtoken, amount);

        address collateralAsset = OToken(vault.shortOtoken).collateralAsset();
        uint256 balBefore = IERC20(collateralAsset).balanceOf(address(this));

        Controller(addressBook.controller()).redeem(vault.shortOtoken, amount);

        payout = IERC20(collateralAsset).balanceOf(address(this)) - balBefore;
        if (payout != expectedPayout) revert RedeemPayoutMismatch();
        if (payout > 0) {
            IERC20(collateralAsset).safeTransfer(payoutReceiver, payout);
        }

        emit PhysicalDeliverySettled(owner_, vaultId, mm, vault.shortOtoken, amount, payoutReceiver, payout);
    }

    function _releasePhysicalDelivery(address owner_, uint256 vaultId) private {
        if (!physicalDeliveryReservedVault[owner_][vaultId]) return;

        MarginVault.Vault memory vault = Controller(addressBook.controller()).getVault(owner_, vaultId);
        address mm = vaultMM[owner_][vaultId];
        if (mm == address(0) || vault.shortOtoken == address(0)) revert InvalidAddress();

        physicalDeliveryReservedVault[owner_][vaultId] = false;
        uint256 reservedForVault = physicalDeliveryReservedAmount[owner_][vaultId];
        physicalDeliveryReservedAmount[owner_][vaultId] = 0;
        uint256 reserved = reservedPhysicalDeliveryBalance[mm][vault.shortOtoken];
        uint256 releaseAmount = reservedForVault < reserved ? reservedForVault : reserved;
        if (releaseAmount > 0) {
            reservedPhysicalDeliveryBalance[mm][vault.shortOtoken] = reserved - releaseAmount;
        }
        emit PhysicalDeliveryReleased(owner_, vaultId, mm, vault.shortOtoken, releaseAmount);
    }

    function _clearVaultLedger(address owner_, uint256 vaultId, address mm, address oToken, uint256 amount) private {
        uint256 vaultBalance = vaultOTokenBalance[owner_][vaultId];
        if (vaultBalance < amount) revert VaultLedgerMismatch();
        uint256 mmBalance = mmOTokenBalance[mm][oToken];
        if (mmBalance < amount) revert InsufficientMMBalance();
        uint256 attributedBalance = attributedMMOTokenBalance[mm][oToken];
        if (attributedBalance < amount) revert VaultLedgerMismatch();

        vaultOTokenBalance[owner_][vaultId] = vaultBalance - amount;
        mmOTokenBalance[mm][oToken] = mmBalance - amount;
        attributedMMOTokenBalance[mm][oToken] = attributedBalance - amount;
    }

    function _availableMMBalance(address mm, address oToken) private view returns (uint256) {
        uint256 balance = mmOTokenBalance[mm][oToken];
        uint256 reserved = reservedPhysicalDeliveryBalance[mm][oToken];
        uint256 attributed = attributedMMOTokenBalance[mm][oToken];
        uint256 locked = attributed;
        if (reserved > locked) locked = reserved;
        if (balance <= locked) return 0;
        return balance - locked;
    }

    // ===== Emergency Ledger Clearance =====

    /// @notice Called by Controller during emergencyWithdrawVault to clear
    ///         the MM's custodied balance after oTokens are burned.
    function clearMMBalanceForVault(address vaultOwner, uint256 vaultId, address oToken, uint256 amount) external {
        if (msg.sender != addressBook.controller()) revert OnlyController();

        address mm = vaultMM[vaultOwner][vaultId];
        if (mm == address(0)) return; // pre-migration vault, safe no-op

        uint256 toClear = amount;
        if (toClear > 0) {
            _clearVaultLedger(vaultOwner, vaultId, mm, oToken, toClear);
            if (physicalDeliveryReservedVault[vaultOwner][vaultId]) {
                uint256 reserved = reservedPhysicalDeliveryBalance[mm][oToken];
                uint256 reservedForVault = physicalDeliveryReservedAmount[vaultOwner][vaultId];
                uint256 reservedToClear = toClear < reservedForVault ? toClear : reservedForVault;
                if (reservedToClear > reserved) reservedToClear = reserved;
                if (reservedToClear > 0) {
                    reservedPhysicalDeliveryBalance[mm][oToken] = reserved - reservedToClear;
                }
                physicalDeliveryReservedVault[vaultOwner][vaultId] = false;
                physicalDeliveryReservedAmount[vaultOwner][vaultId] = 0;
                emit PhysicalDeliveryReleased(vaultOwner, vaultId, mm, oToken, reservedToClear);
            }
            emit MMBalanceCleared(mm, oToken, toClear);
        }
    }

    function _expectedPayout(OToken oToken, uint256 amount) private view returns (uint256) {
        Oracle oracle = Oracle(addressBook.oracle());
        (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert ExpiryPriceNotSet();
        return _calculatePayout(oToken, amount, expiryPrice);
    }

    function _calculatePayout(OToken oToken, uint256 amount, uint256 expiryPrice) private view returns (uint256) {
        uint256 strike = oToken.strikePrice();
        uint256 cd = IERC20Metadata(oToken.collateralAsset()).decimals();

        if (oToken.isPut()) {
            if (cd < 6 || cd > 16) revert UnsupportedDecimals();
            if (expiryPrice >= strike) return 0;
            return (amount * strike) / (10 ** (16 - cd));
        } else {
            if (cd < 8 || cd > 18) revert UnsupportedDecimals();
            if (expiryPrice <= strike) return 0;
            return amount * (10 ** (cd - 8));
        }
    }

    // ===== Monitoring =====

    /// @notice Compares MM's internal ledger balance against actual
    ///         oToken balance held by this contract.
    function verifyLedgerSync(address mm, address oToken)
        external
        view
        returns (uint256 ledgerBalance, uint256 actualBalance, bool inSync)
    {
        ledgerBalance = mmOTokenBalance[mm][oToken];
        actualBalance = IERC20(oToken).balanceOf(address(this));
        inSync = actualBalance >= ledgerBalance;
    }

    /// @dev Re-reverts if `reason` is a Panic(uint256). Panics indicate bugs, not expected failures.
    function _revertOnPanic(bytes memory reason) private pure {
        if (reason.length >= 4) {
            bytes4 selector;
            assembly { selector := mload(add(reason, 32)) }
            if (selector == _PANIC_SELECTOR) {
                assembly { revert(add(reason, 32), mload(reason)) }
            }
        }
    }

    // --- Ownership ---

    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyPendingOwner();

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Per-asset swap fee tier override. Key = underlying asset.
    mapping(address => uint24) public assetSwapFeeTier;

    /// @notice Per-owner order executors authorized to open/settle vaults through strategy adapters.
    mapping(address => mapping(address => bool)) public orderExecutor;

    /// @notice Owner vaults whose custodied oToken balance is reserved for physical delivery settlement.
    mapping(address => mapping(uint256 => bool)) public physicalDeliveryReservedVault;

    /// @notice Per-MM oToken balance that cannot be redeemed through cash escape paths until released by vault owner.
    mapping(address => mapping(address => uint256)) public reservedPhysicalDeliveryBalance;

    /// @notice Exact reserved amount for each owner vault.
    mapping(address => mapping(uint256 => uint256)) public physicalDeliveryReservedAmount;

    /// @notice Product/vault contracts allowed to reserve physical delivery balances.
    mapping(address => bool) public authorizedPhysicalDeliveryVault;

    /// @notice Custodied oTokens attributable to a specific writer vault.
    mapping(address => mapping(uint256 => uint256)) public vaultOTokenBalance;

    /// @notice Aggregate oTokens attributed to writer vaults and excluded from legacy free-form redeem paths.
    mapping(address => mapping(address => uint256)) public attributedMMOTokenBalance;

    /// @notice Per-owner settlement executors authorized to settle vaults outside the owner flow.
    mapping(address => mapping(address => bool)) public settlementExecutor;

    uint256[24] private __gap;
}
