// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AddressBook.sol";

/**
 * @title PriceSheet
 * @notice On-chain price feed from the Market Maker. The MM publishes
 *         bid/ask quotes for each oToken with a deadline (TTL).
 *
 *         Flow:
 *         1. MM calls publishQuotes() with bid/ask prices for active oTokens
 *         2. Frontend reads getQuote() to display prices to users
 *         3. User accepts a price → backend validates against this contract
 *         4. Keeper calls BatchSettler.settleBatch() with accepted orders
 *
 *         Quotes auto-expire at their deadline. The MM can also
 *         invalidate quotes early via invalidateQuotes().
 */
contract PriceSheet {
    AddressBook public addressBook;
    address public owner;
    address public operator; // The MM

    struct Quote {
        uint256 bidPrice;  // premium MM pays per 1 oToken (1e8) — in USDC (6 decimals)
        uint256 askPrice;  // premium MM charges per 1 oToken (1e8) — in USDC (6 decimals)
        uint256 deadline;  // unix timestamp when this quote expires
    }

    /// @notice oToken address → current quote
    mapping(address => Quote) public quotes;

    event QuotePublished(
        address indexed oToken,
        uint256 bidPrice,
        uint256 askPrice,
        uint256 deadline
    );
    event QuoteInvalidated(address indexed oToken);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    error OnlyOwner();
    error OnlyOperator();
    error InvalidAddress();
    error InvalidQuote();
    error LengthMismatch();
    error EmptyArray();

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
     * @param oTokens   Array of oToken addresses
     * @param bidPrices  Bid price per oToken (USDC, 6 decimals)
     * @param askPrices  Ask price per oToken (USDC, 6 decimals)
     * @param deadlines  Unix timestamp when each quote expires
     */
    function publishQuotes(
        address[] calldata oTokens,
        uint256[] calldata bidPrices,
        uint256[] calldata askPrices,
        uint256[] calldata deadlines
    ) external onlyOperator {
        if (oTokens.length == 0) revert EmptyArray();
        if (
            oTokens.length != bidPrices.length ||
            oTokens.length != askPrices.length ||
            oTokens.length != deadlines.length
        ) revert LengthMismatch();

        for (uint256 i = 0; i < oTokens.length; i++) {
            _publishQuote(oTokens[i], bidPrices[i], askPrices[i], deadlines[i]);
        }
    }

    /**
     * @notice Publish a single quote.
     */
    function publishQuote(
        address oToken,
        uint256 bidPrice,
        uint256 askPrice,
        uint256 deadline
    ) external onlyOperator {
        _publishQuote(oToken, bidPrice, askPrice, deadline);
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
     * @return bidPrice  Bid price (0 if no quote or expired)
     * @return askPrice  Ask price (0 if no quote or expired)
     * @return isValid   True if quote exists and hasn't expired
     */
    function getQuote(address oToken)
        external
        view
        returns (uint256 bidPrice, uint256 askPrice, bool isValid)
    {
        Quote storage q = quotes[oToken];
        if (q.deadline > block.timestamp && q.askPrice > 0) {
            return (q.bidPrice, q.askPrice, true);
        }
        return (0, 0, false);
    }

    function _publishQuote(
        address oToken,
        uint256 bidPrice,
        uint256 askPrice,
        uint256 deadline
    ) internal {
        if (oToken == address(0)) revert InvalidAddress();
        if (askPrice == 0 || bidPrice > askPrice) revert InvalidQuote();
        if (deadline <= block.timestamp) revert InvalidQuote();

        quotes[oToken] = Quote(bidPrice, askPrice, deadline);
        emit QuotePublished(oToken, bidPrice, askPrice, deadline);
    }
}
