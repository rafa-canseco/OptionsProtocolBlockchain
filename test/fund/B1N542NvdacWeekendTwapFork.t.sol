// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface INvdacSlipstreamPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IUsdFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface INvdacOracle {
    error InvalidCloseWindow();
    error OnlyOwner();
    error StaleOraclePrice(uint256 updatedAt, uint256 maxAge);

    function owner() external view returns (address);
    function operator() external view returns (address);
    function priceDeviationThresholdBps() external view returns (uint256);
    function maxOracleStaleness() external view returns (uint256);
    function priceFeed(address asset) external view returns (address);
    function marketHoursAsset(address asset) external view returns (bool);
    function legacyPostExpiryAsset(address asset) external view returns (bool);
    function setMarketHoursAsset(address asset, bool enabled) external;
    function setLegacyPostExpiryAsset(address asset, bool enabled) external;
    function setPriceDeviationThreshold(uint256 thresholdBps) external;
    function setExpiryPrice(address asset, uint256 expiry, uint256 price) external;
    function getExpiryPrice(address asset, uint256 expiry) external view returns (uint256, bool);
}

contract B1N542NvdacWeekendTwapForkTest is Test {
    address private constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant PRICE_POOL = 0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC;
    address private constant ORACLE = 0x09daa0194A3AF59b46C5443aF9C20fAd98347671;
    address private constant PRICE_POOL_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
    address private constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    uint32 private constant TWAP_WINDOW = 1 hours;
    uint256 private constant FORK_BLOCK = 54_889_141;

    INvdacSlipstreamPool private pool = INvdacSlipstreamPool(PRICE_POOL);
    INvdacOracle private oracle = INvdacOracle(ORACLE);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        assertEq(block.chainid, 8453, "expected Base mainnet fork");
    }

    function testSelectedPoolHasUsableOneHourTwapAndLiquidity() public view {
        assertEq(pool.token0(), USDC);
        assertEq(pool.token1(), NVDAC);
        assertGt(pool.liquidity(), 0);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        (int56[] memory ticks, uint160[] memory secondsPerLiquidity) = pool.observe(secondsAgos);
        assertEq(ticks.length, 2);
        assertEq(secondsPerLiquidity.length, 2);
        int56 delta = ticks[1] - ticks[0];
        int56 meanTick = delta / int56(uint56(TWAP_WINDOW));
        if (delta < 0 && delta % int56(uint56(TWAP_WINDOW)) != 0) meanTick--;
        assertGe(meanTick, -887272);
        assertLe(meanTick, 887272);
        assertGt(secondsPerLiquidity[1], secondsPerLiquidity[0]);
    }

    function testUpgradedOracleCanStoreApprovedPoolTwapWithoutChangingGlobalGuards() public {
        (,,, uint256 usdcUpdatedAt,) = IUsdFeed(USDC_USD_FEED).latestRoundData();
        assertLe(usdcUpdatedAt, block.timestamp);
        assertLe(block.timestamp - usdcUpdatedAt, 1 days);

        Oracle upgraded = Oracle(
            address(
                new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(1), address(this))))
            )
        );
        upgraded.configureNvdacTwap(PRICE_POOL, PRICE_POOL_FACTORY, USDC, 1 days, 1, 72 hours, 1, 10_000, true);
        uint256 expiry = block.timestamp;
        upgraded.setExpiryPriceFromNvdacTwap(NVDAC, expiry);

        (uint256 price, bool isSet) = upgraded.getExpiryPrice(NVDAC, expiry);
        assertTrue(isSet);
        assertGt(price, 0);
        assertEq(upgraded.priceDeviationThresholdBps(), 0);
        assertEq(upgraded.maxOracleStaleness(), 0);
        assertFalse(upgraded.marketHoursAsset(NVDAC));
        assertFalse(upgraded.legacyPostExpiryAsset(NVDAC));
    }

    function testExistingOracleRejectsTwapEvenWithDeviationThresholdDisabled() public {
        address owner = oracle.owner();
        address operator = oracle.operator();
        assertEq(owner, 0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7);
        assertEq(operator, 0x0bbD599cEB63b4603c2F007c5122e33f7b12364c);
        assertNotEq(owner, operator);
        assertTrue(oracle.marketHoursAsset(NVDAC));

        vm.prank(operator);
        vm.expectRevert(INvdacOracle.OnlyOwner.selector);
        oracle.setPriceDeviationThreshold(0);

        uint256 originalThreshold = oracle.priceDeviationThresholdBps();
        uint256 expiry = _unusedPastExpiry();
        vm.prank(owner);
        oracle.setPriceDeviationThreshold(0);
        vm.prank(operator);
        vm.expectRevert(INvdacOracle.InvalidCloseWindow.selector);
        oracle.setExpiryPrice(NVDAC, expiry, 187e8);

        assertEq(oracle.priceDeviationThresholdBps(), 0);
        (, bool isSet) = oracle.getExpiryPrice(NVDAC, expiry);
        assertFalse(isSet);

        vm.prank(owner);
        oracle.setPriceDeviationThreshold(originalThreshold);
        assertEq(oracle.priceDeviationThresholdBps(), originalThreshold);
    }

    function testConfigOnlyPathCanStoreTwapWithTemporaryFlagChanges() public {
        address owner = oracle.owner();
        address operator = oracle.operator();
        assertTrue(oracle.marketHoursAsset(NVDAC));
        assertFalse(oracle.legacyPostExpiryAsset(NVDAC));

        uint256 expiry = _unusedPastExpiry();
        uint256 originalThreshold = oracle.priceDeviationThresholdBps();
        assertEq(originalThreshold, 1_000);
        assertEq(oracle.maxOracleStaleness(), 3_600);
        assertNotEq(oracle.priceFeed(NVDAC), address(0));

        vm.prank(owner);
        oracle.setMarketHoursAsset(NVDAC, false);
        vm.prank(owner);
        oracle.setLegacyPostExpiryAsset(NVDAC, true);
        assertFalse(oracle.marketHoursAsset(NVDAC));
        assertTrue(oracle.legacyPostExpiryAsset(NVDAC));

        vm.warp(block.timestamp + 3_601);
        vm.prank(operator);
        vm.expectPartialRevert(INvdacOracle.StaleOraclePrice.selector);
        oracle.setExpiryPrice(NVDAC, expiry, 187e8);

        vm.prank(owner);
        oracle.setPriceDeviationThreshold(0);
        vm.prank(operator);
        oracle.setExpiryPrice(NVDAC, expiry, 187e8);
        (uint256 price, bool isSet) = oracle.getExpiryPrice(NVDAC, expiry);
        assertTrue(isSet);
        assertEq(price, 187e8);

        vm.prank(owner);
        oracle.setPriceDeviationThreshold(originalThreshold);
        assertEq(oracle.priceDeviationThresholdBps(), originalThreshold);
        vm.prank(owner);
        oracle.setMarketHoursAsset(NVDAC, true);
        vm.prank(owner);
        oracle.setLegacyPostExpiryAsset(NVDAC, false);
        assertTrue(oracle.marketHoursAsset(NVDAC));
        assertFalse(oracle.legacyPostExpiryAsset(NVDAC));
        (price, isSet) = oracle.getExpiryPrice(NVDAC, expiry);
        assertTrue(isSet);
        assertEq(price, 187e8);
    }

    function _unusedPastExpiry() private view returns (uint256 expiry) {
        expiry = block.timestamp - 1;
        for (uint256 i; i < 1 hours; ++i) {
            (, bool isSet) = oracle.getExpiryPrice(NVDAC, expiry);
            if (!isSet) return expiry;
            expiry--;
        }
        revert("no unused NVDAc expiry found");
    }
}
