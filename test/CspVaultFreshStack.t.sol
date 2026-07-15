// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/AddressBook.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/mocks/MockChainlinkFeed.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockSwapRouter.sol";
import "../src/vaults/CspBatchSettler.sol";
import "../src/vaults/EthCspVault.sol";

contract CspVaultFreshStackTest is Test {
    AddressBook private addressBook;
    Controller private controller;
    MarginPool private pool;
    OTokenFactory private factory;
    Oracle private oracle;
    Whitelist private whitelist;
    CspBatchSettler private settler;
    EthCspVault private vault;

    MockERC20 private weth;
    MockERC20 private usdc;
    MockChainlinkFeed private priceFeed;
    MockSwapRouter private swapRouter;

    address private allocator = address(0xA110C);
    address private feeRecipient = address(0xFEE);
    address private user = address(0xA11CE);
    uint256 private mmKey = 0xBEEF;
    address private mm;
    uint256 private expiry;
    uint256 private quoteId;

    function setUp() public {
        vm.warp(1_700_000_000);
        mm = vm.addr(mmKey);

        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        priceFeed = new MockChainlinkFeed(1800e8);
        swapRouter = new MockSwapRouter(address(usdc));
        swapRouter.setPriceFeed(address(weth), address(priceFeed));

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
        settler = CspBatchSettler(
            address(
                new ERC1967Proxy(
                    address(new CspBatchSettler()),
                    abi.encodeCall(CspBatchSettler.initialize, (address(addressBook), allocator, address(this)))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        factory.setOperator(address(this));
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        oracle.setPriceFeed(address(weth), address(priceFeed));
        controller.setCustodiedRedemptionOnly(true);

        settler.setWhitelistedMM(mm, true);
        settler.setSwapRouter(address(swapRouter));
        settler.setSwapFeeTier(500);

        vault = new EthCspVault(address(addressBook), address(usdc), address(weth), allocator, feeRecipient, 1000);
        settler.setPhysicalDeliveryVault(address(vault), true);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
        usdc.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);
        usdc.mint(user, 10_000e6);
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_openUsesFreshCspStackAndReservesPhysicalDelivery() public {
        _depositAndOpen();

        assertEq(vault.activeBatches(), 1);
        assertEq(vault.activeCollateral(), 2000e6);
        assertEq(settler.vaultMM(address(vault), 1), mm);
        assertEq(settler.vaultOTokenBalance(address(vault), 1), 1e8);
        assertTrue(settler.physicalDeliveryReservedVault(address(vault), 1));
    }

    function test_itmSettlementDeliversWethWithoutMmWeth() public {
        _depositAndOpen();
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(allocator);
        vault.prepareCspBatchSettlement(1, 0);
        assertEq(weth.balanceOf(mm), 0);

        vm.prank(allocator);
        settler.operatorPhysicalRedeemVault(address(vault), 1, 2000e6);
        vm.prank(allocator);
        vault.finalizeCspBatchSettlement(1);

        assertEq(vault.accountedUnderlyingAssets(), 1e18);
        assertEq(weth.balanceOf(address(vault)), 1e18);
        assertEq(settler.vaultOTokenBalance(address(vault), 1), 0);
    }

    function test_timeoutFallbackPaysIntrinsicValueToMm() public {
        _depositAndOpen();
        uint256 mmBalanceBefore = usdc.balanceOf(mm);
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(allocator);
        vault.prepareCspBatchSettlement(1, 0);
        vm.warp(block.timestamp + vault.settlementDefaultDelay());

        vm.prank(allocator);
        vault.settleDefaultedCspBatch(1);

        assertEq(vault.activeBatches(), 0);
        assertEq(vault.accountedIdleAssets(), 9863e6);
        assertEq(vault.accountedUnderlyingAssets(), 0);
        assertEq(usdc.balanceOf(mm) - mmBalanceBefore, 200e6);
        assertEq(settler.vaultOTokenBalance(address(vault), 1), 0);
    }

    function test_timeoutFallbackHandlesRoundedCollateral() public {
        vm.prank(user);
        vault.deposit(10_000e6);

        uint256 roundedStrike = 200_001_000_000;
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), roundedStrike, expiry, true);
        CspBatchSettler.Quote memory quote = CspBatchSettler.Quote({
            oToken: oToken,
            bidPrice: 1e8,
            deadline: block.timestamp + 1 hours,
            quoteId: ++quoteId,
            maxAmount: 1,
            makerNonce: settler.makerNonce(mm)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, settler.hashQuoteFor(address(vault), quote));

        vm.prank(allocator);
        vault.openCspBatch(_asBatchQuote(quote), abi.encodePacked(r, s, v), 1, 21);

        uint256 mmBalanceBefore = usdc.balanceOf(mm);
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(allocator);
        vault.prepareCspBatchSettlement(1, 0);
        vm.warp(block.timestamp + vault.settlementDefaultDelay());
        vm.prank(allocator);
        vault.settleDefaultedCspBatch(1);

        (,,,,,, uint256 collateralReturned, bool settled) = vault.batches(1);
        assertTrue(settled);
        assertEq(collateralReturned, 18);
        assertEq(usdc.balanceOf(mm) - mmBalanceBefore, 2);
        assertEq(usdc.balanceOf(address(pool)), 1);
    }

    function test_settlementExecutorCannotBypassReservedVault() public {
        _depositAndOpen();
        address executor = address(0xE0);
        settler.setSettlementExecutorFor(address(vault), executor, true);

        vm.prank(executor);
        vm.expectRevert(CspBatchSettler.ReservedPhysicalDelivery.selector);
        settler.settleVaultFor(address(vault), 1);
    }

    function test_custodiedRedemptionBlocksDirectHolder() public {
        _depositAndOpen();
        (, address oToken,,,,,,) = vault.batches(1);

        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        uint256 directVaultId = controller.openVault(address(this));
        controller.depositCollateral(address(this), directVaultId, address(usdc), 2000e6);
        controller.mintOtoken(address(this), directVaultId, oToken, 1e8, mm);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(mm);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.redeem(oToken, 1e8);
    }

    function test_emergencyCannotBurnAnotherVaultsCustodiedTokens() public {
        _depositAndOpen();
        (, address oToken,,,,,,) = vault.batches(1);

        usdc.mint(address(this), 2000e6);
        usdc.approve(address(pool), 2000e6);
        uint256 directVaultId = controller.openVault(address(this));
        controller.depositCollateral(address(this), directVaultId, address(usdc), 2000e6);
        controller.mintOtoken(address(this), directVaultId, oToken, 1e8, address(this));
        uint256 custodiedBefore = IERC20(oToken).balanceOf(address(settler));

        controller.setSystemFullyPaused(true);
        vm.expectRevert(Controller.OTokensAlreadyRedeemed.selector);
        controller.emergencyWithdrawVault(directVaultId);

        assertEq(IERC20(oToken).balanceOf(address(settler)), custodiedBefore);
        assertFalse(controller.vaultSettled(address(this), directVaultId));
    }

    function test_settlementExecutorIsOwnerScoped() public {
        address executor = address(0xE0);
        settler.setSettlementExecutor(executor, true);
        assertTrue(settler.settlementExecutor(address(this), executor));
        assertFalse(settler.settlementExecutor(address(vault), executor));

        settler.setSettlementExecutorFor(address(vault), executor, true);
        assertTrue(settler.settlementExecutor(address(vault), executor));
    }

    function test_quoteCannotBeFilledByDifferentOwner() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), 2000e8, expiry, true);
        (BatchSettler.Quote memory quote, bytes memory signature) = _signedQuote(oToken);
        address otherOwner = address(0xBAD);
        usdc.mint(otherOwner, 2000e6);
        vm.prank(otherOwner);
        usdc.approve(address(pool), 2000e6);

        vm.prank(otherOwner);
        vm.expectRevert();
        settler.executeOrder(_asCspQuote(quote), signature, 1e8, 2000e6);
    }

    function test_fragmentedFillsChargeCumulativeProtocolFee() public {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), 2000e8, expiry, true);
        CspBatchSettler.Quote memory quote = CspBatchSettler.Quote({
            oToken: oToken,
            bidPrice: 24,
            deadline: block.timestamp + 1 hours,
            quoteId: ++quoteId,
            maxAmount: 2e8,
            makerNonce: settler.makerNonce(mm)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, settler.hashQuoteFor(address(this), quote));
        bytes memory signature = abi.encodePacked(r, s, v);

        usdc.mint(address(this), 4000e6);
        usdc.approve(address(pool), 4000e6);
        settler.setTreasury(feeRecipient);
        settler.setProtocolFeeBps(400);

        settler.executeOrder(quote, signature, 1e8, 2000e6);
        settler.executeOrder(quote, signature, 1e8, 2000e6);

        assertEq(usdc.balanceOf(feeRecipient), 1);
    }

    function test_settlementRoundingKeepsAggregateRedemptionSolvent() public {
        address tinyPut = factory.createOToken(address(weth), address(usdc), address(usdc), 50e8, expiry, true);
        controller.setCustodiedRedemptionOnly(false);
        usdc.mint(address(this), 2);
        usdc.approve(address(pool), 2);

        uint256 first = controller.openVault(address(this));
        controller.depositCollateral(address(this), first, address(usdc), 1);
        controller.mintOtoken(address(this), first, tinyPut, 1, user);
        uint256 second = controller.openVault(address(this));
        controller.depositCollateral(address(this), second, address(usdc), 1);
        controller.mintOtoken(address(this), second, tinyPut, 1, user);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 40e8);
        controller.settleVault(address(this), first);
        controller.settleVault(address(this), second);

        uint256 userBalanceBefore = usdc.balanceOf(user);
        vm.prank(user);
        controller.redeem(tinyPut, 2);
        assertEq(usdc.balanceOf(user) - userBalanceBefore, 1);
        assertEq(usdc.balanceOf(address(pool)), 1);
    }

    function test_mockInfrastructureRejectsUnauthorizedUpdates() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        priceFeed.setPrice(1e8);
        vm.expectRevert();
        swapRouter.setPriceFeed(address(weth), address(priceFeed));
        vm.stopPrank();
    }

    function _depositAndOpen() private {
        vm.prank(user);
        vault.deposit(10_000e6);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), 2000e8, expiry, true);
        (BatchSettler.Quote memory quote, bytes memory signature) = _signedQuote(oToken);

        vm.prank(allocator);
        vault.openCspBatch(quote, signature, 1e8, 2000e6);
    }

    function _signedQuote(address oToken) private returns (BatchSettler.Quote memory quote, bytes memory signature) {
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 70e6,
            deadline: block.timestamp + 1 hours,
            quoteId: ++quoteId,
            maxAmount: 1e8,
            makerNonce: settler.makerNonce(mm)
        });
        CspBatchSettler.Quote memory cspQuote = _asCspQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, settler.hashQuoteFor(address(vault), cspQuote));
        signature = abi.encodePacked(r, s, v);
    }

    function _asCspQuote(BatchSettler.Quote memory quote) private pure returns (CspBatchSettler.Quote memory cspQuote) {
        cspQuote = CspBatchSettler.Quote({
            oToken: quote.oToken,
            bidPrice: quote.bidPrice,
            deadline: quote.deadline,
            quoteId: quote.quoteId,
            maxAmount: quote.maxAmount,
            makerNonce: quote.makerNonce
        });
    }

    function _asBatchQuote(CspBatchSettler.Quote memory quote)
        private
        pure
        returns (BatchSettler.Quote memory batchQuote)
    {
        batchQuote = BatchSettler.Quote({
            oToken: quote.oToken,
            bidPrice: quote.bidPrice,
            deadline: quote.deadline,
            quoteId: quote.quoteId,
            maxAmount: quote.maxAmount,
            makerNonce: quote.makerNonce
        });
    }
}
