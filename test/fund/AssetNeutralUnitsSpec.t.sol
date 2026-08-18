// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {IAssetNeutralOptionsAdapterV2} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {IAssetNeutralWheelV2} from "../../src/fund/interfaces/IAssetNeutralWheelV2.sol";

contract AssetNeutralUnitsHarness {
    uint256 private constant BPS = 10_000;

    function requireInterfaceVersion(uint64 observed) external pure {
        if (observed != 2) revert IAssetNeutralOptionsAdapterV2.AmbiguousInterfaceVersion(observed);
    }

    function validateTuple(
        uint8 oTokenDecimals,
        uint8 underlyingDecimals,
        uint8 priceDecimals,
        uint8 settlementDecimals
    ) public pure {
        if (oTokenDecimals != 8) {
            revert IAssetNeutralOptionsAdapterV2.UnsupportedDecimals(address(0x01), oTokenDecimals);
        }
        if (underlyingDecimals != 8 && underlyingDecimals != 18) {
            revert IAssetNeutralOptionsAdapterV2.UnsupportedDecimals(address(0x02), underlyingDecimals);
        }
        if (priceDecimals != 8) {
            revert IAssetNeutralOptionsAdapterV2.UnsupportedDecimals(address(0x03), priceDecimals);
        }
        if (settlementDecimals != 6) {
            revert IAssetNeutralOptionsAdapterV2.UnsupportedDecimals(address(0x04), settlementDecimals);
        }
    }

    function optionToUnderlying(uint256 optionAmount8, uint8 underlyingDecimals) external pure returns (uint256) {
        validateTuple(8, underlyingDecimals, 8, 6);
        return optionAmount8 * (10 ** (underlyingDecimals - 8));
    }

    function underlyingToOption(uint256 underlyingAmount, uint8 underlyingDecimals)
        external
        pure
        returns (uint256 optionAmount8, uint256 dust)
    {
        validateTuple(8, underlyingDecimals, 8, 6);
        uint256 scale = 10 ** (underlyingDecimals - 8);
        return (underlyingAmount / scale, underlyingAmount % scale);
    }

    function cspCollateral(uint256 optionAmount8, uint256 strikePriceUsd8) external pure returns (uint256) {
        return Math.mulDiv(optionAmount8, strikePriceUsd8, 1e10, Math.Rounding.Ceil);
    }

    function callAwaySettlement(uint256 optionAmount8, uint256 strikePriceUsd8) external pure returns (uint256) {
        return Math.mulDiv(optionAmount8, strikePriceUsd8, 1e10);
    }

    function grossPremium(uint256 optionAmount8, uint256 premiumPerOptionSettlement) external pure returns (uint256) {
        return Math.mulDiv(optionAmount8, premiumPerOptionSettlement, 1e8);
    }

    function protocolFee(uint256 grossPremiumSettlement, uint16 feeBps) external pure returns (uint256) {
        return Math.mulDiv(grossPremiumSettlement, feeBps, BPS);
    }

    function underlyingAssetValue(uint256 underlyingAmount, uint256 spotPriceUsd8, uint8 underlyingDecimals)
        external
        pure
        returns (uint256)
    {
        validateTuple(8, underlyingDecimals, 8, 6);
        return Math.mulDiv(underlyingAmount, spotPriceUsd8, 10 ** (underlyingDecimals + 2));
    }

    function underlyingLiabilityValue(uint256 underlyingAmount, uint256 spotPriceUsd8, uint8 underlyingDecimals)
        external
        pure
        returns (uint256)
    {
        validateTuple(8, underlyingDecimals, 8, 6);
        return Math.mulDiv(underlyingAmount, spotPriceUsd8, 10 ** (underlyingDecimals + 2), Math.Rounding.Ceil);
    }

    function settlementAssetValueInUnderlying(uint256 settlementAmount, uint256 spotPriceUsd8, uint8 underlyingDecimals)
        external
        pure
        returns (uint256)
    {
        validateTuple(8, underlyingDecimals, 8, 6);
        return Math.mulDiv(settlementAmount, 10 ** (underlyingDecimals + 2), spotPriceUsd8);
    }

    function settlementLiabilityValueInUnderlying(
        uint256 settlementAmount,
        uint256 spotPriceUsd8,
        uint8 underlyingDecimals
    ) external pure returns (uint256) {
        validateTuple(8, underlyingDecimals, 8, 6);
        return Math.mulDiv(settlementAmount, 10 ** (underlyingDecimals + 2), spotPriceUsd8, Math.Rounding.Ceil);
    }

    function normalizationMinimum(uint256 fairOutput, uint16 slippageBps) external pure returns (uint256) {
        return Math.mulDiv(fairOutput, BPS - slippageBps, BPS);
    }

    function normalizationMaximum(uint256 fairInput, uint16 slippageBps) external pure returns (uint256) {
        return Math.mulDiv(fairInput, BPS + slippageBps, BPS, Math.Rounding.Ceil);
    }

    function canonicalNetAssets(uint256 grossAssets, uint256 liabilities) external pure returns (uint256) {
        return grossAssets - liabilities;
    }
}

