// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/AddressBook.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OToken.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/interfaces/IFlashLoanSimple.sol";
import "../src/interfaces/ISwapRouter.sol";

contract MockERC20 is ERC20 {
    uint8 private _dec;

    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _dec = dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

abstract contract BatchSettlerTestBase is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;

    MockERC20 public weth;
    MockERC20 public usdc;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B0);

    uint256 public strikePrice = 2000e8;
    uint256 public expiry;
    uint256 nextQuoteId = 1;

    function _deployProtocol(address _operator) internal {
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );
        controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()),
                    abi.encodeCall(Controller.initialize, (address(addressBook), address(this)))
                )
            )
        );
        pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );
        factory = OTokenFactory(
            address(
                new ERC1967Proxy(
                    address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
                )
            )
        );
        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), address(this)))
                )
            )
        );
        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()),
                    abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
                )
            )
        );
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), _operator, address(this)))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        factory.setOperator(address(this));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    function _computeExpiry() internal {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }

    function _fundUser(address user, uint256 usdcAmount, uint256 wethAmount) internal {
        usdc.mint(user, usdcAmount);
        weth.mint(user, wethAmount);
        vm.startPrank(user);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _createPut(uint256 strike) internal returns (address) {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strike, expiry, true);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _createCall(uint256 strike) internal returns (address) {
        address oToken = factory.createOToken(address(weth), address(usdc), address(weth), strike, expiry, false);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _signQuoteFor(uint256 _mmKey, address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        address signer = vm.addr(_mmKey);
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: deadline,
            quoteId: nextQuoteId++,
            maxAmount: maxAmount,
            makerNonce: settler.makerNonce(signer)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }
}

contract BatchSettlerTest is BatchSettlerTestBase {
    event OrderExecuted(
        address indexed user,
        address indexed oToken,
        address indexed mm,
        uint256 amount,
        uint256 grossPremium,
        uint256 netPremium,
        uint256 fee,
        uint256 collateral,
        uint256 vaultId
    );
    event VaultSettleFailed(address indexed vaultOwner, uint256 vaultId, bytes reason);
    event RedeemFailed(address indexed oToken, uint256 amount, bytes reason);

    uint256 public mmKey = 0xAA01;
    address public mm;

    function setUp() public {
        vm.warp(1700000000);
        mm = vm.addr(mmKey);

        _deployProtocol(mm);

        settler.setWhitelistedMM(mm, true);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        _computeExpiry();

        usdc.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);

        _fundUser(alice, 10_000e6, 10e18);
        _fundUser(bob, 50_000e6, 50e18);
    }

    function _approveOToken(address user, address oToken) internal {
        vm.prank(user);
        IERC20(oToken).approve(address(settler), type(uint256).max);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        return _signQuoteFor(mmKey, oToken, bidPrice, deadline, maxAmount);
    }

    // ===== executeOrder (instant settlement) =====

    function test_executeOrder_noOTokenApprovalNeeded() public {
        address oToken = _createPut(strikePrice);
        // NOTE: deliberately do NOT call _approveOToken -- no oToken approval should be needed
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // oTokens custodied in settler, tracked per MM
        assertEq(OToken(oToken).balanceOf(address(settler)), 1e8);
        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8);
        assertEq(OToken(oToken).balanceOf(alice), 0);
    }

    function test_executeOrder_singlePut() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 mmBefore = usdc.balanceOf(mm);

        vm.prank(alice);
        uint256 vaultId = settler.executeOrder(q, sig, 1e8, 2000e6);

        assertEq(vaultId, 1);
        // Alice: -2000 collateral, +70 premium
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + 70e6);
        // MM: -70 premium, oTokens custodied in settler
        assertEq(usdc.balanceOf(mm), mmBefore - 70e6);
        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8);
        // Pool: holds 2000 collateral
        assertEq(usdc.balanceOf(address(pool)), 2000e6);
    }

    function test_executeOrder_singleCall() public {
        address oToken = _createCall(2300e8);
        _approveOToken(bob, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 50e6, block.timestamp + 1 hours, 100e8);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobWethBefore = weth.balanceOf(bob);

        vm.prank(bob);
        settler.executeOrder(q, sig, 1e8, 1e18);

        // Bob: -1 WETH collateral, +50 USDC premium
        assertEq(weth.balanceOf(bob), bobWethBefore - 1e18);
        assertEq(usdc.balanceOf(bob), bobUsdcBefore + 50e6);
        // oTokens custodied in settler for MM
        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8);
    }

    function test_executeOrder_premiumCalculation() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // 2.5 oTokens -> premium = (2.5e8 * 70e6) / 1e8 = 175e6
        vm.prank(alice);
        settler.executeOrder(q, sig, 2.5e8, 5000e6);

        assertEq(usdc.balanceOf(alice), aliceBefore - 5000e6 + 175e6);
    }

    function test_executeOrder_multipleUsersProgressiveFill() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        // Create a single quote with maxAmount=3e8 that both users will fill against
        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 3e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Alice fills 1 oToken
        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        (uint256 filled1, bool cancelled1) = settler.getQuoteState(mm, digest);
        assertEq(filled1, 1e8);
        assertFalse(cancelled1);

        // Bob fills 2 oTokens
        vm.prank(bob);
        settler.executeOrder(q, sig, 2e8, 4000e6);

        (uint256 filled2, bool cancelled2) = settler.getQuoteState(mm, digest);
        assertEq(filled2, 3e8);
        assertFalse(cancelled2);
    }

    function test_executeOrder_revertsOnCapacityExceeded() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        // Create a single quote with maxAmount=1.5e8 that both users will fill against
        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 1.5e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Alice fills 1 oToken
        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Bob tries 1 more -> exceeds capacity (1e8 + 1e8 > 1.5e8)
        vm.prank(bob);
        vm.expectRevert(BatchSettler.CapacityExceeded.selector);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnExpiredQuote() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.QuoteExpired.selector);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnInvalidSignature() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });

        // Create a random bad signature
        bytes memory badSig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.prank(alice);
        vm.expectRevert(BatchSettler.MMNotWhitelisted.selector);
        settler.executeOrder(q, badSig, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnMMNotWhitelisted() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        // Sign with a non-whitelisted key
        uint256 randomKey = 0xBB01;
        address randomMM = vm.addr(randomKey);

        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(randomMM)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.MMNotWhitelisted.selector);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnStaleNonce() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        // Sign a quote with current makerNonce (0)
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        // MM increments nonce (circuit breaker)
        vm.prank(mm);
        settler.incrementMakerNonce();

        // Now the quote has stale makerNonce
        vm.prank(alice);
        vm.expectRevert(BatchSettler.StaleNonce.selector);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnCancelledQuote() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        // MM cancels the quote
        bytes32 digest = settler.hashQuote(q);
        vm.prank(mm);
        settler.cancelQuote(digest);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.QuoteAlreadyCancelled.selector);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnZeroAmount() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.InvalidAmount.selector);
        settler.executeOrder(q, sig, 0, 2000e6);
    }

    function test_executeOrder_emitsEvent() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        // premium = (1e8 * 70e6) / 1e8 = 70e6, fee = 0 (no treasury/feeBps set)
        vm.expectEmit(true, true, true, true);
        emit OrderExecuted(alice, oToken, mm, 1e8, 70e6, 70e6, 0, 2000e6, 1);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    // ===== Full E2E: executeOrder -> Expiry -> Settle -> Redeem =====

    function test_fullE2E_executeOrderToRedeem() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        // Create a single quote for both users
        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Alice and Bob sell puts via executeOrder
        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        vm.prank(bob);
        settler.executeOrder(q, sig, 2e8, 4000e6);

        // oTokens custodied in settler for MM
        assertEq(settler.mmOTokenBalance(mm, oToken), 3e8);

        // Expire ITM: price = $1800
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle vaults
        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;
        vaultIds[1] = 1;

        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // Physical settlement: ITM put -> users get 0 collateral back
        // Alice: -2000 collateral + 70 premium + 0 returned
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + 70e6);
        // Bob: -4000 collateral + 140 premium + 0 returned
        assertEq(usdc.balanceOf(bob), 50_000e6 - 4000e6 + 140e6);

        // Operator redeems for MM (no oToken approval needed — settler holds them)
        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 3e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm); // mm is operator in this test
        settler.operatorRedeemForMM(mm, oTokens, amounts);

        // Full collateral payout = $2000 * 3 = $6000
        assertEq(usdc.balanceOf(mm), mmBefore + 6000e6);

        // Pool empty
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    // ===== Post-expiry batch settlement =====

    function test_batchSettleVaults() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Expire OTM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;
        vaultIds[1] = 1;

        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // Both users got collateral back (OTM -> full refund)
        assertEq(usdc.balanceOf(alice), 10_000e6 + 70e6);
        assertEq(usdc.balanceOf(bob), 50_000e6 + 70e6);
    }

    function test_batchSettleVaults_continuesOnFailure() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Warp past expiry, set oracle price, and pre-settle Alice's vault
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        // Settle Alice first (so re-settling her later will fail with VaultAlreadySettled)
        address[] memory owners1 = new address[](1);
        uint256[] memory vaults1 = new uint256[](1);
        owners1[0] = alice;
        vaults1[0] = 1;

        vm.prank(mm);
        settler.batchSettleVaults(owners1, vaults1);

        // Now batch with Alice (already settled) + Bob (valid) -- Alice should emit failure event
        address[] memory owners2 = new address[](2);
        uint256[] memory vaults2 = new uint256[](2);
        owners2[0] = alice;
        owners2[1] = bob;
        vaults2[0] = 1; // already settled
        vaults2[1] = 1; // valid

        vm.prank(mm);
        vm.expectEmit(true, false, false, false);
        emit VaultSettleFailed(alice, 1, "");
        settler.batchSettleVaults(owners2, vaults2);

        // Bob still got settled despite Alice's failure
        assertEq(usdc.balanceOf(bob), 50_000e6 + 70e6);
    }

    // ===== batchRedeem =====

    function test_operatorRedeemForMM_singleOtoken() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        // Alice sells put
        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Expire ITM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle vault
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // Operator redeems for MM (no oToken approval needed)
        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm); // mm is operator in this test
        settler.operatorRedeemForMM(mm, oTokens, amounts);

        // Full collateral payout = $2000
        assertEq(usdc.balanceOf(mm), mmBefore + 2000e6);
        // oTokens burned from settler
        assertEq(OToken(oToken).balanceOf(address(settler)), 0);
        // MM balance tracking cleared
        assertEq(settler.mmOTokenBalance(mm, oToken), 0);
    }

    function test_batchRedeem_revertsOnLengthMismatch() public {
        address[] memory oTokens = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = address(0x1);
        oTokens[1] = address(0x2);
        amounts[0] = 1e8;

        vm.expectRevert(BatchSettler.LengthMismatch.selector);
        settler.batchRedeem(oTokens, amounts);
    }

    function test_batchSettleVaults_revertsOnLengthMismatch() public {
        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;

        vm.prank(mm);
        vm.expectRevert(BatchSettler.LengthMismatch.selector);
        settler.batchSettleVaults(owners, vaultIds);
    }

    // ---- Access Control ----

    function test_ownerCanChangeOperator() public {
        address newOperator = address(0xEEEE);
        settler.setOperator(newOperator);
        assertEq(settler.operator(), newOperator);
    }

    function test_nonOwnerCannotChangeOperator() public {
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setOperator(address(0xEEEE));
    }

    function test_batchSettleVaults_revertsForNonOperator() public {
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;

        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOperator.selector);
        settler.batchSettleVaults(owners, vaultIds);
    }

    function test_initializeRevertsOnZeroAddress() public {
        address impl = address(new BatchSettler());

        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(BatchSettler.initialize, (address(0), mm, address(this))));

        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        new ERC1967Proxy(
            impl, abi.encodeCall(BatchSettler.initialize, (address(addressBook), address(0), address(this)))
        );

        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(BatchSettler.initialize, (address(addressBook), mm, address(0))));
    }

    // ===== Premium edge cases =====

    function test_executeOrder_zeroBidPrice() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 0, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Alice gets zero premium (intentional), only loses collateral
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6);
        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8);
    }

    function test_executeOrder_revertsOnPremiumTruncation() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        // bidPrice = 50e6, amount = 1 (smallest unit) -> premium = (1 * 50e6) / 1e8 = 0
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 50e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.PremiumTooSmall.selector);
        settler.executeOrder(q, sig, 1, 1);
    }

    // ===== batchRedeem edge cases =====

    function test_operatorRedeemForMM_multipleOtokensSameCollateral() public {
        // Two different PUT strikes, both USDC-collateralized
        address oToken1 = _createPut(2000e8);
        address oToken2 = _createPut(2500e8);
        _approveOToken(alice, oToken1);
        _approveOToken(bob, oToken2);

        (BatchSettler.Quote memory q1, bytes memory sig1) = _signQuote(oToken1, 70e6, block.timestamp + 1 hours, 100e8);
        (BatchSettler.Quote memory q2, bytes memory sig2) = _signQuote(oToken2, 90e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        settler.executeOrder(q1, sig1, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(q2, sig2, 1e8, 2500e6);

        // Expire ITM for both (price = $1800)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle both vaults
        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;
        vaultIds[1] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // Operator redeems both oTokens for MM (no approvals needed)
        address[] memory oTokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        oTokens[0] = oToken1;
        oTokens[1] = oToken2;
        amounts[0] = 1e8;
        amounts[1] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm); // mm is operator
        settler.operatorRedeemForMM(mm, oTokens, amounts);

        // Full collateral payouts: 2000e6 + 2500e6
        assertEq(usdc.balanceOf(mm), mmBefore + 2000e6 + 2500e6);
        // No residual left in settler
        assertEq(usdc.balanceOf(address(settler)), 0);
    }

    function test_operatorRedeemForMM_otmZeroPayout() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Expire OTM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        // Settle vault (alice gets full collateral back)
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // Operator redeems OTM oToken for MM — zero payout but should not revert
        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm); // mm is operator
        settler.operatorRedeemForMM(mm, oTokens, amounts);

        // Zero payout, balance unchanged
        assertEq(usdc.balanceOf(mm), mmBefore);
        // oTokens burned from settler
        assertEq(OToken(oToken).balanceOf(address(settler)), 0);
        assertEq(settler.mmOTokenBalance(mm, oToken), 0);
    }

    function test_operatorRedeemForMM_continuesOnInsufficientBalance() public {
        address oToken1 = _createPut(2000e8);
        address oToken2 = _createPut(2500e8);
        _approveOToken(alice, oToken1);
        _approveOToken(bob, oToken2);

        (BatchSettler.Quote memory q1, bytes memory sig1) = _signQuote(oToken1, 70e6, block.timestamp + 1 hours, 100e8);
        (BatchSettler.Quote memory q2, bytes memory sig2) = _signQuote(oToken2, 90e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        settler.executeOrder(q1, sig1, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(q2, sig2, 1e8, 2500e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle both vaults
        address[] memory settleOwners = new address[](2);
        uint256[] memory settleVaults = new uint256[](2);
        settleOwners[0] = alice;
        settleOwners[1] = bob;
        settleVaults[0] = 1;
        settleVaults[1] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(settleOwners, settleVaults);

        // Redeem oToken1 first so MM balance is 0
        address[] memory oTokens1 = new address[](1);
        uint256[] memory amounts1 = new uint256[](1);
        oTokens1[0] = oToken1;
        amounts1[0] = 1e8;
        vm.prank(mm);
        settler.operatorRedeemForMM(mm, oTokens1, amounts1);

        // Now batch both: oToken1 fails (0 MM balance), oToken2 succeeds
        address[] memory oTokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        oTokens[0] = oToken1;
        oTokens[1] = oToken2;
        amounts[0] = 1e8;
        amounts[1] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm);
        vm.expectEmit(true, false, false, false);
        emit RedeemFailed(oToken1, 1e8, "");
        settler.operatorRedeemForMM(mm, oTokens, amounts);

        // oToken2 full collateral = $2500, oToken1 failed but didn't kill the batch
        assertEq(usdc.balanceOf(mm), mmBefore + 2500e6);
    }

    function test_operatorRedeemForMM_onlyOperatorCanCall() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 1e8;

        // Non-operator cannot call
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOperator.selector);
        settler.operatorRedeemForMM(mm, oTokens, amounts);
    }

    // ===== New validation tests =====

    function test_executeOrder_revertsOnZeroAddress() public {
        // Create a quote with oToken=address(0), sign it, expect revert
        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: address(0),
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    function test_batchSettleVaults_revertsOnEmptyArrays() public {
        address[] memory owners = new address[](0);
        uint256[] memory vaultIds = new uint256[](0);

        vm.prank(mm);
        vm.expectRevert(BatchSettler.EmptyArray.selector);
        settler.batchSettleVaults(owners, vaultIds);
    }

    function test_batchRedeem_revertsOnEmptyArrays() public {
        address[] memory oTokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(BatchSettler.EmptyArray.selector);
        settler.batchRedeem(oTokens, amounts);
    }

    // ===== Protocol Fee =====

    function test_executeOrder_protocolFee() public {
        address treasury = address(0x7EA5);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400); // 4%

        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 mmBefore = usdc.balanceOf(mm);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // grossPremium = 70e6, fee = 70e6 * 400 / 10000 = 2.8e6, netPremium = 67.2e6
        uint256 expectedFee = (70e6 * 400) / 10000; // 2_800_000
        uint256 expectedNet = 70e6 - expectedFee; // 67_200_000

        // Alice gets net premium
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + expectedNet);
        // MM pays gross premium (net + fee)
        assertEq(usdc.balanceOf(mm), mmBefore - 70e6);
        // Treasury gets fee
        assertEq(usdc.balanceOf(treasury), expectedFee);
    }

    function test_executeOrder_zeroFee_noBps() public {
        // feeBps = 0, treasury set -> no fee
        address treasury = address(0x7EA5);
        settler.setTreasury(treasury);
        // protocolFeeBps defaults to 0

        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Full premium to alice, 0 to treasury
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + 70e6);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_executeOrder_zeroFee_noTreasury() public {
        // feeBps set, treasury = address(0) -> no fee
        settler.setProtocolFeeBps(400);
        // treasury defaults to address(0)

        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Full premium to alice
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + 70e6);
    }

    function test_executeOrder_feeEdgeCases() public {
        address treasury = address(0x7EA5);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400); // 4%

        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        // Tiny bid: 1 (1e-6 USDC per 1e8 oTokens)
        // premium = (1e8 * 1) / 1e8 = 1 (1 wei USDC)
        // fee = (1 * 400) / 10000 = 0 (truncates to 0)
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 1, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Fee truncates to 0, alice gets full 1 wei premium
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + 1);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_executeOrder_protocolFee_emitsEvent() public {
        address treasury = address(0x7EA5);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400);

        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        uint256 expectedFee = (70e6 * 400) / 10000;
        uint256 expectedNet = 70e6 - expectedFee;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit OrderExecuted(alice, oToken, mm, 1e8, 70e6, expectedNet, expectedFee, 2000e6, 1);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    function test_setProtocolFeeBps_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setProtocolFeeBps(400);
    }

    function test_setProtocolFeeBps_revertsTooHigh() public {
        vm.expectRevert(BatchSettler.FeeTooHigh.selector);
        settler.setProtocolFeeBps(2001);
    }

    function test_setProtocolFeeBps_maxAllowed() public {
        settler.setProtocolFeeBps(2000); // exactly 20%, should succeed
        assertEq(settler.protocolFeeBps(), 2000);
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setTreasury(address(0x7EA5));
    }

    function test_setTreasury_revertsOnZero() public {
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.setTreasury(address(0));
    }
}

