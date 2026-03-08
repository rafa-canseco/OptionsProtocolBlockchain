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

    /// @notice Max allowed deviation (bps) between submitted and Chainlink price.
    ///         0 = disabled. e.g. 2000 = 20%.
    uint256 public priceDeviationThresholdBps;

    /// @notice Max age (seconds) for a Chainlink answer to be considered fresh.
    ///         0 = disabled. e.g. 3600 = 1 hour.
    uint256 public maxOracleStaleness;

    /// @notice Address authorized to set expiry prices (bot/operator)
    address public operator;

    event PriceFeedSet(address indexed asset, address indexed feed);
    event ExpiryPriceSet(address indexed asset, uint256 indexed expiry, uint256 price);
    event PriceDeviationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event MaxOracleStalenessUpdated(uint256 oldStaleness, uint256 newStaleness);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    error OnlyOwner();
    error OnlyOwnerOrOperator();
    error PriceAlreadySet();
    error FeedNotSet();
    error InvalidPrice();
    error InvalidAddress();
    error PriceDeviationTooHigh(uint256 submitted, uint256 chainlink, uint256 deviationBps);
    error StaleOraclePrice(uint256 updatedAt, uint256 maxAge);
    error ExpiryNotReached();

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

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    function setExpiryPrice(address _asset, uint256 _expiry, uint256 _price) external {
        if (msg.sender != owner && msg.sender != operator) {
            revert OnlyOwnerOrOperator();
        }
        if (_asset == address(0)) revert InvalidAddress();
        if (_price == 0) revert InvalidPrice();
        if (block.timestamp < _expiry) revert ExpiryNotReached();
        if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();

        _validatePriceDeviation(_asset, _price);

        expiryPrice[_asset][_expiry] = _price;
        expiryPriceSet[_asset][_expiry] = true;

        emit ExpiryPriceSet(_asset, _expiry, _price);
    }

    function setPriceDeviationThreshold(uint256 _thresholdBps) external onlyOwner {
        emit PriceDeviationThresholdUpdated(priceDeviationThresholdBps, _thresholdBps);
        priceDeviationThresholdBps = _thresholdBps;
    }

    function setMaxOracleStaleness(uint256 _maxStaleness) external onlyOwner {
        emit MaxOracleStalenessUpdated(maxOracleStaleness, _maxStaleness);
        maxOracleStaleness = _maxStaleness;
    }

    function getExpiryPrice(address _asset, uint256 _expiry) external view returns (uint256, bool) {
        return (expiryPrice[_asset][_expiry], expiryPriceSet[_asset][_expiry]);
    }

    function getPrice(address _asset) external view returns (uint256) {
        address feed = priceFeed[_asset];
        if (feed == address(0)) revert FeedNotSet();

        (, int256 answer,, uint256 updatedAt,) = IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();

        uint256 maxAge = maxOracleStaleness;
        if (maxAge > 0 && block.timestamp - updatedAt > maxAge) {
            revert StaleOraclePrice(updatedAt, maxAge);
        }

        return uint256(answer);
    }

    // --- Ownership ---

    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyPendingOwner();

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @dev Reverts if a Chainlink feed exists, threshold is set,
    ///      and the submitted price deviates beyond the threshold.
    function _validatePriceDeviation(address _asset, uint256 _price) internal view {
        uint256 threshold = priceDeviationThresholdBps;
        if (threshold == 0) return;

        address feed = priceFeed[_asset];
        if (feed == address(0)) return;

        (, int256 answer,, uint256 updatedAt,) = IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();

        uint256 maxAge = maxOracleStaleness;
        if (maxAge > 0 && block.timestamp - updatedAt > maxAge) {
            revert StaleOraclePrice(updatedAt, maxAge);
        }

        uint256 chainlinkPrice = uint256(answer);
        uint256 diff = _price > chainlinkPrice ? _price - chainlinkPrice : chainlinkPrice - _price;
        uint256 deviationBps = (diff * 10_000) / chainlinkPrice;

        if (deviationBps > threshold) {
            revert PriceDeviationTooHigh(_price, chainlinkPrice, deviationBps);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[41] private __gap;
}

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
