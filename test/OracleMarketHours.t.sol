// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/Oracle.sol";

contract MarketHoursFeed {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    mapping(uint80 => Round) private rounds;
    mapping(uint16 => address) public phaseAggregators;
    uint16 public phaseId;
    uint80 public roundId = 1;

    constructor(int256 _answer, uint256 _updatedAt) {
        _setRound(1, _answer, _updatedAt);
    }

    function _setRound(uint80 _roundId, int256 _answer, uint256 _updatedAt) private {
        rounds[_roundId] = Round(_answer, _updatedAt, _updatedAt, _roundId);
    }

    function setRoundData(int256 _answer, uint256 _updatedAt) external {
        roundId++;
        _setRound(roundId, _answer, _updatedAt);
    }

    function setPhase(uint16 _phaseId, address _aggregator) external {
        phaseAggregators[_phaseId] = _aggregator;
    }

    function setCurrentPhase(uint16 _phaseId) external {
        phaseId = _phaseId;
    }

    function setCompositeRound(uint16 _phaseId, uint64 _localRoundId, int256 _answer, uint256 _updatedAt) external {
        roundId = uint80((uint256(_phaseId) << 64) | _localRoundId);
        _setRound(roundId, _answer, _updatedAt);
    }

    function setRoundMetadata(uint80 _roundId, uint80 _answeredInRound) external {
        rounds[_roundId].answeredInRound = _answeredInRound;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory round = rounds[roundId];
        return (roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    function getRoundData(uint80 _roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory round = rounds[_roundId];
        if (round.updatedAt == 0) revert();
        return (_roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }
}

contract OracleMarketHoursTest is Test {
    Oracle internal oracle;
    MarketHoursFeed internal feed;
    address internal asset = address(0xA55E7);
    address internal operator = address(0xB07);

    function setUp() public {
        vm.warp(1_000_000);
        oracle = Oracle(
            address(
                new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(1), address(this))))
            )
        );
        feed = new MarketHoursFeed(2_000e8, block.timestamp);
        oracle.setPriceFeed(asset, address(feed));
        oracle.setOperator(operator);
        oracle.setPriceDeviationThreshold(100);
        oracle.setMaxOracleStaleness(1 hours);
    }

    function testLiveExpiryPriceKeepsOneHourFreshness() public {
        vm.warp(block.timestamp + 1);
        uint256 expiry = block.timestamp - 1;
        oracle.setExpiryPrice(asset, expiry, 2_000e8);

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testLivePriceRejectsFutureRound() public {
        feed.setRoundData(2_000e8, block.timestamp + 1);

        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.getPrice(asset);
    }

    function testMarketHoursDoesNotRelaxLivePriceFreshness() public {
        oracle.setMarketHoursAsset(asset, true);
        feed.setRoundData(2_000e8, block.timestamp - 1 hours - 1);

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.StaleOraclePrice.selector, block.timestamp - 1 hours - 1, uint256(1 hours))
        );
        oracle.getPrice(asset);
    }

    function testClosePathAcceptsFinalizedPriorClose() public {
        oracle.setMarketHoursAsset(asset, true);

        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 6 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        vm.warp(expiry);
        feed.setRoundData(2_000e8, 1_007_199);

        vm.prank(operator);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testClosePathRejectsExpiryAtSessionClose() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp - 1 hours;
        uint256 expiry = closeAt;
        uint256 nextOpen = closeAt + 4 hours;
        feed.setRoundData(2_000e8, closeAt);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testCloseWindowCannotBeRewritten() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
    }

    function testClosePathRejectsAfterNextSessionOpens() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 3 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        feed.setRoundData(2_000e8, closeAt + 1_800);

        vm.warp(nextOpen);
        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathRejectsIncompleteFeedRound() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        vm.warp(expiry);
        feed.setRoundData(2_000e8, closeAt);
        feed.setRoundMetadata(2, 1);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathRejectsFeedOutsideCloseCaptureWindow() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        uint256 preClose = closeAt - 1;
        vm.warp(expiry);
        feed.setRoundData(2_000e8, preClose);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testMarketHoursAssetActivationIsOwnerOnly() public {
        vm.prank(operator);
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setMarketHoursAsset(asset, true);
    }

    function testCloseWindowIsOwnerOnly() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 expiry = block.timestamp + 2 hours;
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 nextOpen = block.timestamp + 4 hours;

        vm.prank(operator);
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
    }

    function testClosePathIsDisabledByDefault() public {
        uint256 closeAt = block.timestamp - 4 hours;
        uint256 expiry = block.timestamp - 1 hours;
        uint256 nextOpen = block.timestamp + 4 hours;

        vm.expectRevert(Oracle.MarketHoursAssetNotEnabled.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathRejectsCloseOlderThanNinetySixHours() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = closeAt + 96 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        vm.warp(closeAt + 96 hours + 1);
        feed.setRoundData(2_000e8, closeAt);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testGenericExpiryPriceRejectsMarketHoursAsset() public {
        oracle.setMarketHoursAsset(asset, true);
        vm.warp(block.timestamp + 1);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPrice(asset, block.timestamp - 1, 2_000e8);
    }

    function testClosePathRequiresPrecommittedWindow() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        vm.warp(expiry);
        feed.setRoundData(2_000e8, 1_007_199);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt + 1, nextOpen);
    }

    function testClosePathRejectsPostExpiryRound() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        vm.warp(expiry);
        feed.setRoundData(2_000e8, expiry + 1);
        vm.warp(expiry + 1);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathRejectsLaterRoundWithinCaptureWindow() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 6 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        feed.setRoundData(2_000e8, closeAt + 15 minutes);
        feed.setRoundData(2_000e8, closeAt + 30 minutes);
        vm.warp(expiry);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathCanUseHistoricalRoundAfterLatestUpdate() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp + 1 hours;
        uint256 expiry = block.timestamp + 2 hours;
        uint256 nextOpen = block.timestamp + 6 hours;
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        feed.setRoundData(2_000e8, 1_007_199);
        uint80 closeRoundId = feed.roundId();
        feed.setRoundData(2_100e8, expiry + 30 minutes);
        vm.warp(expiry + 30 minutes);

        vm.prank(operator);
        oracle.setExpiryPriceFromCloseAtRound(asset, expiry, 2_000e8, closeAt, nextOpen, closeRoundId);

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testGenericExpiryPriceAllowsDelayedSubmissionWithinExpiryFreshness() public {
        uint256 expiry = block.timestamp + 2 hours;
        feed.setRoundData(2_000e8, expiry - 30 minutes);
        vm.warp(expiry + 31 minutes);

        oracle.setExpiryPrice(asset, expiry, 2_000e8);

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testGenericExpiryPriceAtRoundRejectsNonFinalRound() public {
        uint256 expiry = block.timestamp + 2 hours;
        feed.setRoundData(2_000e8, expiry - 30 minutes);
        uint80 round = feed.roundId();
        feed.setRoundData(2_000e8, expiry - 10 minutes);
        feed.setRoundData(2_100e8, expiry + 1);
        vm.warp(expiry + 1);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceAtRound(asset, expiry, 2_000e8, round);
    }

    function testGenericExpiryPriceAtRoundRejectsPriceMismatchWhenThresholdIsZero() public {
        oracle.setPriceDeviationThreshold(0);
        uint256 expiry = block.timestamp + 2 hours;
        feed.setRoundData(2_000e8, expiry - 30 minutes);
        uint80 round = feed.roundId();
        feed.setRoundData(2_100e8, expiry + 1);
        vm.warp(expiry + 1);

        vm.expectRevert(abi.encodeWithSelector(Oracle.PriceDeviationTooHigh.selector, 2_100e8, 2_000e8, uint256(500)));
        oracle.setExpiryPriceAtRound(asset, expiry, 2_100e8, round);
    }

    function testGenericExpiryPriceAtRoundCanUseHistoricalRound() public {
        uint256 expiry = block.timestamp + 2 hours;
        feed.setRoundData(2_000e8, block.timestamp + 1 hours);
        uint80 round = feed.roundId();
        feed.setRoundData(2_100e8, expiry + 1);
        vm.warp(expiry + 1);

        oracle.setExpiryPriceAtRound(asset, expiry, 2_000e8, round);

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testGenericExpiryPriceAtRoundRejectsPostExpiryRound() public {
        uint256 expiry = block.timestamp + 1 hours;
        feed.setRoundData(2_000e8, expiry + 1);
        uint80 round = feed.roundId();
        vm.warp(expiry + 1);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceAtRound(asset, expiry, 2_000e8, round);
    }

    function testDeviationRoundsUpAtBoundary() public {
        oracle.setPriceDeviationThreshold(1_000);
        vm.warp(block.timestamp + 1);
        uint256 expiry = block.timestamp - 1;

        vm.expectRevert(abi.encodeWithSelector(Oracle.PriceDeviationTooHigh.selector, 220_019_000_000, 2_000e8, 1_001));
        oracle.setExpiryPrice(asset, expiry, 220_019_000_000);
    }
}
