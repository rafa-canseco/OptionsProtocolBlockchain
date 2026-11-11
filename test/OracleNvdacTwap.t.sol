// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Oracle.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TwapTokenMock {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract TwapNvdacMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract TwapUsdcFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp - 100, block.timestamp - 100, 1);
    }
}

contract TwapReferenceFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 18_771_759_854, block.timestamp - 100, block.timestamp - 100, 1);
    }
}

contract TwapBadReferenceFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 10_000_000_000, block.timestamp - 100, block.timestamp - 100, 1);
    }
}

contract TwapStaleReferenceFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 18_771_759_854, block.timestamp - 7200, block.timestamp - 7200, 1);
    }
}

contract TwapNonpositiveReferenceFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 0, block.timestamp - 100, block.timestamp - 100, 1);
    }
}

contract TwapUnavailableReferenceFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert();
    }
}

contract TwapFutureReferenceFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 18_771_759_854, block.timestamp + 1, block.timestamp + 1, 1);
    }
}

contract TwapBoundaryUsdcFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, int256(uint256(type(uint128).max)), block.timestamp - 100, block.timestamp - 100, 1);
    }
}

contract TwapOverBoundaryUsdcFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, int256(uint256(type(uint128).max) + 1), block.timestamp - 100, block.timestamp - 100, 1);
    }
}

contract TwapHugeUsdcFeedMock {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, type(int256).max, block.timestamp - 100, block.timestamp - 100, 1);
    }
}

contract TwapFactoryMock {
    function getPool(address, address, int24) external pure returns (address) {
        return 0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC;
    }
}

