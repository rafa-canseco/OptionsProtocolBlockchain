// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

abstract contract FundVaultStorage {
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
        uint8 accountingAssetDecimals;
        uint8 shareDecimalsOffset;
        bool depositsPaused;
        bool redemptionsPaused;
        mapping(address asset => uint256 amount) unaccountedBalances;
        uint256 baseExitCost;
    }

    bytes32 internal constant FUND_VAULT_STORAGE_LOCATION =
        0x06d529727cf5bc6dc96f9652d8da22d6b7df4e899f31f34198b231dafc3c1900;

    function _getFundVaultStorage() internal pure returns (FundVaultStorageLayout storage $) {
        assembly {
            $.slot := FUND_VAULT_STORAGE_LOCATION
        }
    }
}
