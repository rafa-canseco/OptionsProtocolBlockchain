// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {FundMath} from "./libraries/FundMath.sol";
import {FundFlowManagerStorage} from "./storage/FundFlowManagerStorage.sol";
import {IFundFlowManager} from "./interfaces/IFundFlowManager.sol";
import {IFundVault} from "./interfaces/IFundVault.sol";
import {IFundVaultModuleCallbacks} from "./interfaces/IFundModuleCallbacks.sol";
import {IFundAccounting} from "./interfaces/IFundAccounting.sol";

interface IFundVaultFlow is IFundVault, IFundVaultModuleCallbacks {
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function redemptionsPaused() external view returns (bool);
    function asset() external view returns (address);
}

/// @notice Authoritative accounting-asset redemption request and claim state machine.
contract FundFlowManager is FundUpgradeable, FundFlowManagerStorage, IFundFlowManager {
    error InvalidAddress();
    error InvalidExitPolicy();

    event RedeemBatchSealed(uint64 indexed batchId, uint256 pendingShares);
    event RedeemBatchStarted(
        uint64 indexed batchId, uint256 shares, uint256 processingNav, uint256 reservedAssets, uint256 marginalExitCost
    );
    event RedeemBatchProcessed(uint64 indexed batchId, uint16 controllers, bool roundComplete);
    event ClaimConsumed(address indexed controller, uint256 shares, uint256 assets);
    event PendingCancelled(address indexed controller, uint256 shares);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address fund_, address claimEscrow_, address authority_, uint64 compatibilityVersion_)
        external
        initializer
    {
        if (fund_ == address(0) || claimEscrow_ == address(0) || compatibilityVersion_ == 0) {
            revert InvalidAddress();
        }
        __FundUpgradeable_init(authority_);
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        $.fund = fund_;
        $.claimEscrow = claimEscrow_;
        $.compatibilityVersion = compatibilityVersion_;
        $.nextProcessBatchId = 1;
        $.openBatchId = 1;
        $.maxExitFeeBps = 0;
        $.maxWindowOutflowBps = uint16(FundConstants.BPS);
    }

    function fund() external view returns (address) {
        return _getFundFlowManagerStorage().fund;
    }

    function compatibilityVersion() external view returns (uint64) {
        return _getFundFlowManagerStorage().compatibilityVersion;
    }

    function nextProcessBatchId() external view returns (uint64) {
        return _getFundFlowManagerStorage().nextProcessBatchId;
    }

    function openBatchId() external view returns (uint64) {
        return _getFundFlowManagerStorage().openBatchId;
    }

    function totalPendingShares() external view returns (uint256) {
        return _getFundFlowManagerStorage().totalPendingShares;
    }

    function totalClaimableShares() external view returns (uint256) {
        return _getFundFlowManagerStorage().totalClaimableShares;
    }

    function totalReservedAssets() external view returns (uint256) {
        return _getFundFlowManagerStorage().totalReservedAssets;
    }

    function hasActiveProcessing() external view returns (bool) {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        return $.batches[$.nextProcessBatchId].processing;
    }

    function exitPolicy() external view returns (uint16 maxExitFeeBps, uint16 maxWindowOutflowBps) {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        return ($.maxExitFeeBps, $.maxWindowOutflowBps);
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return requestId == FundConstants.ERC7540_REQUEST_ID
            ? _getFundFlowManagerStorage().redemptions[controller].pendingShares
            : 0;
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return requestId == FundConstants.ERC7540_REQUEST_ID
            ? _getFundFlowManagerStorage().redemptions[controller].claimableShares
            : 0;
    }

    function claimableAssets(address controller) external view returns (uint256) {
        return _getFundFlowManagerStorage().redemptions[controller].claimableAssets;
    }

    function pendingMinimumAssets(address controller) external view returns (uint256) {
        return _getFundFlowManagerStorage().redemptions[controller].pendingMinAssetsOut;
    }

    function isOperator(address controller, address operator) external view returns (bool) {
        return _getFundFlowManagerStorage().operators[controller][operator];
    }

    function setOperator(address controller, address operator, bool approved) external {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        if (msg.sender != $.fund || controller == address(0) || operator == address(0)) revert InvalidAddress();
        $.operators[controller][operator] = approved;
    }

    function recordRedeemRequest(
        address caller,
        uint256 shares,
        address controller,
        address owner,
        uint256 minAssetsOut
    ) external returns (uint256 requestId) {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        if (
            msg.sender != $.fund || caller == address(0) || shares == 0 || controller == address(0)
                || owner == address(0)
        ) revert UnauthorizedOperator(controller, caller);

        uint64 existingBatchId = $.redemptions[controller].latestBatchId;
        if ($.redemptions[controller].pendingShares != 0 && existingBatchId != 0 && existingBatchId != $.openBatchId) {
            revert PendingRequestInSealedBatch(controller, existingBatchId);
        }

        FundTypes.RedemptionBatch storage redeemBatch = $.batches[$.openBatchId];
        FundTypes.RedemptionAccount storage account = $.batchAccounts[$.openBatchId][controller];
        if (account.indexPlusOne == 0) {
            address[] storage controllers = $.batchControllers[$.openBatchId];
            if (controllers.length == FundConstants.MAX_BATCH_CONTROLLERS) {
                revert BatchCapacityExceeded($.openBatchId);
            }
            controllers.push(controller);
            account.indexPlusOne = uint16(controllers.length);
            account.refundOwner = owner;
            $.redemptions[controller].latestBatchId = $.openBatchId;
        } else if (account.refundOwner != owner) {
            revert RequestOwnerMismatch(controller, account.refundOwner, owner);
        }

        account.pendingShares += shares;
        account.pendingMinAssetsOut += minAssetsOut;
        redeemBatch.totalPendingShares += shares;
        redeemBatch.mode = FundTypes.RequestMode.AccountingAsset;
        FundTypes.RedemptionState storage state = $.redemptions[controller];
        state.pendingShares += shares;
        state.pendingMinAssetsOut += minAssetsOut;
        $.totalPendingShares += shares;

        uint256 lockId = IFundVaultFlow($.fund).beginModuleExecution($.compatibilityVersion);
        IFundVaultFlow($.fund).escrowShares(owner, shares);
        IFundVaultFlow($.fund).endModuleExecution(lockId);
        return FundConstants.ERC7540_REQUEST_ID;
    }

    function cancelPending(address caller, address controller, uint256 shares) external {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        if (msg.sender != $.fund) revert InvalidAddress();
        if (caller != controller && !$.operators[controller][caller]) revert UnauthorizedOperator(controller, caller);

        FundTypes.RedemptionState storage state = $.redemptions[controller];
        uint64 batchId = state.latestBatchId;
        FundTypes.RedemptionBatch storage redeemBatch = $.batches[batchId];
        FundTypes.RedemptionAccount storage account = $.batchAccounts[batchId][controller];
        if (
            shares == 0 || shares > account.pendingShares || state.claimableShares != 0 || redeemBatch.processing
                || redeemBatch.unwindCommitted
        ) revert RequestNotCancelable();

        address refundOwner = account.refundOwner;
        uint256 minReduction = Math.mulDiv(account.pendingMinAssetsOut, shares, account.pendingShares);
        account.pendingShares -= shares;
        account.pendingMinAssetsOut -= minReduction;
        redeemBatch.totalPendingShares -= shares;
        state.pendingShares -= shares;
        state.pendingMinAssetsOut -= minReduction;
        $.totalPendingShares -= shares;
        if (account.pendingShares == 0) {
            _removeBatchController($, batchId, controller);
            state.latestBatchId = 0;
        }
        if (redeemBatch.isSealed && redeemBatch.totalPendingShares == 0 && batchId == $.nextProcessBatchId) {
            _releaseBatch($, batchId);
        }

        uint256 lockId = IFundVaultFlow($.fund).beginModuleExecution($.compatibilityVersion);
        IFundVaultFlow($.fund).returnEscrowedShares(refundOwner, shares);
        IFundVaultFlow($.fund).endModuleExecution(lockId);
        emit PendingCancelled(controller, shares);
    }

    function sealRedeemBatch(uint64 batchId) external restricted {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        FundTypes.RedemptionBatch storage redeemBatch = $.batches[batchId];
        if (batchId != $.openBatchId || redeemBatch.isSealed || redeemBatch.totalPendingShares == 0) {
            revert BatchNotProcessable(batchId);
        }
        uint256 lockId = IFundVaultFlow($.fund).beginModuleExecution($.compatibilityVersion);
        redeemBatch.isSealed = true;
        $.openBatchId = batchId + 1;
        IFundVaultFlow($.fund).endModuleExecution(lockId);
        emit RedeemBatchSealed(batchId, redeemBatch.totalPendingShares);
    }

    function releaseRedeemBatch(uint64 batchId) external restricted {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        FundTypes.RedemptionBatch storage redeemBatch = $.batches[batchId];
        if (
            batchId != $.nextProcessBatchId || !redeemBatch.isSealed || redeemBatch.isReleased || redeemBatch.processing
                || redeemBatch.unwindCommitted
        ) revert BatchNotReleasable(batchId);
        uint256 lockId = IFundVaultFlow($.fund).beginModuleExecution($.compatibilityVersion);
        _releaseBatch($, batchId);
        IFundVaultFlow($.fund).endModuleExecution(lockId);
    }

    function startRedeemBatch(uint64 batchId, uint256 shares, uint256 marginalExitCost) external restricted {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        IFundVaultFlow vault = IFundVaultFlow($.fund);
        IFundAccounting(vault.accounting()).accrueManagementFee();
        FundTypes.RedemptionBatch storage redeemBatch = $.batches[batchId];
        if (
            batchId != $.nextProcessBatchId || !redeemBatch.isSealed || redeemBatch.isReleased || redeemBatch.processing
                || shares == 0 || shares > redeemBatch.totalPendingShares || vault.redemptionsPaused()
                || IERC20(vault.asset()).balanceOf($.fund) < vault.accountedIdleAssets()
        ) revert BatchNotProcessable(batchId);

        FundTypes.NavCommit memory nav = vault.activeNavWindow();
        if (block.number < nav.validAfterBlock || block.number > nav.validUntilBlock) {
            revert BatchNotProcessable(batchId);
        }
        uint256 processingNav = vault.totalAssets();
        uint256 eligibleSupply = vault.totalSupply();
        if (
            eligibleSupply == 0 || processingNav == 0
                || shares > Math.mulDiv(eligibleSupply, $.maxWindowOutflowBps, FundConstants.BPS)
                || (redeemBatch.processedShares != 0 && nav.reportNonce <= redeemBatch.processingReportNonce)
        ) revert BatchNotProcessable(batchId);

        uint256 authorizedExitCost = Math.mulDiv(nav.baseExitCost, shares, eligibleSupply, Math.Rounding.Ceil);
        if (marginalExitCost != authorizedExitCost) {
            revert InvalidMarginalExitCost(authorizedExitCost, marginalExitCost);
        }
        (, uint256 roundAssetBudget,) = FundMath.redemptionPayout(
            shares,
            processingNav,
            eligibleSupply,
            vault.virtualShares(),
            FundConstants.VIRTUAL_ASSETS,
            marginalExitCost,
            $.maxExitFeeBps
        );
        _validateBatchMinimums($, batchId, shares, redeemBatch.totalPendingShares, roundAssetBudget);

        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.invalidateNav();
        vault.reserveAccountingAssets(roundAssetBudget);

        redeemBatch.processing = true;
        redeemBatch.unwindCommitted = true;
        redeemBatch.processingNav = processingNav;
        redeemBatch.eligibleSupply = eligibleSupply;
        redeemBatch.roundPendingShares = redeemBatch.totalPendingShares;
        redeemBatch.roundTargetShares = shares;
        redeemBatch.roundCumulativeShares = 0;
        redeemBatch.roundAllocatedShares = 0;
        redeemBatch.roundAssetBudget = roundAssetBudget;
        redeemBatch.roundAllocatedAssets = 0;
        redeemBatch.processingPositionsHash = nav.positionsHash;
        redeemBatch.processingBlock = uint64(block.number);
        redeemBatch.processingReportNonce = nav.reportNonce;
        redeemBatch.processingValidUntilBlock = nav.validUntilBlock;
        redeemBatch.processingCursor = 0;
        redeemBatch.marginalExitCost = marginalExitCost;
        redeemBatch.reservedAssets += roundAssetBudget;
        $.totalReservedAssets += roundAssetBudget;

        vault.endModuleExecution(lockId);
        emit RedeemBatchStarted(batchId, shares, processingNav, roundAssetBudget, marginalExitCost);
    }

    function processRedeemBatch(uint64 batchId, uint16 maxControllers)
        external
        restricted
        returns (uint16 processedControllers, bool roundComplete)
    {
        if (maxControllers == 0 || maxControllers > FundConstants.MAX_PROCESSING_PAGE) {
            revert InvalidProcessingPage(maxControllers, FundConstants.MAX_PROCESSING_PAGE);
        }
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        FundTypes.RedemptionBatch storage redeemBatch = $.batches[batchId];
        if (!redeemBatch.processing || batchId != $.nextProcessBatchId) revert BatchNotProcessable(batchId);

        IFundVaultFlow vault = IFundVaultFlow($.fund);
        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        address[] storage controllers = $.batchControllers[batchId];
        uint256 end = Math.min(uint256(redeemBatch.processingCursor) + maxControllers, controllers.length);
        for (uint256 i = redeemBatch.processingCursor; i < end; ++i) {
            address controller = controllers[i];
            FundTypes.RedemptionAccount storage account = $.batchAccounts[batchId][controller];
            uint256 accountShares = account.pendingShares;
            uint256 newCumulativeShares = redeemBatch.roundCumulativeShares + accountShares;
            uint256 newAllocatedShares =
                Math.mulDiv(newCumulativeShares, redeemBatch.roundTargetShares, redeemBatch.roundPendingShares);
            uint256 allocatedShares = newAllocatedShares - redeemBatch.roundAllocatedShares;

            if (allocatedShares != 0) {
                uint256 minimumAssets =
                    Math.mulDiv(account.pendingMinAssetsOut, allocatedShares, accountShares, Math.Rounding.Ceil);
                uint256 assets = _processedAssets(redeemBatch, redeemBatch.roundAllocatedShares, newAllocatedShares);
                account.pendingShares -= allocatedShares;
                account.pendingMinAssetsOut -= minimumAssets;
                FundTypes.RedemptionState storage state = $.redemptions[controller];
                state.pendingShares -= allocatedShares;
                state.pendingMinAssetsOut -= minimumAssets;
                state.claimableShares += allocatedShares;
                state.claimableAssets += assets;
                $.totalPendingShares -= allocatedShares;
                $.totalClaimableShares += allocatedShares;
                redeemBatch.roundAllocatedAssets += assets;
                if (account.pendingShares == 0) state.latestBatchId = 0;
                vault.processAccountingAssetClaim(controller, allocatedShares, assets);
            }
            redeemBatch.roundCumulativeShares = newCumulativeShares;
            redeemBatch.roundAllocatedShares = newAllocatedShares;
            ++processedControllers;
        }

        redeemBatch.processingCursor = uint16(end);
        if (end == controllers.length) {
            if (
                redeemBatch.roundAllocatedShares != redeemBatch.roundTargetShares
                    || redeemBatch.roundAllocatedAssets != redeemBatch.roundAssetBudget
            ) revert BatchNotProcessable(batchId);
            redeemBatch.totalPendingShares -= redeemBatch.roundTargetShares;
            redeemBatch.processedShares += redeemBatch.roundTargetShares;
            redeemBatch.processing = false;
            redeemBatch.unwindCommitted = false;
            if (redeemBatch.totalPendingShares == 0) $.nextProcessBatchId = batchId + 1;
            vault.restoreNavWindow(
                redeemBatch.processingReportNonce,
                redeemBatch.processingValidUntilBlock,
                redeemBatch.processingPositionsHash
            );
            roundComplete = true;
        }
        vault.endModuleExecution(lockId);
        emit RedeemBatchProcessed(batchId, processedControllers, roundComplete);
    }

    function consumeClaim(address caller, address controller, uint256 shares) external returns (uint256 assets) {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        if (msg.sender != $.fund) revert InvalidAddress();
        if (caller != controller && !$.operators[controller][caller]) revert UnauthorizedOperator(controller, caller);
        FundTypes.RedemptionState storage state = $.redemptions[controller];
        uint256 availableShares = state.claimableShares;
        if (shares == 0 || shares > availableShares) revert ClaimExceedsAvailable();

        assets = Math.mulDiv(state.claimableAssets, shares, availableShares);
        _consumeClaim($, controller, shares, assets);
    }

    function consumeClaimAssets(address caller, address controller, uint256 assets) external returns (uint256 shares) {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        if (msg.sender != $.fund) revert InvalidAddress();
        if (caller != controller && !$.operators[controller][caller]) revert UnauthorizedOperator(controller, caller);
        FundTypes.RedemptionState storage state = $.redemptions[controller];
        uint256 availableAssets = state.claimableAssets;
        if (assets == 0 || assets > availableAssets) revert ClaimExceedsAvailable();

        shares = Math.mulDiv(state.claimableShares, assets, availableAssets, Math.Rounding.Ceil);
        _consumeClaim($, controller, shares, assets);
    }

    function _consumeClaim(FundFlowManagerStorageLayout storage $, address controller, uint256 shares, uint256 assets)
        private
    {
        FundTypes.RedemptionState storage state = $.redemptions[controller];
        state.claimableShares -= shares;
        state.claimableAssets -= assets;
        $.totalClaimableShares -= shares;
        $.totalReservedAssets -= assets;

        IFundVaultFlow vault = IFundVaultFlow($.fund);
        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.releaseClaimReserve(assets);
        vault.endModuleExecution(lockId);
        emit ClaimConsumed(controller, shares, assets);
    }

    function setExitPolicy(uint16 maxExitFeeBps, uint16 maxWindowOutflowBps) external restricted {
        if (maxExitFeeBps > FundConstants.BPS || maxWindowOutflowBps == 0 || maxWindowOutflowBps > FundConstants.BPS) {
            revert InvalidExitPolicy();
        }
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        $.maxExitFeeBps = maxExitFeeBps;
        $.maxWindowOutflowBps = maxWindowOutflowBps;
    }

    function batch(uint64 batchId) external view returns (FundTypes.RedemptionBatch memory) {
        return _getFundFlowManagerStorage().batches[batchId];
    }

    function batchParticipantCount(uint64 batchId) external view returns (uint256) {
        return _getFundFlowManagerStorage().batchControllers[batchId].length;
    }

    function batchController(uint64 batchId, uint256 index) external view returns (address) {
        return _getFundFlowManagerStorage().batchControllers[batchId][index];
    }

    function isCancellationAvailable(address controller) external view returns (bool) {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        FundTypes.RedemptionState storage state = $.redemptions[controller];
        FundTypes.RedemptionBatch storage redeemBatch = $.batches[state.latestBatchId];
        return state.pendingShares != 0 && state.claimableShares == 0 && !redeemBatch.processing
            && !redeemBatch.unwindCommitted;
    }

    function _releaseBatch(FundFlowManagerStorageLayout storage $, uint64 batchId) private {
        $.batches[batchId].isReleased = true;
        $.nextProcessBatchId = batchId + 1;
        emit RedeemBatchReleased(batchId);
    }

    function _removeBatchController(FundFlowManagerStorageLayout storage $, uint64 batchId, address controller)
        private
    {
        FundTypes.RedemptionAccount storage account = $.batchAccounts[batchId][controller];
        uint256 index = account.indexPlusOne - 1;
        address[] storage controllers = $.batchControllers[batchId];
        uint256 lastIndex = controllers.length - 1;
        if (index != lastIndex) {
            address moved = controllers[lastIndex];
            controllers[index] = moved;
            $.batchAccounts[batchId][moved].indexPlusOne = uint16(index + 1);
        }
        controllers.pop();
        delete $.batchAccounts[batchId][controller];
    }

    function _validateBatchMinimums(
        FundFlowManagerStorageLayout storage $,
        uint64 batchId,
        uint256 roundTargetShares,
        uint256 roundPendingShares,
        uint256 roundAssetBudget
    ) private view {
        address[] storage controllers = $.batchControllers[batchId];
        uint256 cumulativeShares;
        uint256 allocatedShares;
        for (uint256 i; i < controllers.length; ++i) {
            address controller = controllers[i];
            FundTypes.RedemptionAccount storage account = $.batchAccounts[batchId][controller];
            cumulativeShares += account.pendingShares;
            uint256 newAllocatedShares = Math.mulDiv(cumulativeShares, roundTargetShares, roundPendingShares);
            uint256 controllerShares = newAllocatedShares - allocatedShares;
            if (controllerShares != 0) {
                uint256 minimumAssets = Math.mulDiv(
                    account.pendingMinAssetsOut, controllerShares, account.pendingShares, Math.Rounding.Ceil
                );
                uint256 assets =
                    _processedAssets(roundAssetBudget, roundTargetShares, allocatedShares, newAllocatedShares);
                if (assets < minimumAssets) {
                    revert MinimumAssetsNotMet(controller, minimumAssets, assets);
                }
            }
            allocatedShares = newAllocatedShares;
        }
    }

    function _processedAssets(
        FundTypes.RedemptionBatch storage redeemBatch,
        uint256 priorAllocatedShares,
        uint256 newAllocatedShares
    ) private view returns (uint256) {
        return _processedAssets(
            redeemBatch.roundAssetBudget, redeemBatch.roundTargetShares, priorAllocatedShares, newAllocatedShares
        );
    }

    function _processedAssets(
        uint256 roundAssetBudget,
        uint256 roundTargetShares,
        uint256 priorAllocatedShares,
        uint256 newAllocatedShares
    ) private pure returns (uint256) {
        uint256 newAllocatedAssets = Math.mulDiv(newAllocatedShares, roundAssetBudget, roundTargetShares);
        uint256 priorAllocatedAssets = Math.mulDiv(priorAllocatedShares, roundAssetBudget, roundTargetShares);
        return newAllocatedAssets - priorAllocatedAssets;
    }
}
