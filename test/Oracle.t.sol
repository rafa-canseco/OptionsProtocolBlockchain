// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Oracle.sol";
import "../src/core/AddressBook.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockChainlinkFeed {
    int256 public price;
    uint256 public lastUpdated;

    constructor(int256 _price) {
        price = _price;
        lastUpdated = block.timestamp;
    }

    function setPrice(int256 _price) external {
        price = _price;
        lastUpdated = block.timestamp;
    }

    function setUpdatedAt(uint256 _ts) external {
        lastUpdated = _ts;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, lastUpdated, lastUpdated, 1);
    }
}

contract OracleTest is Test {
    AddressBook public addressBook;
    Oracle public oracle;
    MockChainlinkFeed public ethFeed;

    address public weth = address(0x1111);
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );

        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), address(this)))
                )
            )
        );

        ethFeed = new MockChainlinkFeed(2087e8); // $2087 in 8 decimals

        oracle.setPriceFeed(weth, address(ethFeed));

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }

    function test_getLivePrice() public view {
        uint256 price = oracle.getPrice(weth);
        assertEq(price, 2087e8);
    }

    function test_revertNoFeed() public {
        vm.expectRevert(Oracle.FeedNotSet.selector);
        oracle.getPrice(address(0xDEAD));
    }

    function test_cannotSetExpiryPriceBeforeExpiry() public {
        vm.expectRevert(Oracle.ExpiryNotReached.selector);
        oracle.setExpiryPrice(weth, expiry, 2100e8);
    }

    function test_setExpiryPrice() public {
        vm.warp(expiry);
        oracle.setExpiryPrice(weth, expiry, 2100e8);

        (uint256 price, bool isSet) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 2100e8);
        assertTrue(isSet);
    }

    function test_expiryPriceNotSetByDefault() public view {
        (uint256 price, bool isSet) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 0);
        assertFalse(isSet);
    }

    function test_cannotSetExpiryPriceTwice() public {
        vm.warp(expiry);
        oracle.setExpiryPrice(weth, expiry, 2100e8);

        vm.expectRevert(Oracle.PriceAlreadySet.selector);
        oracle.setExpiryPrice(weth, expiry, 2200e8);
    }

    function test_cannotSetZeroPrice() public {
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPrice(weth, expiry, 0);
    }

    function test_onlyOwnerCanSetFeed() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setPriceFeed(weth, address(ethFeed));
    }

    function test_onlyOwnerOrOperatorCanSetExpiryPrice() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Oracle.OnlyOwnerOrOperator.selector);
        oracle.setExpiryPrice(weth, expiry, 2100e8);
    }

    function test_operatorCanSetExpiryPrice() public {
        address op = address(0x0BE);
        oracle.setOperator(op);

        vm.warp(expiry);
        vm.prank(op);
        oracle.setExpiryPrice(weth, expiry, 2100e8);

        (uint256 price, bool isSet) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 2100e8);
        assertTrue(isSet);
    }

    function test_setOperator() public {
        address op = address(0x0BE);
        oracle.setOperator(op);
        assertEq(oracle.operator(), op);
    }

    function test_onlyOwnerCanSetOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setOperator(address(0x0BE));
    }

    function test_cannotSetZeroOperator() public {
        vm.expectRevert(Oracle.InvalidAddress.selector);
        oracle.setOperator(address(0));
    }

    function test_differentExpiriesDifferentPrices() public {
        vm.warp(expiry + 7 days);
        oracle.setExpiryPrice(weth, expiry, 2100e8);
        oracle.setExpiryPrice(weth, expiry + 7 days, 2200e8);

        (uint256 price1,) = oracle.getExpiryPrice(weth, expiry);
        (uint256 price2,) = oracle.getExpiryPrice(weth, expiry + 7 days);

        assertEq(price1, 2100e8);
        assertEq(price2, 2200e8);
    }

    // --- Price Deviation Bounds ---

    function test_setPriceDeviationThreshold() public {
        oracle.setPriceDeviationThreshold(2000); // 20%
        assertEq(oracle.priceDeviationThresholdBps(), 2000);
    }

    function test_onlyOwnerCanSetDeviationThreshold() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setPriceDeviationThreshold(2000);
    }

    function test_boundsCheckSkippedWhenThresholdZero() public {
        vm.warp(expiry);
        // threshold=0 (default) → no check, any price accepted
        oracle.setExpiryPrice(weth, expiry, 9999e8);
        (uint256 price,) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 9999e8);
    }

    function test_boundsCheckSkippedWhenNoFeed() public {
        vm.warp(expiry);
        oracle.setPriceDeviationThreshold(1000); // 10%
        address noFeedAsset = address(0xAAAA);
        // No feed set for this asset → skip check
        oracle.setExpiryPrice(noFeedAsset, expiry, 9999e8);
        (uint256 price,) = oracle.getExpiryPrice(noFeedAsset, expiry);
        assertEq(price, 9999e8);
    }

    function test_expiryPriceWithinThresholdAccepted() public {
        vm.warp(expiry);
        // Feed = 2087e8, threshold = 20% (2000 bps)
        // 2087 * 1.20 = 2504.4, 2087 * 0.80 = 1669.6
        oracle.setPriceDeviationThreshold(2000);
        oracle.setExpiryPrice(weth, expiry, 2400e8); // within 20%
        (uint256 price,) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 2400e8);
    }

    function test_expiryPriceAtExactThresholdAccepted() public {
        vm.warp(expiry);
        // Feed = 2087e8, threshold = 2000 bps (20%)
        // Deviation = |2087 - 2504| / 2087 ≈ 19.98% → within 20%
        oracle.setPriceDeviationThreshold(2000);
        oracle.setExpiryPrice(weth, expiry, 2504e8);
        (uint256 price,) = oracle.getExpiryPrice(weth, expiry);
        assertEq(price, 2504e8);
    }

    function test_expiryPriceExceedingThresholdReverts() public {
        vm.warp(expiry);
        // Feed = 2087e8, threshold = 10% (1000 bps)
        // diff = 313e8, deviation = 313e8 * 10000 / 2087e8 = 1499 bps
        oracle.setPriceDeviationThreshold(1000);
        vm.expectRevert(abi.encodeWithSelector(Oracle.PriceDeviationTooHigh.selector, 2400e8, 2087e8, 1499));
        oracle.setExpiryPrice(weth, expiry, 2400e8);
    }

    function test_expiryPriceBelowThresholdReverts() public {
        vm.warp(expiry);
        // Feed = 2087e8, threshold = 10% (1000 bps)
        // diff = 587e8, deviation = 587e8 * 10000 / 2087e8 = 2812 bps
        oracle.setPriceDeviationThreshold(1000);
        vm.expectRevert(abi.encodeWithSelector(Oracle.PriceDeviationTooHigh.selector, 1500e8, 2087e8, 2812));
        oracle.setExpiryPrice(weth, expiry, 1500e8);
    }

    function test_fatFingerPriceRejected() public {
        vm.warp(expiry);
        // Feed = 2087e8, threshold = 20%
        // diff = 1879e8, deviation = 1879e8 * 10000 / 2087e8 = 9003 bps
        oracle.setPriceDeviationThreshold(2000);
        vm.expectRevert(abi.encodeWithSelector(Oracle.PriceDeviationTooHigh.selector, 208e8, 2087e8, 9003));
        oracle.setExpiryPrice(weth, expiry, 208e8);
    }

    function test_wrongDecimalsPriceRejected() public {
        vm.warp(expiry);
        // Feed = 2087e8, threshold = 20%
        // diff = 206613e6, deviation = 206613e6 * 10000 / 2087e8 = 9900 bps
        oracle.setPriceDeviationThreshold(2000);
        vm.expectRevert(abi.encodeWithSelector(Oracle.PriceDeviationTooHigh.selector, 2087e6, 2087e8, 9900));
        oracle.setExpiryPrice(weth, expiry, 2087e6);
    }

    // --- Oracle Staleness ---

    function test_setMaxOracleStaleness() public {
        oracle.setMaxOracleStaleness(7200);
        assertEq(oracle.maxOracleStaleness(), 7200);
    }

    function test_onlyOwnerCanSetMaxStaleness() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setMaxOracleStaleness(3600);
    }

    function test_getPriceRevertsWhenStale() public {
        oracle.setMaxOracleStaleness(3600);
        // Make feed stale: updatedAt = now - 7200
        ethFeed.setUpdatedAt(block.timestamp - 7200);

        vm.expectRevert(abi.encodeWithSelector(Oracle.StaleOraclePrice.selector, block.timestamp - 7200, 3600));
        oracle.getPrice(weth);
    }

    function test_getPricePassesWhenFresh() public {
        oracle.setMaxOracleStaleness(3600);
        // Feed is fresh (updatedAt = now via setPrice)
        uint256 price = oracle.getPrice(weth);
        assertEq(price, 2087e8);
    }

    function test_stalenessDisabledWhenZero() public {
        // maxOracleStaleness = 0 (default) → no staleness check
        ethFeed.setUpdatedAt(block.timestamp - 999999);
        uint256 price = oracle.getPrice(weth);
        assertEq(price, 2087e8);
    }

    function test_setExpiryPriceRevertsWhenStale() public {
        vm.warp(expiry);
        oracle.setMaxOracleStaleness(3600);
        oracle.setPriceDeviationThreshold(1000);
        ethFeed.setUpdatedAt(block.timestamp - 7200);

        vm.expectRevert(abi.encodeWithSelector(Oracle.StaleOraclePrice.selector, block.timestamp - 7200, 3600));
        oracle.setExpiryPrice(weth, expiry, 2087e8);
    }

    function test_stalenessBoundary_exactlyAtThreshold() public {
        oracle.setMaxOracleStaleness(3600);
        // updatedAt = now - 3600 → diff == maxAge, should pass
        ethFeed.setUpdatedAt(block.timestamp - 3600);
        uint256 price = oracle.getPrice(weth);
        assertEq(price, 2087e8);
    }

    function test_stalenessBoundary_oneSecondOver() public {
        oracle.setMaxOracleStaleness(3600);
        // updatedAt = now - 3601 → diff > maxAge, should revert
        ethFeed.setUpdatedAt(block.timestamp - 3601);
        vm.expectRevert(abi.encodeWithSelector(Oracle.StaleOraclePrice.selector, block.timestamp - 3601, 3600));
        oracle.getPrice(weth);
    }

    function test_deviationRevertsWhenChainlinkAnswerZero() public {
        vm.warp(expiry);
        oracle.setPriceDeviationThreshold(1000);
        ethFeed.setPrice(0);

        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPrice(weth, expiry, 2000e8);
    }

    function test_deviationRevertsWhenChainlinkAnswerNegative() public {
        vm.warp(expiry);
        oracle.setPriceDeviationThreshold(1000);
        ethFeed.setPrice(-100);

        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPrice(weth, expiry, 2000e8);
    }
}
