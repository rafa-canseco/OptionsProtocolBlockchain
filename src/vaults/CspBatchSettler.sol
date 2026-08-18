// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../core/AddressBook.sol";
import "../core/Controller.sol";
import "../core/OToken.sol";
import "../core/Oracle.sol";
import "../interfaces/IMarginVault.sol";
import "../interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title CspBatchSettler
 * @notice Dedicated settlement module for CSP vaults.
 * @dev Keeps CSP quote execution and physical-delivery reservation separate
 *      from the already deployed BatchSettler v1 registered in AddressBook.
 */
contract CspBatchSettler is Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("b1nary");
    bytes32 private constant _VERSION_HASH = keccak256("1");
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address owner,address oToken,uint256 bidPrice,uint256 deadline,uint256 quoteId,uint256 maxAmount,uint256 makerNonce)"
    );
    uint256 private constant CANCEL_BIT = 1 << 255;

    struct Quote {
        address oToken;
        uint256 bidPrice;
        uint256 deadline;
        uint256 quoteId;
        uint256 maxAmount;
        uint256 makerNonce;
    }

    AddressBook public addressBook;
    address public owner;
    address public operator;
    address public treasury;
    uint256 public protocolFeeBps;
    address public swapRouter;
    uint24 public swapFeeTier;

    bytes32 private _cachedDomainSeparator;
    uint256 private _cachedChainId;

    mapping(address => mapping(bytes32 => uint256)) public quoteState;
    mapping(address => uint256) public makerNonce;
    mapping(address => bool) public whitelistedMMs;
    mapping(address => mapping(address => uint256)) public mmOTokenBalance;
    mapping(address => mapping(uint256 => address)) public vaultMM;
    mapping(address => mapping(uint256 => uint256)) public vaultOTokenBalance;
    mapping(address => mapping(address => bool)) public orderExecutor;
    mapping(address => mapping(address => bool)) public settlementExecutor;
    mapping(address => mapping(uint256 => bool)) public physicalDeliveryReservedVault;
    mapping(address => mapping(address => uint256)) public reservedPhysicalDeliveryBalance;
    mapping(address => mapping(uint256 => uint256)) public physicalDeliveryReservedAmount;
    mapping(address => bool) public authorizedPhysicalDeliveryVault;

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
    event QuoteCancelled(address indexed mm, bytes32 indexed quoteHash);
    event QuoteCancelSkipped(address indexed mm, bytes32 indexed quoteHash);
    event MakerNonceIncremented(address indexed mm, uint256 newNonce);
    event MMWhitelisted(address indexed mm, bool status);
    event MMBalanceCleared(address indexed mm, address indexed oToken, uint256 amount);
    event ProtocolFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event OrderExecutorUpdated(address indexed owner, address indexed executor, bool status);
    event SettlementExecutorUpdated(address indexed owner, address indexed executor, bool status);
    event PhysicalDeliveryVaultUpdated(address indexed vault, bool status);
    event PhysicalDelivery(address indexed oToken, address indexed user, uint256 contraAmount, uint256 collateralUsed);
    event SwapFeeTierUpdated(uint24 oldFeeTier, uint24 newFeeTier);
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
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyOwner();
    error OnlyOperator();
    error OnlyPendingOwner();
    error OnlyController();
    error InvalidAddress();
    error InvalidAmount();
    error LengthMismatch();
    error PremiumTooSmall();
    error EmptyArray();
    error FeeTooHigh();
    error InsufficientMMBalance();
    error InvalidSignature();
    error MMNotWhitelisted();
    error QuoteExpired();
    error CapacityExceeded();
    error StaleNonce();
    error QuoteAlreadyCancelled();
    error OrderExecutorNotAuthorized();
    error SettlementExecutorNotAuthorized();
    error PhysicalDeliveryVaultNotAuthorized();
    error RedeemPayoutMismatch();
    error VaultLedgerMismatch();
    error ReservedPhysicalDelivery();
    error SwapRouterNotSet();
    error InvalidFeeTier();
    error VaultNotSettled();
    error OptionNotExpired();
    error ExpiryPriceNotSet();
    error OptionNotITM();
    error UnsupportedDecimals();
    error RedeemReturnedZero();
    error InsufficientSwapOutput();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressBook, address _operator, address _owner) external initializer {
        if (_addressBook == address(0) || _operator == address(0) || _owner == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
        operator = _operator;
        owner = _owner;
        _cachedChainId = block.chainid;
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    function _domainSeparator() private view returns (bytes32) {
        return block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function hashQuoteFor(address owner_, Quote calldata quote) public view returns (bytes32) {
        if (owner_ == address(0)) revert InvalidAddress();
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                owner_,
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

    function getQuoteState(address mm, bytes32 quoteHash)
        external
        view
        returns (uint256 filledAmount, bool isCancelled)
    {
        uint256 state = quoteState[mm][quoteHash];
        filledAmount = state & ~CANCEL_BIT;
        isCancelled = state & CANCEL_BIT != 0;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
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

    function setProtocolFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > 2000) revert FeeTooHigh();
        emit ProtocolFeeBpsUpdated(protocolFeeBps, _feeBps);
        protocolFeeBps = _feeBps;
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

    function setPhysicalDeliveryVault(address vault, bool status) external onlyOwner {
        if (vault == address(0)) revert InvalidAddress();
        authorizedPhysicalDeliveryVault[vault] = status;
        emit PhysicalDeliveryVaultUpdated(vault, status);
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

    function setSettlementExecutorFor(address owner_, address executor, bool status) external onlyOwner {
        if (owner_ == address(0) || executor == address(0)) revert InvalidAddress();
        settlementExecutor[owner_][executor] = status;
        emit SettlementExecutorUpdated(owner_, executor, status);
    }

    function cancelQuote(bytes32 quoteHash) external {
        uint256 state = quoteState[msg.sender][quoteHash];
        if (state & CANCEL_BIT != 0) revert QuoteAlreadyCancelled();
        quoteState[msg.sender][quoteHash] = state | CANCEL_BIT;
        emit QuoteCancelled(msg.sender, quoteHash);
    }

    function cancelQuotes(bytes32[] calldata quoteHashes) external {
        if (quoteHashes.length == 0) revert EmptyArray();
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

    function incrementMakerNonce() external returns (uint256 newNonce) {
        newNonce = ++makerNonce[msg.sender];
        emit MakerNonceIncremented(msg.sender, newNonce);
    }

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

    function clearMMBalanceForVault(address vaultOwner, uint256 vaultId, address oToken, uint256 amount) external {
        if (msg.sender != addressBook.controller()) revert OnlyController();

        address mm = vaultMM[vaultOwner][vaultId];
        if (mm == address(0)) return;

        if (amount > 0) {
            _clearVaultLedger(vaultOwner, vaultId, mm, oToken, amount);
            if (physicalDeliveryReservedVault[vaultOwner][vaultId]) {
                uint256 reserved = reservedPhysicalDeliveryBalance[mm][oToken];
                uint256 reservedForVault = physicalDeliveryReservedAmount[vaultOwner][vaultId];
                uint256 reservedToClear = amount < reservedForVault ? amount : reservedForVault;
                if (reservedToClear > reserved) reservedToClear = reserved;
                if (reservedToClear > 0) {
                    reservedPhysicalDeliveryBalance[mm][oToken] = reserved - reservedToClear;
                }
                physicalDeliveryReservedVault[vaultOwner][vaultId] = false;
                physicalDeliveryReservedAmount[vaultOwner][vaultId] = 0;
                emit PhysicalDeliveryReleased(vaultOwner, vaultId, mm, oToken, reservedToClear);
            }
            emit MMBalanceCleared(mm, oToken, amount);
        }
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

        bytes32 digest = hashQuoteFor(owner_, quote);
        (address mm, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || mm == address(0)) revert InvalidSignature();
        if (!whitelistedMMs[mm]) revert MMNotWhitelisted();
        if (block.timestamp > quote.deadline) revert QuoteExpired();
        if (quote.makerNonce != makerNonce[mm]) revert StaleNonce();

        uint256 state = quoteState[mm][digest];
        if (state & CANCEL_BIT != 0) revert QuoteAlreadyCancelled();
        uint256 filled = state & ~CANCEL_BIT;
        if (filled + amount > quote.maxAmount) revert CapacityExceeded();
        quoteState[mm][digest] = filled + amount;

        uint256 previousPremium = (filled * quote.bidPrice) / 1e8;
        uint256 cumulativePremium = ((filled + amount) * quote.bidPrice) / 1e8;
        uint256 premium = cumulativePremium - previousPremium;
        if (premium == 0 && quote.bidPrice > 0) revert PremiumTooSmall();

        uint256 fee;
        if (protocolFeeBps > 0 && treasury != address(0)) {
            fee = (cumulativePremium * protocolFeeBps) / 10000 - (previousPremium * protocolFeeBps) / 10000;
        }

        Controller ctrl = Controller(addressBook.controller());
        vaultId = ctrl.openVault(owner_);
        vaultMM[owner_][vaultId] = mm;

        address collateralAsset = OToken(quote.oToken).collateralAsset();
        ctrl.depositCollateral(owner_, vaultId, collateralAsset, collateral);
        ctrl.mintOtoken(owner_, vaultId, quote.oToken, amount, address(this));

        mmOTokenBalance[mm][quote.oToken] += amount;
        vaultOTokenBalance[owner_][vaultId] = amount;

        _transferPremium(owner_, quote.oToken, amount, premium, fee, collateral, vaultId, mm);
    }

    function _transferPremium(
        address owner_,
        address oToken,
        uint256 amount,
        uint256 premium,
        uint256 fee,
        uint256 collateral,
        uint256 vaultId,
        address mm
    ) private {
        address premiumAsset = OToken(oToken).strikeAsset();
        uint256 netPremium = premium - fee;

        IERC20(premiumAsset).safeTransferFrom(mm, owner_, netPremium);
        if (fee > 0) {
            IERC20(premiumAsset).safeTransferFrom(mm, treasury, fee);
        }

        emit OrderExecuted(owner_, oToken, mm, amount, premium, netPremium, fee, collateral, vaultId);
    }

    function operatorPhysicalRedeemVault(address owner_, uint256 vaultId, uint256 slippageParam)
        external
        onlyOperator
        nonReentrant
        returns (uint256 collateralUsed)
    {
        if (owner_ == address(0)) revert InvalidAddress();
        if (physicalDeliveryReservedVault[owner_][vaultId]) revert ReservedPhysicalDelivery();
        if (swapRouter == address(0)) revert SwapRouterNotSet();

        Controller ctrl = Controller(addressBook.controller());
        if (!ctrl.vaultSettled(owner_, vaultId)) revert VaultNotSettled();

        MarginVault.Vault memory vault = ctrl.getVault(owner_, vaultId);
        if (vault.shortOtoken == address(0) || vault.shortAmount == 0) revert InvalidAmount();
        uint256 amount = vaultOTokenBalance[owner_][vaultId];
        if (amount == 0 || amount != vault.shortAmount) revert VaultLedgerMismatch();

        address mm = vaultMM[owner_][vaultId];
        if (mm == address(0)) revert InvalidAddress();

        OToken oToken = OToken(vault.shortOtoken);
        (address contraAsset, uint256 contraAmount) = _physicalDeliveryTerms(oToken, amount);
        _clearVaultLedger(owner_, vaultId, mm, vault.shortOtoken, amount);

        (address collateralAsset, uint256 collateralReceived) = _redeemCustodiedOTokens(oToken, amount);
        if (collateralReceived == 0) revert RedeemReturnedZero();

        IERC20(collateralAsset).forceApprove(swapRouter, collateralReceived);
        if (oToken.isPut()) {
            collateralUsed = ISwapRouter(swapRouter)
                .exactOutputSingle(
                    ISwapRouter.ExactOutputSingleParams({
                        tokenIn: collateralAsset,
                        tokenOut: contraAsset,
                        fee: swapFeeTier,
                        recipient: owner_,
                        amountOut: contraAmount,
                        amountInMaximum: slippageParam,
                        sqrtPriceLimitX96: 0
                    })
                );
            uint256 surplus = collateralReceived - collateralUsed;
            if (surplus > 0) IERC20(collateralAsset).safeTransfer(mm, surplus);
        } else {
            collateralUsed = collateralReceived;
            uint256 amountOut = ISwapRouter(swapRouter)
                .exactInputSingle(
                    ISwapRouter.ExactInputSingleParams({
                        tokenIn: collateralAsset,
                        tokenOut: contraAsset,
                        fee: swapFeeTier,
                        recipient: address(this),
                        amountIn: collateralReceived,
                        amountOutMinimum: slippageParam,
                        sqrtPriceLimitX96: 0
                    })
                );
            if (amountOut < contraAmount) revert InsufficientSwapOutput();
            IERC20(contraAsset).safeTransfer(owner_, contraAmount);
            uint256 surplus = amountOut - contraAmount;
            if (surplus > 0) IERC20(contraAsset).safeTransfer(mm, surplus);
        }
        IERC20(collateralAsset).forceApprove(swapRouter, 0);

        emit PhysicalDelivery(vault.shortOtoken, owner_, contraAmount, collateralUsed);
    }

    function _physicalDeliveryTerms(OToken oToken, uint256 amount)
        private
        view
        returns (address contraAsset, uint256 contraAmount)
    {
        if (block.timestamp < oToken.expiry()) revert OptionNotExpired();

        (uint256 expiryPrice, bool isSet) =
            Oracle(addressBook.oracle()).getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 strike = oToken.strikePrice();
        if (oToken.isPut()) {
            if (expiryPrice >= strike) revert OptionNotITM();
            contraAsset = oToken.underlying();
            uint256 decimals = IERC20Metadata(contraAsset).decimals();
            if (decimals < 8 || decimals > 18) revert UnsupportedDecimals();
            contraAmount = amount * (10 ** (decimals - 8));
        } else {
            if (expiryPrice <= strike) revert OptionNotITM();
            contraAsset = oToken.strikeAsset();
            uint256 decimals = IERC20Metadata(contraAsset).decimals();
            if (decimals < 6 || decimals > 16) revert UnsupportedDecimals();
            contraAmount = (amount * strike) / (10 ** (16 - decimals));
        }
        if (contraAmount == 0) revert InvalidAmount();
    }

    function _redeemCustodiedOTokens(OToken oToken, uint256 amount)
        private
        returns (address collateralAsset, uint256 payout)
    {
        collateralAsset = oToken.collateralAsset();
        uint256 balanceBefore = IERC20(collateralAsset).balanceOf(address(this));
        uint256 expectedPayout = _expectedPayout(oToken, amount);

        Controller(addressBook.controller()).redeem(address(oToken), amount);

        payout = IERC20(collateralAsset).balanceOf(address(this)) - balanceBefore;
        if (payout != expectedPayout) revert RedeemPayoutMismatch();
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

        vaultOTokenBalance[owner_][vaultId] = vaultBalance - amount;
        mmOTokenBalance[mm][oToken] = mmBalance - amount;
    }

    function _expectedPayout(OToken oToken, uint256 amount) private view returns (uint256) {
        (uint256 expiryPrice, bool isSet) =
            Oracle(addressBook.oracle()).getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 strike = oToken.strikePrice();
        uint256 decimals = IERC20Metadata(oToken.collateralAsset()).decimals();
        if (oToken.isPut()) {
            if (decimals < 6 || decimals > 16) revert UnsupportedDecimals();
            if (expiryPrice >= strike) return 0;
            return (amount * strike) / (10 ** (16 - decimals));
        }
        if (decimals < 8 || decimals > 18) revert UnsupportedDecimals();
        if (expiryPrice <= strike) return 0;
        return amount * (10 ** (decimals - 8));
    }

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

    address public pendingOwner;

    uint256[40] private __gap;
}
