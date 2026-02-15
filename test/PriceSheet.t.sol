// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/core/PriceSheet.sol";
import "../src/core/AddressBook.sol";

contract PriceSheetTest is Test {
    event QuotePublished(address indexed oToken, uint256 bidPrice, uint256 askPrice, uint256 deadline, uint256 maxAmount);
    event QuoteInvalidated(address indexed oToken);
    event QuoteFilled(address indexed oToken, uint256 amount, uint256 newFilledAmount);

    AddressBook public addressBook;
    PriceSheet public priceSheet;

    address public mmOperator = address(0x7700);
    address public oToken1 = address(0xAA01);
    address public oToken2 = address(0xAA02);
    address public attacker = address(0xBEEF);
    address public mockSettler = address(0x5E77);

    function setUp() public {
        addressBook = new AddressBook();
        priceSheet = new PriceSheet(address(addressBook), mmOperator);
        addressBook.setPriceSheet(address(priceSheet));
        // Set mockSettler as batchSettler so fillQuote tests work
        addressBook.setBatchSettler(mockSettler);
    }

    // ---- publishQuote ----

    function test_publishSingleQuote() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        (uint256 bid, uint256 ask, uint256 maxAmt, uint256 filled, bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 50e6);
        assertEq(ask, 52e6);
        assertEq(maxAmt, 10_000e6);
        assertEq(filled, 0);
        assertTrue(valid);
    }

    function test_publishQuoteOverwritesPrevious() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);
        priceSheet.publishQuote(oToken1, 45e6, 48e6, block.timestamp + 2 hours, 20_000e6);
        vm.stopPrank();

        (uint256 bid, uint256 ask, uint256 maxAmt, uint256 filled, bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 45e6);
        assertEq(ask, 48e6);
        assertEq(maxAmt, 20_000e6);
        assertEq(filled, 0);
        assertTrue(valid);
    }

    function test_publishResetsFilledAmount() public {
        // Publish, fill some, then republish — filledAmount should reset
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        vm.prank(mockSettler);
        priceSheet.fillQuote(oToken1, 2000e6);

        (, , , uint256 filledBefore, ) = priceSheet.getQuote(oToken1);
        assertEq(filledBefore, 2000e6);

        // Republish
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        (, , , uint256 filledAfter, ) = priceSheet.getQuote(oToken1);
        assertEq(filledAfter, 0);
    }

    function test_publishQuoteEmitsEvent() public {
        vm.prank(mmOperator);
        vm.expectEmit(true, false, false, true);
        emit QuotePublished(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);
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

        uint256[] memory maxAmts = new uint256[](2);
        maxAmts[0] = 10_000e6;
        maxAmts[1] = 5_000e6;

        vm.prank(mmOperator);
        priceSheet.publishQuotes(tokens, bids, asks, deadlines, maxAmts);

        (uint256 bid1, uint256 ask1, uint256 max1, , bool valid1) = priceSheet.getQuote(oToken1);
        assertEq(bid1, 50e6);
        assertEq(ask1, 52e6);
        assertEq(max1, 10_000e6);
        assertTrue(valid1);

        (uint256 bid2, uint256 ask2, uint256 max2, , bool valid2) = priceSheet.getQuote(oToken2);
        assertEq(bid2, 30e6);
        assertEq(ask2, 33e6);
        assertEq(max2, 5_000e6);
        assertTrue(valid2);
    }

    function test_publishBatchRevertsOnEmptyArray() public {
        address[] memory t = new address[](0);
        uint256[] memory b = new uint256[](0);
        uint256[] memory a = new uint256[](0);
        uint256[] memory d = new uint256[](0);
        uint256[] memory m = new uint256[](0);

        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.EmptyArray.selector);
        priceSheet.publishQuotes(t, b, a, d, m);
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
        uint256[] memory maxAmts = new uint256[](2);
        maxAmts[0] = 10_000e6;
        maxAmts[1] = 5_000e6;

        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.LengthMismatch.selector);
        priceSheet.publishQuotes(tokens, bids, asks, deadlines, maxAmts);
    }

    // ---- fillQuote ----

    function test_fillQuoteIncrements() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        vm.prank(mockSettler);
        priceSheet.fillQuote(oToken1, 2000e6);

        (, , , uint256 filled, ) = priceSheet.getQuote(oToken1);
        assertEq(filled, 2000e6);

        vm.prank(mockSettler);
        priceSheet.fillQuote(oToken1, 3000e6);

        (, , , uint256 filled2, ) = priceSheet.getQuote(oToken1);
        assertEq(filled2, 5000e6);
    }

    function test_fillQuoteRevertsAtCapacity() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 5_000e6);

        vm.prank(mockSettler);
        priceSheet.fillQuote(oToken1, 3000e6);

        vm.prank(mockSettler);
        vm.expectRevert(PriceSheet.CapacityExceeded.selector);
        priceSheet.fillQuote(oToken1, 3000e6); // 3000 + 3000 > 5000
    }

    function test_fillQuoteExactCapacity() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 5_000e6);

        vm.prank(mockSettler);
        priceSheet.fillQuote(oToken1, 5_000e6); // exactly at max

        (, , , uint256 filled, ) = priceSheet.getQuote(oToken1);
        assertEq(filled, 5_000e6);
    }

    function test_fillQuoteRevertsOnExpired() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(mockSettler);
        vm.expectRevert(PriceSheet.QuoteExpired.selector);
        priceSheet.fillQuote(oToken1, 1000e6);
    }

    function test_fillQuoteOnlyBatchSettler() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyBatchSettler.selector);
        priceSheet.fillQuote(oToken1, 1000e6);
    }

    function test_fillQuoteEmitsEvent() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        vm.prank(mockSettler);
        vm.expectEmit(true, false, false, true);
        emit QuoteFilled(oToken1, 2000e6, 2000e6);
        priceSheet.fillQuote(oToken1, 2000e6);
    }

    // ---- Deadline / TTL ----

    function test_quoteExpiresAfterDeadline() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        (, , , , bool valid) = priceSheet.getQuote(oToken1);
        assertTrue(valid);

        vm.warp(block.timestamp + 1 hours + 1);
        (uint256 bid, uint256 ask, , , bool validAfter) = priceSheet.getQuote(oToken1);
        assertFalse(validAfter);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    function test_quoteValidAtExactDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, deadline, 10_000e6);

        vm.warp(deadline);
        (, , , , bool valid) = priceSheet.getQuote(oToken1);
        assertFalse(valid);
    }

    // ---- invalidateQuote ----

    function test_invalidateSingleQuote() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);
        priceSheet.invalidateQuote(oToken1);
        vm.stopPrank();

        (uint256 bid, uint256 ask, , , bool valid) = priceSheet.getQuote(oToken1);
        assertFalse(valid);
        assertEq(bid, 0);
        assertEq(ask, 0);
    }

    function test_invalidateBatchQuotes() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);
        priceSheet.publishQuote(oToken2, 30e6, 33e6, block.timestamp + 1 hours, 5_000e6);

        address[] memory tokens = new address[](2);
        tokens[0] = oToken1;
        tokens[1] = oToken2;
        priceSheet.invalidateQuotes(tokens);
        vm.stopPrank();

        (, , , , bool valid1) = priceSheet.getQuote(oToken1);
        (, , , , bool valid2) = priceSheet.getQuote(oToken2);
        assertFalse(valid1);
        assertFalse(valid2);
    }

    function test_invalidateEmitsEvent() public {
        vm.startPrank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

        vm.expectEmit(true, false, false, false);
        emit QuoteInvalidated(oToken1);
        priceSheet.invalidateQuote(oToken1);
        vm.stopPrank();
    }

    // ---- Validation ----

    function test_revertBidGreaterThanAsk() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidQuote.selector);
        priceSheet.publishQuote(oToken1, 55e6, 50e6, block.timestamp + 1 hours, 10_000e6);
    }

    function test_revertZeroAskPrice() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidQuote.selector);
        priceSheet.publishQuote(oToken1, 0, 0, block.timestamp + 1 hours, 10_000e6);
    }

    function test_revertDeadlineInPast() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidQuote.selector);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp, 10_000e6);
    }

    function test_revertZeroOTokenAddress() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidAddress.selector);
        priceSheet.publishQuote(address(0), 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);
    }

    function test_revertZeroMaxAmount() public {
        vm.prank(mmOperator);
        vm.expectRevert(PriceSheet.InvalidQuote.selector);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 0);
    }

    function test_zeroBidIsAllowed() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 0, 52e6, block.timestamp + 1 hours, 10_000e6);

        (uint256 bid, uint256 ask, , , bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 0);
        assertEq(ask, 52e6);
        assertTrue(valid);
    }

    // ---- Access Control ----

    function test_onlyOperatorCanPublish() public {
        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyOperator.selector);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);
    }

    function test_onlyOperatorCanPublishBatch() public {
        address[] memory t = new address[](1);
        t[0] = oToken1;
        uint256[] memory b = new uint256[](1);
        b[0] = 50e6;
        uint256[] memory a = new uint256[](1);
        a[0] = 52e6;
        uint256[] memory d = new uint256[](1);
        d[0] = block.timestamp + 1 hours;
        uint256[] memory m = new uint256[](1);
        m[0] = 10_000e6;

        vm.prank(attacker);
        vm.expectRevert(PriceSheet.OnlyOperator.selector);
        priceSheet.publishQuotes(t, b, a, d, m);
    }

    function test_onlyOperatorCanInvalidate() public {
        vm.prank(mmOperator);
        priceSheet.publishQuote(oToken1, 50e6, 52e6, block.timestamp + 1 hours, 10_000e6);

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
        (uint256 bid, uint256 ask, uint256 maxAmt, uint256 filled, bool valid) = priceSheet.getQuote(oToken1);
        assertEq(bid, 0);
        assertEq(ask, 0);
        assertEq(maxAmt, 0);
        assertEq(filled, 0);
        assertFalse(valid);
    }
}