// =============================================================================
// Mock contracts for physical delivery testing
// =============================================================================

contract MockAavePool {
    using SafeERC20 for IERC20;

    uint256 public constant FLASH_LOAN_FEE_BPS = 5; // 0.05%

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    )
        external
    {
        // Transfer asset to receiver
        IERC20(asset).safeTransfer(receiverAddress, amount);

        // Calculate fee
        uint256 premium = (amount * FLASH_LOAN_FEE_BPS) / 10_000;

        // Call executeOperation on receiver
        bool success =
            IFlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, receiverAddress, params);
        require(success, "Flash loan callback failed");

        // Pull repayment
        IERC20(asset).safeTransferFrom(receiverAddress, address(this), amount + premium);
    }
}

contract MockSwapRouter {
    using SafeERC20 for IERC20;

    // Mock exchange rate: how many units of tokenOut per 1e18 tokenIn
    // For USDC->WETH: rate = ethPrice (e.g., 1800e6 USDC per 1e18 WETH -> set as 1e18 * 1e18 / 1800e6)
    // Simpler: we set a fixed price and compute amountIn from amountOut
    uint256 public mockEthPriceUsdc; // e.g., 1800e6 = $1800 per ETH
    uint24 public lastFeeTier;

    constructor(uint256 _mockEthPriceUsdc) {
        mockEthPriceUsdc = _mockEthPriceUsdc;
    }

    function setMockPrice(uint256 _price) external {
        mockEthPriceUsdc = _price;
    }

    function exactOutputSingle(ISwapRouter.ExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn)
    {
        lastFeeTier = params.fee;
        // Determine the direction: USDC->WETH or WETH->USDC
        // We compute amountIn based on the mock price
        // For USDC->WETH (put delivery): amountIn (USDC) = amountOut (WETH) * price / 1e18
        // For WETH->USDC (call delivery): amountIn (WETH) = amountOut (USDC) * 1e18 / price

        // Simple heuristic: if tokenIn has fewer decimals, it's USDC->WETH
        // We check by amount magnitude instead
        if (params.amountOut > 1e12) {
            // Large amountOut -> this is WETH (18 decimals)
            // amountIn is USDC (6 decimals)
            // amountIn = amountOut * mockEthPriceUsdc / 1e18
            amountIn = (params.amountOut * mockEthPriceUsdc) / 1e18;
        } else {
            // Small amountOut -> this is USDC (6 decimals)
            // amountIn is WETH (18 decimals)
            // amountIn = amountOut * 1e18 / mockEthPriceUsdc
            amountIn = (params.amountOut * 1e18) / mockEthPriceUsdc;
        }

        require(amountIn <= params.amountInMaximum, "Too much slippage");

        // Pull tokenIn from sender
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Send tokenOut to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, params.amountOut);

        return amountIn;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        lastFeeTier = params.fee;
        // Compute amountOut from amountIn using mock price
        if (params.amountIn > 1e12) {
            // Large amountIn -> WETH (18 decimals), output is USDC
            amountOut = (params.amountIn * mockEthPriceUsdc) / 1e18;
        } else {
            // Small amountIn -> USDC (6 decimals), output is WETH
            amountOut = (params.amountIn * 1e18) / mockEthPriceUsdc;
        }

        require(amountOut >= params.amountOutMinimum, "Too much slippage");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        return amountOut;
    }
}

