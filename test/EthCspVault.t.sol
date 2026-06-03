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
import "../src/mocks/MockERC20.sol";
import "../src/vaults/EthCspVault.sol";

contract EthCspVaultTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;
    EthCspVault public vault;

    MockERC20 public weth;
    MockERC20 public usdc;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA20);
    address public receiver = address(0x1234);
    address public operator = address(0x0F);
    address public feeRecipient = address(0xFEE);

    uint256 public mmKey = 0xAA01;
    address public mm;

    uint256 public expiry;
    uint256 public nextQuoteId = 1;
    uint256 public constant STRIKE = 2000e8;

    function setUp() public {
        vm.warp(1700000000);
        mm = vm.addr(mmKey);

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
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operator, address(this)))
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
        settler.setWhitelistedMM(mm, true);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        vault = new EthCspVault(address(addressBook), address(usdc), address(weth), operator, feeRecipient, 1000);

        _computeExpiry();

        usdc.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);

        usdc.mint(alice, 20_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(bob, 20_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);

        usdc.mint(carol, 20_000e6);
        vm.prank(carol);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_depositMintsInternalShares() public {
        vm.prank(alice);
        uint256 minted = vault.deposit(10_000e6);

        assertEq(minted, 10_000e6);
        assertEq(vault.sharesOf(alice), 10_000e6);
        assertEq(vault.totalShares(), 10_000e6);
        assertEq(vault.totalManagedAssets(), 10_000e6);

        (uint64 startedAt,,,,,,,,,,,,) = vault.epochs(1);
        assertEq(startedAt, uint64(block.timestamp));
    }

    function test_openCspBatchUsesExistingBatchSettlerFlow() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        address oToken = _createPut();
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        (uint256 batchId, uint256 protocolVaultId) = vault.openCspBatch(quote, sig, 1e8, 2000e6);

        assertEq(batchId, 1);
        assertEq(protocolVaultId, 1);
        assertEq(vault.activeBatches(), 1);
        assertEq(vault.activeCollateral(), 2000e6);
        assertEq(vault.idleAssets(), 8063e6);
        assertEq(vault.totalManagedAssets(), 10_063e6);
        assertEq(usdc.balanceOf(feeRecipient), 7e6);
        assertEq(usdc.balanceOf(address(pool)), 2000e6);
        assertEq(usdc.allowance(address(vault), address(pool)), 0);
        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8);
        assertEq(OToken(oToken).balanceOf(address(settler)), 1e8);

        (uint256 epochId,, uint256 storedVaultId, uint256 amount, uint256 collateral, uint256 premium,, bool settled) =
            vault.batches(batchId);
        assertEq(epochId, 1);
        assertEq(storedVaultId, protocolVaultId);
        assertEq(amount, 1e8);
        assertEq(collateral, 2000e6);
        assertEq(premium, 70e6);
        assertFalse(settled);
    }

    function test_withdrawIdleExitsImmediatelyWhenUsdcIsAvailable() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(alice);
        uint256 withdrawn = vault.withdrawIdle(2_500e6, receiver);

        assertEq(withdrawn, 2_500e6);
        assertEq(usdc.balanceOf(receiver), 2_500e6);
        assertEq(vault.sharesOf(alice), 7_500e6);
        assertEq(vault.totalShares(), 7_500e6);
        assertEq(vault.totalManagedAssets(), 7_500e6);
    }

    function test_withdrawIdleRevertsWhileBatchIsActive() public {
        _depositAndOpenOnePut();

        vm.prank(alice);
        vm.expectRevert(EthCspVault.OpenBatches.selector);
        vault.withdrawIdle(1_000e6, receiver);
    }

    function test_underlyingDonationDoesNotBlockDeposits() public {
        weth.mint(address(vault), 1);

        vm.prank(alice);
        uint256 minted = vault.deposit(10_000e6);

        assertEq(minted, 10_000e6);
        assertEq(vault.availableUnderlyingAssets(), 0);
        assertEq(vault.accountedUnderlyingAssets(), 0);
    }

    function test_settleOtmCloseEpochChargesPerformanceFeeAndRollsOver() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        uint256 returned = _backendSettleVault(1, 1);
        vm.prank(operator);
        vault.settleCspBatch(1, returned, 0);

        assertEq(returned, 2000e6);
        assertEq(vault.activeBatches(), 0);
        assertEq(vault.activeCollateral(), 0);
        assertEq(vault.idleAssets(), 10_063e6);

        (,,,,,,, uint256 assignmentShortfallBeforeFee,,,,,) = vault.epochs(1);
        assertEq(assignmentShortfallBeforeFee, 0);

        vm.prank(operator);
        uint256 nextEpoch = vault.closeEpoch();

        assertEq(nextEpoch, 2);
        assertEq(vault.currentEpoch(), 2);
        assertEq(usdc.balanceOf(feeRecipient), 7e6);
        assertEq(vault.totalManagedAssets(), 10_063e6);

        (,,,,,,,, uint256 performanceFee,,,, bool closed) = vault.epochs(1);
        assertEq(performanceFee, 7e6);
        assertTrue(closed);
    }

    function test_settleItmTracksAssignmentShortfallAndFeesOnlyPremium() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        uint256 returned = _backendSettleVault(1, 1);
        weth.mint(address(vault), 1e18);
        vm.prank(operator);
        vault.settleCspBatch(1, returned, 1e18);
        assertEq(returned, 0);

        vm.prank(operator);
        vault.closeEpoch();

        assertEq(usdc.balanceOf(feeRecipient), 7e6);
        assertEq(vault.totalManagedAssets(), 8063e6);

        (,,,,,,, uint256 assignmentShortfall, uint256 performanceFee,,,,) = vault.epochs(1);
        assertEq(assignmentShortfall, 2000e6);
        assertEq(performanceFee, 7e6);
    }

    function test_requestWithdrawBeforeCloseAndClaimAfterEpoch() public {
        _depositAndOpenOnePut();

        vm.prank(bob);
        vm.expectRevert(EthCspVault.OpenBatches.selector);
        vault.deposit(1_000e6);

        vm.prank(alice);
        vault.requestWithdraw(10_000e6);

        assertEq(vault.sharesOf(alice), 0);
        assertEq(vault.pendingWithdrawalEpoch(alice), 1);
        assertEq(vault.pendingWithdrawalShares(alice), 10_000e6);
        assertEq(vault.totalPendingWithdrawalShares(), 10_000e6);

        vm.prank(alice);
        vm.expectRevert(EthCspVault.EpochNotClosed.selector);
        vault.claimWithdraw();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);
        uint256 returned = _backendSettleVault(1, 1);
        vm.prank(operator);
        vault.settleCspBatch(1, returned, 0);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.totalShares(), 0);
        assertEq(vault.reservedWithdrawalAssets(), 10_063e6);
        assertEq(vault.totalManagedAssets(), 0);

        vm.prank(alice);
        (uint256 withdrawn, uint256 underlyingWithdrawn) = vault.claimWithdrawTo(receiver);

        assertEq(withdrawn, 10_063e6);
        assertEq(underlyingWithdrawn, 0);
        assertEq(usdc.balanceOf(receiver), 10_063e6);
        assertEq(vault.reservedWithdrawalAssets(), 0);
        assertEq(vault.totalManagedAssets(), 0);
    }

    function test_reservedWithdrawalAssetsCannotBeOpenedAsCollateral() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(alice);
        vault.requestWithdraw(10_000e6);

        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(bob);
        vault.deposit(1_000e6);

        address oToken = _createPut();
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.InsufficientAvailableAssets.selector);
        vault.openCspBatch(quote, sig, 1e8, 2_000e6);

        assertEq(vault.reservedWithdrawalAssets(), 10_000e6);
        assertEq(vault.availableIdleAssets(), 1_000e6);
    }

    function test_closeEpochDoesNotDoubleCountPreviousWithdrawalReserves() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(bob);
        vault.deposit(10_000e6);

        vm.prank(alice);
        vault.requestWithdraw(10_000e6);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.reservedWithdrawalAssets(), 10_000e6);
        assertEq(vault.availableIdleAssets(), 10_000e6);
        assertEq(vault.totalShares(), 10_000e6);

        vm.prank(bob);
        vault.requestWithdraw(10_000e6);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.reservedWithdrawalAssets(), 20_000e6);
        assertEq(vault.availableIdleAssets(), 0);
        assertEq(vault.totalShares(), 0);
    }

    function test_depositRevertsWhenExistingSharesHaveNoManagedAssets() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(address(vault));
        assertTrue(usdc.transfer(address(0xDEAD), 10_000e6));

        assertEq(vault.totalShares(), 10_000e6);
        assertEq(vault.totalManagedAssets(), 0);

        vm.prank(bob);
        vm.expectRevert(EthCspVault.InsolventShareSupply.selector);
        vault.deposit(1_000e6);
    }

    function test_depositRevertsWhileWithdrawalsArePending() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(1_000e6);

        vm.prank(bob);
        vm.expectRevert(EthCspVault.PendingWithdrawalsOpen.selector);
        vault.deposit(1_000e6);
    }

    function test_virtualSharesPreventDonationShareInflationProfit() public {
        vm.prank(alice);
        vault.deposit(1);

        vm.prank(alice);
        assertTrue(usdc.transfer(address(vault), 999_999));

        vm.prank(bob);
        uint256 bobShares = vault.deposit(1_999_999);
        assertGt(bobShares, 1);

        vm.prank(alice);
        vault.requestWithdraw(1);
        vm.prank(operator);
        vault.closeEpoch();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 withdrawn,) = vault.claimWithdraw();

        assertLt(withdrawn, 1_000_000);
        assertEq(usdc.balanceOf(alice), aliceBefore + withdrawn);
    }

    function test_pendingWithdrawalsOnlyReduceDeployableBatchCollateral() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(1_000e6);

        assertEq(vault.deployableIdleAssets(), 9_000e6);

        address oToken = _createPut();
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.InsufficientAvailableAssets.selector);
        vault.openCspBatch(quote, sig, 1e8, 9_001e6);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2_000e6);

        assertEq(vault.activeCollateral(), 2_000e6);
    }

    function test_lastWithdrawalClaimConsumesRoundingDust() public {
        vm.prank(alice);
        vault.deposit(1);
        vm.prank(bob);
        vault.deposit(2);

        vm.prank(address(vault));
        assertTrue(usdc.transfer(address(0xDEAD), 2));

        vm.prank(alice);
        vault.requestWithdraw(1);
        vm.prank(bob);
        vault.requestWithdraw(2);

        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.reservedWithdrawalAssets(), 1);

        vm.prank(alice);
        (uint256 aliceWithdrawn,) = vault.claimWithdraw();
        assertEq(aliceWithdrawn, 0);
        assertEq(vault.reservedWithdrawalAssets(), 1);

        vm.prank(bob);
        (uint256 bobWithdrawn,) = vault.claimWithdraw();
        assertEq(bobWithdrawn, 1);
        assertEq(vault.reservedWithdrawalAssets(), 0);
    }

    function test_itmWithdrawerClaimsAssignedWethAfterPhysicalDelivery() public {
        _depositAndOpenOnePut();

        vm.prank(alice);
        vault.requestWithdraw(10_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        uint256 returned = _backendSettleVault(1, 1);
        assertEq(returned, 0);

        weth.mint(address(vault), 1e18);
        vm.prank(operator);
        vault.settleCspBatch(1, 0, 1e18);
        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(alice);
        (uint256 usdcWithdrawn, uint256 wethWithdrawn) = vault.claimWithdrawTo(receiver);

        assertEq(usdcWithdrawn, 8063e6);
        assertEq(wethWithdrawn, 1e18);
        assertEq(weth.balanceOf(receiver), 1e18);
        assertEq(vault.reservedUnderlyingAssets(), 0);
        assertEq(vault.accountedUnderlyingAssets(), 0);
    }

    function test_withdrawIdleRevertsAfterAssignmentUntilUnderlyingIsClaimed() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        uint256 returned = _backendSettleVault(1, 1);
        assertEq(returned, 0);

        weth.mint(address(vault), 1e18);
        vm.prank(operator);
        vault.settleCspBatch(1, 0, 1e18);
        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(alice);
        vm.expectRevert(EthCspVault.OpenBatches.selector);
        vault.withdrawIdle(1_000e6, receiver);
    }

    function test_rejectsCoveredCallAndNonOperatorOpen() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        address callToken = factory.createOToken(address(weth), address(usdc), address(weth), 2300e8, expiry, false);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(callToken, 50e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.InvalidOToken.selector);
        vault.openCspBatch(quote, sig, 1e8, 1e18);

        address putToken = _createPut();
        (quote, sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(alice);
        vm.expectRevert(EthCspVault.OnlyOperator.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function _depositAndOpenOnePut() internal {
        vm.prank(alice);
        vault.deposit(10_000e6);

        address oToken = _createPut();
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function _backendSettleVault(uint256 batchId, uint256 expectedVaultId) internal returns (uint256 returned) {
        uint256 balanceBefore = usdc.balanceOf(address(vault));
        (,, uint256 protocolVaultId,,,,,) = vault.batches(batchId);
        assertEq(protocolVaultId, expectedVaultId);

        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = address(vault);
        vaultIds[0] = protocolVaultId;

        vm.prank(operator);
        settler.batchSettleVaults(owners, vaultIds);

        returned = usdc.balanceOf(address(vault)) - balanceBefore;
    }

    function _createPut() internal returns (address) {
        return factory.createOToken(address(weth), address(usdc), address(usdc), STRIKE, expiry, true);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: maxAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _computeExpiry() internal {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }
}
