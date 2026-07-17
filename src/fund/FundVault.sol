// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {ClaimEscrow} from "./ClaimEscrow.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {FundVaultStorage} from "./storage/FundVaultStorage.sol";
import {IFundFlowManager} from "./interfaces/IFundFlowManager.sol";
import {IFundAccounting} from "./interfaces/IFundAccounting.sol";
import {IFundShare} from "./interfaces/IFundShare.sol";

interface IFundFlowManagerVault is IFundFlowManager {
    function setOperator(address controller, address operator, bool approved) external;
    function claimableAssets(address controller) external view returns (uint256);
    function consumeClaimAssets(address caller, address controller, uint256 assets) external returns (uint256 shares);
}

/// @notice Transferable ERC-4626 shares and the custody/supply authority for one fund.
contract FundVault is FundUpgradeable, FundVaultStorage {
    using SafeERC20 for IERC20;

    error AsyncPreviewUnsupported();
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);
    error ERC4626ExceededMaxRedeem(address controller, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(address controller, uint256 assets, uint256 max);
    error FundExecutionLocked(address lockOwner);
    error InactiveNavWindow();
    error InvalidModule(address caller);
    error IncompatibleModuleVersion(uint64 expected, uint64 actual);
    error MinimumSharesNotMet(uint256 minimum, uint256 actual);
    error ZeroSharesDeposit(uint256 assets);
    error UnsupportedAccountingAssetDecimals(uint8 decimals);
    error UnaccountedBalance(address asset, uint256 amount);
    error InvalidAddress();
    error InvalidNavCommit();
    error InvalidReportNonce(uint64 expected, uint64 actual);
    error UnsupportedAssetBehavior(address asset);
    error InsufficientIdleAssets(uint256 available, uint256 required);
    error UnauthorizedOperator(address controller, address caller);

    event NavCommitted(uint64 indexed reportNonce, uint256 netAssets, uint64 validAfterBlock, uint64 validUntilBlock);
    event NavInvalidated(bytes32 indexed positionsHash);
    event NavWindowRestored(uint64 indexed reportNonce, uint64 validUntilBlock);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event ClaimReserved(address indexed controller, uint256 shares, uint256 assets);
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata,
        string calldata,
        IERC20 asset_,
        address share_,
        address accounting_,
        address flowManager_,
        address strategyManager_,
        address claimEscrow_,
        address distributionEscrow_,
        address authority_,
        uint64 compatibilityVersion_
    ) external initializer {
        if (
            address(asset_) == address(0) || share_ == address(0) || accounting_ == address(0)
                || flowManager_ == address(0) || strategyManager_ == address(0) || claimEscrow_ == address(0)
                || compatibilityVersion_ == 0
        ) revert InvalidAddress();
        if (IFundShare(share_).vault(address(asset_)) != address(this)) revert InvalidAddress();

        uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
        if (assetDecimals > FundConstants.SHARE_DECIMALS) {
            revert UnsupportedAccountingAssetDecimals(assetDecimals);
        }

        __FundUpgradeable_init(authority_);

        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        $.accountingAsset = address(asset_);
        $.shareToken = share_;
        $.accounting = accounting_;
        $.flowManager = flowManager_;
        $.strategyManager = strategyManager_;
        $.claimEscrow = claimEscrow_;
        $.distributionEscrow = distributionEscrow_;
        $.accountingAssetDecimals = assetDecimals;
        $.shareDecimalsOffset = FundConstants.SHARE_DECIMALS - assetDecimals;
        $.compatibilityVersion = compatibilityVersion_;
        $.positionsHash = FundConstants.INITIAL_POSITIONS_HASH;
    }

    function accounting() external view returns (address) {
        return _getFundVaultStorage().accounting;
    }

    function flowManager() external view returns (address) {
        return _getFundVaultStorage().flowManager;
    }

    function strategyManager() external view returns (address) {
        return _getFundVaultStorage().strategyManager;
    }

    function claimEscrow() external view returns (address) {
        return _getFundVaultStorage().claimEscrow;
    }

    function distributionEscrow() external view returns (address) {
        return _getFundVaultStorage().distributionEscrow;
    }

    function compatibilityVersion() external view returns (uint64) {
        return _getFundVaultStorage().compatibilityVersion;
    }

    function committedNav() external view returns (uint256) {
        return _getFundVaultStorage().committedNav;
    }

    function accountedIdleAssets() external view returns (uint256) {
        return _getFundVaultStorage().accountedIdleAssets;
    }

    function reservedClaimAssets() external view returns (uint256) {
        return _getFundVaultStorage().reservedClaimAssets;
    }

    function fundFlowNonce() external view returns (uint64) {
        return _getFundVaultStorage().fundFlowNonce;
    }

    function idleStateHash() public view returns (bytes32) {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        return _idleStateHash($);
    }

    function virtualShares() external view returns (uint256) {
        return 10 ** _getFundVaultStorage().shareDecimalsOffset;
    }

    function executionLockOwner() external view returns (address) {
        return _getFundVaultStorage().executionLockOwner;
    }

    function depositsPaused() external view returns (bool) {
        return _getFundVaultStorage().depositsPaused;
    }

    function redemptionsPaused() external view returns (bool) {
        return _getFundVaultStorage().redemptionsPaused;
    }

    function share() external view returns (address) {
        return _getFundVaultStorage().shareToken;
    }

    function asset() public view returns (address) {
        return _getFundVaultStorage().accountingAsset;
    }

    function totalAssets() public view returns (uint256) {
        return _getFundVaultStorage().committedNav;
    }

    function decimals() public pure returns (uint8) {
        return FundConstants.SHARE_DECIMALS;
    }

    function shareSupply() public view returns (uint256) {
        return IFundShare(_getFundVaultStorage().shareToken).totalSupply();
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function activeNavWindow() external view returns (FundTypes.NavCommit memory nav) {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        nav.grossAssets = $.committedNav;
        nav.netAssets = $.committedNav;
        nav.liquidAccountingAssets = $.accountedIdleAssets;
        nav.baseExitCost = $.baseExitCost;
        nav.snapshotBlock = $.snapshotBlock;
        nav.validAfterBlock = $.navValidAfterBlock;
        nav.validUntilBlock = $.navValidUntilBlock;
        nav.reporterSetVersion = $.reporterSetVersion;
        nav.reportNonce = $.reportNonce;
        nav.positionsHash = $.positionsHash;
        nav.reportHash = $.reportHash;
        nav.signaturesHash = $.signaturesHash;
        nav.fundFlowNonce = $.acceptedFlowNonce;
        nav.idleStateHash = $.acceptedIdleStateHash;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == FundConstants.ERC7540_OPERATOR_INTERFACE_ID
            || interfaceId == FundConstants.ERC7540_REDEEM_INTERFACE_ID
            || interfaceId == FundConstants.ERC7575_VAULT_INTERFACE_ID
            || interfaceId == FundConstants.ERC165_INTERFACE_ID;
    }

    function maxDeposit(address) public view returns (uint256) {
        return _creationOpen() ? type(uint256).max : 0;
    }

    function maxMint(address) public view returns (uint256) {
        return _creationOpen() ? type(uint256).max : 0;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    function depositWithMinShares(uint256 assets, address receiver, uint256 minSharesOut)
        external
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver);
        if (shares < minSharesOut) revert MinimumSharesNotMet(minSharesOut, shares);
    }

    function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
        _accrueManagementFee();
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        _accrueManagementFee();
        uint256 maxShares = maxMint(receiver);
        if (shares > maxShares) revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
    }

    function isOperator(address controller, address operator) public view returns (bool) {
        return IFundFlowManagerVault(_getFundVaultStorage().flowManager).isOperator(controller, operator);
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        _requireUnlocked();
        IFundFlowManagerVault(_getFundVaultStorage().flowManager).setOperator(msg.sender, operator, approved);
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        return _requestRedeem(shares, controller, owner, 0);
    }

    function requestRedeemWithMinAssets(uint256 shares, address controller, address owner, uint256 minAssetsOut)
        external
        returns (uint256 requestId)
    {
        return _requestRedeem(shares, controller, owner, minAssetsOut);
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return IFundFlowManagerVault(_getFundVaultStorage().flowManager).pendingRedeemRequest(requestId, controller);
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return IFundFlowManagerVault(_getFundVaultStorage().flowManager).claimableRedeemRequest(requestId, controller);
    }

    function cancelPending(uint256 shares) external {
        _requireUnlocked();
        IFundFlowManagerVault(_getFundVaultStorage().flowManager).cancelPending(msg.sender, msg.sender, shares);
    }

    function cancelRedeemRequest(address controller, uint256 shares) external {
        _requireUnlocked();
        IFundFlowManagerVault(_getFundVaultStorage().flowManager).cancelPending(msg.sender, controller, shares);
    }

    function maxRedeem(address controller) public view returns (uint256) {
        return IFundFlowManagerVault(_getFundVaultStorage().flowManager)
            .claimableRedeemRequest(FundConstants.ERC7540_REQUEST_ID, controller);
    }

    function maxWithdraw(address controller) public view returns (uint256) {
        return IFundFlowManagerVault(_getFundVaultStorage().flowManager).claimableAssets(controller);
    }

    function previewRedeem(uint256) public pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function previewWithdraw(uint256) public pure returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function redeem(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        _requireController(controller);
        uint256 available = maxRedeem(controller);
        if (shares == 0 || shares > available) revert ERC4626ExceededMaxRedeem(controller, shares, available);

        assets = IFundFlowManagerVault(_getFundVaultStorage().flowManager).consumeClaim(msg.sender, controller, shares);
        _releaseClaim(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _requireController(controller);
        uint256 availableAssets = maxWithdraw(controller);
        if (assets == 0 || assets > availableAssets) {
            revert ERC4626ExceededMaxWithdraw(controller, assets, availableAssets);
        }
        shares = IFundFlowManagerVault(_getFundVaultStorage().flowManager)
            .consumeClaimAssets(msg.sender, controller, assets);
        _releaseClaim(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function commitNav(FundTypes.NavCommit calldata nav, uint256 feeShares, address feeRecipient) external {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        _requireLockedModule($.accounting);
        uint64 expectedNonce = $.reportNonce + 1;
        if (
            nav.reportNonce != expectedNonce || nav.positionsHash != $.positionsHash
                || nav.liabilities > nav.grossAssets || nav.netAssets != nav.grossAssets - nav.liabilities
                || nav.validAfterBlock <= nav.snapshotBlock || nav.validUntilBlock <= nav.validAfterBlock
        ) {
            if (nav.reportNonce != expectedNonce) revert InvalidReportNonce(expectedNonce, nav.reportNonce);
            revert InvalidNavCommit();
        }
        if (feeShares != 0 && (feeRecipient == address(0) || (shareSupply() != 0 && nav.netAssets == 0))) {
            revert InvalidNavCommit();
        }

        uint256 rawIdle = IERC20($.accountingAsset).balanceOf(address(this));
        if (nav.fundFlowNonce != $.fundFlowNonce || nav.idleStateHash != _idleStateHash($)) {
            revert InvalidNavCommit();
        }
        $.committedNav = nav.netAssets;
        $.accountedIdleAssets = rawIdle;
        $.baseExitCost = nav.baseExitCost;
        $.unaccountedBalances[$.accountingAsset] = 0;
        $.positionsHash = nav.positionsHash;
        $.reportHash = nav.reportHash;
        $.signaturesHash = nav.signaturesHash;
        $.snapshotBlock = nav.snapshotBlock;
        $.navValidAfterBlock = nav.validAfterBlock;
        $.navValidUntilBlock = nav.validUntilBlock;
        $.reporterSetVersion = nav.reporterSetVersion;
        $.reportNonce = nav.reportNonce;
        $.acceptedFlowNonce = nav.fundFlowNonce;
        $.acceptedIdleStateHash = nav.idleStateHash;
        ++$.fundFlowNonce;
        if (feeShares != 0) IFundShare($.shareToken).mint(feeRecipient, feeShares);

        emit NavCommitted(nav.reportNonce, nav.netAssets, nav.validAfterBlock, nav.validUntilBlock);
    }

    function escrowShares(address owner, address spender, uint256 shares) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().flowManager);
        if (owner == address(0) || spender == address(0) || shares == 0) revert InvalidAddress();
        IFundShare($.shareToken).escrowShares(owner, spender, shares);
    }

    function returnEscrowedShares(address receiver, uint256 shares) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().flowManager);
        if (receiver == address(0) || shares == 0) revert InvalidAddress();
        IFundShare($.shareToken).returnEscrowedShares(receiver, shares);
    }

    function reserveAccountingAssets(uint256 assets) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().flowManager);
        if (assets > $.accountedIdleAssets || assets > $.committedNav) {
            revert InsufficientIdleAssets($.accountedIdleAssets, assets);
        }
        IERC20 token = IERC20($.accountingAsset);
        uint256 beforeBalance = token.balanceOf($.claimEscrow);
        token.safeTransfer($.claimEscrow, assets);
        if (token.balanceOf($.claimEscrow) - beforeBalance != assets) {
            revert UnsupportedAssetBehavior($.accountingAsset);
        }
        $.accountedIdleAssets -= assets;
        $.committedNav -= assets;
        $.reservedClaimAssets += assets;
        ++$.fundFlowNonce;
    }

    function processAccountingAssetClaim(address controller, uint256 shares, uint256 assets) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().flowManager);
        if (controller == address(0) || shares == 0 || assets > $.reservedClaimAssets) revert InvalidNavCommit();
        IFundShare($.shareToken).burn(address(this), shares);
        ++$.fundFlowNonce;
        emit ClaimReserved(controller, shares, assets);
    }

    function releaseClaimReserve(uint256 assets) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().flowManager);
        if (assets > $.reservedClaimAssets) revert InvalidNavCommit();
        $.reservedClaimAssets -= assets;
        ++$.fundFlowNonce;
    }

    function mintFeeShares(uint256 shares, address recipient) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().accounting);
        if (shares == 0 || recipient == address(0) || (shareSupply() != 0 && $.committedNav == 0)) {
            revert InvalidNavCommit();
        }
        IFundShare($.shareToken).mint(recipient, shares);
        ++$.fundFlowNonce;
    }

    function transferToStrategy(address asset_, address adapter, uint256 amount) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().strategyManager);
        if (asset_ != $.accountingAsset || adapter == address(0) || amount > $.accountedIdleAssets) {
            revert InsufficientIdleAssets($.accountedIdleAssets, amount);
        }
        IERC20 token = IERC20(asset_);
        uint256 vaultBefore = token.balanceOf(address(this));
        uint256 adapterBefore = token.balanceOf(adapter);
        token.safeTransfer(adapter, amount);
        if (
            vaultBefore - token.balanceOf(address(this)) != amount || token.balanceOf(adapter) - adapterBefore != amount
        ) {
            revert UnsupportedAssetBehavior(asset_);
        }
        $.accountedIdleAssets -= amount;
        ++$.fundFlowNonce;
    }

    function recordStrategyReturn(address asset_, uint256 balanceBefore) external returns (uint256 received) {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().strategyManager);
        if (asset_ != $.accountingAsset) revert UnsupportedAssetBehavior(asset_);
        uint256 currentBalance = IERC20(asset_).balanceOf(address(this));
        if (currentBalance < balanceBefore) revert UnsupportedAssetBehavior(asset_);
        received = currentBalance - balanceBefore;
        $.accountedIdleAssets += received;
        ++$.fundFlowNonce;
    }

    function invalidateNav() external {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        address caller = msg.sender;
        if (caller != $.strategyManager && caller != $.flowManager) revert InvalidModule(caller);
        _requireLockedModule(caller);
        $.navValidUntilBlock = block.number == 0 ? 0 : uint64(block.number - 1);
        emit NavInvalidated($.positionsHash);
    }

    function restoreNavWindow(uint64 reportNonce, uint64 validUntilBlock, bytes32 positionsHash) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().flowManager);
        if (
            $.reportNonce == reportNonce && $.positionsHash == positionsHash && block.number <= validUntilBlock
                && validUntilBlock > $.navValidUntilBlock
        ) {
            $.navValidUntilBlock = validUntilBlock;
            emit NavWindowRestored(reportNonce, validUntilBlock);
        }
    }

    function recordStrategyPositions(bytes32 positionsHash_) external {
        FundVaultStorageLayout storage $ = _requireLockedModule(_getFundVaultStorage().strategyManager);
        $.positionsHash = positionsHash_;
    }

    function beginModuleExecution(uint64 moduleVersion) external returns (uint256 lockId) {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        if (msg.sender != $.accounting && msg.sender != $.flowManager && msg.sender != $.strategyManager) {
            revert InvalidModule(msg.sender);
        }
        if ($.compatibilityVersion != moduleVersion) {
            revert IncompatibleModuleVersion($.compatibilityVersion, moduleVersion);
        }
        if ($.executionLockOwner != address(0)) revert FundExecutionLocked($.executionLockOwner);
        $.executionLockOwner = msg.sender;
        lockId = ++$.executionLockNonce;
    }

    function endModuleExecution(uint256 lockId) external {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        if (msg.sender != $.executionLockOwner || lockId != $.executionLockNonce) revert InvalidModule(msg.sender);
        $.executionLockOwner = address(0);
    }

    function pauseDeposits() external restricted {
        _getFundVaultStorage().depositsPaused = true;
    }

    function pauseRedemptions() external restricted {
        _getFundVaultStorage().redemptionsPaused = true;
    }

    function resumeDeposits() external restricted {
        _getFundVaultStorage().depositsPaused = false;
    }

    function resumeRedemptions() external restricted {
        _getFundVaultStorage().redemptionsPaused = false;
    }

    function unaccountedBalance(address asset_) public view returns (uint256) {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        if (asset_ != $.accountingAsset) return $.unaccountedBalances[asset_];
        uint256 rawBalance = IERC20(asset_).balanceOf(address(this));
        return rawBalance > $.accountedIdleAssets ? rawBalance - $.accountedIdleAssets : 0;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) private {
        if (!_creationOpen()) revert InactiveNavWindow();
        if (assets != 0 && shares == 0) revert ZeroSharesDeposit(assets);
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        _enterUserExecution();
        IERC20 token = IERC20($.accountingAsset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(caller, address(this), assets);
        if (token.balanceOf(address(this)) - beforeBalance != assets) {
            revert UnsupportedAssetBehavior($.accountingAsset);
        }
        IFundShare($.shareToken).mint(receiver, shares);
        $.accountedIdleAssets += assets;
        $.committedNav += assets;
        ++$.fundFlowNonce;
        emit Deposit(caller, receiver, assets, shares);
        _exitUserExecution();
    }

    function _requestRedeem(uint256 shares, address controller, address owner, uint256 minAssetsOut)
        private
        returns (uint256 requestId)
    {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        _requireUnlocked();
        if ($.redemptionsPaused || shares == 0 || controller == address(0) || owner == address(0)) {
            revert UnauthorizedOperator(controller, msg.sender);
        }
        address shareSpender = _shareSpender(controller, owner);

        requestId = IFundFlowManagerVault($.flowManager)
            .recordRedeemRequest(msg.sender, shareSpender, shares, controller, owner, minAssetsOut);
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    function _releaseClaim(address receiver, uint256 assets) private {
        if (receiver == address(0)) revert InvalidAddress();
        _enterUserExecution();
        ClaimEscrow(_getFundVaultStorage().claimEscrow).release(receiver, assets);
        _exitUserExecution();
    }

    function _requireController(address controller) private view {
        if (msg.sender != controller && !isOperator(controller, msg.sender)) {
            revert UnauthorizedOperator(controller, msg.sender);
        }
    }

    function _creationOpen() private view returns (bool) {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        if ($.depositsPaused || $.executionLockOwner != address(0)) return false;
        if (block.number < $.navValidAfterBlock || block.number > $.navValidUntilBlock) return false;
        if (shareSupply() != 0 && $.committedNav == 0) return false;
        return IERC20($.accountingAsset).balanceOf(address(this)) >= $.accountedIdleAssets;
    }

    function _requireUnlocked() private view {
        address owner = _getFundVaultStorage().executionLockOwner;
        if (owner != address(0)) revert FundExecutionLocked(owner);
    }

    function _enterUserExecution() private {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        if ($.executionLockOwner != address(0)) revert FundExecutionLocked($.executionLockOwner);
        $.executionLockOwner = address(this);
        ++$.executionLockNonce;
    }

    function _exitUserExecution() private {
        _getFundVaultStorage().executionLockOwner = address(0);
    }

    function _requireLockedModule(address module) private view returns (FundVaultStorageLayout storage $) {
        $ = _getFundVaultStorage();
        if (msg.sender != module || $.executionLockOwner != module) revert InvalidModule(msg.sender);
    }

    function _accrueManagementFee() private {
        IFundAccounting(_getFundVaultStorage().accounting).accrueManagementFee();
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) private view returns (uint256) {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        return Math.mulDiv(assets, shareSupply() + 10 ** $.shareDecimalsOffset, totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) private view returns (uint256) {
        FundVaultStorageLayout storage $ = _getFundVaultStorage();
        return Math.mulDiv(shares, totalAssets() + 1, shareSupply() + 10 ** $.shareDecimalsOffset, rounding);
    }

    function _shareSpender(address controller, address owner) private view returns (address) {
        if (msg.sender == owner || (controller == owner && isOperator(controller, msg.sender))) {
            return owner;
        }
        return msg.sender;
    }

    function _idleStateHash(FundVaultStorageLayout storage $) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                address(this),
                block.chainid,
                $.fundFlowNonce,
                $.accountedIdleAssets,
                IERC20($.accountingAsset).balanceOf(address(this))
            )
        );
    }
}
