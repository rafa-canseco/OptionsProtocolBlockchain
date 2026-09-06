// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
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

    uint256 public constant MAX_CLOSED_PRICE_AGE = 96 hours;
    uint256 public constant CLOSE_CAPTURE_WINDOW = 1 hours;

    event PriceFeedSet(address indexed asset, address indexed feed);
    event MarketHoursAssetUpdated(address indexed asset, bool enabled);
    event LegacyPostExpiryAssetUpdated(address indexed asset, bool enabled);
    event CloseWindowSet(address indexed asset, uint256 indexed expiry, uint256 closeAt, uint256 nextSessionOpenAt);
    event ExpiryPriceSet(address indexed asset, uint256 indexed expiry, uint256 price);
    event ExpiryPriceSetFromClose(
        address indexed asset,
        uint256 indexed expiry,
        uint256 price,
        uint256 closeAt,
        uint256 nextSessionOpenAt,
        uint256 feedUpdatedAt
    );
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
    error MarketHoursAssetNotEnabled();
    error InvalidCloseWindow();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    function _requireOwnerOrOperator() internal view {
        if (msg.sender != owner && msg.sender != operator) revert OnlyOwnerOrOperator();
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

    /// @notice Enables the explicit last-official-close settlement path for an asset.
    /// @dev This does not relax live `getPrice` freshness or change other assets.
    function setMarketHoursAsset(address _asset, bool _enabled) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();
        marketHoursAsset[_asset] = _enabled;
        emit MarketHoursAssetUpdated(_asset, _enabled);
    }

    /// @notice Allows an explicitly configured legacy asset to retain old settlement behavior.
    function setLegacyPostExpiryAsset(address _asset, bool _enabled) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();
        legacyPostExpiryAsset[_asset] = _enabled;
        emit LegacyPostExpiryAssetUpdated(_asset, _enabled);
    }

    /// @notice Records immutable Chainlink proxy phase metadata for historical settlement.
    /// @dev Set `_lastRoundId` to zero while the phase is active, then finalize it after
    ///      the proxy advances to the next phase.
    function setChainlinkPhase(
        address _feed,
        uint16 _phaseId,
        uint64 _firstRoundId,
        uint64 _lastRoundId,
        uint256 _activatedAt
    ) external onlyOwner {
        if (
            _feed == address(0) || _phaseId == 0 || _firstRoundId == 0
                || (_lastRoundId != 0 && _lastRoundId < _firstRoundId) || _activatedAt == 0
        ) revert InvalidCloseWindow();
        ChainlinkPhase storage configured = chainlinkPhase[_feed][_phaseId];
        if (configured.firstRoundId != 0) revert InvalidCloseWindow();
        if (_lastRoundId != 0) _requireEndedChainlinkPhase(_feed, _phaseId);
        configured.firstRoundId = _firstRoundId;
        configured.lastRoundId = _lastRoundId;
        configured.activatedAt = _activatedAt;
        emit ChainlinkPhaseSet(_feed, _phaseId, _firstRoundId, _lastRoundId, _activatedAt);
    }

    /// @notice Commits the terminal local round after a Chainlink proxy phase ends.
    function finalizeChainlinkPhase(address _feed, uint16 _phaseId, uint64 _lastRoundId) external onlyOwner {
        ChainlinkPhase storage configured = chainlinkPhase[_feed][_phaseId];
        if (
            _feed == address(0) || _phaseId == 0 || configured.firstRoundId == 0 || configured.lastRoundId != 0
                || _lastRoundId < configured.firstRoundId
        ) revert InvalidCloseWindow();
        _requireEndedChainlinkPhase(_feed, _phaseId);
        configured.lastRoundId = _lastRoundId;
        emit ChainlinkPhaseSet(_feed, _phaseId, configured.firstRoundId, _lastRoundId, configured.activatedAt);
    }

    /// @notice Pre-commits the exchange session window before the expiry.
    function setCloseWindow(address _asset, uint256 _expiry, uint256 _closeAt, uint256 _nextSessionOpenAt)
        external
        onlyOwner
    {
        if (_asset == address(0)) revert InvalidAddress();
        if (!marketHoursAsset[_asset]) revert MarketHoursAssetNotEnabled();
        if (block.timestamp >= _expiry) revert InvalidCloseWindow();
        if (block.timestamp >= _closeAt) revert InvalidCloseWindow();
        CloseWindow memory configured = closeWindow[_asset][_expiry];
        if (configured.closeAt != 0 || configured.nextSessionOpenAt != 0) revert InvalidCloseWindow();
        _validateSessionTimestamps(_expiry, _closeAt, _nextSessionOpenAt);

        closeWindow[_asset][_expiry] = CloseWindow(_closeAt, _nextSessionOpenAt);
        emit CloseWindowSet(_asset, _expiry, _closeAt, _nextSessionOpenAt);
    }

    function setExpiryPrice(address _asset, uint256 _expiry, uint256 _price) external {
        _requireOwnerOrOperator();
        if (_asset == address(0)) revert InvalidAddress();
        if (marketHoursAsset[_asset] || _hasCloseWindow(_asset, _expiry)) revert InvalidCloseWindow();
        if (_price == 0) revert InvalidPrice();
        if (block.timestamp < _expiry) revert ExpiryNotReached();
        if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();

        if (legacyPostExpiryAsset[_asset]) {
            _validatePriceDeviation(_asset, _price);
        } else {
            if (priceFeed[_asset] == address(0)) revert FeedNotSet();
            if (block.timestamp <= _expiry) revert ExpiryNotReached();
            _validateExpiryPriceAtLatestRound(_asset, _price, _expiry);
        }
        _storeExpiryPrice(_asset, _expiry, _price);
    }

    /// @notice Settles a non-market-hours asset from a specific historical Chainlink round.
    function setExpiryPriceAtRound(address _asset, uint256 _expiry, uint256 _price, uint80 _roundId) external {
        _requireOwnerOrOperator();
        if (_asset == address(0)) revert InvalidAddress();
        if (marketHoursAsset[_asset] || _hasCloseWindow(_asset, _expiry)) revert InvalidCloseWindow();
        if (_price == 0) revert InvalidPrice();
        if (block.timestamp < _expiry) revert ExpiryNotReached();
        if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();

        _validatePriceDeviationAtRound(_asset, _price, _expiry, _roundId);
        _storeExpiryPrice(_asset, _expiry, _price);
    }

    /// @notice Locks a market-hours asset to its pre-committed finalized official close.
    /// @dev The legacy ABI remains available and uses the latest round. Use the
    ///      round-specific entry point when a later feed update has superseded it.
    function setExpiryPriceFromClose(
        address _asset,
        uint256 _expiry,
        uint256 _price,
        uint256 _closeAt,
        uint256 _nextSessionOpenAt
    ) external {
        _requireOwnerOrOperator();
        _setExpiryPriceFromClose(_asset, _expiry, _price, _closeAt, _nextSessionOpenAt, false, 0);
    }

    /// @notice Locks a market-hours asset using an explicitly selected Chainlink round.
    function setExpiryPriceFromCloseAtRound(
        address _asset,
        uint256 _expiry,
        uint256 _price,
        uint256 _closeAt,
        uint256 _nextSessionOpenAt,
        uint80 _roundId
    ) external {
        _requireOwnerOrOperator();
        _setExpiryPriceFromClose(_asset, _expiry, _price, _closeAt, _nextSessionOpenAt, true, _roundId);
    }

    function _setExpiryPriceFromClose(
        address _asset,
        uint256 _expiry,
        uint256 _price,
        uint256 _closeAt,
        uint256 _nextSessionOpenAt,
        bool _useRound,
        uint80 _roundId
    ) internal {
        if (_asset == address(0)) revert InvalidAddress();
        if (!marketHoursAsset[_asset]) revert MarketHoursAssetNotEnabled();
        if (_price == 0) revert InvalidPrice();
        if (block.timestamp < _expiry) revert ExpiryNotReached();
        if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();
        _validateConfiguredCloseWindow(_asset, _expiry, _closeAt, _nextSessionOpenAt);

        uint256 feedUpdatedAt = _useRound
            ? _validateFinalizedCloseAtRound(_asset, _price, _expiry, _closeAt, _roundId)
            : _validateFinalizedClose(_asset, _price, _expiry, _closeAt);
        _storeExpiryPrice(_asset, _expiry, _price);

        emit ExpiryPriceSetFromClose(_asset, _expiry, _price, _closeAt, _nextSessionOpenAt, feedUpdatedAt);
    }

    function _hasCloseWindow(address _asset, uint256 _expiry) internal view returns (bool) {
        CloseWindow memory configured = closeWindow[_asset][_expiry];
        return configured.closeAt != 0 || configured.nextSessionOpenAt != 0;
    }

    function _storeExpiryPrice(address _asset, uint256 _expiry, uint256 _price) internal {
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

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (
            roundId == 0 || answeredInRound < roundId || startedAt == 0 || updatedAt == 0 || startedAt > updatedAt
                || updatedAt > block.timestamp
        ) {
            revert InvalidPrice();
        }

        uint256 maxAge = maxOracleStaleness;
        if (maxAge > 0 && block.timestamp - updatedAt > maxAge) {
            revert StaleOraclePrice(updatedAt, maxAge);
        }

        return uint256(answer);
    }

    // --- Ownership ---

    address public pendingOwner;

    /// @notice Assets whose expiry prices may use a finalized market-session close.
    mapping(address => bool) public marketHoursAsset;

    struct CloseWindow {
        uint256 closeAt;
        uint256 nextSessionOpenAt;
    }

    /// @notice Owner-committed exchange session boundaries per asset and expiry.
    mapping(address => mapping(uint256 => CloseWindow)) public closeWindow;

    /// @notice Assets explicitly allowed to retain legacy post-expiry settlement behavior.
    mapping(address => bool) public legacyPostExpiryAsset;

    struct ChainlinkPhase {
        uint64 firstRoundId;
        uint64 lastRoundId;
        uint256 activatedAt;
    }

    /// @notice Owner-recorded proxy phase boundaries used for canonical historical rounds.
    mapping(address => mapping(uint16 => ChainlinkPhase)) public chainlinkPhase;

    event ChainlinkPhaseSet(
        address indexed feed, uint16 indexed phaseId, uint64 firstRoundId, uint64 lastRoundId, uint256 activatedAt
    );
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

    function _validateSessionTimestamps(uint256 _expiry, uint256 _closeAt, uint256 _nextSessionOpenAt) internal pure {
        if (_closeAt >= _expiry || _nextSessionOpenAt <= _expiry || _nextSessionOpenAt <= _closeAt) {
            revert InvalidCloseWindow();
        }
        if (_nextSessionOpenAt - _closeAt > MAX_CLOSED_PRICE_AGE) revert InvalidCloseWindow();
    }

    function _validateConfiguredCloseWindow(
        address _asset,
        uint256 _expiry,
        uint256 _closeAt,
        uint256 _nextSessionOpenAt
    ) internal view {
        _validateSessionTimestamps(_expiry, _closeAt, _nextSessionOpenAt);
        CloseWindow memory configured = closeWindow[_asset][_expiry];
        if (configured.closeAt != _closeAt || configured.nextSessionOpenAt != _nextSessionOpenAt) {
            revert InvalidCloseWindow();
        }
        if (block.timestamp < _closeAt || block.timestamp - _closeAt > MAX_CLOSED_PRICE_AGE) {
            revert InvalidCloseWindow();
        }
        if (block.timestamp >= _nextSessionOpenAt) revert InvalidCloseWindow();
    }

    function _requireEndedChainlinkPhase(address _feed, uint16 _phaseId) internal view {
        try IChainlinkProxy(_feed).phaseId() returns (uint16 currentPhaseId) {
            if (currentPhaseId <= _phaseId) revert InvalidCloseWindow();
        } catch {
            revert InvalidCloseWindow();
        }
    }

    function _validateConfiguredPhase(address _feed, uint80 _roundId, uint256 _updatedAt) internal view {
        uint16 phaseId = uint16(uint256(_roundId) >> 64);
        if (phaseId == 0) return;
        uint64 localRoundId = uint64(_roundId);
        ChainlinkPhase memory configured = chainlinkPhase[_feed][phaseId];
        if (
            configured.firstRoundId == 0 || localRoundId < configured.firstRoundId
                || (configured.lastRoundId != 0 && localRoundId > configured.lastRoundId)
                || _updatedAt < configured.activatedAt
        ) revert InvalidCloseWindow();
        if (configured.lastRoundId == 0) {
            try IChainlinkProxy(_feed).phaseId() returns (uint16 currentPhaseId) {
                if (currentPhaseId != phaseId) revert InvalidCloseWindow();
            } catch {
                revert InvalidCloseWindow();
            }
        }
    }

    /// @dev Validates a selected Chainlink round as the finalized close.
    function _validateFinalizedClose(address _asset, uint256 _price, uint256 _expiry, uint256 _closeAt)
        internal
        view
        returns (uint256 feedUpdatedAt)
    {
        address feed = priceFeed[_asset];
        if (feed == address(0)) revert FeedNotSet();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        return _validateFinalizedCloseRound(
            feed, _price, _expiry, _closeAt, roundId, answer, startedAt, updatedAt, answeredInRound
        );
    }

    function _validateFinalizedCloseAtRound(
        address _asset,
        uint256 _price,
        uint256 _expiry,
        uint256 _closeAt,
        uint80 _roundId
    ) internal view returns (uint256 feedUpdatedAt) {
        address feed = priceFeed[_asset];
        if (feed == address(0)) revert FeedNotSet();
        if (_roundId == 0) revert InvalidCloseWindow();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).getRoundData(_roundId);
        if (roundId != _roundId) revert InvalidCloseWindow();
        return _validateFinalizedCloseRound(
            feed, _price, _expiry, _closeAt, roundId, answer, startedAt, updatedAt, answeredInRound
        );
    }

    function _validateFinalizedCloseRound(
        address _feed,
        uint256 _price,
        uint256 _expiry,
        uint256 _closeAt,
        uint80 _roundId,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) internal view returns (uint256) {
        if (_answer <= 0) revert InvalidPrice();
        if (
            _roundId == 0 || _answeredInRound < _roundId || _startedAt == 0 || _updatedAt == 0
                || _startedAt > _updatedAt || _updatedAt > block.timestamp || _updatedAt > _expiry
        ) {
            revert InvalidCloseWindow();
        }
        if (_updatedAt < _closeAt || _updatedAt - _closeAt > CLOSE_CAPTURE_WINDOW) {
            revert InvalidCloseWindow();
        }
        _validateConfiguredPhase(_feed, _roundId, _updatedAt);
        uint256 chainlinkPrice = uint256(_answer);
        if (_price != chainlinkPrice) {
            uint256 diff = _price > chainlinkPrice ? _price - chainlinkPrice : chainlinkPrice - _price;
            uint256 deviationBps = Math.mulDiv(diff, 10_000, chainlinkPrice, Math.Rounding.Ceil);
            revert PriceDeviationTooHigh(_price, chainlinkPrice, deviationBps);
        }
        _validateFirstCloseRound(_feed, _roundId, _closeAt);
        return _updatedAt;
    }

    function _validateFirstCloseRound(address _feed, uint80 _roundId, uint256 _closeAt) internal view {
        if (_roundId == 0) revert InvalidCloseWindow();
        uint16 phaseId = uint16(uint256(_roundId) >> 64);
        uint64 localRoundId = uint64(_roundId);
        uint80 previousRoundId;
        uint256 phaseActivatedAt;

        if (phaseId == 0) {
            previousRoundId = _roundId - 1;
        } else {
            ChainlinkPhase memory configured = chainlinkPhase[_feed][phaseId];
            if (
                configured.firstRoundId == 0 || localRoundId < configured.firstRoundId
                    || (configured.lastRoundId != 0 && localRoundId > configured.lastRoundId)
            ) revert InvalidCloseWindow();
            phaseActivatedAt = configured.activatedAt;
            if (localRoundId > configured.firstRoundId) {
                previousRoundId = uint80((uint256(phaseId) << 64) | (localRoundId - 1));
            } else {
                if (phaseId == 1) revert InvalidCloseWindow();
                ChainlinkPhase memory previous = chainlinkPhase[_feed][phaseId - 1];
                if (previous.lastRoundId == 0) revert InvalidCloseWindow();
                previousRoundId = uint80((uint256(phaseId - 1) << 64) | previous.lastRoundId);
            }
        }

        try IChainlinkAggregator(_feed).getRoundData(previousRoundId) returns (
            uint80 returnedRoundId,
            int256 previousAnswer,
            uint256 previousStartedAt,
            uint256 previousUpdatedAt,
            uint80 previousAnsweredInRound
        ) {
            if (
                returnedRoundId != previousRoundId || previousAnswer <= 0 || previousAnsweredInRound < returnedRoundId
                    || previousStartedAt == 0 || previousUpdatedAt == 0 || previousStartedAt > previousUpdatedAt
                    || previousUpdatedAt >= _closeAt || previousUpdatedAt > block.timestamp
            ) revert InvalidCloseWindow();
            _validateConfiguredPhase(_feed, returnedRoundId, previousUpdatedAt);
            if (phaseId > 0 && localRoundId == chainlinkPhase[_feed][phaseId].firstRoundId) {
                if (previousUpdatedAt > phaseActivatedAt) revert InvalidCloseWindow();
            }
        } catch {
            revert InvalidCloseWindow();
        }
    }

    function _validateExpiryRound(address _feed, uint80 _roundId, uint256 _expiry) internal view {
        if (_roundId == type(uint80).max) revert InvalidCloseWindow();
        uint16 phaseId = uint16(uint256(_roundId) >> 64);
        uint64 localRoundId = uint64(_roundId);
        uint80 nextRoundId;

        if (phaseId == 0) {
            nextRoundId = _roundId + 1;
        } else {
            ChainlinkPhase memory configured = chainlinkPhase[_feed][phaseId];
            if (
                configured.firstRoundId == 0 || localRoundId < configured.firstRoundId
                    || (configured.lastRoundId != 0 && localRoundId > configured.lastRoundId)
            ) revert InvalidCloseWindow();
            if (configured.lastRoundId == 0 || localRoundId < configured.lastRoundId) {
                nextRoundId = uint80((uint256(phaseId) << 64) | (localRoundId + 1));
            } else {
                if (phaseId == type(uint16).max) revert InvalidCloseWindow();
                ChainlinkPhase memory next = chainlinkPhase[_feed][phaseId + 1];
                if (next.firstRoundId == 0) revert InvalidCloseWindow();
                nextRoundId = uint80((uint256(phaseId + 1) << 64) | next.firstRoundId);
            }
        }

        try IChainlinkAggregator(_feed).getRoundData(nextRoundId) returns (
            uint80 returnedRoundId,
            int256 nextAnswer,
            uint256 nextStartedAt,
            uint256 nextUpdatedAt,
            uint80 nextAnsweredInRound
        ) {
            if (
                returnedRoundId != nextRoundId || nextAnswer <= 0 || nextAnsweredInRound < returnedRoundId
                    || nextStartedAt == 0 || nextUpdatedAt == 0 || nextStartedAt > nextUpdatedAt
                    || nextUpdatedAt <= _expiry || nextUpdatedAt > block.timestamp
            ) revert InvalidCloseWindow();
            _validateConfiguredPhase(_feed, returnedRoundId, nextUpdatedAt);
        } catch {
            revert InvalidCloseWindow();
        }
    }

    function _validateExactPrice(uint256 _price, uint256 _chainlinkPrice) internal pure {
        if (_price != _chainlinkPrice) {
            uint256 diff = _price > _chainlinkPrice ? _price - _chainlinkPrice : _chainlinkPrice - _price;
            uint256 deviationBps = Math.mulDiv(diff, 10_000, _chainlinkPrice, Math.Rounding.Ceil);
            revert PriceDeviationTooHigh(_price, _chainlinkPrice, deviationBps);
        }
    }

    function _validateExpiryPriceAtLatestRound(address _asset, uint256 _price, uint256 _expiry) internal view {
        address feed = priceFeed[_asset];
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        if (
            roundId == 0 || answeredInRound < roundId || answer <= 0 || startedAt == 0 || updatedAt == 0
                || startedAt > updatedAt || updatedAt > block.timestamp || updatedAt > _expiry
        ) {
            revert InvalidCloseWindow();
        }
        _validateConfiguredPhase(feed, roundId, updatedAt);
        uint256 maxAge = maxOracleStaleness;
        if (maxAge > 0 && _expiry - updatedAt > maxAge) {
            revert StaleOraclePrice(updatedAt, maxAge);
        }
        _validateExactPrice(_price, uint256(answer));
    }

    /// @dev Reverts if a Chainlink feed exists, threshold is set,
    ///      and the submitted price deviates beyond the threshold.
    function _validatePriceDeviation(address _asset, uint256 _price) internal view {
        uint256 threshold = priceDeviationThresholdBps;
        if (threshold == 0) return;

        address feed = priceFeed[_asset];
        if (feed == address(0)) return;

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (
            roundId == 0 || answeredInRound < roundId || startedAt == 0 || updatedAt == 0 || startedAt > updatedAt
                || updatedAt > block.timestamp
        ) {
            revert InvalidPrice();
        }

        uint256 maxAge = maxOracleStaleness;
        if (maxAge > 0 && block.timestamp - updatedAt > maxAge) {
            revert StaleOraclePrice(updatedAt, maxAge);
        }

        _validatePriceDeviationAgainst(_price, uint256(answer));
    }

    function _validatePriceDeviationAtRound(address _asset, uint256 _price, uint256 _expiry, uint80 _roundId)
        internal
        view
    {
        address feed = priceFeed[_asset];
        if (feed == address(0)) revert FeedNotSet();
        if (_roundId == 0) revert InvalidCloseWindow();

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).getRoundData(_roundId);
        if (
            roundId != _roundId || roundId == 0 || answeredInRound < roundId || answer <= 0 || startedAt == 0
                || updatedAt == 0 || startedAt > updatedAt || updatedAt > block.timestamp || updatedAt > _expiry
        ) {
            revert InvalidCloseWindow();
        }
        uint256 maxAge = maxOracleStaleness;
        if (maxAge > 0 && _expiry - updatedAt > maxAge) {
            revert StaleOraclePrice(updatedAt, maxAge);
        }
        _validateConfiguredPhase(feed, roundId, updatedAt);
        _validateExactPrice(_price, uint256(answer));
        _validateExpiryRound(feed, roundId, _expiry);
    }

    function _validatePriceDeviationAgainst(uint256 _price, uint256 _chainlinkPrice) internal view {
        uint256 threshold = priceDeviationThresholdBps;
        if (threshold == 0) return;

        uint256 diff = _price > _chainlinkPrice ? _price - _chainlinkPrice : _chainlinkPrice - _price;
        uint256 deviationBps = Math.mulDiv(diff, 10_000, _chainlinkPrice, Math.Rounding.Ceil);
        if (deviationBps > threshold) {
            revert PriceDeviationTooHigh(_price, _chainlinkPrice, deviationBps);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[37] private __gap;
}

interface IChainlinkProxy {
    function phaseId() external view returns (uint16);
}

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
