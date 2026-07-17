// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundMath} from "../../src/fund/libraries/FundMath.sol";

contract FundMathHarness {
    function managementFeeShares(uint256 nav, uint256 supply, uint256 rate, uint256 elapsed)
        external
        pure
        returns (uint256 feeAssets, uint256 feeShares)
    {
        return FundMath.managementFeeShares(nav, supply, rate, elapsed);
    }

    function performanceFeeShares(uint256 nav, uint256 supply, uint256 scale, uint256 hwm, uint256 feeBps)
        external
        pure
        returns (uint256 feeAssets, uint256 feeShares, uint256 pps)
    {
        return FundMath.performanceFeeShares(nav, supply, scale, hwm, feeBps);
    }

    function adjustedHwm(
        uint256 hwm,
        uint256 distribution,
        uint256 supply,
        uint256 scale,
        uint256 priorRemainder,
        uint256 priorRemainderSupply
    ) external pure returns (uint256 adjusted, uint256 remainder, uint256 remainderSupply) {
        return FundMath.adjustedHighWaterMarkAfterDistribution(
            hwm, distribution, supply, scale, priorRemainder, priorRemainderSupply
        );
    }

    function redemptionPayout(uint256 shares, uint256 nav, uint256 supply, uint256 marginalCost, uint256 feeBps)
        external
        pure
        returns (uint256 gross, uint256 payout, uint256 fee)
    {
        return FundMath.redemptionPayout(shares, nav, supply, marginalCost, feeBps);
    }

    function proRata(uint256 controllerShares, uint256 processedShares, uint256 batchShares)
        external
        pure
        returns (uint256)
    {
        return FundMath.proRata(controllerShares, processedShares, batchShares);
    }

    function convertToShares(uint256 assets, uint256 supply, uint256 nav, uint256 virtualShares, uint256 virtualAssets)
        external
        pure
        returns (uint256)
    {
        return FundMath.convertToShares(assets, supply, nav, virtualShares, virtualAssets, Math.Rounding.Floor);
    }

    function shareDecimalsOffset(uint8 assetDecimals) external pure returns (uint8) {
        return FundMath.shareDecimalsOffset(assetDecimals);
    }

    function initialVirtualShares(uint8 assetDecimals) external pure returns (uint256) {
        return FundMath.initialVirtualShares(assetDecimals);
    }
}