// =============================================================================
// Physical Delivery Tests
// =============================================================================

contract PhysicalRedeemTest is BatchSettlerTestBase {
    using SafeERC20 for IERC20;

    event PhysicalDelivery(address indexed oToken, address indexed user, uint256 contraAmount, uint256 collateralUsed);
    event PhysicalRedeemFailed(address indexed oToken, address indexed user, uint256 amount, bytes reason);

    MockAavePool public mockAave;
    MockSwapRouter public mockRouter;

    uint256 public mmKey = 0xAA01;
    address public mm;
    address public operatorBot = address(0x0BE0A702);

    uint256 public constant MOCK_ETH_PRICE = 1800e6;

    function setUp() public {
        vm.warp(1700000000);
        mm = vm.addr(mmKey);

        mockAave = new MockAavePool();
        mockRouter = new MockSwapRouter(MOCK_ETH_PRICE);

        _deployProtocol(operatorBot);

        settler.setWhitelistedMM(mm, true);
        settler.setAavePool(address(mockAave));
        settler.setSwapRouter(address(mockRouter));
        settler.setSwapFeeTier(500);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        _computeExpiry();

        usdc.mint(mm, 1_000_000e6);
        weth.mint(mm, 1_000e18);
        vm.startPrank(mm);
        usdc.approve(address(settler), type(uint256).max);
        weth.approve(address(settler), type(uint256).max);
        vm.stopPrank();

        _fundUser(alice, 50_000e6, 50e18);
        _fundUser(bob, 50_000e6, 50e18);

        weth.mint(address(mockAave), 1_000e18);
        usdc.mint(address(mockAave), 10_000_000e6);
        weth.mint(address(mockRouter), 1_000e18);
        usdc.mint(address(mockRouter), 10_000_000e6);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        return _signQuoteFor(mmKey, oToken, bidPrice, deadline, maxAmount);
    }

    function _setupPutPosition(address user, address oToken, uint256 amount) internal {
        uint256 collateral = (amount * strikePrice) / 1e10;

        vm.prank(user);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 1000e8);

        vm.prank(user);
        settler.executeOrder(q, sig, amount, collateral);
        // No MM oToken approval needed — settler custodies oTokens
    }

    function _setupCallPosition(address user, address oToken, uint256 amount) internal {
        uint256 collateral = amount * 1e10;

        vm.prank(user);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 50e6, block.timestamp + 1 hours, 1000e8);

        vm.prank(user);
        settler.executeOrder(q, sig, amount, collateral);
        // No MM oToken approval needed — settler custodies oTokens
    }

    // ===== Physical Redeem: PUT ITM =====

    function test_physicalRedeem_putITM() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Expire ITM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle vault (alice gets 0 back)
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Physical delivery: alice should receive 1 ETH
        vm.prank(operatorBot);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        // Alice received 1 WETH
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);
        // oTokens burned from settler
        assertEq(OToken(oToken).balanceOf(address(settler)), 0);
        assertEq(settler.mmOTokenBalance(mm, oToken), 0);
    }

    // ===== Physical Redeem: CALL ITM =====

    function test_physicalRedeem_callITM() public {
        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        // Expire ITM (ETH > strike)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);

        // Set mock price to match oracle
        mockRouter.setMockPrice(2500e6);

        // Settle vault
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Physical delivery: alice should receive $2000 USDC (strike amount)
        // slippageParam = minAmountOut for calls (min USDC from swap)
        vm.prank(operatorBot);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        // Alice received strikePrice USDC
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 2000e6);
    }

    // ===== Reverts on OTM =====

    function test_physicalRedeem_revertsOnOTM() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Expire OTM (ETH > strike)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);
    }

    // ===== Reverts on ATM (expiryPrice == strike) =====

    function test_physicalRedeem_revertsOnATM() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2000e8); // exactly at strike

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);
    }

    // ===== Reverts on not expired =====

    function test_physicalRedeem_revertsOnNotExpired() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Don't warp past expiry
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.OptionNotExpired.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);
    }

    // ===== Reverts on non-operator =====

    function test_physicalRedeem_revertsOnNonOperator() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOperator.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);
    }

    // ===== MM receives surplus (not operator) =====

    function test_physicalRedeem_mmReceivesSurplus() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 mmUsdcBefore = usdc.balanceOf(mm);
        uint256 operatorUsdcBefore = usdc.balanceOf(operatorBot);

        // Physical delivery — operator triggers, but surplus goes to MM
        vm.prank(operatorBot);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        uint256 mmUsdcAfter = usdc.balanceOf(mm);
        uint256 surplus = mmUsdcAfter - mmUsdcBefore;

        // MM should have received surplus (approximately $199 USDC)
        assertGt(surplus, 0);
        // Surplus should be less than full collateral (some went to swap)
        assertLt(surplus, 2000e6);
        // Operator balance unchanged — surplus goes to MM, not operator
        assertEq(usdc.balanceOf(operatorBot), operatorUsdcBefore);
    }

    // ===== Batch physical redeem =====

    function test_batchPhysicalRedeem_multipleUsers() public {
        address oToken = _createPut(strikePrice);

        // Setup positions for alice and bob using a single quote
        vm.prank(alice);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        BatchSettler.Quote memory q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 1000e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        vm.prank(bob);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.prank(bob);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // Expire ITM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle both vaults
        address[] memory settleOwners = new address[](2);
        uint256[] memory settleVaults = new uint256[](2);
        settleOwners[0] = alice;
        settleOwners[1] = bob;
        settleVaults[0] = 1;
        settleVaults[1] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(settleOwners, settleVaults);

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 bobWethBefore = weth.balanceOf(bob);

        // Batch physical delivery with MM addresses
        address[] memory oTokens = new address[](2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory maxSpents = new uint256[](2);
        address[] memory mms = new address[](2);
        oTokens[0] = oToken;
        oTokens[1] = oToken;
        users[0] = alice;
        users[1] = bob;
        amounts[0] = 1e8;
        amounts[1] = 1e8;
        maxSpents[0] = 2000e6;
        maxSpents[1] = 2000e6;
        mms[0] = mm;
        mms[1] = mm;

        vm.prank(operatorBot);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents, mms);

        // Both received 1 WETH each
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);
        assertEq(weth.balanceOf(bob), bobWethBefore + 1e18);
    }

    // ===== Batch continues on failure =====

    function test_batchPhysicalRedeem_continuesOnFailure() public {
        address oToken = _createPut(strikePrice);

        vm.prank(alice);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 1000e8);

        vm.prank(alice);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        address[] memory settleOwners = new address[](1);
        uint256[] memory settleVaults = new uint256[](1);
        settleOwners[0] = alice;
        settleVaults[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(settleOwners, settleVaults);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Batch: first item is a bogus oToken (will fail), second is valid
        address bogusToken = address(0xDEAD);

        address[] memory oTokens = new address[](2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory maxSpents = new uint256[](2);
        address[] memory mms = new address[](2);
        oTokens[0] = bogusToken;
        oTokens[1] = oToken;
        users[0] = bob;
        users[1] = alice;
        amounts[0] = 1e8;
        amounts[1] = 1e8;
        maxSpents[0] = 2000e6;
        maxSpents[1] = 2000e6;
        mms[0] = mm;
        mms[1] = mm;

        vm.prank(operatorBot);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents, mms);

        // Alice still got her delivery despite bogus first item
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);
    }

    // ===== Setters access control =====

    function test_setAavePool_revertsOnNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setAavePool(address(0x1));
    }

    function test_setSwapRouter_revertsOnNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setSwapRouter(address(0x1));
    }

    function test_physicalRedeem_revertsOnAavePoolNotSet() public {
        // Deploy a fresh settler without aavePool configured
        BatchSettler freshSettler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operatorBot, address(this)))
                )
            )
        );
        addressBook.setBatchSettler(address(freshSettler));
        freshSettler.setWhitelistedMM(mm, true);
        freshSettler.setSwapRouter(address(mockRouter));
        freshSettler.setSwapFeeTier(500);

        address oToken = _createPut(strikePrice);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.AavePoolNotSet.selector);
        freshSettler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        // Restore original settler
        addressBook.setBatchSettler(address(settler));
    }

    function test_physicalRedeem_revertsOnSwapRouterNotSet() public {
        BatchSettler freshSettler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operatorBot, address(this)))
                )
            )
        );
        addressBook.setBatchSettler(address(freshSettler));
        freshSettler.setWhitelistedMM(mm, true);
        freshSettler.setAavePool(address(mockAave));
        // swapRouter left as address(0)

        address oToken = _createPut(strikePrice);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.SwapRouterNotSet.selector);
        freshSettler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        addressBook.setBatchSettler(address(settler));
    }

    function test_physicalRedeem_revertsOnZeroAmount() public {
        address oToken = _createPut(strikePrice);
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.InvalidAmount.selector);
        settler.physicalRedeem(oToken, alice, 0, 2000e6, mm);
    }

    function test_physicalRedeem_revertsOnExpiryPriceNotSet() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);
        vm.warp(expiry + 1);
        // oracle price NOT set

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.ExpiryPriceNotSet.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);
    }

    // ===== Flash loan callback security =====

    function test_executeOperation_revertsOnUnauthorizedCaller() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(address(weth), 1e18, 0, address(settler), "");
    }

    function test_executeOperation_revertsOnWrongInitiator() public {
        vm.prank(address(mockAave)); // correct sender
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(address(weth), 1e18, 0, address(0xBAD), ""); // wrong initiator
    }

    // ===== Self-call guard =====

    function test_physicalRedeemSingle_revertsOnDirectCall() public {
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler._physicalRedeemSingle(address(0x1), alice, 1e8, 2000e6, mm);
    }

    // ===== Slippage protection =====

    function test_physicalRedeem_revertsOnSlippageExceeded() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle vault
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        // maxCollateralSpent = 1 USDC (way too low to buy 1 ETH)
        vm.prank(operatorBot);
        vm.expectRevert(); // "Too much slippage" from MockSwapRouter
        settler.physicalRedeem(oToken, alice, 1e8, 1e6, mm);
    }

    function test_physicalRedeem_callRevertsOnSlippageExceeded() public {
        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);
        mockRouter.setMockPrice(2500e6);

        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = alice;
        ids[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, ids);

        // minAmountOut = type(uint256).max (impossible to satisfy)
        vm.prank(operatorBot);
        vm.expectRevert(); // "Too much slippage" from MockSwapRouter
        settler.physicalRedeem(oToken, alice, 1e8, type(uint256).max, mm);
    }

    function test_physicalRedeem_callRevertsOnInsufficientSwapOutput() public {
        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);

        // Set mock price very low so swap output < repayAmount
        mockRouter.setMockPrice(100e6);

        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = alice;
        ids[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, ids);

        // slippageParam = 0 (no min), but swap output will be tiny
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.InsufficientSwapOutput.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 0, mm);
    }

    // ===== Fee tier validation =====

    function test_setSwapFeeTier_revertsOnInvalidTier() public {
        vm.expectRevert(BatchSettler.InvalidFeeTier.selector);
        settler.setSwapFeeTier(0);

        vm.expectRevert(BatchSettler.InvalidFeeTier.selector);
        settler.setSwapFeeTier(300); // not a valid Uniswap tier

        vm.expectRevert(BatchSettler.InvalidFeeTier.selector);
        settler.setSwapFeeTier(1000);
    }

    function test_setSwapFeeTier_acceptsValidTiers() public {
        settler.setSwapFeeTier(100);
        assertEq(settler.swapFeeTier(), 100);

        settler.setSwapFeeTier(500);
        assertEq(settler.swapFeeTier(), 500);

        settler.setSwapFeeTier(3000);
        assertEq(settler.swapFeeTier(), 3000);

        settler.setSwapFeeTier(10000);
        assertEq(settler.swapFeeTier(), 10000);
    }

    function test_setSwapFeeTier_revertsOnNonOwner() public {
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setSwapFeeTier(500);
    }

    // ===== address(0) validation =====

    function test_physicalRedeem_revertsOnZeroOToken() public {
        vm.warp(expiry + 1);
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.physicalRedeem(address(0), alice, 1e8, 2000e6, mm);
    }

    function test_physicalRedeem_revertsOnZeroUser() public {
        address oToken = _createPut(strikePrice);
        vm.warp(expiry + 1);
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.physicalRedeem(oToken, address(0), 1e8, 2000e6, mm);
    }

    function test_physicalRedeem_revertsOnZeroMM() public {
        address oToken = _createPut(strikePrice);
        vm.warp(expiry + 1);
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, address(0));
    }

    function test_setAavePool_revertsOnZeroAddress() public {
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.setAavePool(address(0));
    }

    function test_setSwapRouter_revertsOnZeroAddress() public {
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.setSwapRouter(address(0));
    }

    // ===== batchPhysicalRedeem input validation =====

    function test_batchPhysicalRedeem_revertsOnLengthMismatch() public {
        address[] memory oTokens = new address[](2);
        address[] memory users = new address[](1);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory maxSpents = new uint256[](2);
        address[] memory mms = new address[](2);

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.LengthMismatch.selector);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents, mms);
    }

    function test_batchPhysicalRedeem_revertsOnEmptyArrays() public {
        address[] memory oTokens = new address[](0);
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory maxSpents = new uint256[](0);
        address[] memory mms = new address[](0);

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.EmptyArray.selector);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents, mms);
    }

    // ===== CALL ATM boundary =====

    function test_physicalRedeem_callATM_revertsNotITM() public {
        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2000e8); // exactly at strike

        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 1e18, mm);
    }

    // ===== Per-asset swap fee tier =====

    function test_setAssetSwapFeeTier() public {
        settler.setAssetSwapFeeTier(address(weth), 500);
        assertEq(settler.assetSwapFeeTier(address(weth)), 500);

        settler.setAssetSwapFeeTier(address(weth), 3000);
        assertEq(settler.assetSwapFeeTier(address(weth)), 3000);

        // Setting to 0 clears the override
        settler.setAssetSwapFeeTier(address(weth), 0);
        assertEq(settler.assetSwapFeeTier(address(weth)), 0);
    }

    function test_setAssetSwapFeeTier_revertsOnInvalidTier() public {
        vm.expectRevert(BatchSettler.InvalidFeeTier.selector);
        settler.setAssetSwapFeeTier(address(weth), 300);
    }

    function test_setAssetSwapFeeTier_revertsOnZeroAddress() public {
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.setAssetSwapFeeTier(address(0), 500);
    }

    function test_setAssetSwapFeeTier_revertsOnNonOwner() public {
        vm.prank(operatorBot);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setAssetSwapFeeTier(address(weth), 500);
    }

    function test_physicalRedeem_usesAssetFeeTier() public {
        // Global = 500 (set in setUp), asset override = 3000
        settler.setAssetSwapFeeTier(address(weth), 3000);

        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        vm.prank(operatorBot);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        // MockSwapRouter records lastFeeTier — should be 3000 (asset), not 500 (global)
        assertEq(mockRouter.lastFeeTier(), 3000);
    }

    function test_physicalRedeem_fallsBackToGlobalFeeTier() public {
        // No asset override set — should use global (500)
        assertEq(settler.assetSwapFeeTier(address(weth)), 0);

        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        vm.prank(operatorBot);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        // Should fall back to global fee tier (500)
        assertEq(mockRouter.lastFeeTier(), 500);
    }

    function test_physicalRedeem_callUsesAssetFeeTier() public {
        settler.setAssetSwapFeeTier(address(weth), 10000);

        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);
        mockRouter.setMockPrice(2500e6);

        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        vm.prank(operatorBot);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6, mm);

        // CALL path: should use asset override (10000), not global (500)
        assertEq(mockRouter.lastFeeTier(), 10000);
    }
}

