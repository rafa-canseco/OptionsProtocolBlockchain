// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ArcMetaVault is Initializable, UUPSUpgradeable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACC_PREMIUM_PRECISION = 1e18;

    struct Policy {
        bool depositsEnabled;
        bool deploymentsEnabled;
        uint256 minDepositAssets;
        uint256 maxDepositAssets;
    }

    struct WithdrawalRequest {
        uint256 requestedEpoch;
        uint256 shares;
    }

    IERC20 public usdc;
    uint256 public assetToShareScale;

    address public owner;
    address public pendingOwner;
    address public operator;
    address public agent;

    uint64 public epochDuration;
    uint64 public currentEpochStartedAt;
    uint256 public currentEpoch;
    Policy public policy;

    uint256 public totalActiveShares;
    uint256 public totalActivePrincipal;
    uint256 public totalPendingShares;
    uint256 public totalPendingAssets;
    uint256 public totalClaimablePremium;
    uint256 public totalClaimableWithdrawals;
    uint256 public totalLockedWithdrawalShares;
    uint256 public totalDeployedAssets;
    uint256 public totalAccountedAssets;
    uint256 public accPremiumPerShare;

    mapping(address => uint256) public activeShares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public claimablePremium;
    mapping(address => bool) public autoCompound;
    mapping(address => uint256) public lockedWithdrawalShares;
    mapping(address => WithdrawalRequest) public withdrawalRequests;
    mapping(address => uint256) public claimableWithdrawals;
    mapping(address => uint256) public totalPendingSharesOf;
    mapping(uint256 => mapping(address => uint256)) public pendingShares;
    mapping(bytes32 => bool) public processedIntent;

    event DepositQueued(
        address indexed caller,
        address indexed receiver,
        uint256 indexed activationEpoch,
        uint256 assets,
        uint256 shares
    );
    event BridgeDepositFinalized(
        bytes32 indexed intentId,
        address indexed receiver,
        uint256 indexed activationEpoch,
        uint256 assets,
        uint256 shares
    );
    event PendingSharesActivated(address indexed user, uint256 indexed activationEpoch, uint256 assets, uint256 shares);
    event PremiumRecorded(address indexed caller, uint256 indexed epoch, uint256 assets, uint256 accPremiumPerShare);
    event PremiumClaimed(address indexed user, address indexed receiver, uint256 assets);
    event PremiumAutoCompounded(address indexed user, uint256 indexed activationEpoch, uint256 assets, uint256 shares);
    event AutoCompoundUpdated(address indexed user, bool enabled);
    event WithdrawalRequested(address indexed user, uint256 indexed epoch, uint256 shares);
    event WithdrawalProcessed(address indexed user, uint256 indexed epoch, uint256 shares, uint256 assets);
    event WithdrawalClaimed(address indexed user, address indexed receiver, uint256 assets);
    event DeploymentRecorded(
        bytes32 indexed intentId, address indexed destination, uint256 indexed epoch, uint256 assets
    );
    event DeploymentReturnRecorded(bytes32 indexed intentId, uint256 indexed epoch, uint256 assets);
    event EpochStarted(uint256 indexed epoch, uint64 startedAt);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event PolicyUpdated(
        bool depositsEnabled, bool deploymentsEnabled, uint256 minDepositAssets, uint256 maxDepositAssets
    );
    event EpochDurationUpdated(uint64 oldDuration, uint64 newDuration);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidConfig();
    error DepositsDisabled();
    error DeploymentsDisabled();
    error DepositBelowMinimum();
    error DepositAboveMaximum();
    error EpochNotReady();
    error EpochNotMature();
    error IntentAlreadyProcessed();
    error NoActiveShares();
    error NoPendingShares();
    error NoClaimableAmount();
    error NoWithdrawalRequest();
    error InsufficientShares();
    error InsufficientLiquidAssets();
    error InsufficientUnaccountedAssets();
    error OnlyOwner();
    error OnlyPendingOwner();
    error OnlyAgentOrOperator();

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyAgentOrOperator() {
        _checkAgentOrOperator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address usdc_, address initialOwner, address operator_, address agent_, uint64 epochDuration_)
        external
        initializer
    {
        if (usdc_ == address(0) || initialOwner == address(0) || operator_ == address(0) || agent_ == address(0)) {
            revert InvalidAddress();
        }
        if (epochDuration_ == 0) revert InvalidConfig();

        uint8 assetDecimals = IERC20Metadata(usdc_).decimals();
        if (assetDecimals > 18) revert InvalidConfig();

        usdc = IERC20(usdc_);
        assetToShareScale = 10 ** (18 - assetDecimals);
        owner = initialOwner;
        operator = operator_;
        agent = agent_;
        epochDuration = epochDuration_;
        currentEpoch = 1;
        currentEpochStartedAt = uint64(block.timestamp);
        policy = Policy({depositsEnabled: true, deploymentsEnabled: true, minDepositAssets: 0, maxDepositAssets: 0});

        emit EpochStarted(currentEpoch, currentEpochStartedAt);
    }

    function deposit(uint256 assets, address receiver) external whenNotPaused nonReentrant returns (uint256 shares) {
        _validateDeposit(assets, receiver);

        shares = _assetsToShares(assets);
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        totalAccountedAssets += assets;
        _queuePendingShares(receiver, currentEpoch + 1, assets, shares);

        emit DepositQueued(msg.sender, receiver, currentEpoch + 1, assets, shares);
    }

    function finalizeBridgeDeposit(bytes32 intentId, address receiver, uint256 assets)
        external
        onlyAgentOrOperator
        whenNotPaused
        returns (uint256 shares)
    {
        if (intentId == bytes32(0)) revert InvalidConfig();
        _validateDeposit(assets, receiver);
        _markIntentProcessed(intentId);
        _requireUnaccountedAssets(assets);

        shares = _assetsToShares(assets);
        totalAccountedAssets += assets;
        _queuePendingShares(receiver, currentEpoch + 1, assets, shares);

        emit BridgeDepositFinalized(intentId, receiver, currentEpoch + 1, assets, shares);
    }

    function startNextEpoch() external onlyAgentOrOperator {
        if (block.timestamp < currentEpochStartedAt + epochDuration) revert EpochNotReady();

        currentEpoch += 1;
        currentEpochStartedAt = uint64(block.timestamp);

        emit EpochStarted(currentEpoch, currentEpochStartedAt);
    }

    function activatePending(address user, uint256 activationEpoch) external whenNotPaused {
        if (user == address(0)) revert InvalidAddress();
        if (activationEpoch > currentEpoch) revert EpochNotMature();

        uint256 shares = pendingShares[activationEpoch][user];
        if (shares == 0) revert NoPendingShares();

        uint256 assets = _sharesToAssets(shares);
        pendingShares[activationEpoch][user] = 0;
        totalPendingSharesOf[user] -= shares;
        totalPendingShares -= shares;
        totalPendingAssets -= assets;

        _accrue(user);
        activeShares[user] += shares;
        totalActiveShares += shares;
        totalActivePrincipal += assets;
        rewardDebt[user] = _premiumDebt(user);

        emit PendingSharesActivated(user, activationEpoch, assets, shares);
    }

    function recordPremium(uint256 assets) external onlyAgentOrOperator whenNotPaused nonReentrant {
        if (assets == 0) revert InvalidAmount();
        if (totalActiveShares == 0) revert NoActiveShares();

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        totalAccountedAssets += assets;
        accPremiumPerShare += (assets * ACC_PREMIUM_PRECISION) / totalActiveShares;

        emit PremiumRecorded(msg.sender, currentEpoch, assets, accPremiumPerShare);
    }

    function claim(address receiver) external nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert InvalidAddress();

        _accrue(msg.sender);
        assets = claimablePremium[msg.sender];
        if (assets == 0) revert NoClaimableAmount();

        claimablePremium[msg.sender] = 0;
        totalClaimablePremium -= assets;

        if (autoCompound[msg.sender]) {
            uint256 shares = _assetsToShares(assets);
            _queuePendingShares(msg.sender, currentEpoch + 1, assets, shares);
            emit PremiumAutoCompounded(msg.sender, currentEpoch + 1, assets, shares);
        } else {
            totalAccountedAssets -= assets;
            usdc.safeTransfer(receiver, assets);
            emit PremiumClaimed(msg.sender, receiver, assets);
        }
    }

    function requestWithdrawal(uint256 shares) external whenNotPaused {
        if (shares == 0) revert InvalidAmount();

        uint256 available = activeShares[msg.sender] - lockedWithdrawalShares[msg.sender];
        if (shares > available) revert InsufficientShares();

        lockedWithdrawalShares[msg.sender] += shares;
        totalLockedWithdrawalShares += shares;
        withdrawalRequests[msg.sender] =
            WithdrawalRequest({requestedEpoch: currentEpoch, shares: lockedWithdrawalShares[msg.sender]});

        emit WithdrawalRequested(msg.sender, currentEpoch, lockedWithdrawalShares[msg.sender]);
    }

    function processWithdrawal(address user) external onlyAgentOrOperator whenNotPaused returns (uint256 assets) {
        WithdrawalRequest memory request = withdrawalRequests[user];
        if (request.shares == 0) revert NoWithdrawalRequest();

        _accrue(user);

        assets = _sharesToAssets(request.shares);
        activeShares[user] -= request.shares;
        totalActiveShares -= request.shares;
        totalActivePrincipal -= assets;
        lockedWithdrawalShares[user] = 0;
        totalLockedWithdrawalShares -= request.shares;
        delete withdrawalRequests[user];
        rewardDebt[user] = _premiumDebt(user);

        claimableWithdrawals[user] += assets;
        totalClaimableWithdrawals += assets;

        emit WithdrawalProcessed(user, currentEpoch, request.shares, assets);
    }

    function claimWithdrawal(address receiver) external nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert InvalidAddress();

        assets = claimableWithdrawals[msg.sender];
        if (assets == 0) revert NoClaimableAmount();

        claimableWithdrawals[msg.sender] = 0;
        totalClaimableWithdrawals -= assets;
        totalAccountedAssets -= assets;
        usdc.safeTransfer(receiver, assets);

        emit WithdrawalClaimed(msg.sender, receiver, assets);
    }

    function recordDeployment(bytes32 intentId, address destination, uint256 assets)
        external
        onlyAgentOrOperator
        whenNotPaused
        nonReentrant
    {
        if (intentId == bytes32(0)) revert InvalidConfig();
        if (destination == address(0)) revert InvalidAddress();
        if (assets == 0) revert InvalidAmount();
        if (!policy.deploymentsEnabled) revert DeploymentsDisabled();
        _markIntentProcessed(intentId);
        _requireDeployableAssets(assets);

        totalDeployedAssets += assets;
        usdc.safeTransfer(destination, assets);

        emit DeploymentRecorded(intentId, destination, currentEpoch, assets);
    }

    function recordDeploymentReturn(bytes32 intentId, uint256 assets)
        external
        onlyAgentOrOperator
        whenNotPaused
        nonReentrant
    {
        if (intentId == bytes32(0)) revert InvalidConfig();
        if (assets == 0) revert InvalidAmount();
        if (assets > totalDeployedAssets) revert InsufficientLiquidAssets();
        _markIntentProcessed(intentId);
        _requireUnaccountedAssets(assets);

        totalDeployedAssets -= assets;

        emit DeploymentReturnRecorded(intentId, currentEpoch, assets);
    }

    function setAutoCompound(bool enabled) external {
        autoCompound[msg.sender] = enabled;
        emit AutoCompoundUpdated(msg.sender, enabled);
    }

    function setAgent(address newAgent) external onlyOwner {
        if (newAgent == address(0)) revert InvalidAddress();
        emit AgentUpdated(agent, newAgent);
        agent = newAgent;
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setPolicy(Policy calldata newPolicy) external onlyOwner {
        if (newPolicy.maxDepositAssets != 0 && newPolicy.minDepositAssets > newPolicy.maxDepositAssets) {
            revert InvalidConfig();
        }

        policy = newPolicy;
        emit PolicyUpdated(
            newPolicy.depositsEnabled,
            newPolicy.deploymentsEnabled,
            newPolicy.minDepositAssets,
            newPolicy.maxDepositAssets
        );
    }

    function setEpochDuration(uint64 newEpochDuration) external onlyOwner {
        if (newEpochDuration == 0) revert InvalidConfig();
        emit EpochDurationUpdated(epochDuration, newEpochDuration);
        epochDuration = newEpochDuration;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function pendingPremium(address user) public view returns (uint256) {
        uint256 accrued = (activeShares[user] * accPremiumPerShare) / ACC_PREMIUM_PRECISION;
        uint256 debt = rewardDebt[user];
        uint256 pending = accrued > debt ? accrued - debt : 0;
        return claimablePremium[user] + pending;
    }

    function availableShares(address user) external view returns (uint256) {
        return activeShares[user] - lockedWithdrawalShares[user];
    }

    function liquidAssets() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function deployableAssets() public view returns (uint256) {
        uint256 reserved = totalPendingAssets + totalClaimablePremium + totalClaimableWithdrawals
            + _sharesToAssets(totalLockedWithdrawalShares);
        uint256 liquid = liquidAssets();
        return liquid > reserved ? liquid - reserved : 0;
    }

    function accountedAssetsWithDeployments() public view returns (uint256) {
        return liquidAssets() + totalDeployedAssets;
    }

    function _validateDeposit(uint256 assets, address receiver) internal view {
        if (!policy.depositsEnabled) revert DepositsDisabled();
        if (receiver == address(0)) revert InvalidAddress();
        if (assets == 0) revert InvalidAmount();
        if (assets < policy.minDepositAssets) revert DepositBelowMinimum();
        if (policy.maxDepositAssets != 0 && assets > policy.maxDepositAssets) revert DepositAboveMaximum();
    }

    function _queuePendingShares(address receiver, uint256 activationEpoch, uint256 assets, uint256 shares) internal {
        pendingShares[activationEpoch][receiver] += shares;
        totalPendingSharesOf[receiver] += shares;
        totalPendingShares += shares;
        totalPendingAssets += assets;
    }

    function _accrue(address user) internal {
        uint256 pending = pendingPremium(user) - claimablePremium[user];
        if (pending > 0) {
            claimablePremium[user] += pending;
            totalClaimablePremium += pending;
        }
        rewardDebt[user] = _premiumDebt(user);
    }

    function _premiumDebt(address user) internal view returns (uint256) {
        return (activeShares[user] * accPremiumPerShare) / ACC_PREMIUM_PRECISION;
    }

    function _markIntentProcessed(bytes32 intentId) internal {
        if (processedIntent[intentId]) revert IntentAlreadyProcessed();
        processedIntent[intentId] = true;
    }

    function _checkAgentOrOperator() internal view {
        if (msg.sender != agent && msg.sender != operator) revert OnlyAgentOrOperator();
    }

    function _checkOwner() internal view {
        if (msg.sender != owner) revert OnlyOwner();
    }

    function _requireDeployableAssets(uint256 assets) internal view {
        if (assets > deployableAssets()) revert InsufficientLiquidAssets();
    }

    function _requireUnaccountedAssets(uint256 assets) internal view {
        if (accountedAssetsWithDeployments() < totalAccountedAssets + assets) {
            revert InsufficientUnaccountedAssets();
        }
    }

    function _assetsToShares(uint256 assets) internal view returns (uint256) {
        return assets * assetToShareScale;
    }

    function _sharesToAssets(uint256 shares) internal view returns (uint256) {
        return shares / assetToShareScale;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[40] private __gap;
}
