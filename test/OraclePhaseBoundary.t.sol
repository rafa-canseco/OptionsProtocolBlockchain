// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/Oracle.sol";

contract PhaseFeed {
    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    mapping(uint80 => Round) private rounds;
    mapping(uint16 => address) public phaseAggregators;
    uint16 public phaseId;
    uint80 public roundId;

    function setPhase(uint16 _phaseId, address _aggregator) external {
        phaseAggregators[_phaseId] = _aggregator;
    }

    function setCurrentPhase(uint16 _phaseId) external {
        phaseId = _phaseId;
    }

    function setRound(uint16 _phaseId, uint64 _localRoundId, int256 _answer, uint256 _updatedAt) external {
        uint80 compositeRoundId = uint80((uint256(_phaseId) << 64) | _localRoundId);
        roundId = compositeRoundId;
        rounds[compositeRoundId] = Round(_answer, _updatedAt, _updatedAt, compositeRoundId);
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

contract LocalFeed {
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;

    function setRound(uint80 _roundId, int256 _answer, uint256 _updatedAt) external {
        roundId = _roundId;
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract OraclePhaseBoundaryTest is Test {
    Oracle internal oracle;
    LocalFeed internal previous;
    PhaseFeed internal feed;
    address internal asset = address(0xA55E7);

    function setUp() public {
        vm.warp(1_000_000);
        oracle = Oracle(
            address(
                new ERC1967Proxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(1), address(this))))
            )
        );
        oracle.setPriceDeviationThreshold(100);
        oracle.setMaxOracleStaleness(1 hours);
    }

    function testActiveChainlinkPhaseCanBeFinalized() public {
        feed = new PhaseFeed();
        feed.setCurrentPhase(2);
        oracle.setChainlinkPhase(address(feed), 2, 1, 0, block.timestamp);
        feed.setCurrentPhase(3);
        oracle.finalizeChainlinkPhase(address(feed), 2, 7);

        (uint64 firstRoundId, uint64 lastRoundId, uint256 activatedAt) = oracle.chainlinkPhase(address(feed), 2);
        assertEq(firstRoundId, 1);
        assertEq(lastRoundId, 7);
        assertEq(activatedAt, block.timestamp);
    }

    function testClosePathHandlesSamePhasePredecessor() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 base = 3_000_000;
        uint256 closeAt = base + 1 hours;
        uint256 expiry = base + 2 hours;
        uint256 nextOpen = base + 6 hours;
        vm.warp(base);

        feed = new PhaseFeed();
        feed.setCurrentPhase(2);
        feed.setRound(2, 49, 2_000e8, closeAt - 1);
        feed.setRound(2, 50, 2_000e8, closeAt + 1);
        oracle.setChainlinkPhase(address(feed), 2, 1, 0, base);
        oracle.setPriceFeed(asset, address(feed));
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        vm.warp(expiry);

        oracle.setExpiryPriceFromCloseAtRound(
            asset, expiry, 2_000e8, closeAt, nextOpen, uint80((uint256(2) << 64) | 50)
        );
        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testGenericExpiryPriceAtRoundHandlesPhaseBoundary() public {
        uint256 expiry = block.timestamp + 2 hours;
        _configurePhaseFeed(expiry - 30 minutes, expiry + 1, 2_000e8, 2_100e8);
        oracle.setChainlinkPhase(address(feed), 1, 1, 1, expiry - 1 hours);
        oracle.setChainlinkPhase(address(feed), 2, 1, 0, expiry - 30 minutes);
        oracle.setPriceFeed(asset, address(feed));
        vm.warp(expiry + 1);

        oracle.setExpiryPriceAtRound(asset, expiry, 2_000e8, uint80((uint256(1) << 64) | 1));

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function testClosePathHandlesPhaseBoundary() public {
        oracle.setMarketHoursAsset(asset, true);
        uint256 base = 2_000_000;
        uint256 closeAt = base + 1 hours;
        uint256 expiry = base + 2 hours;
        uint256 nextOpen = base + 6 hours;
        vm.warp(base);
        oracle.setCloseWindow(asset, expiry, closeAt, nextOpen);
        _configurePhaseFeed(closeAt - 1, closeAt + 1, 2_000e8, 2_000e8);
        oracle.setChainlinkPhase(address(feed), 1, 1, 1, base);
        oracle.setChainlinkPhase(address(feed), 2, 1, 0, closeAt - 1);
        oracle.setPriceFeed(asset, address(feed));
        vm.warp(expiry);

        oracle.setExpiryPriceFromCloseAtRound(asset, expiry, 2_000e8, closeAt, nextOpen, uint80((uint256(2) << 64) | 1));

        (uint256 price, bool set) = oracle.getExpiryPrice(asset, expiry);
        assertTrue(set);
        assertEq(price, 2_000e8);
    }

    function _configurePhaseFeed(
        uint256 previousUpdatedAt,
        uint256 currentUpdatedAt,
        int256 previousAnswer,
        int256 currentAnswer
    ) internal {
        previous = new LocalFeed();
        feed = new PhaseFeed();
        previous.setRound(1, previousAnswer, previousUpdatedAt);
        feed.setPhase(1, address(previous));
        feed.setPhase(2, address(feed));
        feed.setCurrentPhase(2);
        feed.setRound(1, 1, previousAnswer, previousUpdatedAt);
        feed.setRound(2, 1, currentAnswer, currentUpdatedAt);
    }
}
