// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

abstract contract FundShareStorage {
    /// @custom:storage-location erc7201:b1nary.storage.FundShare
    struct FundShareStorageLayout {
        address asset;
        address vault;
        uint64 compatibilityVersion;
    }

    bytes32 internal constant FUND_SHARE_STORAGE_LOCATION =
        0xe2a81ba6c0d9ac928aa029ae20ba46e88a57a7f1559bca1aece691f6075ce400;

    function _getFundShareStorage() internal pure returns (FundShareStorageLayout storage $) {
        assembly {
            $.slot := FUND_SHARE_STORAGE_LOCATION
        }
    }
}
