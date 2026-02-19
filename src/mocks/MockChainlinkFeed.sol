// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title MockChainlinkFeed
 * @notice Returns a settable price in Chainlink's latestRoundData() format.
 *         Price uses 8 decimals (e.g., $2500 = 2500e8 = 250_000_000_000).
 */
contract MockChainlinkFeed {
    int256 public price;

    constructor(int256 _price) {
        price = _price;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}
