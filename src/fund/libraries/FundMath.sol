// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundConstants} from "../FundConstants.sol";

library FundMath {
    error FeeExceedsNav();
    error InvalidBps(uint256 bps);
    error InvalidSupply();
    error UnsupportedAssetDecimals(uint8 decimals);
    error ZeroPayout();
    error ZeroNavWithExistingSupply();

    function managementFeeShares(uint256 preFeeNav, uint256 supply, uint256 annualRateWad, uint256 elapsed)
        internal
        pure
        returns (uint256 feeAssets, uint256 feeShares)
    {
        uint256 elapsedRateWad = Math.mulDiv(annualRateWad, elapsed, FundConstants.YEAR);
        feeAssets = Math.mulDiv(preFeeNav, elapsedRateWad, FundConstants.WAD);
        feeShares = _feeShares(preFeeNav, supply, feeAssets);
    }

    function performanceFeeShares(
        uint256 preFeeNav,
        uint256 eligibleSupply,
        uint256 shareScale,
        uint256 adjustedHighWaterMark,
        uint256 performanceFeeBps
    ) internal pure returns (uint256 feeAssets, uint256 feeShares, uint256 preFeePps) {
        if (performanceFeeBps > FundConstants.BPS) revert InvalidBps(performanceFeeBps);
        if (eligibleSupply == 0 || preFeeNav == 0) return (0, 0, adjustedHighWaterMark);

        preFeePps = Math.mulDiv(preFeeNav, shareScale, eligibleSupply);
        if (preFeePps <= adjustedHighWaterMark) return (0, 0, preFeePps);

        uint256 gainAssets = Math.mulDiv(preFeePps - adjustedHighWaterMark, eligibleSupply, shareScale);
        feeAssets = Math.mulDiv(gainAssets, performanceFeeBps, FundConstants.BPS);
        feeShares = _feeShares(preFeeNav, eligibleSupply, feeAssets);
    }

    function adjustedHighWaterMarkAfterDistribution(
        uint256 highWaterMark,
        uint256 distributionAssets,
        uint256 eligibleSupply,
        uint256 shareScale,
        uint256 priorRemainder,
        uint256 priorRemainderSupply
    ) internal pure returns (uint256 adjustedHighWaterMark, uint256 newRemainder, uint256 newRemainderSupply) {
        if (eligibleSupply == 0) revert InvalidSupply();
        if (priorRemainderSupply != eligibleSupply) priorRemainder = 0;
        if (priorRemainder >= eligibleSupply) revert InvalidSupply();
        if (distributionAssets == 0) return (highWaterMark, priorRemainder, eligibleSupply);

        uint256 distributionPerShare = Math.mulDiv(distributionAssets, shareScale, eligibleSupply);
        uint256 currentRemainder = mulmod(distributionAssets, shareScale, eligibleSupply);
        if (currentRemainder >= eligibleSupply - priorRemainder) {
            distributionPerShare += 1;
            newRemainder = currentRemainder - (eligibleSupply - priorRemainder);
        } else {
            newRemainder = currentRemainder + priorRemainder;
        }

        if (distributionPerShare >= highWaterMark) return (0, 0, eligibleSupply);
        return (highWaterMark - distributionPerShare, newRemainder, eligibleSupply);
    }

    function shareDecimalsOffset(uint8 assetDecimals) internal pure returns (uint8) {
        if (assetDecimals > FundConstants.SHARE_DECIMALS) revert UnsupportedAssetDecimals(assetDecimals);
        return FundConstants.SHARE_DECIMALS - assetDecimals;
    }

    function initialVirtualShares(uint8 assetDecimals) internal pure returns (uint256) {
        return 10 ** shareDecimalsOffset(assetDecimals);
    }

    function redemptionPayout(
        uint256 processedShares,
        uint256 processingNav,
        uint256 eligibleSupply,
        uint256 virtualShares,
        uint256 virtualAssets,
        uint256 marginalExitCost,
        uint256 exitFeeBps
    ) internal pure returns (uint256 grossAssets, uint256 payoutAssets, uint256 exitFeeAssets) {
        if (eligibleSupply == 0) revert InvalidSupply();
        if (processingNav == 0) revert ZeroNavWithExistingSupply();
        if (exitFeeBps > FundConstants.BPS) revert InvalidBps(exitFeeBps);

        grossAssets = Math.mulDiv(processedShares, processingNav + virtualAssets, eligibleSupply + virtualShares);
        if (marginalExitCost > grossAssets) revert FeeExceedsNav();
        uint256 afterMarginalCost = grossAssets - marginalExitCost;
        exitFeeAssets = Math.mulDiv(afterMarginalCost, exitFeeBps, FundConstants.BPS, Math.Rounding.Ceil);
        payoutAssets = afterMarginalCost - exitFeeAssets;
        if (payoutAssets == 0) revert ZeroPayout();
    }

    function proRata(uint256 controllerShares, uint256 processedShares, uint256 batchShares)
        internal
        pure
        returns (uint256)
    {
        if (batchShares == 0) revert InvalidSupply();
        return Math.mulDiv(controllerShares, processedShares, batchShares);
    }

    function convertToShares(
        uint256 assets,
        uint256 totalSupply,
        uint256 totalAssets,
        uint256 virtualShares,
        uint256 virtualAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        if (totalSupply != 0 && totalAssets == 0) revert ZeroNavWithExistingSupply();
        return Math.mulDiv(assets, totalSupply + virtualShares, totalAssets + virtualAssets, rounding);
    }

    function convertToAssets(
        uint256 shares,
        uint256 totalSupply,
        uint256 totalAssets,
        uint256 virtualShares,
        uint256 virtualAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + virtualAssets, totalSupply + virtualShares, rounding);
    }

    function _feeShares(uint256 preFeeNav, uint256 supply, uint256 feeAssets) private pure returns (uint256) {
        if (feeAssets == 0 || supply == 0) return 0;
        if (feeAssets >= preFeeNav) revert FeeExceedsNav();
        return Math.mulDiv(feeAssets, supply, preFeeNav - feeAssets, Math.Rounding.Ceil);
    }
}
