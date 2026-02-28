// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./AddressBook.sol";

/**
 * @title Oracle
 * @notice Provides price feeds for the protocol.
 *         Uses Chainlink for live prices and stores expiry prices for settlement.
 *         The owner sets the Chainlink feed per asset.
 *         At expiry, the owner (or a bot) locks in the settlement price.
 */
contract Oracle is Initializable, UUPSUpgradeable {
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
    error OnlyOwner();
    error PriceAlreadySet();
    error PriceNotSet();
    error FeedNotSet();
    error InvalidPrice();
    error InvalidAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressBook, address _owner) external initializer {
        if (_addressBook == address(0) || _owner == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
        owner = _owner;
    }

    function setPriceFeed(address _asset, address _feed) external onlyOwner {
        if (_asset == address(0) || _feed == address(0)) revert InvalidAddress();
        priceFeed[_asset] = _feed;
        emit PriceFeedSet(_asset, _feed);
    }

    function setExpiryPrice(address _asset, uint256 _expiry, uint256 _price) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();
        if (_price == 0) revert InvalidPrice();
        if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();

        expiryPrice[_asset][_expiry] = _price;
        expiryPriceSet[_asset][_expiry] = true;

        emit ExpiryPriceSet(_asset, _expiry, _price);
    }

    function getExpiryPrice(address _asset, uint256 _expiry) external view returns (uint256, bool) {
        return (expiryPrice[_asset][_expiry], expiryPriceSet[_asset][_expiry]);
    }

    function getPrice(address _asset) external view returns (uint256) {
        address feed = priceFeed[_asset];
        if (feed == address(0)) revert FeedNotSet();

        (, int256 answer,,,) = IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();

        return uint256(answer);
    }

    // --- Ownership ---

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[45] private __gap;
}

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
