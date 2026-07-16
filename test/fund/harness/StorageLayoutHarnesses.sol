// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {FundVaultStorage} from "../../../src/fund/storage/FundVaultStorage.sol";
import {FundAccountingStorage} from "../../../src/fund/storage/FundAccountingStorage.sol";
import {FundFlowManagerStorage} from "../../../src/fund/storage/FundFlowManagerStorage.sol";
import {StrategyManagerStorage} from "../../../src/fund/storage/StrategyManagerStorage.sol";

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

contract FundFlowManagerStorageHarnessV1 is StorageHarnessBase, FundFlowManagerStorage {
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

contract StrategyManagerStorageHarnessV1 is StorageHarnessBase, StrategyManagerStorage {
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
}

abstract contract FundVaultStorageV2Definition {
    /// @custom:storage-location erc7201:b1nary.storage.FundVault
    struct FundVaultStorageLayout {
        address accountingAsset;
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
        bool depositsPaused;
        bool redemptionsPaused;
        mapping(address asset => uint256 amount) unaccountedBalances;
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
