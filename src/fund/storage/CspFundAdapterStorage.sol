// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ICspFundAdapter} from "../interfaces/ICspFundAdapter.sol";

abstract contract CspFundAdapterStorage {
    /// @custom:storage-location erc7201:b1nary.storage.CspFundAdapter
    struct CspFundAdapterStorageLayout {
        address fund;
        address strategyManager;
        address addressBook;
        address accountingAsset;
        address weth;
        address swapRouter;
        uint24 swapFeeTier;
        uint64 stateNonce;
        uint256 positionCount;
        uint256 activePositionCount;
        uint256 accountedUsdc;
        uint256 accountedWeth;
        bytes32 positionsHash;
        ICspFundAdapter.RiskConfig riskConfig;
        mapping(uint256 positionId => ICspFundAdapter.Position position) positions;
    }

    bytes32 internal constant CSP_FUND_ADAPTER_STORAGE_LOCATION =
        0xd22de47223fb04c91ae131d6d8b510768988ac2102d26bf6a5b1c57722278200;

    function _getCspFundAdapterStorage() internal pure returns (CspFundAdapterStorageLayout storage $) {
        assembly {
            $.slot := CSP_FUND_ADAPTER_STORAGE_LOCATION
        }
    }
}
