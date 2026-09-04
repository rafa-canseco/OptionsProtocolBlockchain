// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/Oracle.sol";

contract MarketHoursFeed {
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(int256 _answer, uint256 _updatedAt) {
        answer = _answer;
        startedAt = _updatedAt;
        updatedAt = _updatedAt;
    }

    function setRoundData(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        startedAt = _updatedAt;
        updatedAt = _updatedAt;
        roundId = 1;
        answeredInRound = 1;
    }

    function setRoundMetadata(uint80 _roundId, uint80 _answeredInRound) external {
        roundId = _roundId;
        answeredInRound = _answeredInRound;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
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
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(1), address(this)))
                )
            )
        );
        feed = new MarketHoursFeed(2_000e8, block.timestamp);
        oracle.setPriceFeed(asset, address(feed));
        oracle.setOperator(operator);
        oracle.setPriceDeviationThreshold(100);
        oracle.setMaxOracleStaleness(1 hours);
    }

    function testLiveExpiryPriceKeepsOneHourFreshness() public {
        uint256 expiry = block.timestamp - 1;
        oracle.setExpiryPrice(asset, expiry, 2_000e8);

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
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

        uint256 closeAt = block.timestamp - 4 hours;
        uint256 expiry = block.timestamp - 1 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        feed.setRoundData(2_000e8, closeAt + 30 minutes);

        vm.prank(operator);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testClosePathRejectsExpiryAtSessionClose() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp;
        uint256 nextOpen = closeAt + 4 hours;
        feed.setRoundData(2_000e8, closeAt);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, closeAt, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathRejectsAfterNextSessionOpens() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp - 4 hours;
        uint256 expiry = block.timestamp - 1 hours;
        uint256 nextOpen = block.timestamp + 1 hours;
        feed.setRoundData(2_000e8, closeAt + 30 minutes);

        vm.warp(nextOpen);
        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathRejectsIncompleteFeedRound() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp - 4 hours;
        uint256 expiry = block.timestamp - 1 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        feed.setRoundData(2_000e8, closeAt);
        feed.setRoundMetadata(2, 1);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testClosePathRejectsFeedOutsideCloseCaptureWindow() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 closeAt = block.timestamp - 4 hours;
        uint256 expiry = block.timestamp - 1 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        feed.setRoundData(2_000e8, closeAt - 1 hours - 1);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }

    function testMarketHoursAssetActivationIsOwnerOnly() public {
        vm.prank(operator);
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setMarketHoursAsset(asset, true);
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
        uint256 closeAt = block.timestamp - 96 hours - 1;
        uint256 expiry = block.timestamp - 1 hours;
        uint256 nextOpen = block.timestamp + 4 hours;
        feed.setRoundData(2_000e8, closeAt + 30 minutes);

        vm.expectRevert(Oracle.InvalidCloseWindow.selector);
        oracle.setExpiryPriceFromClose(asset, expiry, 2_000e8, closeAt, nextOpen);
    }
}