// ===== Escape Hatch, Ledger Sync, Multi-MM Tests =====

contract EscapeHatchTest is BatchSettlerTestBase {
    uint256 public mm1Key = 0xAA01;
    uint256 public mm2Key = 0xBB02;
    address public mm1;
    address public mm2;
    address public operatorBot = address(0x0BE0A702);

    function setUp() public {
        vm.warp(1700000000);
        mm1 = vm.addr(mm1Key);
        mm2 = vm.addr(mm2Key);

        _deployProtocol(operatorBot);

        settler.setWhitelistedMM(mm1, true);
        settler.setWhitelistedMM(mm2, true);
        settler.setEscapeDelay(7 days);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        _computeExpiry();

        usdc.mint(mm1, 1_000_000e6);
        usdc.mint(mm2, 1_000_000e6);
        vm.prank(mm1);
        usdc.approve(address(settler), type(uint256).max);
        vm.prank(mm2);
        usdc.approve(address(settler), type(uint256).max);

        usdc.mint(alice, 50_000e6);
        usdc.mint(bob, 50_000e6);
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _signQuote(uint256 _mmKey, address oToken, uint256 bidPrice, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory q, bytes memory sig)
    {
        return _signQuoteFor(_mmKey, oToken, bidPrice, block.timestamp + 1 hours, maxAmount);
    }

    function _executeOrderForMM(uint256 _mmKey, address user, address oToken, uint256 amount, uint256 collateral)
        internal
    {
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(_mmKey, oToken, 50e6, 100e8);
        vm.prank(user);
        settler.executeOrder(q, sig, amount, collateral);
    }

    // ===== setEscapeDelay =====

    function test_setEscapeDelay() public {
        settler.setEscapeDelay(10 days);
        assertEq(settler.escapeDelay(), 10 days);
    }

    function test_setEscapeDelay_revertsBelowMinimum() public {
        vm.expectRevert(BatchSettler.EscapeDelayTooShort.selector);
        settler.setEscapeDelay(2 days);
    }

    function test_setEscapeDelay_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setEscapeDelay(7 days);
    }

    // ===== mmSelfRedeem =====

    function test_mmSelfRedeem_afterDelay() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        assertEq(settler.mmOTokenBalance(mm1, oToken), 1e8);

        // Expire OTM (price above strike for put)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);

        // Settle vault so collateral returns
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        // Before escape delay: should revert
        vm.prank(mm1);
        vm.expectRevert(BatchSettler.EscapeNotReady.selector);
        settler.mmSelfRedeem(oToken, 1e8);

        // After escape delay: should succeed
        vm.warp(expiry + 7 days + 1);
        uint256 mm1UsdcBefore = usdc.balanceOf(mm1);
        vm.prank(mm1);
        settler.mmSelfRedeem(oToken, 1e8);

        assertEq(settler.mmOTokenBalance(mm1, oToken), 0);
        // OTM put: full collateral returned to settler, then to MM
        assertGe(usdc.balanceOf(mm1), mm1UsdcBefore);
    }

    function test_mmSelfRedeem_revertsNonWhitelistedMM() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        vm.warp(expiry + 7 days + 1);

        vm.prank(alice); // alice is not a whitelisted MM
        vm.expectRevert(BatchSettler.MMNotWhitelisted.selector);
        settler.mmSelfRedeem(oToken, 1e8);
    }

    function test_mmSelfRedeem_revertsZeroAmount() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        vm.warp(expiry + 7 days + 1);

        vm.prank(mm1);
        vm.expectRevert(BatchSettler.InvalidAmount.selector);
        settler.mmSelfRedeem(oToken, 0);
    }

    function test_mmSelfRedeem_revertsInsufficientBalance() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        vm.warp(expiry + 7 days + 1);

        vm.prank(mm1);
        vm.expectRevert(BatchSettler.InsufficientMMBalance.selector);
        settler.mmSelfRedeem(oToken, 1e8);
    }

    function test_mmSelfRedeem_revertsWhenEscapeDelayNotSet() public {
        // Deploy a fresh settler with no escape delay
        BatchSettler settler2 = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operatorBot, address(this)))
                )
            )
        );
        settler2.setWhitelistedMM(mm1, true);

        vm.warp(expiry + 30 days);

        vm.prank(mm1);
        vm.expectRevert(BatchSettler.EscapeNotReady.selector);
        settler2.mmSelfRedeem(address(0x1), 1e8);
    }

    function test_mmSelfRedeem_cannotFrontrunOperator() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);

        // Expire and settle
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = alice;
        ids[0] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, ids);

        // MM tries self-redeem right after expiry (within delay)
        vm.prank(mm1);
        vm.expectRevert(BatchSettler.EscapeNotReady.selector);
        settler.mmSelfRedeem(oToken, 1e8);

        // Operator can still redeem normally during delay period
        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 1e8;
        vm.prank(operatorBot);
        settler.operatorRedeemForMM(mm1, oTokens, amounts);

        assertEq(settler.mmOTokenBalance(mm1, oToken), 0);
    }

    // ===== verifyLedgerSync =====

    function test_verifyLedgerSync_inSync() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);

        (uint256 ledger, uint256 actual, bool inSync) = settler.verifyLedgerSync(mm1, oToken);
        assertEq(ledger, 1e8);
        assertEq(actual, 1e8);
        assertTrue(inSync);
    }

    function test_verifyLedgerSync_multiMM() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        _executeOrderForMM(mm2Key, bob, oToken, 2e8, 4000e6);

        (uint256 ledger1,,) = settler.verifyLedgerSync(mm1, oToken);
        (uint256 ledger2, uint256 actual,) = settler.verifyLedgerSync(mm2, oToken);

        assertEq(ledger1, 1e8);
        assertEq(ledger2, 2e8);
        // Total actual should cover both MMs
        assertEq(actual, 3e8);
    }

    // ===== Multi-MM Isolation =====

    function test_multiMM_balancesIsolated() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        _executeOrderForMM(mm2Key, bob, oToken, 3e8, 6000e6);

        assertEq(settler.mmOTokenBalance(mm1, oToken), 1e8);
        assertEq(settler.mmOTokenBalance(mm2, oToken), 3e8);
        assertEq(IERC20(oToken).balanceOf(address(settler)), 4e8);
    }

    function test_multiMM_redeemIsolated() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        _executeOrderForMM(mm2Key, bob, oToken, 2e8, 4000e6);

        // Expire OTM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);

        // Settle vaults
        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;
        vaultIds[1] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        // Redeem only mm1's tokens
        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 1e8;
        vm.prank(operatorBot);
        settler.operatorRedeemForMM(mm1, oTokens, amounts);

        // mm1 balance zeroed, mm2 untouched
        assertEq(settler.mmOTokenBalance(mm1, oToken), 0);
        assertEq(settler.mmOTokenBalance(mm2, oToken), 2e8);
    }

    function test_multiMM_selfRedeemIsolated() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        _executeOrderForMM(mm2Key, bob, oToken, 2e8, 4000e6);

        // Expire OTM + settle
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);
        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;
        vaultIds[1] = 1;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, vaultIds);

        // Wait for escape delay
        vm.warp(expiry + 7 days + 1);

        // mm1 self-redeems — should NOT affect mm2
        vm.prank(mm1);
        settler.mmSelfRedeem(oToken, 1e8);

        assertEq(settler.mmOTokenBalance(mm1, oToken), 0);
        assertEq(settler.mmOTokenBalance(mm2, oToken), 2e8);

        // mm2 can still self-redeem independently
        uint256 mm2UsdcBefore = usdc.balanceOf(mm2);
        vm.prank(mm2);
        settler.mmSelfRedeem(oToken, 2e8);

        assertEq(settler.mmOTokenBalance(mm2, oToken), 0);
        assertGe(usdc.balanceOf(mm2), mm2UsdcBefore);
    }

    function test_multiMM_cannotRedeemOtherMMBalance() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        // mm2 has no balance for this oToken

        vm.warp(expiry + 7 days + 1);

        // mm2 tries to self-redeem: should fail (no balance)
        vm.prank(mm2);
        vm.expectRevert(BatchSettler.InsufficientMMBalance.selector);
        settler.mmSelfRedeem(oToken, 1e8);

        // mm1's balance untouched
        assertEq(settler.mmOTokenBalance(mm1, oToken), 1e8);
    }

    // ===== Emergency Withdrawal Ledger Clearance (Finding 2 fix) =====

    function test_emergencyWithdraw_clearsMMBalance() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        // Alice sells option via mm1
        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        assertEq(settler.mmOTokenBalance(mm1, oToken), 1e8);
        assertEq(settler.vaultMM(alice, 1), mm1);

        // Full pause + emergency withdraw
        controller.setSystemFullyPaused(true);
        vm.prank(alice);
        controller.emergencyWithdrawVault(1);

        // mm1's balance should be cleared
        assertEq(settler.mmOTokenBalance(mm1, oToken), 0);
    }

    function test_emergencyWithdraw_preventsCrossMMTheft() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        // Alice sells via mm1, Bob sells via mm2
        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        _executeOrderForMM(mm2Key, bob, oToken, 2e8, 4000e6);
        assertEq(settler.mmOTokenBalance(mm1, oToken), 1e8);
        assertEq(settler.mmOTokenBalance(mm2, oToken), 2e8);

        // Emergency: Alice withdraws, mm1's balance cleared
        controller.setSystemFullyPaused(true);
        vm.prank(alice);
        controller.emergencyWithdrawVault(1);
        assertEq(settler.mmOTokenBalance(mm1, oToken), 0);
        // mm2's balance untouched
        assertEq(settler.mmOTokenBalance(mm2, oToken), 2e8);

        // Unpause and settle normally for mm2
        controller.setSystemFullyPaused(false);
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // mm2 can still redeem their oTokens
        vm.prank(operatorBot);
        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 2e8;
        settler.operatorRedeemForMM(mm2, oTokens, amounts);

        assertEq(settler.mmOTokenBalance(mm2, oToken), 0);
    }

    function test_emergencyWithdraw_clearUsesMinForPartialBalance() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        // mm1 fills two vaults: Alice (1e8) and Bob (2e8) = 3e8 total
        _executeOrderForMM(mm1Key, alice, oToken, 1e8, 2000e6);
        _executeOrderForMM(mm1Key, bob, oToken, 2e8, 4000e6);
        assertEq(settler.mmOTokenBalance(mm1, oToken), 3e8);

        // Full pause + Alice emergency withdraws vault 1 (shortAmount=1e8)
        controller.setSystemFullyPaused(true);
        vm.prank(alice);
        controller.emergencyWithdrawVault(1);

        // 1e8 cleared from mm1's balance, 2e8 remains (Bob's vault)
        assertEq(settler.mmOTokenBalance(mm1, oToken), 2e8);

        // Bob also emergency withdraws vault 1 (shortAmount=2e8)
        vm.prank(bob);
        controller.emergencyWithdrawVault(1);

        // All cleared, no underflow
        assertEq(settler.mmOTokenBalance(mm1, oToken), 0);
    }

    function test_clearMMBalance_onlyController() public {
        vm.expectRevert(BatchSettler.OnlyController.selector);
        settler.clearMMBalanceForVault(alice, 1, address(0x123), 1e8);
    }
}
