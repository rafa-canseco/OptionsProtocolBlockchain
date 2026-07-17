// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {StrategyManagerStorage} from "./storage/StrategyManagerStorage.sol";
import {IStrategyManager} from "./interfaces/IStrategyManager.sol";
import {IFundVault} from "./interfaces/IFundVault.sol";
import {IFundStrategyAdapter} from "./interfaces/IFundStrategyAdapter.sol";
import {IPositionValuator} from "./interfaces/IPositionValuator.sol";
import {IFundVaultModuleCallbacks, IFundAccountingModuleCallbacks} from "./interfaces/IFundModuleCallbacks.sol";

interface IFundVaultStrategy is IFundVault, IFundVaultModuleCallbacks {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
}

interface IFundAccountingStrategyRegistry {
    function componentState(bytes32 componentId)
        external
        view
        returns (address valuator, uint64 interfaceVersion, uint64 nonce, bytes32 positionStateHash, bool active);
}

interface IFlowProcessingState {
    function hasActiveProcessing() external view returns (bool);
    function strategyExitEscrows() external view returns (address inKindEscrow, address emergencyEscrow);
    function consumeStrategyInKindBatch(bytes32 batchId, address adapter, uint256 fractionWad)
        external
        returns (address escrow);
}

/// @notice Adapter registry and bounded allocation authority for one fund.
contract StrategyManager is FundUpgradeable, StrategyManagerStorage, IStrategyManager {
    error InvalidAddress();
    error InvalidBps(uint256 bps);
    error UnsupportedAsset(address asset);
    error StrategyCooldown(address adapter, uint256 availableAt);
    error StrategyLossExceeded(address adapter, uint256 minimum, uint256 actual);
    error CapCanOnlyDecrease();

    event StrategyConfigured(address indexed adapter, address indexed valuator, bool active);
    event StrategyAllocated(address indexed adapter, address indexed asset, uint256 amount, uint64 positionNonce);
    event StrategyDeallocated(address indexed adapter, uint256 targetValue, uint256 assetsOut, uint64 positionNonce);
    event StrategyDeallocatedInKind(
        bytes32 indexed batchId,
        address indexed adapter,
        address indexed escrow,
        uint256 fractionWad,
        uint64 positionNonce
    );
    event StrategyEmergencyExited(address indexed adapter, address indexed escrow, uint64 positionNonce);
    event AllocationPaused(address indexed adapter);
    event AllocationResumed(address indexed adapter);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address fund_, address authority_, uint64 compatibilityVersion_, uint16 minimumIdleBps_)
        external
        initializer
    {
        if (fund_ == address(0) || compatibilityVersion_ == 0) revert InvalidAddress();
        if (minimumIdleBps_ > FundConstants.BPS) revert InvalidBps(minimumIdleBps_);
        __FundUpgradeable_init(authority_);
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        $.fund = fund_;
        $.compatibilityVersion = compatibilityVersion_;
        $.minimumIdleBps = minimumIdleBps_;
        $.positionsHash = FundConstants.INITIAL_POSITIONS_HASH;
        $.allowedAssets[IFundVaultStrategy(fund_).asset()] = true;
    }

    function fund() external view returns (address) {
        return _getStrategyManagerStorage().fund;
    }

    function compatibilityVersion() external view returns (uint64) {
        return _getStrategyManagerStorage().compatibilityVersion;
    }

    function positionsHash() external view returns (bytes32) {
        return _getStrategyManagerStorage().positionsHash;
    }

    function minimumIdleBps() external view returns (uint16) {
        return _getStrategyManagerStorage().minimumIdleBps;
    }

    function strategyConfig(address adapter) external view returns (FundTypes.StrategyConfig memory) {
        return _getStrategyManagerStorage().strategies[adapter];
    }

    function positionNonce(address adapter) external view returns (uint64) {
        return _getStrategyManagerStorage().positionNonces[adapter];
    }

    function activeAdapterCount() external view returns (uint256) {
        return _getStrategyManagerStorage().activeAdapters.length;
    }

    function activeAdapterAt(uint256 index) external view returns (address) {
        return _getStrategyManagerStorage().activeAdapters[index];
    }

    function isAssetAllowed(address asset_) external view returns (bool) {
        return _getStrategyManagerStorage().allowedAssets[asset_];
    }

    function allocatedToAdapter(address adapter, address asset_) external view returns (uint256) {
        return _getStrategyManagerStorage().adapterAllocated[adapter][asset_];
    }

    function allocate(address adapter, address asset_, uint256 amount, bytes calldata data) external restricted {
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        FundTypes.StrategyConfig storage config = $.strategies[adapter];
        if (!config.active) revert AdapterNotActive(adapter);
        if (!$.allowedAssets[asset_]) revert UnsupportedAsset(asset_);
        IFundVaultStrategy vault = IFundVaultStrategy($.fund);
        if (
            amount == 0 || IERC20Balance(asset_).balanceOf($.fund) < vault.accountedIdleAssets()
                || IFlowProcessingState(vault.flowManager()).hasActiveProcessing()
        ) {
            revert AllocationCapExceeded(adapter);
        }

        uint256 projected = $.adapterAllocated[adapter][asset_] + amount;
        if (
            projected > config.absoluteCap
                || projected > Math.mulDiv(vault.totalAssets(), config.maxAllocationBps, FundConstants.BPS)
        ) revert AllocationCapExceeded(adapter);
        uint256 idle = vault.accountedIdleAssets();
        uint256 requiredIdle = Math.mulDiv(vault.totalAssets(), $.minimumIdleBps, FundConstants.BPS);
        if (amount > idle || idle - amount < requiredIdle) revert MinimumIdleViolation();
        uint256 availableAt = uint256($.lastOperationAt[adapter]) + config.cooldown;
        if (block.timestamp < availableAt) revert StrategyCooldown(adapter, availableAt);

        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.invalidateNav();
        vault.transferToStrategy(asset_, adapter, amount);
        IFundStrategyAdapter(adapter).allocate(asset_, amount, data);

        $.adapterAllocated[adapter][asset_] = projected;
        $.totalAllocated[asset_] += amount;
        $.lastOperationAt[adapter] = uint48(block.timestamp);
        (uint64 nonce, bytes32 stateHash) = _recordPosition($, adapter);
        vault.recordStrategyPositions($.positionsHash);
        _syncAccounting(vault.accounting(), adapter, nonce, stateHash);
        vault.endModuleExecution(lockId);
        emit StrategyAllocated(adapter, asset_, amount, nonce);
    }

    function deallocate(address adapter, uint256 targetValue, uint256 minAssetsOut, bytes calldata data)
        external
        restricted
        returns (uint256 assetsOut)
    {
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        FundTypes.StrategyConfig storage config = $.strategies[adapter];
        if (config.interfaceVersion == 0 || targetValue == 0) revert AdapterNotActive(adapter);
        IFundVaultStrategy vault = IFundVaultStrategy($.fund);
        address accountingAsset = vault.asset();

        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.invalidateNav();
        uint256 balanceBefore = IERC20Balance(accountingAsset).balanceOf($.fund);
        IFundStrategyAdapter(adapter).deallocate(targetValue, minAssetsOut, data);
        assetsOut = vault.recordStrategyReturn(accountingAsset, balanceBefore);
        if (assetsOut < minAssetsOut) revert StrategyLossExceeded(adapter, minAssetsOut, assetsOut);
        uint256 minimumAfterLoss = Math.mulDiv(targetValue, FundConstants.BPS - config.maxLossBps, FundConstants.BPS);
        if (assetsOut < minimumAfterLoss) revert StrategyLossExceeded(adapter, minimumAfterLoss, assetsOut);

        uint256 allocated = $.adapterAllocated[adapter][accountingAsset];
        uint256 reduction = Math.min(allocated, targetValue);
        $.adapterAllocated[adapter][accountingAsset] = allocated - reduction;
        $.totalAllocated[accountingAsset] -= reduction;
        $.lastOperationAt[adapter] = uint48(block.timestamp);
        (uint64 nonce, bytes32 stateHash) = _recordPosition($, adapter);
        vault.recordStrategyPositions($.positionsHash);
        _syncAccounting(vault.accounting(), adapter, nonce, stateHash);
        vault.endModuleExecution(lockId);
        emit StrategyDeallocated(adapter, targetValue, assetsOut, nonce);
    }

    function deallocateInKind(bytes32 batchId, address adapter, uint256 fractionWad, bytes calldata data)
        external
        restricted
        returns (address[] memory assets, uint256[] memory amounts)
    {
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        FundTypes.StrategyConfig storage config = $.strategies[adapter];
        if (config.interfaceVersion == 0 || fractionWad == 0 || fractionWad > FundConstants.WAD) {
            revert AdapterNotActive(adapter);
        }
        IFundVaultStrategy vault = IFundVaultStrategy($.fund);
        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.invalidateNav();
        address escrow =
            IFlowProcessingState(vault.flowManager()).consumeStrategyInKindBatch(batchId, adapter, fractionWad);
        (assets, amounts) = IFundStrategyAdapter(adapter).deallocateInKind(fractionWad, escrow, data);
        if (assets.length == 0 || assets.length != amounts.length) revert InvalidAddress();

        address accountingAsset = vault.asset();
        uint256 allocated = $.adapterAllocated[adapter][accountingAsset];
        uint256 reduction = Math.mulDiv(allocated, fractionWad, FundConstants.WAD);
        $.adapterAllocated[adapter][accountingAsset] = allocated - reduction;
        $.totalAllocated[accountingAsset] -= reduction;
        $.lastOperationAt[adapter] = uint48(block.timestamp);
        (uint64 nonce, bytes32 stateHash) = _recordPosition($, adapter);
        vault.recordStrategyPositions($.positionsHash);
        _syncAccounting(vault.accounting(), adapter, nonce, stateHash);
        vault.endModuleExecution(lockId);
        emit StrategyDeallocatedInKind(batchId, adapter, escrow, fractionWad, nonce);
    }

    function emergencyExit(address adapter, bytes calldata data)
        external
        restricted
        returns (address[] memory assets, uint256[] memory amounts)
    {
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        FundTypes.StrategyConfig storage config = $.strategies[adapter];
        if (config.interfaceVersion == 0) revert AdapterNotActive(adapter);
        IFundVaultStrategy vault = IFundVaultStrategy($.fund);
        (, address escrow) = IFlowProcessingState(vault.flowManager()).strategyExitEscrows();
        if (escrow == address(0) || escrow.code.length == 0) revert InvalidAddress();
        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.invalidateNav();
        (assets, amounts) = IFundStrategyAdapter(adapter).emergencyExit(escrow, data);
        if (assets.length == 0 || assets.length != amounts.length) revert InvalidAddress();

        address accountingAsset = vault.asset();
        uint256 allocated = $.adapterAllocated[adapter][accountingAsset];
        $.adapterAllocated[adapter][accountingAsset] = 0;
        $.totalAllocated[accountingAsset] -= allocated;
        $.strategies[adapter].active = false;
        $.lastOperationAt[adapter] = uint48(block.timestamp);
        (uint64 nonce, bytes32 stateHash) = _recordPosition($, adapter);
        vault.recordStrategyPositions($.positionsHash);
        _syncAccounting(vault.accounting(), adapter, nonce, stateHash);
        vault.endModuleExecution(lockId);
        emit StrategyEmergencyExited(adapter, escrow, nonce);
    }

    function setStrategyConfig(address adapter, FundTypes.StrategyConfig calldata config) external restricted {
        if (
            adapter == address(0) || config.interfaceVersion == 0 || config.maxAllocationBps > FundConstants.BPS
                || config.maxLossBps > FundConstants.BPS || config.absoluteCap == 0
        ) revert InvalidAddress();
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        IFundVaultStrategy vault = IFundVaultStrategy($.fund);
        if (adapter.code.length == 0) revert InvalidAddress();
        IFundStrategyAdapter strategy = IFundStrategyAdapter(adapter);
        uint64 actualVersion = strategy.interfaceVersion();
        if (
            strategy.fund() != $.fund || strategy.accountingAsset() != vault.asset()
                || actualVersion != config.interfaceVersion
        ) revert InvalidAdapterVersion(config.interfaceVersion, actualVersion);
        if (
            config.valuator == address(0) || config.valuator.code.length == 0
                || IPositionValuator(config.valuator).interfaceVersion() != config.interfaceVersion
        ) revert InvalidAddress();
        (address approvedValuator, uint64 approvedVersion,,, bool componentActive) = IFundAccountingStrategyRegistry(
                vault.accounting()
            ).componentState(keccak256(abi.encodePacked("STRATEGY", adapter)));
        if (!componentActive || approvedValuator != config.valuator || approvedVersion != config.interfaceVersion) {
            revert InvalidAddress();
        }

        if ($.strategies[adapter].interfaceVersion == 0) $.activeAdapters.push(adapter);
        $.strategies[adapter] = config;
        emit StrategyConfigured(adapter, config.valuator, config.active);
    }

    function reduceStrategyCap(address adapter, uint256 absoluteCap, uint16 maxAllocationBps) external restricted {
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        FundTypes.StrategyConfig storage config = $.strategies[adapter];
        if (
            config.interfaceVersion == 0 || absoluteCap > config.absoluteCap
                || maxAllocationBps > config.maxAllocationBps
        ) revert CapCanOnlyDecrease();
        config.absoluteCap = absoluteCap;
        config.maxAllocationBps = maxAllocationBps;
    }

    function setMinimumIdleBps(uint16 newMinimumIdleBps) external restricted {
        if (newMinimumIdleBps > FundConstants.BPS) revert InvalidBps(newMinimumIdleBps);
        _getStrategyManagerStorage().minimumIdleBps = newMinimumIdleBps;
    }

    function pauseAllocation(address adapter) external restricted {
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        if ($.strategies[adapter].interfaceVersion == 0) revert AdapterNotActive(adapter);
        $.strategies[adapter].active = false;
        emit AllocationPaused(adapter);
    }

    function resumeAllocation(address adapter) external restricted {
        StrategyManagerStorageLayout storage $ = _getStrategyManagerStorage();
        if ($.strategies[adapter].interfaceVersion == 0) revert AdapterNotActive(adapter);
        $.strategies[adapter].active = true;
        emit AllocationResumed(adapter);
    }

    function _recordPosition(StrategyManagerStorageLayout storage $, address adapter)
        private
        returns (uint64 nonce, bytes32 stateHash)
    {
        nonce = ++$.positionNonces[adapter];
        stateHash = IFundStrategyAdapter(adapter).positionStateHash();
        $.positionsHash = keccak256(abi.encode($.positionsHash, adapter, nonce, stateHash));
    }

    function _syncAccounting(address accounting, address adapter, uint64 nonce, bytes32 stateHash) private {
        IFundAccountingModuleCallbacks(accounting).syncStrategyComponent(adapter, nonce, stateHash);
    }
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}