contract TwapPoolMock {
    function factory() external pure returns (address) {
        return 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    }

    function token0() external pure returns (address) {
        return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    }

    function token1() external pure returns (address) {
        return 0xb20000000000000000000078ee7ce2fE4908108C;
    }

    function tickSpacing() external pure returns (int24) {
        return 10;
    }

    function fee() external pure returns (uint24) {
        return 1175;
    }

    function liquidity() external pure returns (uint128) {
        return 1e15;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (1 << 96, -6298, 1, 1801, 1801, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (uint32(block.timestamp), 0, 1, true);
    }

    function observe(uint32[] calldata secondsAgos) external pure returns (int56[] memory t, uint160[] memory l) {
        require(secondsAgos[0] == 3700 && secondsAgos[1] == 100);
        t = new int56[](2);
        l = new uint160[](2);
        t[0] = 0;
        t[1] = -22_669_901;
        l[0] = 0;
        l[1] = uint160((uint256(3_600) << 128) / 1e15);
    }
}

contract OracleNvdacTwapTest is Test {
    address constant ASSET = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant POOL = 0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC;
    address constant FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address constant USDC_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant REFERENCE_FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    Oracle oracle;
    uint256 expiry;

    function setUp() public {
        vm.warp(1_699_790_400); // Sunday, 2023-11-12 12:00 UTC.
        vm.etch(USDC, address(new TwapTokenMock()).code);
        vm.etch(ASSET, address(new TwapNvdacMock()).code);
        vm.etch(POOL, address(new TwapPoolMock()).code);
        vm.etch(FACTORY, address(new TwapFactoryMock()).code);
        vm.etch(USDC_FEED, address(new TwapUsdcFeedMock()).code);
        vm.etch(REFERENCE_FEED, address(new TwapReferenceFeedMock()).code);
        oracle = Oracle(
            address(
                new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(1), address(this))))
            )
        );
        oracle.configureNvdacTwap(POOL, FACTORY, USDC, 7200, 1, 3600, 3600, 100, true);
        expiry = block.timestamp - 100;
    }

    function testSettlesUsingExactExpiryWindowAndWritesOnce() public {
        oracle.setOperator(address(0xB07));
        vm.prank(address(0xB07));
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
        (uint256 price, bool set) = oracle.getExpiryPrice(ASSET, expiry);
        assertTrue(set);
        assertEq(price, 18_771_759_854);
        vm.expectRevert(Oracle.PriceAlreadySet.selector);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
        assertTrue(oracle.marketHoursAsset(ASSET) == false);
        assertFalse(oracle.legacyPostExpiryAsset(ASSET));
    }

    function testRouteDisabledByDefaultAndAssetScoped() public {
        vm.warp(expiry + 1);
        vm.expectRevert(Oracle.InvalidNvdacTwapConfig.selector);
        oracle.setExpiryPriceFromNvdacTwap(address(0x123), expiry);
    }

    function testOwnerCanDisableAndReenableRoute() public {
        oracle.setNvdacTwapEnabled(false);
        vm.expectRevert(Oracle.InvalidNvdacTwapConfig.selector);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);

        vm.prank(address(0xB07));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setNvdacTwapEnabled(true);

        oracle.setNvdacTwapEnabled(true);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
        (, bool set) = oracle.getExpiryPrice(ASSET, expiry);
        assertTrue(set);
    }

    function testFreshReferenceDeviationFailsClosed() public {
        vm.etch(REFERENCE_FEED, address(new TwapBadReferenceFeedMock()).code);
        vm.expectRevert(
            abi.encodeWithSelector(Oracle.PriceDeviationTooHigh.selector, 18_771_759_854, 10_000_000_000, 8772)
        );
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
    }

    function testHugeUsdcAnswerFailsWithInvalidPrice() public {
        vm.etch(USDC_FEED, address(new TwapHugeUsdcFeedMock()).code);
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
    }

    function testWeekendStaleReferenceIsAllowedByConfiguredPolicy() public {
        vm.etch(REFERENCE_FEED, address(new TwapStaleReferenceFeedMock()).code);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
        (, bool set) = oracle.getExpiryPrice(ASSET, expiry);
        assertTrue(set);
    }

    function testWeekendUnavailableReferenceIsAllowedByConfiguredPolicy() public {
        vm.etch(REFERENCE_FEED, address(new TwapUnavailableReferenceFeedMock()).code);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
        (, bool set) = oracle.getExpiryPrice(ASSET, expiry);
        assertTrue(set);
    }

    function testWeekdayStaleAndUnavailableReferenceFailClosed() public {
        vm.warp(1_699_876_800); // Monday, 2023-11-13 12:00 UTC.
        expiry = block.timestamp - 100;

        vm.etch(REFERENCE_FEED, address(new TwapStaleReferenceFeedMock()).code);
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);

        vm.etch(REFERENCE_FEED, address(new TwapUnavailableReferenceFeedMock()).code);
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
    }

    function testNonpositiveReferenceFailsClosedOnWeekend() public {
        vm.etch(REFERENCE_FEED, address(new TwapNonpositiveReferenceFeedMock()).code);
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
    }

    function testMalformedFutureReferenceFailsClosed() public {
        vm.etch(REFERENCE_FEED, address(new TwapFutureReferenceFeedMock()).code);
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
    }

    function testFeedAnswerUpperBoundaryAcceptedAndAboveBoundaryRejected() public {
        vm.etch(REFERENCE_FEED, address(new TwapStaleReferenceFeedMock()).code);
        vm.etch(USDC_FEED, address(new TwapBoundaryUsdcFeedMock()).code);
        oracle.setExpiryPriceFromNvdacTwap(ASSET, expiry);
        (uint256 price, bool set) = oracle.getExpiryPrice(ASSET, expiry);
        assertTrue(set);
        assertGt(price, type(uint128).max);

        Oracle fresh = _newOracle();
        fresh.configureNvdacTwap(POOL, FACTORY, USDC, 7200, 1, 3600, 3600, 100, true);
        vm.etch(USDC_FEED, address(new TwapOverBoundaryUsdcFeedMock()).code);
        vm.expectRevert(Oracle.InvalidPrice.selector);
        fresh.setExpiryPriceFromNvdacTwap(ASSET, expiry);
    }

    function testMaxSettlementDelayCannotExceedBackendBound() public {
        Oracle fresh = Oracle(
            address(
                new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(1), address(this))))
            )
        );
        vm.expectRevert(Oracle.InvalidNvdacTwapConfig.selector);
        fresh.configureNvdacTwap(POOL, FACTORY, USDC, 1 days + 1, 1, 3600, 3600, 100, true);
    }

    function testBackendMaxSettlementDelayBoundaryAccepted() public {
        Oracle fresh = _newOracle();
        fresh.configureNvdacTwap(POOL, FACTORY, USDC, 1 days, 1, 3600, 3600, 100, true);
        (,,,,, uint32 configuredDelay,,,,,) = fresh.nvdacTwapConfig();
        assertEq(configuredDelay, 1 days);
    }

    function _newOracle() private returns (Oracle) {
        return Oracle(
            address(
                new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(1), address(this))))
            )
        );
    }
}