contract FundMathSpecTest is Test {
    FundMathHarness internal harness;

    function setUp() public {
        harness = new FundMathHarness();
    }

    function test_managementFeeMintsDilutionAtPreFeeNav() public view {
        (uint256 feeAssets, uint256 feeShares) =
            harness.managementFeeShares(1_000_000e6, 1_000_000e18, 0.02e18, 365 days);

        assertEq(feeAssets, 20_000e6);
        assertEq(feeShares, Math.mulDiv(feeAssets, 1_000_000e18, 980_000e6, Math.Rounding.Ceil));
    }

    function test_performanceFeeUsesAdjustedHighWaterMark() public view {
        (uint256 feeAssets, uint256 feeShares, uint256 pps) =
            harness.performanceFeeShares(1_200_000e6, 1_000_000e18, 1e18, 1e6, 2_000);

        assertEq(pps, 1.2e6);
        assertEq(feeAssets, 40_000e6);
        assertEq(feeShares, Math.mulDiv(40_000e6, 1_000_000e18, 1_160_000e6, Math.Rounding.Ceil));
    }

    function test_performanceFeeIsZeroBelowHighWaterMark() public view {
        (uint256 feeAssets, uint256 feeShares, uint256 pps) =
            harness.performanceFeeShares(900_000e6, 1_000_000e18, 1e18, 1e6, 2_000);

        assertEq(pps, 0.9e6);
        assertEq(feeAssets, 0);
        assertEq(feeShares, 0);
    }

    function test_distributionAdjustsHighWaterMarkPerEligibleShare() public view {
        (uint256 adjusted, uint256 remainder, uint256 remainderSupply) =
            harness.adjustedHwm(1e6, 100_000e6, 1_000_000e18, 1e18, 0, 0);
        assertEq(adjusted, 0.9e6);
        assertEq(remainder, 0);
        assertEq(remainderSupply, 1_000_000e18);
    }

    function test_swingPricingChargesOnlyExitingFlow() public view {
        (uint256 gross, uint256 payout, uint256 fee) = harness.redemptionPayout(100e18, 1_000e6, 1_000e18, 2e6, 50);

        assertEq(gross, 100e6);
        assertEq(fee, 490_000);
        assertEq(payout, 97_510_000);
    }

    function test_zeroNavWithSupplyStopsConversionAndRedemption() public {
        vm.expectRevert(FundMath.ZeroNavWithExistingSupply.selector);
        harness.convertToShares(1e6, 1e18, 0, 1e18, 1);

        vm.expectRevert(FundMath.ZeroNavWithExistingSupply.selector);
        harness.redemptionPayout(1e18, 0, 1e18, 0, 0);
    }

    function test_virtualSharesCaptureDonationValue() public view {
        uint256 virtualShares = harness.initialVirtualShares(6);
        uint256 sharesBeforeDonation = harness.convertToShares(100e6, 0, 0, virtualShares, 1);
        uint256 sharesAfterDonation = harness.convertToShares(100e6, 1e18, 1_000e6, virtualShares, 1);

        assertEq(sharesBeforeDonation, 100e18);
        assertLt(sharesAfterDonation, sharesBeforeDonation);
    }

    function test_sharePrecisionIsAlwaysEighteenDecimals() public view {
        assertEq(harness.shareDecimalsOffset(6), 12);
        assertEq(harness.initialVirtualShares(6), 1e12);
        assertEq(harness.shareDecimalsOffset(18), 0);
        assertEq(harness.initialVirtualShares(18), 1);
        assertEq(FundConstants.SHARE_SCALE, 1e18);
    }

    function test_rejectsAccountingAssetsAboveEighteenDecimals() public {
        vm.expectRevert(abi.encodeWithSelector(FundMath.UnsupportedAssetDecimals.selector, 19));
        harness.shareDecimalsOffset(19);
    }

    function test_distributionRemainderAccumulatesInsteadOfDrifting() public view {
        uint256 supply = 3e18;
        uint256 hwm = 10;
        uint256 remainder;
        uint256 remainderSupply;

        (hwm, remainder, remainderSupply) =
            harness.adjustedHwm(hwm, 1, supply, FundConstants.SHARE_SCALE, remainder, remainderSupply);
        assertEq(hwm, 10);
        assertEq(remainder, 1e18);
        (hwm, remainder, remainderSupply) =
            harness.adjustedHwm(hwm, 1, supply, FundConstants.SHARE_SCALE, remainder, remainderSupply);
        assertEq(hwm, 10);
        assertEq(remainder, 2e18);
        (hwm, remainder, remainderSupply) =
            harness.adjustedHwm(hwm, 1, supply, FundConstants.SHARE_SCALE, remainder, remainderSupply);
        assertEq(hwm, 9);
        assertEq(remainder, 0);
        assertEq(remainderSupply, supply);
    }

    function test_distributionRemainderDoesNotCrossSupplyDenominations() public view {
        (uint256 hwm, uint256 remainder, uint256 remainderSupply) =
            harness.adjustedHwm(10, 1, 3e18, FundConstants.SHARE_SCALE, 0, 0);
        assertEq(remainder, 1e18);

        (hwm, remainder, remainderSupply) =
            harness.adjustedHwm(hwm, 1, 4e18, FundConstants.SHARE_SCALE, remainder, remainderSupply);
        assertEq(hwm, 10);
        assertEq(remainder, 1e18);
        assertEq(remainderSupply, 4e18);
    }

    function test_performanceFeeRoundsGainAndFeeAssetsDownWithoutOvercharging() public view {
        (uint256 feeAssets, uint256 feeShares, uint256 pps) = harness.performanceFeeShares(101, 100e18, 1e18, 1, 2_000);

        assertEq(pps, 1);
        assertEq(feeAssets, 0);
        assertEq(feeShares, 0);
    }

    function testFuzz_proRataNeverExceedsControllerPending(
        uint128 controllerPending,
        uint128 processed,
        uint128 batchPending
    ) public view {
        vm.assume(batchPending > 0);
        vm.assume(controllerPending <= batchPending);
        vm.assume(processed <= batchPending);

        uint256 result = harness.proRata(controllerPending, processed, batchPending);
        assertLe(result, controllerPending);
        assertLe(result, processed);
    }
}