contract AssetNeutralUnitsSpecTest is Test {
    AssetNeutralUnitsHarness private units;

    function setUp() public {
        units = new AssetNeutralUnitsHarness();
    }

    function test_LBTC8OptionAndAssignmentConversionIsIdentity() public view {
        assertEq(units.optionToUnderlying(12_345_678, 8), 12_345_678);
        (uint256 optionAmount8, uint256 dust) = units.underlyingToOption(12_345_678, 8);
        assertEq(optionAmount8, 12_345_678);
        assertEq(dust, 0);
    }

    function test_weth18CompatibilityScaleAndDustRemainExplicit() public view {
        assertEq(units.optionToUnderlying(123, 18), 123e10);
        (uint256 optionAmount8, uint256 dust) = units.underlyingToOption(123e10 + 999, 18);
        assertEq(optionAmount8, 123);
        assertEq(dust, 999);
    }

    function test_unsupportedDecimalTuplesFailClosed() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAssetNeutralOptionsAdapterV2.UnsupportedDecimals.selector, address(0x01), 18)
        );
        units.validateTuple(18, 8, 8, 6);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetNeutralOptionsAdapterV2.UnsupportedDecimals.selector, address(0x02), 9)
        );
        units.validateTuple(8, 9, 8, 6);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetNeutralOptionsAdapterV2.UnsupportedDecimals.selector, address(0x03), 18)
        );
        units.validateTuple(8, 8, 18, 6);
        vm.expectRevert(
            abi.encodeWithSelector(IAssetNeutralOptionsAdapterV2.UnsupportedDecimals.selector, address(0x04), 8)
        );
        units.validateTuple(8, 8, 8, 8);
    }

    function test_ambiguousInterfaceVersionsFailClosed() public {
        units.requireInterfaceVersion(2);
        for (uint64 observed = 0; observed < 4; ++observed) {
            if (observed == 2) continue;
            vm.expectRevert(
                abi.encodeWithSelector(IAssetNeutralOptionsAdapterV2.AmbiguousInterfaceVersion.selector, observed)
            );
            units.requireInterfaceVersion(observed);
        }
    }

    function test_collateralRoundsUpWhileCallAwayRoundsDown() public view {
        uint256 oneSat8 = 1;
        uint256 nonIntegralStrike8 = 70_000e8 + 1;
        assertEq(units.cspCollateral(oneSat8, nonIntegralStrike8), 701);
        assertEq(units.callAwaySettlement(oneSat8, nonIntegralStrike8), 700);
    }

    function test_premiumAndProtocolFeeRoundTowardWriterConservatively() public view {
        uint256 gross = units.grossPremium(50_000_001, 1e6);
        assertEq(gross, 500_000);
        assertEq(units.protocolFee(gross + 1, 400), 20_000);
    }

    function test_navAssetsRoundDownAndLiabilitiesRoundUpForLBTC8() public view {
        uint256 oneSat8 = 1;
        uint256 nonIntegralSpot8 = 70_000e8 + 1;
        assertEq(units.underlyingAssetValue(oneSat8, nonIntegralSpot8, 8), 700);
        assertEq(units.underlyingLiabilityValue(oneSat8, nonIntegralSpot8, 8), 701);
    }

    function test_inverseNavConversionUsesSameConservativeDirections() public view {
        uint256 oneUsdc = 1e6;
        uint256 spot8 = 70_000e8 + 1;
        uint256 assetValue = units.settlementAssetValueInUnderlying(oneUsdc, spot8, 8);
        uint256 liabilityValue = units.settlementLiabilityValueInUnderlying(oneUsdc, spot8, 8);
        assertEq(assetValue, 1_428);
        assertEq(liabilityValue, 1_429);
    }

    function test_normalizationMinimumRoundsDownAndMaximumRoundsUp() public view {
        assertEq(units.normalizationMinimum(101, 50), 100);
        assertEq(units.normalizationMaximum(101, 50), 102);
    }

    function test_fullPrecisionMulDivSupportsMaxValueWithoutIntermediateOverflow() public view {
        assertEq(units.cspCollateral(type(uint256).max, 1e10), type(uint256).max);
        assertEq(units.callAwaySettlement(type(uint256).max, 1e10), type(uint256).max);
    }

    function test_exactScaleOverflowAndZeroSpotFailClosed() public {
        vm.expectRevert(stdError.arithmeticError);
        units.optionToUnderlying(type(uint256).max, 18);

        vm.expectRevert();
        units.settlementAssetValueInUnderlying(1e6, 0, 8);
    }

    function test_canonicalNavExcludesSeparateBaseExitCost() public view {
        assertEq(units.canonicalNetAssets(1_000e6, 100e6), 900e6);
    }

    function test_canonicalNavFailsClosedWhenLiabilitiesExceedAssets() public {
        vm.expectRevert(stdError.arithmeticError);
        units.canonicalNetAssets(99e6, 100e6);
    }

    function test_v2DtoTupleOrderRoundTrips() public pure {
        IAssetNeutralOptionsAdapterV2.OpenPositionDataV2 memory openData =
            IAssetNeutralOptionsAdapterV2.OpenPositionDataV2({
                quote: BatchSettler.Quote({
                    oToken: address(0xA11CE),
                    bidPrice: 25e6,
                    deadline: 123,
                    quoteId: 456,
                    maxAmount: 2e8,
                    makerNonce: 789
                }),
                signature: hex"1234",
                optionAmount8: 2e8,
                collateralAmount: 140_000e6
            });
        IAssetNeutralOptionsAdapterV2.OpenPositionDataV2 memory decodedOpen =
            abi.decode(abi.encode(openData), (IAssetNeutralOptionsAdapterV2.OpenPositionDataV2));
        assertEq(decodedOpen.quote.oToken, address(0xA11CE));
        assertEq(decodedOpen.quote.bidPrice, 25e6);
        assertEq(decodedOpen.optionAmount8, 2e8);
        assertEq(decodedOpen.collateralAmount, 140_000e6);
        assertEq(decodedOpen.signature, hex"1234");

        IAssetNeutralWheelV2.AssignmentLotV2 memory lot = IAssetNeutralWheelV2.AssignmentLotV2({
            originCspLane: address(0xC5F),
            createdAt: 123,
            status: IAssetNeutralWheelV2.LotStatus.Available,
            trancheId: 7,
            originCspPositionId: 8,
            underlyingReceivedAmount: 1e8,
            remainingUnderlyingAmount: 1e8,
            literalAssignmentStrikeUsd8: 70_000e8
        });
        IAssetNeutralWheelV2.AssignmentLotV2 memory decodedLot =
            abi.decode(abi.encode(lot), (IAssetNeutralWheelV2.AssignmentLotV2));
        assertEq(decodedLot.originCspLane, address(0xC5F));
        assertEq(decodedLot.underlyingReceivedAmount, 1e8);
        assertEq(decodedLot.remainingUnderlyingAmount, 1e8);
        assertEq(decodedLot.literalAssignmentStrikeUsd8, 70_000e8);
    }

    function test_v2SelectorsAndEventSignaturesAreFrozen() public pure {
        assertEq(IAssetNeutralOptionsAdapterV2.assetConfigV2.selector, bytes4(keccak256("assetConfigV2()")));
        assertEq(IAssetNeutralOptionsAdapterV2.adapterStateV2.selector, bytes4(keccak256("adapterStateV2()")));
        assertEq(IAssetNeutralOptionsAdapterV2.positionV2.selector, bytes4(keccak256("positionV2(uint256)")));
        assertEq(
            keccak256(
                "AssetNeutralPositionOpenedV2(uint256,uint256,address,uint8,address,address,address,address,uint256,uint256,uint256,uint256,bytes32)"
            ),
            IAssetNeutralOptionsAdapterV2.AssetNeutralPositionOpenedV2.selector
        );
        assertEq(
            keccak256(
                "AssetNeutralPositionTransitionedV2(uint256,uint256,uint8,uint256,uint256,uint256,uint256,bytes32)"
            ),
            IAssetNeutralOptionsAdapterV2.AssetNeutralPositionTransitionedV2.selector
        );
        assertEq(IAssetNeutralWheelV2.summaryV2.selector, bytes4(keccak256("summaryV2()")));
        assertEq(IAssetNeutralWheelV2.trancheV2.selector, bytes4(keccak256("trancheV2(uint256)")));
        assertEq(
            keccak256("AssetNeutralWheelChildHandoffV2(uint256,address,bytes32,uint8,uint256,uint256,uint256)"),
            IAssetNeutralWheelV2.AssetNeutralWheelChildHandoffV2.selector
        );
    }
}
