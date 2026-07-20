// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {FundVaultStorage} from "../../../src/fund/storage/FundVaultStorage.sol";
import {FundAccountingStorage} from "../../../src/fund/storage/FundAccountingStorage.sol";
import {FundFlowManagerStorage} from "../../../src/fund/storage/FundFlowManagerStorage.sol";
import {StrategyManagerStorage} from "../../../src/fund/storage/StrategyManagerStorage.sol";
import {CspFundAdapterStorage} from "../../../src/fund/storage/CspFundAdapterStorage.sol";
import {FundTypes} from "../../../src/fund/FundTypes.sol";

abstract contract StorageHarnessBase is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    function __StorageHarnessBase_init(address owner) internal onlyInitializing {
        __Ownable_init(owner);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

contract FundVaultStorageHarnessV1 is StorageHarnessBase, FundVaultStorage {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function storageLocation() external pure returns (bytes32) {
        return FUND_VAULT_STORAGE_LOCATION;
    }

    function setCommittedNav(uint256 value) external onlyOwner {
        _getFundVaultStorage().committedNav = value;
    }

    function committedNav() external view returns (uint256) {
        return _getFundVaultStorage().committedNav;
    }
}

contract FundAccountingStorageHarnessV1 is StorageHarnessBase, FundAccountingStorage {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function storageLocation() external pure returns (bytes32) {
        return FUND_ACCOUNTING_STORAGE_LOCATION;
    }

    function setFund(address value) external onlyOwner {
        _getFundAccountingStorage().fund = value;
    }
}

abstract contract FundFlowManagerStorageV1Definition {
    struct OutflowWindow {
        uint256 eligibleSupply;
        uint256 processedShares;
    }

    /// @custom:storage-location erc7201:b1nary.storage.FundFlowManager
    struct FundFlowManagerStorageLayout {
        address fund;
        address claimEscrow;
        uint64 compatibilityVersion;
        uint64 nextProcessBatchId;
        uint64 openBatchId;
        uint256 totalPendingShares;
        uint256 totalClaimableShares;
        uint256 totalReservedAssets;
        mapping(address controller => mapping(address operator => bool approved)) operators;
        mapping(address controller => FundTypes.RedemptionState state) redemptions;
        mapping(uint64 batchId => FundTypes.RedemptionBatch batch) batches;
        mapping(uint64 batchId => address[] controllers) batchControllers;
        mapping(uint64 batchId => mapping(address controller => FundTypes.RedemptionAccount account)) batchAccounts;
        uint16 maxExitFeeBps;
        uint16 maxWindowOutflowBps;
        mapping(uint64 reportNonce => OutflowWindow window) outflowWindows;
    }

    bytes32 internal constant FUND_FLOW_MANAGER_STORAGE_LOCATION =
        0xa2150758e26bb44e0a441458c3c47420e0cafabeb20258a8fa06803a087dec00;

    function _getFundFlowManagerStorage() internal pure returns (FundFlowManagerStorageLayout storage $) {
        assembly {
            $.slot := FUND_FLOW_MANAGER_STORAGE_LOCATION
        }
    }
}

contract FundFlowManagerStorageHarnessV1 is StorageHarnessBase, FundFlowManagerStorageV1Definition {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function storageLocation() external pure returns (bytes32) {
        return FUND_FLOW_MANAGER_STORAGE_LOCATION;
    }

    function setFund(address value) external onlyOwner {
        _getFundFlowManagerStorage().fund = value;
    }
}

/// @custom:oz-upgrades-from FundFlowManagerStorageHarnessV1
contract FundFlowManagerStorageHarnessV2 is StorageHarnessBase, FundFlowManagerStorage {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function storageLocation() external pure returns (bytes32) {
        return FUND_FLOW_MANAGER_STORAGE_LOCATION;
    }

    function setFund(address value) external onlyOwner {
        _getFundFlowManagerStorage().fund = value;
    }

    function setStrategyExitEscrows(address inKindEscrow, address emergencyEscrow) external onlyOwner {
        FundFlowManagerStorageLayout storage $ = _getFundFlowManagerStorage();
        $.strategyInKindEscrow = inKindEscrow;
        $.strategyEmergencyEscrow = emergencyEscrow;
    }
}

abstract contract StrategyManagerStorageV1Definition {
    /// @custom:storage-location erc7201:b1nary.storage.StrategyManager
    struct StrategyManagerStorageLayout {
        address fund;
        uint64 compatibilityVersion;
        uint16 minimumIdleBps;
        bytes32 positionsHash;
        address[] activeAdapters;
        mapping(address adapter => FundTypes.StrategyConfig config) strategies;
        mapping(address adapter => uint64 nonce) positionNonces;
        mapping(address asset => bool allowed) allowedAssets;
        mapping(address asset => uint256 amount) totalAllocated;
        mapping(address adapter => mapping(address asset => uint256 amount)) adapterAllocated;
        mapping(address adapter => uint48 timestamp) lastOperationAt;
    }

    bytes32 internal constant STRATEGY_MANAGER_STORAGE_LOCATION =
        0x25887ea3e5e75cc13395c4a56dac59490fcb6528f03e6c5e7b324f5c7afd6b00;

    function _getStrategyManagerStorage() internal pure returns (StrategyManagerStorageLayout storage $) {
        assembly {
            $.slot := STRATEGY_MANAGER_STORAGE_LOCATION
        }
    }
}

contract StrategyManagerStorageHarnessV1 is StorageHarnessBase, StrategyManagerStorageV1Definition {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function storageLocation() external pure returns (bytes32) {
        return STRATEGY_MANAGER_STORAGE_LOCATION;
    }

    function setFund(address value) external onlyOwner {
        _getStrategyManagerStorage().fund = value;
    }

    function fund() external view returns (address) {
        return _getStrategyManagerStorage().fund;
    }
}

/// @custom:oz-upgrades-from StrategyManagerStorageHarnessV1
contract StrategyManagerStorageHarnessV2 is StorageHarnessBase, StrategyManagerStorage {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function storageLocation() external pure returns (bytes32) {
        return STRATEGY_MANAGER_STORAGE_LOCATION;
    }

    function fund() external view returns (address) {
        return _getStrategyManagerStorage().fund;
    }

    function setAllocationPauseNonce(address adapter, uint64 value) external onlyOwner {
        _getStrategyManagerStorage().allocationPauseNonces[adapter] = value;
    }

    function allocationPauseNonce(address adapter) external view returns (uint64) {
        return _getStrategyManagerStorage().allocationPauseNonces[adapter];
    }
}

contract CspFundAdapterStorageHarnessV1 is StorageHarnessBase, CspFundAdapterStorage {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function storageLocation() external pure returns (bytes32) {
        return CSP_FUND_ADAPTER_STORAGE_LOCATION;
    }

    function setFund(address value) external onlyOwner {
        _getCspFundAdapterStorage().fund = value;
    }
}

abstract contract FundVaultStorageV2Definition {
    /// @custom:storage-location erc7201:b1nary.storage.FundVault
    struct FundVaultStorageLayout {
        address accountingAsset;
        address shareToken;
        address accounting;
        address flowManager;
        address strategyManager;
        address claimEscrow;
        address distributionEscrow;
        uint256 committedNav;
        uint256 accountedIdleAssets;
        uint256 reservedClaimAssets;
        uint256 reservedDistributionAssets;
        bytes32 positionsHash;
        bytes32 reportHash;
        bytes32 signaturesHash;
        uint64 snapshotBlock;
        uint64 navValidAfterBlock;
        uint64 navValidUntilBlock;
        uint64 reporterSetVersion;
        uint64 reportNonce;
        uint64 compatibilityVersion;
        uint256 executionLockNonce;
        address executionLockOwner;
        uint8 accountingAssetDecimals;
        uint8 shareDecimalsOffset;
        bool depositsPaused;
        bool redemptionsPaused;
        mapping(address asset => uint256 amount) unaccountedBalances;
        uint256 baseExitCost;
        uint64 fundFlowNonce;
        uint64 acceptedFlowNonce;
        bytes32 acceptedIdleStateHash;
        uint256 appendedField;
    }

    bytes32 internal constant FUND_VAULT_STORAGE_LOCATION =
        0x06d529727cf5bc6dc96f9652d8da22d6b7df4e899f31f34198b231dafc3c1900;

    function _getFundVaultStorage() internal pure returns (FundVaultStorageLayout storage $) {
        assembly {
            $.slot := FUND_VAULT_STORAGE_LOCATION
        }
    }
}

/// @custom:oz-upgrades-from FundVaultStorageHarnessV1
contract FundVaultStorageHarnessV2 is StorageHarnessBase, FundVaultStorageV2Definition {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }

    function setAppendedField(uint256 value) external onlyOwner {
        _getFundVaultStorage().appendedField = value;
    }

    function committedNav() external view returns (uint256) {
        return _getFundVaultStorage().committedNav;
    }

    function appendedField() external view returns (uint256) {
        return _getFundVaultStorage().appendedField;
    }
}

