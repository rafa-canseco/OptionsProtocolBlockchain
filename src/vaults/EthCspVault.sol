// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../core/AddressBook.sol";
import "../core/BatchSettler.sol";
import "../core/Controller.sol";
import "../core/MarginPool.sol";
import "../core/OToken.sol";
import "../core/Oracle.sol";
import "../interfaces/IMarginVault.sol";
import "./interfaces/IEthCspOptionSelector.sol";
import "./modules/EthCspAssignmentLedger.sol";
import "./modules/EthCspDepositQueue.sol";
import "./modules/EthCspEpochAccounting.sol";
import "./modules/EthCspVaultTypes.sol";
import "./modules/EthCspWithdrawalQueue.sol";

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

    address public owner;
    address public curator;
    address public allocator;
    address public feeRecipient;
    address public optionSelector;
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
    uint256 public accountedIdleAssets;
    uint256 public accountedUnderlyingAssets;
    uint256 public allocatedUnderlyingAssets;
    uint256 public cumulativeUnderlyingPerShare;
    uint256 public currentShareGeneration = 1;
    uint256 public settlementDefaultDelay = 1 days;

    mapping(uint256 => EthCspVaultTypes.Epoch) public epochs;
    mapping(uint256 => EthCspVaultTypes.CspBatch) public batches;
    mapping(uint256 => uint256) public batchUnderlyingReceived;
    mapping(uint256 => uint256) public epochAssignedUnderlying;
    mapping(uint256 => uint256) public withdrawalUnderlyingPerShare;
    mapping(uint256 => uint256) public withdrawalUnderlyingRemaining;
    mapping(address => uint256) public pendingDepositAssets;
    mapping(address => uint256) public pendingDepositMinShares;
    mapping(address => uint256) public pendingWithdrawalEpoch;
    mapping(address => uint256) public pendingWithdrawalShares;
    mapping(address => uint256) public underlyingPerSharePaid;
    mapping(address => uint256) public claimableAssignedUnderlying;
    mapping(address => uint256) public shareGeneration;
    mapping(uint256 => uint256) public generationCumulativeUnderlyingPerShare;

    uint256 public preparedSettlementBatchId;
    uint256 private _preparedSettlementCollateralReturned;
    mapping(uint256 => uint256) private _batchDefaultEligibleAt;

    uint256 private constant MAX_PERFORMANCE_FEE_BPS = 2000;
    uint256 private constant MIN_SETTLEMENT_DEFAULT_DELAY = 1 hours;
    uint256 private constant MAX_SETTLEMENT_DEFAULT_DELAY = 30 days;
    uint256 public constant MIN_DEPOSIT_ASSETS = 1e6;
    uint256 public constant MAX_UNDERLYING_DUST_THRESHOLD = 1e14;

    uint256 public underlyingDustThreshold = MAX_UNDERLYING_DUST_THRESHOLD;

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event DepositQueued(address indexed user, uint256 indexed epochId, uint256 amount);
    event DepositRefunded(address indexed user, uint256 amount);
    event PendingDepositCancelled(address indexed user, address indexed receiver, uint256 amount);
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
    event OptionSelectorUpdated(address indexed oldSelector, address indexed newSelector);
    event PerformanceFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event SettlementDefaultDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event AssignedUnderlyingDustSwept(address indexed receiver, uint256 amount);
    event AssignedUnderlyingAllocated(uint256 indexed epochId, uint256 amount, uint256 activeShares);
    event AssignedUnderlyingClaimed(address indexed user, address indexed receiver, uint256 amount);
    event AssignedShareGenerationExpired(
        uint256 indexed epochId, uint256 indexed expiredGeneration, uint256 shares, uint256 underlyingAmount
    );
    event ExpiredSharesBurned(address indexed user, uint256 indexed expiredGeneration, uint256 shares);
    event UnderlyingDustThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

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
    error CollateralAccountingMismatch();
    error StrategyConstraint();
    error AssignedUnderlyingTooLarge();
    error SettlementDefaultNotReady();

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
        mintedShares = _deposit(amount, 0);
    }

    function deposit(uint256 amount, uint256 minSharesOut) external nonReentrant returns (uint256 mintedShares) {
        mintedShares = _deposit(amount, minSharesOut);
    }

    function _deposit(uint256 amount, uint256 minSharesOut) internal returns (uint256 mintedShares) {
        if (amount < MIN_DEPOSIT_ASSETS) revert InvalidAmount();
        _settleExpiredShares(msg.sender);
        _activateDepositIfPossible(msg.sender);

        uint256 managedBefore = totalManagedAssets();
        uint256 balanceBefore = idleAssets();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = idleAssets() - balanceBefore;
        if (received == 0) revert InvalidAmount();
        accountedIdleAssets += received;

        if (_canActivateDeposits()) {
            mintedShares = _mintActiveShares(msg.sender, received, managedBefore, minSharesOut);
        } else {
            totalPendingDepositAssets =
                EthCspDepositQueue.queue(pendingDepositAssets, msg.sender, received, totalPendingDepositAssets);
            pendingDepositMinShares[msg.sender] += minSharesOut;
            emit DepositQueued(msg.sender, currentEpoch, received);
        }
    }

    function activateDeposit() external nonReentrant returns (uint256 mintedShares) {
        return _activateDeposit(msg.sender);
    }

    function activateDepositFor(address user) external nonReentrant returns (uint256 mintedShares) {
        if (user == address(0)) revert InvalidAddress();
        if (msg.sender != user && msg.sender != allocator) revert OnlyAllocator();
        return _activateDeposit(user);
    }

    function activateDeposits(address[] calldata users)
        external
        onlyAllocator
        nonReentrant
        returns (uint256 mintedShares)
    {
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] == address(0)) revert InvalidAddress();
            if (pendingDepositAssets[users[i]] == 0) continue;
            mintedShares += _activateDeposit(users[i]);
        }
    }

    function cancelPendingDeposit(address receiver) external nonReentrant returns (uint256 amount) {
        if (receiver == address(0)) revert InvalidAddress();
        (amount, totalPendingDepositAssets) =
            EthCspDepositQueue.cancel(pendingDepositAssets, msg.sender, totalPendingDepositAssets);
        pendingDepositMinShares[msg.sender] = 0;
        accountedIdleAssets -= amount;

        usdc.safeTransfer(receiver, amount);
        emit PendingDepositCancelled(msg.sender, receiver, amount);
    }

    function withdrawIdle(uint256 shares, address receiver) external nonReentrant returns (uint256 amount) {
        _settleExpiredShares(msg.sender);
        _activateDepositIfPossible(msg.sender);
        _accrueAssignedUnderlying(msg.sender);
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
        accountedIdleAssets -= amount;

        usdc.safeTransfer(receiver, amount);
        emit IdleWithdrawn(msg.sender, receiver, amount, shares);
    }

    function requestWithdraw(uint256 shares) external nonReentrant {
        _settleExpiredShares(msg.sender);
        _activateDepositIfPossible(msg.sender);
        _requestWithdraw(msg.sender, shares);
    }

    function forceRequestWithdraw(address user) external onlyAllocator nonReentrant {
        if (user == address(0)) revert InvalidAddress();
        if (activeBatches != 0 || availableUnderlyingAssets() == 0) revert OpenBatches();
        _settleExpiredShares(user);
        uint256 shares = sharesOf[user];
        if (shares == 0) revert NoShares();
        _requestWithdraw(user, shares);
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

    function claimAssignedUnderlying(address receiver) external nonReentrant returns (uint256 amount) {
        if (receiver == address(0)) revert InvalidAddress();
        _settleExpiredShares(msg.sender);
        _accrueAssignedUnderlying(msg.sender);
        amount = EthCspAssignmentLedger.consumeClaim(claimableAssignedUnderlying, msg.sender);
        allocatedUnderlyingAssets -= amount;
        accountedUnderlyingAssets -= amount;
        underlying.safeTransfer(receiver, amount);

        emit AssignedUnderlyingClaimed(msg.sender, receiver, amount);
    }

    function _claimWithdraw(address receiver) internal returns (uint256 usdcAmount, uint256 underlyingAmount) {
        uint256 epochId = pendingWithdrawalEpoch[msg.sender];
        uint256 shares = pendingWithdrawalShares[msg.sender];
        if (shares == 0) revert InvalidAmount();

        EthCspVaultTypes.Epoch storage epoch = epochs[epochId];
        EthCspWithdrawalQueue.ClaimPreview memory preview = EthCspWithdrawalQueue.previewClaim(
            shares,
            epoch.closed,
            epoch.remainingWithdrawalClaims,
            epoch.withdrawalAssetsPerShare,
            epoch.withdrawalAssetsRemaining,
            withdrawalUnderlyingPerShare[epochId],
            withdrawalUnderlyingRemaining[epochId]
        );
        usdcAmount = preview.usdcAmount;
        underlyingAmount = preview.underlyingAmount;

        EthCspWithdrawalQueue.clearClaim(pendingWithdrawalEpoch, pendingWithdrawalShares, msg.sender);
        epoch.remainingWithdrawalClaims--;
        epoch.withdrawalAssetsRemaining -= usdcAmount;
        withdrawalUnderlyingRemaining[epochId] -= underlyingAmount;
        reservedWithdrawalAssets -= usdcAmount;
        reservedUnderlyingAssets -= underlyingAmount;
        accountedIdleAssets -= usdcAmount;
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

    function _requestWithdraw(address user, uint256 shares) internal {
        _settleExpiredShares(user);
        _accrueAssignedUnderlying(user);
        (totalPendingWithdrawalShares, totalPendingWithdrawalClaims) = EthCspWithdrawalQueue.request(
            sharesOf,
            pendingWithdrawalEpoch,
            pendingWithdrawalShares,
            user,
            shares,
            currentEpoch,
            totalPendingWithdrawalShares,
            totalPendingWithdrawalClaims
        );

        emit WithdrawRequested(user, currentEpoch, shares);
    }

    function openCspBatch(
        BatchSettler.Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral
    ) external onlyAllocator nonReentrant returns (uint256 batchId, uint256 protocolVaultId) {
        if (amount == 0 || collateral == 0) revert InvalidAmount();
        _validateEthUsdcPut(quote.oToken);
        if (totalPendingWithdrawalShares != 0) revert PendingWithdrawalsOpen();
        if (availableUnderlyingAssets() != 0) revert OpenBatches();
        if (collateral > deployableIdleAssets()) revert InsufficientAvailableAssets();
        uint256 requiredCollateral = _requiredPutCollateral(quote.oToken, amount);
        if (collateral != requiredCollateral) revert CollateralAccountingMismatch();
        _validateOptionSelection(quote.oToken, collateral);
        address marginPool = addressBook.marginPool();
        if (
            MarginPool(marginPool).isAaveEnabled(address(usdc))
                || MarginPool(marginPool).totalDeposited(address(usdc)) != 0
        ) revert StrategyConstraint();
        uint256 premiumEarned;
        Controller ctrl = Controller(addressBook.controller());
        uint256 expectedProtocolVaultId = ctrl.vaultCount(address(this)) + 1;
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
        premiumEarned = premiumEarnedWithCollateral - balanceBefore;
        if (protocolVaultId != expectedProtocolVaultId) revert CollateralAccountingMismatch();
        _validateProtocolVault(protocolVaultId, quote.oToken, amount, address(usdc), collateral);
        _validateStrategyPremium(collateral, premiumEarned);
        accountedIdleAssets = accountedIdleAssets - collateral + premiumEarned;

        batchId = ++batchCount;
        batches[batchId] = EthCspVaultTypes.CspBatch({
            epochId: currentEpoch,
            oToken: quote.oToken,
            protocolVaultId: protocolVaultId,
            amount: amount,
            collateral: collateral,
            premiumEarned: premiumEarned,
            collateralReturned: 0,
            settled: false
        });
        _batchDefaultEligibleAt[batchId] = 0;
        BatchSettler(addressBook.batchSettler()).reservePhysicalDelivery(protocolVaultId);

        activeBatches++;
        activeCollateral += collateral;

        EthCspVaultTypes.Epoch storage epoch = epochs[currentEpoch];
        epoch.committedCollateral += collateral;
        epoch.premiumEarned += premiumEarned;
        if (premiumEarned > 0 && performanceFeeBps > 0) {
            uint256 fee = (premiumEarned * performanceFeeBps) / 10000;
            if (fee > 0) {
                epoch.performanceFee += fee;
                accountedIdleAssets -= fee;
                usdc.safeTransfer(feeRecipient, fee);
            }
        }

        emit CspBatchOpened(batchId, currentEpoch, quote.oToken, protocolVaultId, amount, collateral, premiumEarned);
    }

    /// @notice Settles the writer vault and releases an ITM position for BatchSettler's physical-delivery bot.
    /// @dev OTM positions finalize immediately. ITM positions are finalized only after
    ///      operatorPhysicalRedeemVault clears the attributed oTokens and delivers WETH.
    function prepareCspBatchSettlement(uint256 batchId, uint256 collateralReturned)
        external
        onlyAllocator
        nonReentrant
    {
        EthCspVaultTypes.CspBatch storage batch = batches[batchId];
        if (batch.protocolVaultId == 0) revert InvalidAmount();
        if (batch.settled) revert BatchAlreadySettled();
        if (preparedSettlementBatchId != 0) revert OpenBatches();
        if (collateralReturned > batch.collateral) revert CollateralAccountingMismatch();

        BatchSettler settler = BatchSettler(addressBook.batchSettler());
        address mm = settler.vaultMM(address(this), batch.protocolVaultId);
        if (mm == address(0)) revert InvalidAddress();

        uint256 usdcBefore = usdc.balanceOf(address(this));
        Controller(addressBook.controller()).settleVault(address(this), batch.protocolVaultId);
        uint256 observedCollateralReturned = usdc.balanceOf(address(this)) - usdcBefore;
        if (observedCollateralReturned != collateralReturned) revert CollateralAccountingMismatch();

        uint256 expectedUnderlying = collateralReturned == batch.collateral ? 0 : batch.amount * 1e10;
        if (expectedUnderlying == 0) {
            uint256 payout = settler.settleReservedPhysicalDelivery(batch.protocolVaultId, mm, 0);
            if (payout != 0) revert CollateralAccountingMismatch();
            _finalizeCspBatch(batchId, collateralReturned, 0);
            return;
        }

        settler.releasePhysicalDelivery(batch.protocolVaultId);
        preparedSettlementBatchId = batchId;
        _preparedSettlementCollateralReturned = collateralReturned;
        _batchDefaultEligibleAt[batchId] = block.timestamp + settlementDefaultDelay;
    }

    /// @notice Finalizes an ITM batch after the existing BatchSettler operator delivers WETH.
    function finalizeCspBatchSettlement(uint256 batchId) external onlyAllocator nonReentrant {
        if (preparedSettlementBatchId != batchId) revert InvalidAmount();

        EthCspVaultTypes.CspBatch storage batch = batches[batchId];
        if (batch.protocolVaultId == 0) revert InvalidAmount();
        if (batch.settled) revert BatchAlreadySettled();

        BatchSettler settler = BatchSettler(addressBook.batchSettler());
        if (settler.physicalDeliveryReservedVault(address(this), batch.protocolVaultId)) {
            revert CollateralAccountingMismatch();
        }
        if (settler.vaultOTokenBalance(address(this), batch.protocolVaultId) != 0) {
            revert CollateralAccountingMismatch();
        }

        uint256 collateralReturned = _preparedSettlementCollateralReturned;
        uint256 underlyingReceived = collateralReturned == batch.collateral ? 0 : batch.amount * 1e10;
        if (underlying.balanceOf(address(this)) < accountedUnderlyingAssets + underlyingReceived) {
            revert CollateralAccountingMismatch();
        }

        _clearPreparedSettlement();
        _finalizeCspBatch(batchId, collateralReturned, underlyingReceived);
    }

    /// @notice Cash fallback when physical delivery was not completed before the configured timeout.
    /// @dev Reserved oTokens are redeemed back to this vault. The MM receives the cash intrinsic value
    ///      and the vault retains the remaining collateral, so no MM WETH or protocol-wide pause is needed.
    function settleDefaultedCspBatch(uint256 batchId) external onlyAllocator nonReentrant {
        EthCspVaultTypes.CspBatch storage batch = batches[batchId];
        if (batch.protocolVaultId == 0) revert InvalidAmount();
        if (batch.settled) revert BatchAlreadySettled();

        bool wasPrepared = preparedSettlementBatchId == batchId;
        if (preparedSettlementBatchId != 0 && !wasPrepared) revert OpenBatches();

        Controller controller = Controller(addressBook.controller());
        if (controller.systemFullyPaused()) revert SettlementDefaultNotReady();

        if (!wasPrepared || block.timestamp < _batchDefaultEligibleAt[batchId]) revert SettlementDefaultNotReady();

        uint256 collateralReturned;
        if (controller.vaultSettled(address(this), batch.protocolVaultId)) {
            if (!wasPrepared) revert CollateralAccountingMismatch();
            collateralReturned = _preparedSettlementCollateralReturned;
        } else {
            uint256 usdcBeforeSettlement = usdc.balanceOf(address(this));
            controller.settleVault(address(this), batch.protocolVaultId);
            collateralReturned = usdc.balanceOf(address(this)) - usdcBeforeSettlement;
        }
        if (collateralReturned > batch.collateral) revert CollateralAccountingMismatch();

        BatchSettler settler = BatchSettler(addressBook.batchSettler());
        if (!settler.physicalDeliveryReservedVault(address(this), batch.protocolVaultId)) {
            settler.reservePhysicalDelivery(batch.protocolVaultId);
        }

        (uint256 expectedPayout, uint256 mmCashPayout) = _putCashPayouts(batch.oToken, batch.amount);
        uint256 usdcBeforePayout = usdc.balanceOf(address(this));
        uint256 payout = settler.settleReservedPhysicalDelivery(batch.protocolVaultId, address(this), expectedPayout);
        if (payout != expectedPayout || usdc.balanceOf(address(this)) - usdcBeforePayout != expectedPayout) {
            revert CollateralAccountingMismatch();
        }
        if (mmCashPayout > payout) revert CollateralAccountingMismatch();
        address mm = settler.vaultMM(address(this), batch.protocolVaultId);
        if (mm == address(0)) revert InvalidAddress();
        if (mmCashPayout > 0) usdc.safeTransfer(mm, mmCashPayout);

        collateralReturned += payout - mmCashPayout;
        if (collateralReturned + mmCashPayout > batch.collateral) revert CollateralAccountingMismatch();
        // Per-vault collateral rounds up while aggregate redemption rounds down.
        if (batch.collateral - collateralReturned - mmCashPayout > 1) revert CollateralAccountingMismatch();

        if (wasPrepared) _clearPreparedSettlement();
        _finalizeCspBatch(batchId, collateralReturned, 0);
    }

    function _putCashPayouts(address oTokenAddress, uint256 amount)
        private
        view
        returns (uint256 redemptionPayout, uint256 mmCashPayout)
    {
        OToken oToken = OToken(oTokenAddress);
        (uint256 expiryPrice, bool isSet) =
            Oracle(addressBook.oracle()).getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert CollateralAccountingMismatch();
        uint256 strike = oToken.strikePrice();
        if (expiryPrice >= strike) return (0, 0);

        uint256 collateralDecimals = IERC20Metadata(address(usdc)).decimals();
        if (collateralDecimals < 6 || collateralDecimals > 16) revert StrategyConstraint();
        uint256 denominator = 10 ** (16 - collateralDecimals);
        redemptionPayout = (amount * strike) / denominator;
        mmCashPayout = (amount * (strike - expiryPrice)) / denominator;
    }

    function _finalizeCspBatch(uint256 batchId, uint256 collateralReturned, uint256 underlyingReceived) internal {
        EthCspVaultTypes.CspBatch storage batch = batches[batchId];
        batch.settled = true;
        batch.collateralReturned = collateralReturned;

        batchUnderlyingReceived[batchId] = underlyingReceived;
        accountedIdleAssets += collateralReturned;
        accountedUnderlyingAssets += underlyingReceived;
        activeBatches--;
        activeCollateral -= batch.collateral;

        uint256 assignmentShortfall = batch.collateral - collateralReturned;

        EthCspVaultTypes.Epoch storage epoch = epochs[batch.epochId];
        epoch.returnedCollateral += collateralReturned;
        epoch.assignmentShortfall += assignmentShortfall;
        epochAssignedUnderlying[batch.epochId] += underlyingReceived;

        emit CspBatchSettled(
            batchId, batch.epochId, batch.protocolVaultId, collateralReturned, underlyingReceived, assignmentShortfall
        );
    }

    function _clearPreparedSettlement() internal {
        preparedSettlementBatchId = 0;
        _preparedSettlementCollateralReturned = 0;
    }

    function closeEpoch() external onlyAllocator nonReentrant returns (uint256 nextEpoch) {
        if (activeBatches != 0) revert OpenBatches();

        EthCspVaultTypes.Epoch storage epoch = epochs[currentEpoch];
        if (epoch.closed) revert InvalidAmount();

        uint256 pendingShares = totalPendingWithdrawalShares;
        uint256 pendingClaims = totalPendingWithdrawalClaims;
        EthCspEpochAccounting.ClosePreview memory preview = EthCspEpochAccounting.previewClose(
            totalShares, pendingShares, availableIdleAssets(), availableUnderlyingAssets()
        );
        if (pendingShares > 0) {
            epoch.withdrawalAssetsPerShare = preview.withdrawalAssetsPerShare;
            epoch.withdrawalAssetsRemaining = preview.reservedAssets;
            withdrawalUnderlyingPerShare[currentEpoch] = preview.withdrawalUnderlyingPerShare;
            withdrawalUnderlyingRemaining[currentEpoch] = preview.reservedUnderlying;
            epoch.remainingWithdrawalClaims = pendingClaims;
            totalShares -= pendingShares;
            totalPendingWithdrawalShares = 0;
            totalPendingWithdrawalClaims = 0;
            reservedWithdrawalAssets += preview.reservedAssets;
            reservedUnderlyingAssets += preview.reservedUnderlying;
        }
        _allocateAssignedUnderlying(currentEpoch);

        epoch.closed = true;
        epoch.endedAt = uint64(block.timestamp);

        emit EpochClosed(
            currentEpoch, epoch.premiumEarned, epoch.assignmentShortfall, epoch.performanceFee, preview.reservedAssets
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

    function setOptionSelector(address newOptionSelector) external onlyCurator {
        emit OptionSelectorUpdated(optionSelector, newOptionSelector);
        optionSelector = newOptionSelector;
    }

    function setPerformanceFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PERFORMANCE_FEE_BPS) revert FeeTooHigh();
        emit PerformanceFeeUpdated(performanceFeeBps, newFeeBps);
        performanceFeeBps = newFeeBps;
    }

    function setSettlementDefaultDelay(uint256 newDelay) external onlyCurator {
        if (newDelay < MIN_SETTLEMENT_DEFAULT_DELAY || newDelay > MAX_SETTLEMENT_DEFAULT_DELAY) {
            revert StrategyConstraint();
        }
        emit SettlementDefaultDelayUpdated(settlementDefaultDelay, newDelay);
        settlementDefaultDelay = newDelay;
    }

    function setUnderlyingDustThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold > MAX_UNDERLYING_DUST_THRESHOLD) revert StrategyConstraint();
        emit UnderlyingDustThresholdUpdated(underlyingDustThreshold, newThreshold);
        underlyingDustThreshold = newThreshold;
    }

    function sweepAssignedUnderlyingDust() external onlyAllocator nonReentrant returns (uint256 amount) {
        if (!epochs[currentEpoch].closed && epochAssignedUnderlying[currentEpoch] != 0) revert OpenBatches();
        amount = availableUnderlyingAssets();
        if (amount == 0) revert InvalidAmount();
        if (amount > underlyingDustThreshold) revert AssignedUnderlyingTooLarge();

        accountedUnderlyingAssets -= amount;
        underlying.safeTransfer(feeRecipient, amount);
        emit AssignedUnderlyingDustSwept(feeRecipient, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        if (optionSelector != address(0)) revert StrategyConstraint();
        address oldOwner = owner;
        emit OwnershipTransferred(oldOwner, newOwner);
        owner = newOwner;
        if (curator == oldOwner) {
            emit CuratorUpdated(oldOwner, newOwner);
            curator = newOwner;
        }
    }

    function idleAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function availableIdleAssets() public view returns (uint256) {
        uint256 idle = accountedIdleAssets;
        uint256 unavailable = reservedWithdrawalAssets + totalPendingDepositAssets;
        if (idle <= unavailable) return 0;
        return idle - unavailable;
    }

    function availableUnderlyingAssets() public view returns (uint256) {
        return EthCspAssignmentLedger.available(
            accountedUnderlyingAssets, reservedUnderlyingAssets, allocatedUnderlyingAssets
        );
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
        _settleExpiredShares(user);
        uint256 assets = pendingDepositAssets[user];
        if (assets == 0) revert InvalidAmount();

        uint256 managedBefore = totalManagedAssets();
        uint256 minSharesOut = pendingDepositMinShares[user];
        (assets, totalPendingDepositAssets) =
            EthCspDepositQueue.consume(pendingDepositAssets, user, totalPendingDepositAssets, _canActivateDeposits());
        pendingDepositMinShares[user] = 0;
        mintedShares = _previewActiveShares(assets, managedBefore);
        if (mintedShares < minSharesOut) revert NoShares();
        if (mintedShares == 0) {
            accountedIdleAssets -= assets;
            usdc.safeTransfer(user, assets);
            emit DepositRefunded(user, assets);
            return 0;
        }

        _recordActiveShares(user, assets, mintedShares);
    }

    function _mintActiveShares(address user, uint256 assets, uint256 managedBefore, uint256 minSharesOut)
        internal
        returns (uint256 mintedShares)
    {
        mintedShares = _previewActiveShares(assets, managedBefore);
        if (mintedShares == 0 || mintedShares < minSharesOut) revert NoShares();
        _recordActiveShares(user, assets, mintedShares);
    }

    function _previewActiveShares(uint256 assets, uint256 managedBefore) internal view returns (uint256 mintedShares) {
        mintedShares = EthCspDepositQueue.previewActiveShares(assets, totalShares, managedBefore);
    }

    function _recordActiveShares(address user, uint256 assets, uint256 mintedShares) internal {
        _accrueAssignedUnderlying(user);
        shareGeneration[user] = currentShareGeneration;
        sharesOf[user] += mintedShares;
        totalShares += mintedShares;
        underlyingPerSharePaid[user] = cumulativeUnderlyingPerShare;
        epochs[currentEpoch].deposits += assets;

        emit Deposited(user, assets, mintedShares);
    }

    function _canActivateDeposits() internal view returns (bool) {
        return EthCspDepositQueue.canActivate(activeBatches, totalPendingWithdrawalShares, availableUnderlyingAssets());
    }

    function _allocateAssignedUnderlying(uint256 epochId) internal {
        uint256 amount = availableUnderlyingAssets();
        if (amount != 0 && totalShares != 0 && totalManagedAssets() == 0) {
            _expireAssignedShareGeneration(epochId, amount);
            return;
        }

        EthCspAssignmentLedger.AllocationResult memory result = EthCspAssignmentLedger.allocate(
            amount,
            totalShares,
            accountedUnderlyingAssets,
            allocatedUnderlyingAssets,
            cumulativeUnderlyingPerShare,
            underlyingDustThreshold
        );

        accountedUnderlyingAssets = result.newAccountedUnderlyingAssets;
        allocatedUnderlyingAssets = result.newAllocatedUnderlyingAssets;
        cumulativeUnderlyingPerShare = result.newCumulativeUnderlyingPerShare;

        if (result.swept > 0) {
            underlying.safeTransfer(feeRecipient, result.swept);
            emit AssignedUnderlyingDustSwept(feeRecipient, result.swept);
        }
        if (result.distributed > 0) {
            emit AssignedUnderlyingAllocated(epochId, result.distributed, totalShares);
        }
    }

    function _expireAssignedShareGeneration(uint256 epochId, uint256 amount) internal {
        uint256 expiredShares = totalShares;
        uint256 expiredGeneration = currentShareGeneration;
        EthCspAssignmentLedger.AllocationResult memory result = EthCspAssignmentLedger.allocate(
            amount,
            expiredShares,
            accountedUnderlyingAssets,
            allocatedUnderlyingAssets,
            cumulativeUnderlyingPerShare,
            underlyingDustThreshold
        );

        accountedUnderlyingAssets = result.newAccountedUnderlyingAssets;
        allocatedUnderlyingAssets = result.newAllocatedUnderlyingAssets;
        cumulativeUnderlyingPerShare = result.newCumulativeUnderlyingPerShare;
        generationCumulativeUnderlyingPerShare[expiredGeneration] = result.newCumulativeUnderlyingPerShare;
        totalShares = 0;
        currentShareGeneration = expiredGeneration + 1;
        generationCumulativeUnderlyingPerShare[currentShareGeneration] = result.newCumulativeUnderlyingPerShare;

        if (result.swept > 0) {
            underlying.safeTransfer(feeRecipient, result.swept);
            emit AssignedUnderlyingDustSwept(feeRecipient, result.swept);
        }
        emit AssignedShareGenerationExpired(epochId, expiredGeneration, expiredShares, result.distributed);
    }

    function _accrueAssignedUnderlying(address user) internal {
        if (shareGeneration[user] != currentShareGeneration) {
            _settleExpiredShares(user);
            return;
        }
        EthCspAssignmentLedger.accrue(
            underlyingPerSharePaid, claimableAssignedUnderlying, sharesOf, user, cumulativeUnderlyingPerShare
        );
    }

    function _settleExpiredShares(address user) internal {
        if (shareGeneration[user] == currentShareGeneration) return;

        uint256 expiredShares = sharesOf[user];
        if (expiredShares > 0) {
            uint256 expiredGeneration = shareGeneration[user];
            uint256 paid = underlyingPerSharePaid[user];
            uint256 cutoff = generationCumulativeUnderlyingPerShare[expiredGeneration];
            if (cutoff > paid) {
                uint256 accrued = (expiredShares * (cutoff - paid)) / 1e18;
                if (accrued > 0) {
                    claimableAssignedUnderlying[user] += accrued;
                }
            }
            sharesOf[user] = 0;
            underlyingPerSharePaid[user] = cumulativeUnderlyingPerShare;
            emit ExpiredSharesBurned(user, expiredGeneration, expiredShares);
        } else {
            underlyingPerSharePaid[user] = cumulativeUnderlyingPerShare;
        }
        shareGeneration[user] = currentShareGeneration;
    }

    function _validateOptionSelection(address oTokenAddress, uint256 collateral) internal view {
        address selector = optionSelector;
        if (selector != address(0)) {
            IEthCspOptionSelector(selector)
                .validateOption(
                    oTokenAddress,
                    address(underlying),
                    address(usdc),
                    collateral,
                    activeCollateral,
                    totalManagedAssets()
                );
            return;
        }

        StrategyConfig memory config = strategyConfig;
        OToken oToken = OToken(oTokenAddress);

        if (collateral > config.maxCollateralPerBatch) revert StrategyConstraint();
        uint256 nextActiveCollateral = activeCollateral + collateral;
        if (nextActiveCollateral * 10_000 > totalManagedAssets() * config.maxUtilizationBps) {
            revert StrategyConstraint();
        }

        uint256 expiryDelay = oToken.expiry() > block.timestamp ? oToken.expiry() - block.timestamp : 0;
        if (expiryDelay < config.minExpiryDelay || expiryDelay > config.maxExpiryDelay) revert StrategyConstraint();

        uint256 strike = oToken.strikePrice();
        if (strike < config.minStrike || strike > config.maxStrike) revert StrategyConstraint();
    }

    function _requiredPutCollateral(address oTokenAddress, uint256 amount) internal view returns (uint256) {
        OToken oToken = OToken(oTokenAddress);
        uint8 collateralDecimals = IERC20Metadata(oToken.collateralAsset()).decimals();
        if (collateralDecimals < 6 || collateralDecimals > 16) revert StrategyConstraint();
        uint256 denominator = 10 ** (16 - collateralDecimals);
        uint256 required = (amount * oToken.strikePrice() + denominator - 1) / denominator;
        if (required == 0 && amount > 0) revert CollateralAccountingMismatch();
        return required;
    }

    function _validateProtocolVault(
        uint256 protocolVaultId,
        address expectedOToken,
        uint256 expectedAmount,
        address expectedCollateralAsset,
        uint256 expectedCollateral
    ) internal view {
        if (protocolVaultId == 0) revert InvalidAmount();
        Controller ctrl = Controller(addressBook.controller());
        if (ctrl.vaultSettled(address(this), protocolVaultId)) revert CollateralAccountingMismatch();
        MarginVault.Vault memory protocolVault = ctrl.getVault(address(this), protocolVaultId);
        if (
            protocolVault.shortOtoken != expectedOToken || protocolVault.shortAmount != expectedAmount
                || protocolVault.collateralAsset != expectedCollateralAsset
                || protocolVault.collateralAmount != expectedCollateral
        ) {
            revert CollateralAccountingMismatch();
        }
    }

    function _validateStrategyPremium(uint256 collateral, uint256 premiumEarned) internal view {
        address selector = optionSelector;
        if (selector != address(0)) {
            IEthCspOptionSelector(selector).validatePremium(collateral, premiumEarned);
            return;
        }

        uint256 minPremiumBps = strategyConfig.minPremiumBps;
        if (premiumEarned * 10_000 < collateral * minPremiumBps) revert StrategyConstraint();
    }

    function _validateEthUsdcPut(address oTokenAddress) internal view {
        if (oTokenAddress == address(0)) revert InvalidOToken();
        OToken oToken = OToken(oTokenAddress);
        if (
            !oToken.isPut() || oToken.underlying() != address(underlying) || oToken.strikeAsset() != address(usdc)
                || oToken.collateralAsset() != address(usdc)
        ) {
            revert InvalidOToken();
        }
    }
}
