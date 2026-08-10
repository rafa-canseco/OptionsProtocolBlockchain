// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Canonical conservative conversions for the supported (8,8,8,6) tuple.
library AssetNeutralUnitsV2 {
    uint256 internal constant OPTION_SCALE = 1e8;
    uint256 internal constant UNDERLYING_SCALE = 1e8;
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant SETTLEMENT_SCALE = 1e6;
    uint256 internal constant OPTION_PRICE_TO_SETTLEMENT = 1e10;

    function cspCollateral(uint256 optionAmount8, uint256 strikePriceUsd8) internal pure returns (uint256) {
        return Math.mulDiv(optionAmount8, strikePriceUsd8, OPTION_PRICE_TO_SETTLEMENT, Math.Rounding.Ceil);
    }

    function coveredCallCollateral(uint256 optionAmount8) internal pure returns (uint256) {
        return optionAmount8;
    }

    function callAwaySettlement(uint256 optionAmount8, uint256 strikePriceUsd8) internal pure returns (uint256) {
        return Math.mulDiv(optionAmount8, strikePriceUsd8, OPTION_PRICE_TO_SETTLEMENT);
    }

    function underlyingToSettlement(uint256 underlying8, uint256 priceUsd8) internal pure returns (uint256) {
        return Math.mulDiv(underlying8, priceUsd8, OPTION_PRICE_TO_SETTLEMENT);
    }

    function underlyingLiabilityToSettlement(uint256 underlying8, uint256 priceUsd8) internal pure returns (uint256) {
        return Math.mulDiv(underlying8, priceUsd8, OPTION_PRICE_TO_SETTLEMENT, Math.Rounding.Ceil);
    }

    function settlementToUnderlying(uint256 settlement6, uint256 priceUsd8) internal pure returns (uint256) {
        return Math.mulDiv(settlement6, OPTION_PRICE_TO_SETTLEMENT, priceUsd8);
    }

    function settlementLiabilityToUnderlying(uint256 settlement6, uint256 priceUsd8) internal pure returns (uint256) {
        return Math.mulDiv(settlement6, OPTION_PRICE_TO_SETTLEMENT, priceUsd8, Math.Rounding.Ceil);
    }
}
