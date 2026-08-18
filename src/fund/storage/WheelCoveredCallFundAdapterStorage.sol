// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

abstract contract WheelCoveredCallFundAdapterStorage {
    /// @custom:storage-location erc7201:b1nary.storage.WheelCoveredCallFundAdapter
    struct WheelCoveredCallFundAdapterStorageLayout {
        mapping(bytes32 transitionHash => bool consumed) consumedHandoffs;
    }

    bytes32 internal constant WHEEL_COVERED_CALL_FUND_ADAPTER_STORAGE_LOCATION =
        0x84b36632ceb5aa99dc21476807d500e650198e6e36cd65bd2dd94c57cf76e600;

    function _getWheelCoveredCallFundAdapterStorage()
        internal
        pure
        returns (WheelCoveredCallFundAdapterStorageLayout storage $)
    {
        assembly {
            $.slot := WHEEL_COVERED_CALL_FUND_ADAPTER_STORAGE_LOCATION
        }
    }
}