abstract contract FundVaultStorageBadTypeDefinition {
    /// @custom:storage-location erc7201:b1nary.storage.FundVault
    struct FundVaultStorageLayout {
        address accountingAsset;
        address shareToken;
        address accounting;
        address flowManager;
        address strategyManager;
        address claimEscrow;
        address distributionEscrow;
        address committedNav;
        uint256 accountedIdleAssets;
        uint256 reservedClaimAssets;
        uint256 reservedDistributionAssets;
        bytes32 positionsHash;
        bytes32 reportHash;
        bytes32 signaturesHash;
        uint64 snapshotBlock;
        uint64 navValidAfterBlock;
        uint64 navValidUntilBlock;
        uint64 reporterSetVersion;
        uint64 reportNonce;
        uint64 compatibilityVersion;
        uint256 executionLockNonce;
        address executionLockOwner;
        uint8 accountingAssetDecimals;
        uint8 shareDecimalsOffset;
        bool depositsPaused;
        bool redemptionsPaused;
        mapping(address asset => uint256 amount) unaccountedBalances;
    }

    bytes32 internal constant FUND_VAULT_STORAGE_LOCATION =
        0x06d529727cf5bc6dc96f9652d8da22d6b7df4e899f31f34198b231dafc3c1900;
}

contract FundVaultStorageHarnessBadType is StorageHarnessBase, FundVaultStorageBadTypeDefinition {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }
}

contract FundVaultStorageHarnessRemovedNamespace is StorageHarnessBase {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        __StorageHarnessBase_init(owner);
    }
}
