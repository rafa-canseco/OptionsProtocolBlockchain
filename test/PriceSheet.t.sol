// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/core/PriceSheet.sol";
import "../src/core/AddressBook.sol";

contract PriceSheetTest is Test {
    event QuotePublished(address indexed oToken, uint256 bidPrice, uint256 askPrice, uint256 deadline);
    event QuoteInvalidated(address indexed oToken);

    AddressBook public addressBook;
    PriceSheet public priceSheet;

    address public mmOperator = address(0x7700);
    address public oToken1 = address(0xAA01);
    address public oToken2 = address(0xAA02);
    address public attacker = address(0xBEEF);

    function setUp() public {
        addressBook = new AddressBook();
        priceSheet = new PriceSheet(address(addressBook), mmOperator);
        addressBook.setPriceSheet(address(priceSheet));
    }

    // ---- publishQuote ----

    function test_publishSingleQuote() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);

        (uint256 bid, uint256 ask, bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 50e6);
        assertEq(ask, 52e6);
        assertTrue(valid);
    }

    function test_publishQuoteOverwritesPrevious() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);
        priceSheet.publishQuote(oToken1, 45e6, 48e6, block.timestamp + 2 hours);
        vm.stopPrank();

        (uint256 bid, uint256 ask, bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 45e6);
        assertEq(ask, 48e6);
        assertTrue(valid);
    }

    function test_publishQuoteEmitsEvent() public {
        vm.prank(mmOperator);
        vm.expectEmit(true, false, false, true);
        emit QuotePublished(oToken1, 50e6, 52e6, block.timestamp + 1 hours);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);
    }

    // ---- publishQuotes (batch) ----

    function test_publishBatchQuotes() public {
        address[] memory tokens = new address[](2);
        tokens[0] = oToken1;
        tokens[1] = oToken2;

        uint256[] memory bids = new uint256[](2);
        bids[0] = 50e6;
        bids[1] = 30e6;

        uint256[] memory asks = new uint256[](2);
        asks[0] = 52e6;
        asks[1] = 33e6;

        uint256[] memory deadlines = new uint256[](2);
        deadlines[0] = block.timestamp + 1 hours;
        deadlines[1] = block.timestamp + 1 hours;

        vm.prank(mmOperator);
        priceSheet.publishQuotes(tokens, bids, asks, deadlines);

        (uint256 bid1, uint256 ask1, bool valid1) = priceSheet.getQuote(oToken1);
        assertEq(bid1, 50e6);
        assertEq(ask1, 52e6);
        assertTrue(valid1);

        (uint256 bid2, uint256 ask2, bool valid2) = priceSheet.getQuote(oToken2);
        assertEq(bid2, 30e6);
        assertEq(ask2, 33e6);
        assertTrue(valid2);
    }

    function test_publishBatchRevertsOnEmptyArray() public {
        address[] memory tokens = new address[](0);
        uint256[] memory bids = new uint256[](0);
        uint256[] memory asks = new uint256[](0);
        uint256[] memory deadlines = new uint256[](0);

        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.EmptyArray.selector);
        priceSheet.publishQuotes(tokens, bids, asks, deadlines);
    }

    function test_publishBatchRevertsOnLengthMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = oToken1;
        tokens[1] = oToken2;
        uint256[] memory bids = new uint256[](1);
        bids[0] = 50e6;
        uint256[] memory asks = new uint256[](2);
        asks[0] = 52e6;
        asks[1] = 33e6;
        uint256[] memory deadlines = new uint256[](2);
        deadlines[0] = block.timestamp + 1 hours;
        deadlines[1] = block.timestamp + 1 hours;

        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.LengthMismatch.selector);
        priceSheet.publishQuotes(tokens, bids, asks, deadlines);
    }

    // ---- Deadline / TTL ----

    function test_quoteExpiresAfterDeadline() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);

        // Still valid
        (, , bool valid) = priceSheet.getQuote(oToken1);
        assertTrue(valid);

        // Warp past deadline
        vm.warp(block.timestamp + 1 hours + 1);
        (uint256 bid, uint256 ask, bool validAfter) = priceSheet.getQuote(oToken1);
        assertFalse(validAfter);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    function test_quoteValidAtExactDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, deadline);

        // At exact deadline, block.timestamp == deadline, so deadline > block.timestamp is false
        vm.warp(deadline);
        (, , bool valid) = priceSheet.getQuote(oToken1);
        assertFalse(valid);
    }

    // ---- invalidateQuote ----

    function test_invalidateSingleQuote() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);

        priceSheet.invalidateQuote(oToken1);
        vm.stopPrank();

        (uint256 bid, uint256 ask, bool valid) = priceSheet.getQuote(oToken1);
        assertFalse(valid);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    function test_invalidateBatchQuotes() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);
        priceSheet.publishQuote(oToken2, 30e6, 33e6, block.timestamp + 1 hours);

        address[] memory tokens = new address[](2);
        tokens[0] = oToken1;
        tokens[1] = oToken2;
        priceSheet.invalidateQuotes(tokens);
        vm.stopPrank();

        (, , bool valid1) = priceSheet.getQuote(oToken1);
        (, , bool valid2) = priceSheet.getQuote(oToken2);
        assertFalse(valid1);
        assertFalse(valid2);
    }

    function test_invalidateEmitsEvent() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);

        vm.expectEmit(true, false, false, false);
        emit QuoteInvalidated(oToken1);
        priceSheet.invalidateQuote(oToken1);
        vm.stopPrank();
    }

    // ---- Validation ----

    function test_revertBidGreaterThanAsk() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidQuote.selector);
        priceSheet.publishQuote(oToken1, 55e6, 50e6, block.timestamp + 1 hours);
    }

    function test_revertZeroAskPrice() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidQuote.selector);
        priceSheet.publishQuote(oToken1, 0, 0, block.timestamp + 1 hours);
    }

    function test_revertDeadlineInPast() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidQuote.selector);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp);
    }

    function test_revertZeroOTokenAddress() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidAddress.selector);
        priceSheet.publishQuote(address(0), 50e6, 52e6, block.timestamp + 1 hours);
    }

    function test_zeroBidIsAllowed() public {
        // bid=0 means MM doesn't want to buy, only sell. Valid use case.
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 0, 52e6, block.timestamp + 1 hours);

        (uint256 bid, uint256 ask, bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 0);
        assertEq(ask, 52e6);
        assertTrue(valid);
    }

    // ---- Access Control ----

    function test_onlyOperatorCanPublish() public {
        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyOperator.selector);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);
    }

    function test_onlyOperatorCanPublishBatch() public {
        address[] memory tokens = new address[](1);
        tokens[0] = oToken1;
        uint256[] memory bids = new uint256[](1);
        bids[0] = 50e6;
        uint256[] memory asks = new uint256[](1);
        asks[0] = 52e6;
        uint256[] memory deadlines = new uint256[](1);
        deadlines[0] = block.timestamp + 1 hours;

        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyOperator.selector);
        priceSheet.publishQuotes(tokens, bids, asks, deadlines);
    }

    function test_onlyOperatorCanInvalidate() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours);

        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyOperator.selector);
        priceSheet.invalidateQuote(oToken1);
    }

    function test_onlyOperatorCanInvalidateBatch() public {
        address[] memory tokens = new address[](1);
        tokens[0] = oToken1;

        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyOperator.selector);
        priceSheet.invalidateQuotes(tokens);
    }

    function test_onlyOwnerCanSetOperator() public {
        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyOwner.selector);
        priceSheet.setOperator(address(0x9999));
    }

    function test_ownerCanSetOperator() public {
        address newOp = address(0x9999);
        priceSheet.setOperator(newOp);
        assertEq(priceSheet.operator(), newOp);
    }

    function test_setOperatorRevertsZeroAddress() public {
        vm.expectRevert(PriceSheet.InvalidAddress.selector);
        priceSheet.setOperator(address(0));
    }

    // ---- getQuote for non-existent oToken ----

    function test_noQuoteReturnsInvalid() public view {
        (uint256 bid, uint256 ask, bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 0);
        assertEq(ask, 0);
        assertFalse(valid);
    }
}
