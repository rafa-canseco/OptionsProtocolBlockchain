// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../core/AddressBook.sol";
import "../core/BatchSettler.sol";
import "../core/MarginPool.sol";
import "../core/OToken.sol";

/**
 * @title EthCspVault
 * @notice First vault slice: users deposit USDC once and an allocator repeatedly
 *         sells ETH cash-secured puts through the existing BatchSettler flow.
 * @dev Not ERC4626 by design. This keeps the V1 accounting explicit while the
 *      product is limited to one collateral asset, one underlying, and one
 *      strategy.
 */
contract EthCspVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Epoch {
        uint64 startedAt;
        uint64 endedAt;
        uint256 deposits;
        uint256 withdrawals;
        uint256 committedCollateral;
        uint256 returnedCollateral;
        uint256 premiumEarned;
        uint256 assignmentShortfall;
        uint256 performanceFee;
        uint256 withdrawalAssetsPerShare;
        uint256 withdrawalAssetsRemaining;
        uint256 remainingWithdrawalClaims;
        bool closed;
    }

    struct CspBatch {
        uint256 epochId;
        address oToken;
        uint256 protocolVaultId;
        uint256 amount;
        uint256 collateral;
        uint256 premiumEarned;
        uint256 collateralReturned;
        bool settled;
    }

    struct StrategyConfig {
        uint256 maxCollateralPerBatch;
        uint256 maxUtilizationBps;
        uint256 minPremiumBps;
        uint256 minExpiryDelay;
        uint256 maxExpiryDelay;
        uint256 minStrike;
        uint256 maxStrike;
    }

    AddressBook public immutable addressBook;
    IERC20 public immutable usdc;
    IERC20 public immutable underlying;
    address public immutable ethUnderlying;

    address public owner;
    address public curator;
    address public allocator;
    address public feeRecipient;
    uint256 public performanceFeeBps;
    StrategyConfig public strategyConfig;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public currentEpoch;
    uint256 public batchCount;
    uint256 public activeBatches;
    uint256 public activeCollateral;
    uint256 public totalPendingWithdrawalShares;
    uint256 public totalPendingWithdrawalClaims;
    uint256 public totalPendingDepositAssets;
    uint256 public reservedWithdrawalAssets;
    uint256 public reservedUnderlyingAssets;
    uint256 public accountedUnderlyingAssets;

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => CspBatch) public batches;
    mapping(uint256 => uint256) public batchUnderlyingReceived;
    mapping(uint256 => uint256) public epochAssignedUnderlying;
    mapping(uint256 => uint256) public withdrawalUnderlyingPerShare;
    mapping(uint256 => uint256) public withdrawalUnderlyingRemaining;
    mapping(address => uint256) public pendingDepositAssets;
    mapping(address => uint256) public pendingWithdrawalEpoch;
    mapping(address => uint256) public pendingWithdrawalShares;

    uint256 private constant MAX_PERFORMANCE_FEE_BPS = 2000;

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event DepositQueued(address indexed user, uint256 indexed epochId, uint256 amount);
    event IdleWithdrawn(address indexed user, address indexed receiver, uint256 amount, uint256 shares);
    event WithdrawRequested(address indexed user, uint256 indexed epochId, uint256 shares);
    event WithdrawClaimed(
        address indexed user,
        address indexed receiver,
        uint256 indexed epochId,
        uint256 usdcAmount,
        uint256 underlyingAmount,
        uint256 shares
    );
    event CspBatchOpened(
        uint256 indexed batchId,
        uint256 indexed epochId,
        address indexed oToken,
        uint256 protocolVaultId,
        uint256 amount,
        uint256 collateral,
        uint256 premiumEarned
    );
    event CspBatchSettled(
        uint256 indexed batchId,
        uint256 indexed epochId,
        uint256 protocolVaultId,
        uint256 collateralReturned,
        uint256 underlyingReceived,
        uint256 assignmentShortfall
    );
    event EpochClosed(
        uint256 indexed epochId,
        uint256 premiumEarned,
        uint256 assignmentShortfall,
        uint256 performanceFee,
        uint256 reservedWithdrawalAssets
    );
    event CuratorUpdated(address indexed oldCurator, address indexed newCurator);
    event AllocatorUpdated(address indexed oldAllocator, address indexed newAllocator);
    event StrategyConfigUpdated(StrategyConfig config);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event PerformanceFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    error InvalidAddress();
    error InvalidAmount();
    error OnlyOwner();
    error OnlyCurator();
    error OnlyAllocator();
    error OpenBatches();
    error NoShares();
    error InsufficientShares();
    error InvalidOToken();
    error BatchAlreadySettled();
    error FeeTooHigh();
    error PremiumAccountingMismatch();
    error PendingWithdrawal();
    error EpochNotClosed();
    error InsufficientAvailableAssets();
    error InsolventShareSupply();
    error PendingWithdrawalsOpen();
    error PendingDepositsOpen();
    error CollateralAccountingMismatch();
    error StrategyConstraint();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != owner && msg.sender != curator) revert OnlyCurator();
        _;
    }

    modifier onlyAllocator() {
        if (msg.sender != allocator) revert OnlyAllocator();
        _;
    }

    constructor(
        address _addressBook,
        address _usdc,
        address _ethUnderlying,
        address _allocator,
        address _feeRecipient,
        uint256 _performanceFeeBps
    ) {
        if (
            _addressBook == address(0) || _usdc == address(0) || _ethUnderlying == address(0)
                || _allocator == address(0) || _feeRecipient == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();

        addressBook = AddressBook(_addressBook);
        usdc = IERC20(_usdc);
        underlying = IERC20(_ethUnderlying);
        ethUnderlying = _ethUnderlying;
        owner = msg.sender;
        curator = msg.sender;
        allocator = _allocator;
        feeRecipient = _feeRecipient;
        performanceFeeBps = _performanceFeeBps;
        strategyConfig = StrategyConfig({
            maxCollateralPerBatch: type(uint256).max,
            maxUtilizationBps: 10_000,
            minPremiumBps: 0,
            minExpiryDelay: 0,
            maxExpiryDelay: type(uint256).max,
            minStrike: 0,
            maxStrike: type(uint256).max
        });

        currentEpoch = 1;
        epochs[currentEpoch].startedAt = uint64(block.timestamp);
    }

    function deposit(uint256 amount) external nonReentrant returns (uint256 mintedShares) {
        if (amount == 0) revert InvalidAmount();
        _activateDepositIfPossible(msg.sender);

        uint256 managedBefore = totalManagedAssets();
        uint256 balanceBefore = idleAssets();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = idleAssets() - balanceBefore;
        if (received == 0) revert InvalidAmount();

        if (_canActivateDeposits()) {
            mintedShares = _mintActiveShares(msg.sender, received, managedBefore);
        } else {
            pendingDepositAssets[msg.sender] += received;
            totalPendingDepositAssets += received;
            emit DepositQueued(msg.sender, currentEpoch, received);
        }
    }

    function activateDeposit() external nonReentrant returns (uint256 mintedShares) {
        return _activateDeposit(msg.sender);
    }

    function activateDepositFor(address user) external nonReentrant returns (uint256 mintedShares) {
        if (user == address(0)) revert InvalidAddress();
        return _activateDeposit(user);
    }

    function activateDeposits(address[] calldata users) external nonReentrant returns (uint256 mintedShares) {
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert InvalidAddress();
            if (pendingDepositAssets[users[i]] == 0) continue;
            mintedShares += _activateDeposit(users[i]);
        }
    }

    function withdrawIdle(uint256 shares, address receiver) external nonReentrant returns (uint256 amount) {
        _activateDepositIfPossible(msg.sender);
        if (receiver == address(0)) revert InvalidAddress();
        if (shares == 0) revert InvalidAmount();
        if (activeBatches != 0) revert OpenBatches();
        if (availableUnderlyingAssets() != 0) revert OpenBatches();
        if (sharesOf[msg.sender] < shares) revert InsufficientShares();

        amount = _convertToAssets(shares);
        if (amount == 0) revert InvalidAmount();
        if (amount > availableIdleAssets()) revert InsufficientAvailableAssets();

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;

        usdc.safeTransfer(receiver, amount);
        emit IdleWithdrawn(msg.sender, receiver, amount, shares);
    }

    function requestWithdraw(uint256 shares) external nonReentrant {
        _activateDepositIfPossible(msg.sender);
        if (shares == 0) revert InvalidAmount();
        if (pendingWithdrawalShares[msg.sender] != 0) revert PendingWithdrawal();
        if (sharesOf[msg.sender] < shares) revert InsufficientShares();

        sharesOf[msg.sender] -= shares;
        pendingWithdrawalEpoch[msg.sender] = currentEpoch;
        pendingWithdrawalShares[msg.sender] = shares;
        totalPendingWithdrawalShares += shares;
        totalPendingWithdrawalClaims++;

        emit WithdrawRequested(msg.sender, currentEpoch, shares);
    }

    function claimWithdraw() external nonReentrant returns (uint256 usdcAmount, uint256 underlyingAmount) {
        return _claimWithdraw(msg.sender);
    }

    function claimWithdrawTo(address receiver)
        external
        nonReentrant
        returns (uint256 usdcAmount, uint256 underlyingAmount)
    {
        if (receiver == address(0)) revert InvalidAddress();
        return _claimWithdraw(receiver);
    }

    function _claimWithdraw(address receiver) internal returns (uint256 usdcAmount, uint256 underlyingAmount) {
        uint256 epochId = pendingWithdrawalEpoch[msg.sender];
        uint256 shares = pendingWithdrawalShares[msg.sender];
        if (shares == 0) revert InvalidAmount();

        Epoch storage epoch = epochs[epochId];
        if (!epoch.closed) revert EpochNotClosed();
        if (epoch.remainingWithdrawalClaims == 0) revert InvalidAmount();

        if (epoch.remainingWithdrawalClaims == 1) {
            usdcAmount = epoch.withdrawalAssetsRemaining;
            underlyingAmount = withdrawalUnderlyingRemaining[epochId];
        } else {
            usdcAmount = (shares * epoch.withdrawalAssetsPerShare) / 1e18;
            underlyingAmount = (shares * withdrawalUnderlyingPerShare[epochId]) / 1e18;
        }

        pendingWithdrawalEpoch[msg.sender] = 0;
        pendingWithdrawalShares[msg.sender] = 0;
        epoch.remainingWithdrawalClaims--;
        epoch.withdrawalAssetsRemaining -= usdcAmount;
        withdrawalUnderlyingRemaining[epochId] -= underlyingAmount;
        reservedWithdrawalAssets -= usdcAmount;
        reservedUnderlyingAssets -= underlyingAmount;
        accountedUnderlyingAssets -= underlyingAmount;
        epoch.withdrawals += usdcAmount;

        if (usdcAmount > 0) {
            usdc.safeTransfer(receiver, usdcAmount);
        }
        if (underlyingAmount > 0) {
            underlying.safeTransfer(receiver, underlyingAmount);
        }
        emit WithdrawClaimed(msg.sender, receiver, epochId, usdcAmount, underlyingAmount, shares);
    }

    function openCspBatch(
        BatchSettler.Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral
    ) external onlyAllocator nonReentrant returns (uint256 batchId, uint256 protocolVaultId) {
        if (amount == 0 || collateral == 0) revert InvalidAmount();
        _validateEthUsdcPut(quote.oToken);
        if (totalPendingDepositAssets != 0) revert PendingDepositsOpen();
        if (availableUnderlyingAssets() != 0) revert OpenBatches();
        if (collateral > deployableIdleAssets()) revert InsufficientAvailableAssets();
        _validateStrategy(quote, amount, collateral);

        address marginPool = addressBook.marginPool();
        uint256 poolBalanceBefore = MarginPool(marginPool).getStoredBalance(address(usdc));
        usdc.forceApprove(marginPool, collateral);

        uint256 balanceBefore = usdc.balanceOf(address(this));
        protocolVaultId = BatchSettler(addressBook.batchSettler()).executeOrder(quote, signature, amount, collateral);
        usdc.forceApprove(marginPool, 0);
        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 poolBalanceAfter = MarginPool(marginPool).getStoredBalance(address(usdc));
        if (poolBalanceAfter < poolBalanceBefore || poolBalanceAfter - poolBalanceBefore != collateral) {
            revert CollateralAccountingMismatch();
        }

        uint256 premiumEarnedWithCollateral = balanceAfter + collateral;
        if (premiumEarnedWithCollateral < balanceBefore) revert PremiumAccountingMismatch();
        uint256 premiumEarned = premiumEarnedWithCollateral - balanceBefore;

        batchId = ++batchCount;
        batches[batchId] = CspBatch({
            epochId: currentEpoch,
            oToken: quote.oToken,
            protocolVaultId: protocolVaultId,
            amount: amount,
            collateral: collateral,
            premiumEarned: premiumEarned,
            collateralReturned: 0,
            settled: false
        });

        activeBatches++;
        activeCollateral += collateral;

        Epoch storage epoch = epochs[currentEpoch];
        epoch.committedCollateral += collateral;
        epoch.premiumEarned += premiumEarned;
        if (premiumEarned > 0 && performanceFeeBps > 0) {
            uint256 fee = (premiumEarned * performanceFeeBps) / 10000;
            if (fee > 0) {
                epoch.performanceFee += fee;
                usdc.safeTransfer(feeRecipient, fee);
            }
        }

        emit CspBatchOpened(batchId, currentEpoch, quote.oToken, protocolVaultId, amount, collateral, premiumEarned);
    }

    /// @notice Finalizes vault accounting after the backend has settled the protocol vault.
    /// @dev The vault never calls Controller settlement or physical redemption itself. The allocator
    ///      must first settle through BatchSettler and, when assigned, deliver WETH to this vault.
    function settleCspBatch(uint256 batchId, uint256 collateralReturned, uint256 underlyingReceived)
        external
        onlyAllocator
        nonReentrant
    {
        CspBatch storage batch = batches[batchId];
        if (batch.protocolVaultId == 0) revert InvalidAmount();
        if (batch.settled) revert BatchAlreadySettled();
        if (collateralReturned > batch.collateral) revert CollateralAccountingMismatch();
        if (collateralReturned > availableIdleAssets()) revert CollateralAccountingMismatch();
        if (underlying.balanceOf(address(this)) < accountedUnderlyingAssets + underlyingReceived) {
            revert CollateralAccountingMismatch();
        }

        batch.settled = true;
        batch.collateralReturned = collateralReturned;
        batchUnderlyingReceived[batchId] = underlyingReceived;
        accountedUnderlyingAssets += underlyingReceived;
        activeBatches--;
        activeCollateral -= batch.collateral;

        uint256 assignmentShortfall = batch.collateral - collateralReturned;

        Epoch storage epoch = epochs[batch.epochId];
        epoch.returnedCollateral += collateralReturned;
        epoch.assignmentShortfall += assignmentShortfall;
        epochAssignedUnderlying[batch.epochId] += underlyingReceived;

        emit CspBatchSettled(
            batchId, batch.epochId, batch.protocolVaultId, collateralReturned, underlyingReceived, assignmentShortfall
        );
    }

    function closeEpoch() external onlyAllocator nonReentrant returns (uint256 nextEpoch) {
        if (activeBatches != 0) revert OpenBatches();

        Epoch storage epoch = epochs[currentEpoch];
        if (epoch.closed) revert InvalidAmount();

        uint256 pendingShares = totalPendingWithdrawalShares;
        uint256 pendingClaims = totalPendingWithdrawalClaims;
        uint256 reservedAssets;
        uint256 reservedUnderlying;
        if (pendingShares > 0) {
            reservedAssets = (availableIdleAssets() * pendingShares) / totalShares;
            reservedUnderlying = (availableUnderlyingAssets() * pendingShares) / totalShares;
            epoch.withdrawalAssetsPerShare = (reservedAssets * 1e18) / pendingShares;
            epoch.withdrawalAssetsRemaining = reservedAssets;
            withdrawalUnderlyingPerShare[currentEpoch] = (reservedUnderlying * 1e18) / pendingShares;
            withdrawalUnderlyingRemaining[currentEpoch] = reservedUnderlying;
            epoch.remainingWithdrawalClaims = pendingClaims;
            totalShares -= pendingShares;
            totalPendingWithdrawalShares = 0;
            totalPendingWithdrawalClaims = 0;
            reservedWithdrawalAssets += reservedAssets;
            reservedUnderlyingAssets += reservedUnderlying;
        }

        epoch.closed = true;
        epoch.endedAt = uint64(block.timestamp);

        emit EpochClosed(
            currentEpoch, epoch.premiumEarned, epoch.assignmentShortfall, epoch.performanceFee, reservedAssets
        );

        nextEpoch = currentEpoch + 1;
        currentEpoch = nextEpoch;
        epochs[nextEpoch].startedAt = uint64(block.timestamp);
    }

    function setCurator(address newCurator) external onlyOwner {
        if (newCurator == address(0)) revert InvalidAddress();
        emit CuratorUpdated(curator, newCurator);
        curator = newCurator;
    }

    function setAllocator(address newAllocator) external onlyCurator {
        if (newAllocator == address(0)) revert InvalidAddress();
        emit AllocatorUpdated(allocator, newAllocator);
        allocator = newAllocator;
    }

    function setStrategyConfig(StrategyConfig calldata newConfig) external onlyCurator {
        if (newConfig.maxUtilizationBps > 10_000) revert StrategyConstraint();
        if (newConfig.maxExpiryDelay < newConfig.minExpiryDelay) revert StrategyConstraint();
        if (newConfig.maxStrike < newConfig.minStrike) revert StrategyConstraint();
        strategyConfig = newConfig;
        emit StrategyConfigUpdated(newConfig);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert InvalidAddress();
        emit FeeRecipientUpdated(feeRecipient, newFeeRecipient);
        feeRecipient = newFeeRecipient;
    }

    function setPerformanceFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        emit PerformanceFeeUpdated(performanceFeeBps, newFeeBps);
        performanceFeeBps = newFeeBps;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function idleAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function availableIdleAssets() public view returns (uint256) {
        uint256 idle = idleAssets();
        uint256 unavailable = reservedWithdrawalAssets + totalPendingDepositAssets;
        if (idle <= unavailable) return 0;
        return idle - unavailable;
    }

    function availableUnderlyingAssets() public view returns (uint256) {
        if (accountedUnderlyingAssets <= reservedUnderlyingAssets) return 0;
        return accountedUnderlyingAssets - reservedUnderlyingAssets;
    }

    function deployableIdleAssets() public view returns (uint256) {
        uint256 available = availableIdleAssets();
        if (totalPendingWithdrawalShares == 0) return available;
        uint256 activeShares = totalShares - totalPendingWithdrawalShares;
        return (available * activeShares) / totalShares;
    }

    function totalManagedAssets() public view returns (uint256) {
        return availableIdleAssets() + activeCollateral;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        if (totalShares == 0) return shares;
        return (totalManagedAssets() * shares) / totalShares;
    }

    function _activateDepositIfPossible(address user) internal returns (uint256 mintedShares) {
        if (pendingDepositAssets[user] == 0 || !_canActivateDeposits()) return 0;
        return _activateDeposit(user);
    }

    function _activateDeposit(address user) internal returns (uint256 mintedShares) {
        if (!_canActivateDeposits()) revert OpenBatches();
        uint256 assets = pendingDepositAssets[user];
        if (assets == 0) revert InvalidAmount();

        uint256 managedBefore = totalManagedAssets();
        pendingDepositAssets[user] = 0;
        totalPendingDepositAssets -= assets;
        mintedShares = _mintActiveShares(user, assets, managedBefore);
    }

    function _mintActiveShares(address user, uint256 assets, uint256 managedBefore)
        internal
        returns (uint256 mintedShares)
    {
        if (totalShares == 0) {
            mintedShares = assets;
        } else if (managedBefore == 0) {
            revert InsolventShareSupply();
        } else {
            mintedShares = (assets * (totalShares + _virtualShares())) / (managedBefore + _virtualAssets());
        }
        if (mintedShares == 0) revert NoShares();

        sharesOf[user] += mintedShares;
        totalShares += mintedShares;
        epochs[currentEpoch].deposits += assets;

        emit Deposited(user, assets, mintedShares);
    }

    function _canActivateDeposits() internal view returns (bool) {
        return activeBatches == 0 && totalPendingWithdrawalShares == 0 && availableUnderlyingAssets() == 0;
    }

    function _validateStrategy(BatchSettler.Quote calldata quote, uint256 amount, uint256 collateral) internal view {
        StrategyConfig memory config = strategyConfig;
        OToken oToken = OToken(quote.oToken);

        if (collateral > config.maxCollateralPerBatch) revert StrategyConstraint();
        if (collateral * 10_000 > totalManagedAssets() * config.maxUtilizationBps) revert StrategyConstraint();

        uint256 premium = (amount * quote.bidPrice) / 1e8;
        if (premium * 10_000 < collateral * config.minPremiumBps) revert StrategyConstraint();

        uint256 expiryDelay = oToken.expiry() > block.timestamp ? oToken.expiry() - block.timestamp : 0;
        if (expiryDelay < config.minExpiryDelay || expiryDelay > config.maxExpiryDelay) revert StrategyConstraint();

        uint256 strike = oToken.strikePrice();
        if (strike < config.minStrike || strike > config.maxStrike) revert StrategyConstraint();
    }

    function _virtualAssets() internal pure returns (uint256) {
        return 1e6;
    }

    function _virtualShares() internal pure returns (uint256) {
        return 1e6;
    }

    function _validateEthUsdcPut(address oTokenAddress) internal view {
        if (oTokenAddress == address(0)) revert InvalidOToken();
        OToken oToken = OToken(oTokenAddress);
        if (
            !oToken.isPut() || oToken.underlying() != ethUnderlying || oToken.strikeAsset() != address(usdc)
                || oToken.collateralAsset() != address(usdc)
        ) {
            revert InvalidOToken();
        }
    }
}
