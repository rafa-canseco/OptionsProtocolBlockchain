// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ICoveredCallFundAdapter} from "../interfaces/ICoveredCallFundAdapter.sol";

abstract contract CoveredCallFundAdapterStorage {
    /// @custom:storage-location erc7201:b1nary.storage.CoveredCallFundAdapter
    struct CoveredCallFundAdapterStorageLayout {
        address fund;
        address strategyManager;
        address addressBook;
        address accountingAsset;
        address usdc;
        address swapRouter;
        uint24 swapFeeTier;
        uint64 stateNonce;
        uint256 positionCount;
        uint256 activePositionCount;
        uint256 activeCollateral;
        uint256 accountedWeth;
        uint256 accountedUsdc;
        bytes32 positionsHash;
        ICoveredCallFundAdapter.RiskConfig riskConfig;
        mapping(uint256 positionId => ICoveredCallFundAdapter.Position position) positions;
        uint256 releasablePrincipal;
    }

    bytes32 internal constant COVERED_CALL_FUND_ADAPTER_STORAGE_LOCATION =
        0x87c2fcf2eb487ab099069387b4c834e159db5117bd35c067363dcc0f68a6c200;

    function _getCoveredCallFundAdapterStorage() internal pure returns (CoveredCallFundAdapterStorageLayout storage $) {
        assembly {
            $.slot := COVERED_CALL_FUND_ADAPTER_STORAGE_LOCATION
        }
    }
}
