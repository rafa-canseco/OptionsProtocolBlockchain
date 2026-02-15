// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AddressBook.sol";

/**
 * @title PriceSheet
 * @notice On-chain price feed from the Market Maker with capacity tracking.
 *
 *         Flow:
 *         1. MM calls publishQuotes() with bid/ask prices + maxAmount for active oTokens
 *         2. Frontend reads getQuote() to display prices and remaining capacity
 *         3. User calls BatchSettler.executeOrder() which atomically fills the quote
 *         4. filledAmount increments on each fill; orders revert when capacity is reached
 *
 *         Quotes auto-expire at their deadline. The MM can also
 *         invalidate quotes early via invalidateQuotes().
 */
contract PriceSheet {
    AddressBook public addressBook;
    address public owner;
    address public operator; // The MM

    struct Quote {
        uint256 bidPrice;      // premium MM pays per 1 oToken (1e8) — in strike asset units
        uint256 askPrice;      // premium MM charges per 1 oToken (1e8) — in strike asset units
        uint256 deadline;      // unix timestamp when this quote expires
        uint256 maxAmount;     // max oToken capacity (8 decimals)
        uint256 filledAmount;  // oToken amount already filled (8 decimals)
    }

    /// @notice oToken address → current quote
    mapping(address => Quote) public quotes;

    event QuotePublished(
        address indexed oToken,
        uint256 bidPrice,
        uint256 askPrice,
        uint256 deadline,
        uint256 maxAmount
    );
    event QuoteInvalidated(address indexed oToken);
    event QuoteFilled(address indexed oToken, uint256 amount, uint256 newFilledAmount);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    error OnlyOwner();
    error OnlyOperator();
    error OnlyBatchSettler();
    error InvalidAddress();
    error InvalidQuote();
    error LengthMismatch();
    error EmptyArray();
    error QuoteExpired();
    error CapacityExceeded();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    constructor(address _addressBook, address _operator) {
        if (_addressBook == address(0) || _operator == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
        owner = msg.sender;
        operator = _operator;
    }

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    /**
     * @notice Publish quotes for multiple oTokens in a single tx.
     *         Publishing overwrites any existing quote (resets filledAmount to 0).
     */
    function publishQuotes(
        address[] calldata oTokens,
        uint256[] calldata bidPrices,
        uint256[] calldata askPrices,
        uint256[] calldata deadlines,
        uint256[] calldata maxAmounts
    ) external onlyOperator {
        if (oTokens.length == 0) revert EmptyArray();
        if (
            oTokens.length != bidPrices.length ||
            oTokens.length != askPrices.length ||
            oTokens.length != deadlines.length ||
            oTokens.length != maxAmounts.length
        ) revert LengthMismatch();

        for (uint256 i = 0; i < oTokens.length; i++) {
            _publishQuote(oTokens[i], bidPrices[i], askPrices[i], deadlines[i], maxAmounts[i]);
        }
    }

    /**
     * @notice Publish a single quote. Resets filledAmount to 0.
     */
    function publishQuote(
        address oToken,
        uint256 bidPrice,
        uint256 askPrice,
        uint256 deadline,
        uint256 maxAmount
    ) external onlyOperator {
        _publishQuote(oToken, bidPrice, askPrice, deadline, maxAmount);
    }

    /**
     * @notice Fill a quote's capacity. Only callable by the BatchSettler.
     * @param oToken  The oToken being filled
     * @param amount  Amount to fill (in oToken units, 8 decimals)
     */
    function fillQuote(address oToken, uint256 amount) external {
        if (msg.sender != addressBook.batchSettler()) revert OnlyBatchSettler();

        Quote storage q = quotes[oToken];
        if (q.deadline <= block.timestamp || q.askPrice == 0) revert QuoteExpired();
        if (q.filledAmount + amount > q.maxAmount) revert CapacityExceeded();

        q.filledAmount += amount;
        emit QuoteFilled(oToken, amount, q.filledAmount);
    }

    /**
     * @notice Invalidate quotes for multiple oTokens (cancel before deadline).
     */
    function invalidateQuotes(address[] calldata oTokens) external onlyOperator {
        for (uint256 i = 0; i < oTokens.length; i++) {
            delete quotes[oTokens[i]];
            emit QuoteInvalidated(oTokens[i]);
        }
    }

    /**
     * @notice Invalidate a single quote.
     */
    function invalidateQuote(address oToken) external onlyOperator {
        delete quotes[oToken];
        emit QuoteInvalidated(oToken);
    }

    /**
     * @notice Get a quote for an oToken and whether it's still valid.
     * @return bidPrice      Bid price (0 if no quote or expired)
     * @return askPrice      Ask price (0 if no quote or expired)
     * @return maxAmount     Max oToken capacity (8 decimals, 0 if no quote or expired)
     * @return filledAmount  oToken amount already filled (8 decimals, 0 if no quote or expired)
     * @return isValid       True if quote exists and hasn't expired
     */
    function getQuote(address oToken)
        external
        view
        returns (uint256 bidPrice, uint256 askPrice, uint256 maxAmount, uint256 filledAmount, bool isValid)
    {
        Quote storage q = quotes[oToken];
        if (q.deadline > block.timestamp && q.askPrice > 0) {
            return (q.bidPrice, q.askPrice, q.maxAmount, q.filledAmount, true);
        }
        return (0, 0, 0, 0, false);
    }

    function _publishQuote(
        address oToken,
        uint256 bidPrice,
        uint256 askPrice,
        uint256 deadline,
        uint256 maxAmount
    ) internal {
        if (oToken == address(0)) revert InvalidAddress();
        if (askPrice == 0 || bidPrice > askPrice) revert InvalidQuote();
        if (deadline <= block.timestamp) revert InvalidQuote();
        if (maxAmount == 0) revert InvalidQuote();

        quotes[oToken] = Quote(bidPrice, askPrice, deadline, maxAmount, 0);
        emit QuotePublished(oToken, bidPrice, askPrice, deadline, maxAmount);
    }
}
