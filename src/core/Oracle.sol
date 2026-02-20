// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AddressBook.sol";
import "./Controller.sol";

/**
 * @title Oracle
 * @notice Provides price feeds for the protocol.
 *         Uses Chainlink for live prices and stores expiry prices for settlement.
 *         The owner sets the Chainlink feed per asset.
 *         At expiry, the owner (or a bot) locks in the settlement price.
 */
contract Oracle {
    AddressBook public addressBook;
    address public owner;

    /// @notice Chainlink price feed per asset (e.g., WETH → ETH/USD feed)
    mapping(address => address) public priceFeed;

    /// @notice Stored expiry prices: asset → expiry timestamp → price (8 decimals)
    mapping(address => mapping(uint256 => uint256)) public expiryPrice;

    /// @notice Whether an expiry price has been set
    mapping(address => mapping(uint256 => bool)) public expiryPriceSet;

    event PriceFeedSet(address indexed asset, address indexed feed);
    event ExpiryPriceSet(address indexed asset, uint256 indexed expiry, uint256 price);
    event ExpiryPriceReset(address indexed asset, uint256 indexed expiry);

    error OnlyOwner();
    error PriceAlreadySet();
    error PriceNotSet();
    error FeedNotSet();
    error InvalidPrice();
    error InvalidAddress();
    error NotBetaMode();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(address _addressBook) {
        addressBook = AddressBook(_addressBook);
        owner = msg.sender;
    }

    /**
     * @notice Set the Chainlink price feed for an asset.
     */
    function setPriceFeed(address _asset, address _feed) external onlyOwner {
        if (_asset == address(0) || _feed == address(0)) revert InvalidAddress();
        priceFeed[_asset] = _feed;
        emit PriceFeedSet(_asset, _feed);
    }

    /**
     * @notice Set the settlement price for an asset at a specific expiry.
     *         Called by the owner (or settlement bot) after expiry.
     *         Price is in 8 decimals (e.g., $2000 = 200000000000).
     */
    function setExpiryPrice(address _asset, uint256 _expiry, uint256 _price) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();
        if (_price == 0) revert InvalidPrice();
        if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();

        expiryPrice[_asset][_expiry] = _price;
        expiryPriceSet[_asset][_expiry] = true;

        emit ExpiryPriceSet(_asset, _expiry, _price);
    }

    /**
     * @notice Reset an expiry price so it can be set again (owner only).
     *         Only callable when Controller.betaMode() is true.
     */
    function resetExpiryPrice(address _asset, uint256 _expiry) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();

        Controller ctrl = Controller(addressBook.controller());
        if (!ctrl.betaMode()) revert NotBetaMode();
        if (!expiryPriceSet[_asset][_expiry]) revert PriceNotSet();

        expiryPrice[_asset][_expiry] = 0;
        expiryPriceSet[_asset][_expiry] = false;

        emit ExpiryPriceReset(_asset, _expiry);
    }

    /**
     * @notice Get the settlement price for an asset at expiry.
     *         Returns (0, false) if not yet set.
     */
    function getExpiryPrice(address _asset, uint256 _expiry) external view returns (uint256, bool) {
        return (expiryPrice[_asset][_expiry], expiryPriceSet[_asset][_expiry]);
    }

    /**
     * @notice Get live price from Chainlink feed. Returns price in 8 decimals.
     */
    function getPrice(address _asset) external view returns (uint256) {
        address feed = priceFeed[_asset];
        if (feed == address(0)) revert FeedNotSet();

        (, int256 answer,,,) = IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();

        return uint256(answer);
    }
}

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
