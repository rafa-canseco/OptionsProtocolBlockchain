// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/libraries/TickMath.sol";

contract TickMathTest is Test {
    function testCanonicalVectors() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(0), uint160(1 << 96));
        assertEq(TickMath.getSqrtRatioAtTick(1), uint160(79232123823359799118286999568));
        assertEq(TickMath.getSqrtRatioAtTick(-1), uint160(79224201403219477170569942574));
        assertEq(TickMath.getSqrtRatioAtTick(-6298), uint160(57826524214715807163796057747));
        assertEq(TickMath.getSqrtRatioAtTick(-887272), TickMath.MIN_SQRT_RATIO);
        assertEq(TickMath.getSqrtRatioAtTick(887272), TickMath.MAX_SQRT_RATIO);
    }

    function testFuzzTickRoundTrip(int24 tick) public pure {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        assertGe(sqrtPrice, TickMath.MIN_SQRT_RATIO);
        assertLe(sqrtPrice, TickMath.MAX_SQRT_RATIO);
    }
}
