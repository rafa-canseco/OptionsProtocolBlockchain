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
import "../src/vaults/CspBatchSettler.sol";
import "../src/vaults/EthCspVault.sol";
import "../src/vaults/EthCspOptionSelector.sol";
import "../src/vaults/EthCspStrategyAdapter.sol";
import "../src/vaults/interfaces/IEthCspOptionSelector.sol";
import "../src/vaults/interfaces/IEthCspStrategyAdapter.sol";

contract BadEthCspStrategyAdapter is IEthCspStrategyAdapter {
    function openCspBatch(
        address,
        address,
        address,
        address,
        CspBatchSettler.Quote calldata,
        bytes calldata,
        uint256,
        uint256
    ) external pure returns (OpenResult memory result) {
        result = OpenResult({protocolVaultId: 1, premiumEarned: 0});
    }
}

contract EthCspVaultTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public legacySettler;
    CspBatchSettler public settler;
    EthCspVault public vault;
    EthCspStrategyAdapter public strategyAdapter;

    MockERC20 public weth;
    MockERC20 public usdc;

    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA20);
    address public receiver = address(0x1234);
    address public operator = address(0x0F);
    address public curator = address(0xC02A);
    address public newAllocator = address(0xA110C);
    address public newOwner = address(0x0A0A);
    address public treasury = address(0x7A2);
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
        legacySettler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operator, address(this)))
                )
            )
        );
        settler = CspBatchSettler(
            address(
                new ERC1967Proxy(
                    address(new CspBatchSettler()),
                    abi.encodeCall(CspBatchSettler.initialize, (address(addressBook), address(this)))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(legacySettler));

        factory.setOperator(address(this));
        controller.setAuthorizedSettler(address(settler), true);
        settler.setWhitelistedMM(mm, true);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        vault = new EthCspVault(
            address(addressBook), address(settler), address(usdc), address(weth), operator, feeRecipient, 1000
        );
        strategyAdapter = new EthCspStrategyAdapter();
        settler.setPhysicalDeliveryVault(address(vault), true);

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

    function test_openCspBatchUsesDedicatedCspSettlerAndLeavesLegacyRegistered() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        address oToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

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

    function test_openCspBatchRejectsAaveRoutedUsdcCollateral() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        pool.setAavePool(address(0xA0));
        pool.setAaveEnabled(address(usdc), true);

        address oToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
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

    function test_depositDuringActiveBatchQueuesAndActivatesNextEpoch() public {
        _depositAndOpenOnePut();

        vm.prank(bob);
        uint256 mintedDuringBatch = vault.deposit(1_000e6);

        assertEq(mintedDuringBatch, 0);
        assertEq(vault.pendingDepositAssets(bob), 1_000e6);
        assertEq(vault.totalPendingDepositAssets(), 1_000e6);
        assertEq(vault.sharesOf(bob), 0);
        assertEq(vault.totalManagedAssets(), 10_063e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);
        _settleVaultBatch(1, 1, 2000e6, 0);
        vm.prank(operator);
        vault.closeEpoch();

        _computeExpiry();
        address oToken = _createPut();
        (CspBatchSettler.Quote memory tooLargeQuote, bytes memory tooLargeSig) = _signQuote(oToken, 0, 503_200_000);
        vm.prank(operator);
        vm.expectRevert(EthCspVault.InsufficientAvailableAssets.selector);
        vault.openCspBatch(tooLargeQuote, tooLargeSig, 503_200_000, 10_064e6);

        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2_000e6);
        assertEq(vault.pendingDepositAssets(bob), 1_000e6);
        assertEq(vault.totalPendingDepositAssets(), 1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);
        _settleVaultBatch(2, 2, 2_000e6, 0);
        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(operator);
        uint256 activated = vault.activateDepositFor(bob);

        assertEq(activated, 987_556_784);
        assertEq(vault.pendingDepositAssets(bob), 0);
        assertEq(vault.totalPendingDepositAssets(), 0);
        assertEq(vault.sharesOf(bob), 987_556_784);
        assertEq(vault.totalShares(), 10_987_556_784);
    }

    function test_thirdPartyCannotForceActivatePendingDeposit() public {
        _depositAndOpenOnePut();

        vm.prank(bob);
        vault.deposit(1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);
        _settleVaultBatch(1, 1, 2000e6, 0);
        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(carol);
        vm.expectRevert(EthCspVault.OnlyAllocator.selector);
        vault.activateDepositFor(bob);

        vm.prank(bob);
        vault.cancelPendingDeposit(receiver);
        assertEq(vault.pendingDepositAssets(bob), 0);
        assertEq(usdc.balanceOf(receiver), 1_000e6);
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

        uint256 returned = _settleVaultBatch(1, 1, 2000e6, 0);

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

    function test_emergencyWithdrawBatchUnsticksPausedCoreSettlement() public {
        _depositAndOpenOnePut();
        address oToken = _currentBatchOToken(1);

        controller.setSystemFullyPaused(true);

        vm.prank(operator);
        vault.emergencyWithdrawBatch(1);

        assertEq(vault.activeBatches(), 0);
        assertEq(vault.activeCollateral(), 0);
        assertEq(vault.accountedIdleAssets(), 10_063e6);
        assertEq(vault.totalManagedAssets(), 10_063e6);
        assertTrue(controller.vaultSettled(address(vault), 1));
        assertFalse(settler.physicalDeliveryReservedVault(address(vault), 1));
        assertEq(settler.reservedPhysicalDeliveryBalance(mm, oToken), 0);
    }

    function test_defaultSettlementUnsticksWhenMmWithholdsPhysicalDelivery() public {
        _depositAndOpenOnePut();
        address oToken = _currentBatchOToken(1);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(operator);
        vm.expectRevert();
        vault.settleCspBatch(1, 0, 1e18);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.SettlementDefaultNotReady.selector);
        vault.settleDefaultedCspBatch(1, 0);

        vm.warp(expiry + vault.settlementDefaultDelay());

        vm.prank(operator);
        vault.settleDefaultedCspBatch(1, 0);

        assertEq(vault.activeBatches(), 0);
        assertEq(vault.activeCollateral(), 0);
        assertEq(vault.accountedIdleAssets(), 8063e6);
        assertEq(vault.accountedUnderlyingAssets(), 0);
        assertEq(vault.batchUnderlyingReceived(1), 0);
        assertTrue(controller.vaultSettled(address(vault), 1));
        assertFalse(settler.physicalDeliveryReservedVault(address(vault), 1));
        assertEq(settler.reservedPhysicalDeliveryBalance(mm, oToken), 0);

        (,,,, uint256 committedCollateral, uint256 returnedCollateral,, uint256 assignmentShortfall,,,,,) =
            vault.epochs(1);
        assertEq(committedCollateral, 2000e6);
        assertEq(returnedCollateral, 0);
        assertEq(assignmentShortfall, 2000e6);

        vm.prank(operator);
        vault.closeEpoch();

        uint256 aliceShares = vault.sharesOf(alice);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawIdle(aliceShares, receiver);
        assertEq(withdrawn, 8063e6);
        assertEq(usdc.balanceOf(receiver), 8063e6);
    }

    function test_curatorCanSetSettlementDefaultDelayWithinCap() public {
        vault.setSettlementDefaultDelay(2 days);
        assertEq(vault.settlementDefaultDelay(), 2 days);

        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.setSettlementDefaultDelay(31 days);
    }

    function test_settleRejectsAllocatorCollateralReportNotBackedByControllerDelta() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.CollateralAccountingMismatch.selector);
        vault.settleCspBatch(1, 100e6, 0);

        assertEq(vault.activeBatches(), 1);
        assertEq(vault.activeCollateral(), 2000e6);
        assertEq(vault.totalManagedAssets(), 10_063e6);

        _settleVaultBatch(1, 1, 2000e6, 0);
        assertEq(vault.activeBatches(), 0);
        assertEq(vault.activeCollateral(), 0);
    }

    function test_settleIgnoresUnsolicitedUnderlyingDonation() public {
        _depositAndOpenOnePut();

        weth.mint(address(vault), vault.underlyingDustThreshold() + 1);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        _settleVaultBatch(1, 1, 2000e6, 0);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.accountedUnderlyingAssets(), 0);
        assertEq(vault.availableUnderlyingAssets(), 0);

        _computeExpiry();
        address oToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
        assertEq(vault.activeBatches(), 1);
    }

    function test_settleItmTracksAssignmentShortfallAndFeesOnlyPremium() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        uint256 returned = _settleVaultBatch(1, 1, 0, 1e18);
        assertEq(returned, 0);

        vm.prank(operator);
        vault.closeEpoch();

        assertEq(usdc.balanceOf(feeRecipient), 7e6);
        assertEq(vault.totalManagedAssets(), 8063e6);

        (,,,,,,, uint256 assignmentShortfall, uint256 performanceFee,,,,) = vault.epochs(1);
        assertEq(assignmentShortfall, 2000e6);
        assertEq(performanceFee, 7e6);
    }

    function test_settleItmRejectsMissingAssignedUnderlying() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.CollateralAccountingMismatch.selector);
        vault.settleCspBatch(1, 0, 0);

        assertEq(vault.activeBatches(), 1);
        assertEq(vault.activeCollateral(), 2000e6);
    }

    function test_withdrawIdleRevertsBeforeAssignedUnderlyingIsAllocated() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 1e18);

        vm.prank(alice);
        vm.expectRevert(EthCspVault.OpenBatches.selector);
        vault.withdrawIdle(1_000e6, receiver);
    }

    function test_depositAfterItmSettlementBeforeCloseQueuesToProtectAssignedUnderlying() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 1e18);

        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6);

        assertEq(minted, 0);
        assertEq(vault.pendingDepositAssets(bob), 1_000e6);
        assertEq(vault.sharesOf(bob), 0);
        assertEq(vault.availableUnderlyingAssets(), 1e18);

        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(bob);
        uint256 activated = vault.activateDeposit();
        assertGt(activated, 0);

        vm.prank(bob);
        vm.expectRevert(EthCspVault.InvalidAmount.selector);
        vault.claimAssignedUnderlying(bob);

        vm.prank(alice);
        assertEq(vault.claimAssignedUnderlying(alice), 1e18);
    }

    function test_requestWithdrawBeforeCloseAndClaimAfterEpoch() public {
        _depositAndOpenOnePut();

        vm.prank(bob);
        uint256 bobMinted = vault.deposit(1_000e6);
        assertEq(bobMinted, 0);
        assertEq(vault.pendingDepositAssets(bob), 1_000e6);
        assertEq(vault.totalPendingDepositAssets(), 1_000e6);

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
        _settleVaultBatch(1, 1, 2000e6, 0);
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

        vm.prank(bob);
        uint256 activated = vault.activateDeposit();
        assertEq(activated, 1_000e6);
        assertEq(vault.pendingDepositAssets(bob), 0);
        assertEq(vault.totalPendingDepositAssets(), 0);
        assertEq(vault.sharesOf(bob), 1_000e6);
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
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

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

    function test_unaccountedUsdcDonationDoesNotInflateSharePrice() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        usdc.mint(address(vault), 10_000e6);

        assertEq(vault.totalShares(), 10_000e6);
        assertEq(vault.idleAssets(), 20_000e6);
        assertEq(vault.accountedIdleAssets(), 10_000e6);
        assertEq(vault.totalManagedAssets(), 10_000e6);

        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6);

        assertEq(minted, 1_000e6);
        assertEq(vault.sharesOf(bob), 1_000e6);
        assertEq(vault.totalManagedAssets(), 11_000e6);
    }

    function test_depositQueuesWhileWithdrawalsArePending() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(1_000e6);

        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6);

        assertEq(minted, 0);
        assertEq(vault.pendingDepositAssets(bob), 1_000e6);
        assertEq(vault.totalPendingDepositAssets(), 1_000e6);

        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(bob);
        uint256 activated = vault.activateDeposit();
        assertEq(activated, 1_000e6);
        assertEq(vault.sharesOf(bob), 1_000e6);
    }

    function test_cancelPendingDepositReturnsQueuedAssetsDuringAssignedUnderlying() public {
        _depositAndOpenOnePut();

        vm.prank(bob);
        vault.deposit(1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 1e18);
        vm.prank(operator);
        vault.closeEpoch();

        uint256 receiverBefore = usdc.balanceOf(receiver);
        vm.prank(bob);
        uint256 cancelled = vault.cancelPendingDeposit(receiver);

        assertEq(cancelled, 1_000e6);
        assertEq(usdc.balanceOf(receiver) - receiverBefore, 1_000e6);
        assertEq(vault.pendingDepositAssets(bob), 0);
        assertEq(vault.totalPendingDepositAssets(), 0);
        assertEq(vault.sharesOf(bob), 0);
    }

    function test_minDepositPreventsTinyFirstDepositDonationAttack() public {
        vm.prank(alice);
        vm.expectRevert(EthCspVault.InvalidAmount.selector);
        vault.deposit(1);
    }

    function test_sharePricingDoesNotLeakYieldToPostProfitDeposit() public {
        vm.prank(alice);
        vault.deposit(1e6);

        vm.prank(alice);
        assertTrue(usdc.transfer(address(vault), 1e6));

        vm.prank(bob);
        uint256 bobShares = vault.deposit(1e6);

        assertEq(bobShares, 1e6);

        vm.prank(bob);
        uint256 withdrawn = vault.withdrawIdle(bobShares, bob);
        assertEq(withdrawn, 1e6);
    }

    function test_depositMinSharesOutProtectsCaller() public {
        vm.prank(alice);
        vault.deposit(1e6);

        vm.prank(bob);
        vm.expectRevert(EthCspVault.NoShares.selector);
        vault.deposit(1e6, 1e6 + 1);

        vm.prank(bob);
        uint256 minted = vault.deposit(1e6, 1e6);
        assertEq(minted, 1e6);
    }

    function test_pendingWithdrawalsOnlyReduceDeployableBatchCollateral() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(alice);
        vault.requestWithdraw(1_000e6);

        assertEq(vault.deployableIdleAssets(), 9_000e6);

        address oToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.PendingWithdrawalsOpen.selector);
        vault.openCspBatch(quote, sig, 1e8, 2_000e6);
    }

    function test_lastWithdrawalClaimConsumesRoundingDust() public {
        vm.prank(alice);
        vault.deposit(1e6);
        vm.prank(bob);
        vault.deposit(2e6);

        vm.prank(alice);
        vault.requestWithdraw(1e6);
        vm.prank(bob);
        vault.requestWithdraw(2e6);

        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.reservedWithdrawalAssets(), 3e6);

        vm.prank(alice);
        (uint256 aliceWithdrawn,) = vault.claimWithdraw();
        assertEq(aliceWithdrawn, 1e6);
        assertEq(vault.reservedWithdrawalAssets(), 2e6);

        vm.prank(bob);
        (uint256 bobWithdrawn,) = vault.claimWithdraw();
        assertEq(bobWithdrawn, 2e6);
        assertEq(vault.reservedWithdrawalAssets(), 0);
    }

    function test_itmWithdrawerClaimsAssignedWethAfterPhysicalDelivery() public {
        _depositAndOpenOnePut();

        vm.prank(alice);
        vault.requestWithdraw(10_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        uint256 returned = _settleVaultBatch(1, 1, 0, 1e18);
        assertEq(returned, 0);
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

    function test_withdrawIdleAfterAssignmentKeepsAssignedWethClaimable() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        uint256 returned = _settleVaultBatch(1, 1, 0, 1e18);
        assertEq(returned, 0);
        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(alice);
        uint256 usdcWithdrawn = vault.withdrawIdle(1_000e6, receiver);

        assertEq(usdcWithdrawn, 806_300_000);
        assertEq(vault.claimableAssignedUnderlying(alice), 1e18);

        vm.prank(alice);
        uint256 wethClaimed = vault.claimAssignedUnderlying(receiver);

        assertEq(wethClaimed, 1e18);
        assertEq(weth.balanceOf(receiver), 1e18);
        assertEq(vault.accountedUnderlyingAssets(), 0);
        assertEq(vault.allocatedUnderlyingAssets(), 0);
    }

    function test_assignedUnderlyingClaimsDoNotBlockNewBatches() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(bob);
        vault.deposit(1e6);

        address oToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2_000e6);

        vm.prank(alice);
        vault.requestWithdraw(10_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        uint256 returned = _settleVaultBatch(1, 1, 0, 1e18);
        assertEq(returned, 0);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.availableUnderlyingAssets(), 0);
        assertGt(vault.allocatedUnderlyingAssets(), 0);

        _computeExpiry();
        oToken = _createPut();
        (quote, sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 10_000, 200_000);
        assertEq(vault.activeBatches(), 1);
    }

    function test_assignedUnderlyingStaysWithExposedHolderAfterNewDeposits() public {
        vm.prank(alice);
        vault.deposit(10_000e6);
        vm.prank(bob);
        vault.deposit(1_000e6);

        address oToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2_000e6);

        vm.prank(alice);
        vault.requestWithdraw(10_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        uint256 returned = _settleVaultBatch(1, 1, 0, 1e18);
        assertEq(returned, 0);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.availableUnderlyingAssets(), 0);
        assertGt(vault.allocatedUnderlyingAssets(), 0);

        vm.prank(carol);
        uint256 carolShares = vault.deposit(1_000e6);
        assertGt(carolShares, 0);

        _computeExpiry();
        oToken = _createPut();
        (quote, sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 10_000, 200_000);
        assertEq(vault.activeBatches(), 1);

        vm.prank(bob);
        uint256 bobWeth = vault.claimAssignedUnderlying(bob);
        assertGt(bobWeth, 0);

        vm.prank(carol);
        vm.expectRevert(EthCspVault.InvalidAmount.selector);
        vault.claimAssignedUnderlying(carol);
    }

    function test_assignedUnderlyingRoundingResidualIsSweptOnce() public {
        vm.prank(alice);
        vault.deposit(3e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 0, 1);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1, 20);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 1e10);

        uint256 feeRecipientBefore = weth.balanceOf(feeRecipient);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(weth.balanceOf(feeRecipient) - feeRecipientBefore, 1);
        assertEq(vault.availableUnderlyingAssets(), 0);
        assertEq(vault.allocatedUnderlyingAssets(), 9_999_999_999);

        vm.prank(alice);
        assertEq(vault.claimAssignedUnderlying(alice), 9_999_999_999);
    }

    function test_settleItmAcceptsRoundedCollateralResidual() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        address putToken = _createPutWithStrike(200_001_000_000);
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 0, 1);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1, 21);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 1, 1e10);

        assertEq(vault.activeBatches(), 0);
        assertEq(vault.activeCollateral(), 0);
        assertEq(vault.accountedIdleAssets(), 999_999_980);
        assertEq(weth.balanceOf(address(vault)), 1e10);
    }

    function test_fullAssignmentWithNoUsdcExpiresOldShareGeneration() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 0, 50_000_000);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 50_000_000, 1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 5e17);

        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.totalManagedAssets(), 0);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.currentShareGeneration(), 2);
        assertEq(vault.sharesOf(alice), 1_000e6);

        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6);
        assertEq(minted, 1_000e6);
        assertEq(vault.totalShares(), 1_000e6);
        assertEq(vault.sharesOf(bob), 1_000e6);

        vm.prank(alice);
        uint256 claimed = vault.claimAssignedUnderlying(receiver);
        assertEq(claimed, 5e17);
        assertEq(vault.sharesOf(alice), 0);
        assertEq(weth.balanceOf(receiver), 5e17);

        vm.prank(bob);
        vm.expectRevert(EthCspVault.InvalidAmount.selector);
        vault.claimAssignedUnderlying(bob);
    }

    function test_expiredSharesCannotClaimFutureGenerationUnderlying() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 0, 50_000_000);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 50_000_000, 1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 5e17);

        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.currentShareGeneration(), 2);
        assertEq(vault.generationCumulativeUnderlyingPerShare(1), 5e26);

        _computeExpiry();
        vm.prank(bob);
        vault.deposit(1_000e6);

        putToken = _createPut();
        (quote, sig) = _signQuote(putToken, 0, 50_000_000);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 50_000_000, 1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(2, 2, 0, 5e17);

        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.currentShareGeneration(), 3);
        assertEq(vault.generationCumulativeUnderlyingPerShare(2), 1e27);

        vm.prank(alice);
        assertEq(vault.claimAssignedUnderlying(alice), 5e17);

        vm.prank(bob);
        assertEq(vault.claimAssignedUnderlying(bob), 5e17);

        assertEq(vault.allocatedUnderlyingAssets(), 0);
        assertEq(vault.accountedUnderlyingAssets(), 0);
    }

    function test_forceRequestWithdrawCannotQueueExpiredShares() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 0, 50_000_000);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 50_000_000, 1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 5e17);

        vm.prank(operator);
        vault.closeEpoch();

        _computeExpiry();
        vm.prank(bob);
        vault.deposit(1_000e6);

        putToken = _createPut();
        (quote, sig) = _signQuote(putToken, 0, 25_000_000);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 25_000_000, 500e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(2, 2, 0, 25e16);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.NoShares.selector);
        vault.forceRequestWithdraw(alice);

        assertEq(vault.totalPendingWithdrawalShares(), 0);
        assertEq(vault.pendingWithdrawalShares(alice), 0);

        vm.prank(alice);
        assertEq(vault.claimAssignedUnderlying(alice), 5e17);
    }

    function test_depositAfterAssignmentActivatesWithoutClaimingOldWeth() public {
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        uint256 returned = _settleVaultBatch(1, 1, 0, 1e18);
        assertEq(returned, 0);
        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6);

        assertGt(minted, 0);
        assertEq(vault.pendingDepositAssets(bob), 0);
        assertEq(vault.totalPendingDepositAssets(), 0);
        assertEq(vault.sharesOf(bob), minted);
        assertEq(vault.availableUnderlyingAssets(), 0);

        vm.prank(bob);
        vm.expectRevert(EthCspVault.InvalidAmount.selector);
        vault.claimAssignedUnderlying(bob);

        vm.prank(alice);
        uint256 aliceWeth = vault.claimAssignedUnderlying(alice);
        assertEq(aliceWeth, 1e18);
    }

    function test_rejectsCoveredCallAndNonAllocatorOpen() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        address callToken = factory.createOToken(address(weth), address(usdc), address(weth), 2300e8, expiry, false);
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(callToken, 50e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.InvalidOToken.selector);
        vault.openCspBatch(quote, sig, 1e8, 1e18);

        address putToken = _createPut();
        (quote, sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(alice);
        vm.expectRevert(EthCspVault.OnlyAllocator.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function test_ownerSetsCuratorAndCuratorSetsAllocator() public {
        vault.setCurator(curator);
        assertEq(vault.curator(), curator);

        vm.prank(curator);
        vault.setAllocator(newAllocator);
        assertEq(vault.allocator(), newAllocator);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(alice);
        vault.deposit(10_000e6);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.OnlyAllocator.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);

        vm.prank(newAllocator);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function test_transferOwnershipMovesDefaultCurator() public {
        vault.transferOwnership(newOwner);

        assertEq(vault.owner(), newOwner);
        assertEq(vault.curator(), newOwner);

        vm.expectRevert(EthCspVault.OnlyOwner.selector);
        vault.setCurator(curator);

        vm.prank(newOwner);
        vault.setAllocator(newAllocator);
        assertEq(vault.allocator(), newAllocator);
    }

    function test_transferOwnershipPreservesExplicitCurator() public {
        vault.setCurator(curator);
        vault.transferOwnership(newOwner);

        assertEq(vault.owner(), newOwner);
        assertEq(vault.curator(), curator);

        vm.prank(curator);
        vault.setAllocator(newAllocator);
        assertEq(vault.allocator(), newAllocator);
    }

    function test_curatorStrategyBoundsAllocator() public {
        vault.setStrategyConfig(
            EthCspVault.StrategyConfig({
                maxCollateralPerBatch: 1500e6,
                maxUtilizationBps: 10_000,
                minPremiumBps: 0,
                minExpiryDelay: 0,
                maxExpiryDelay: type(uint256).max,
                minStrike: 0,
                maxStrike: type(uint256).max
            })
        );

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);

        vault.setStrategyConfig(
            EthCspVault.StrategyConfig({
                maxCollateralPerBatch: 2000e6,
                maxUtilizationBps: 10_000,
                minPremiumBps: 400,
                minExpiryDelay: 0,
                maxExpiryDelay: type(uint256).max,
                minStrike: 0,
                maxStrike: type(uint256).max
            })
        );

        vm.prank(operator);
        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function test_curatorUtilizationBoundsCumulativeExposure() public {
        vault.setStrategyConfig(
            EthCspVault.StrategyConfig({
                maxCollateralPerBatch: 10_000e6,
                maxUtilizationBps: 5000,
                minPremiumBps: 0,
                minExpiryDelay: 0,
                maxExpiryDelay: type(uint256).max,
                minStrike: 0,
                maxStrike: type(uint256).max
            })
        );

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 25e7, 5_000e6);

        (quote, sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 5e6, 100e6);
    }

    function test_curatorMinPremiumUsesNetPremiumReceived() public {
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(2000);

        vault.setStrategyConfig(
            EthCspVault.StrategyConfig({
                maxCollateralPerBatch: type(uint256).max,
                maxUtilizationBps: 10_000,
                minPremiumBps: 300,
                minExpiryDelay: 0,
                maxExpiryDelay: type(uint256).max,
                minStrike: 0,
                maxStrike: type(uint256).max
            })
        );

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function test_curatorCanDelegateOptionSelectionToModule() public {
        EthCspOptionSelector selector = new EthCspOptionSelector(
            address(this),
            IEthCspOptionSelector.StrategyConfig({
                maxCollateralPerBatch: type(uint256).max,
                maxUtilizationBps: 10_000,
                minPremiumBps: 400,
                minExpiryDelay: 0,
                maxExpiryDelay: type(uint256).max,
                minStrike: 0,
                maxStrike: type(uint256).max
            })
        );
        vault.setOptionSelector(address(selector));

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspOptionSelector.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function test_strategyAdapterCanOpenButSettlementIsVaultOnly() public {
        address strategyVault = address(0x5157);
        usdc.mint(strategyVault, 10_000e6);
        vm.prank(strategyVault);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(strategyVault);
        settler.setOrderExecutor(address(strategyAdapter), true);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(strategyVault);
        IEthCspStrategyAdapter.OpenResult memory opened = strategyAdapter.openCspBatch(
            strategyVault, address(settler), address(addressBook), address(usdc), quote, sig, 1e8, 2000e6
        );

        assertEq(opened.protocolVaultId, 1);
        assertEq(opened.premiumEarned, 70e6);
        assertEq(controller.vaultCount(strategyVault), 1);
        assertEq(settler.vaultMM(strategyVault, opened.protocolVaultId), mm);
        assertEq(usdc.balanceOf(strategyVault), 8070e6);
        assertEq(usdc.balanceOf(address(pool)), 2000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(strategyVault);
        settler.setSettlementExecutor(address(strategyAdapter), true);
        settler.setPhysicalDeliveryVault(strategyVault, true);
        vm.prank(strategyVault);
        settler.reservePhysicalDelivery(1);

        bytes memory settlementCall = abi.encodeWithSignature(
            "settleCspBatch(address,address,address,uint256,uint256,uint256,address)",
            strategyVault,
            address(addressBook),
            address(usdc),
            1,
            2000e6,
            0,
            strategyVault
        );
        (bool ok,) = address(strategyAdapter).call(settlementCall);
        assertFalse(ok);
        assertEq(usdc.balanceOf(strategyVault), 8070e6);
    }

    function test_strategyAdapterRejectsThirdPartyCalls() public {
        address strategyVault = address(0x5157);
        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.expectRevert(EthCspStrategyAdapter.Unauthorized.selector);
        strategyAdapter.openCspBatch(
            strategyVault, address(settler), address(addressBook), address(usdc), quote, sig, 1e8, 2000e6
        );
    }

    function test_vaultUsesStrategyAdapterWithBoundedAllowance() public {
        _installStrategyAdapter(type(uint256).max);

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        (uint256 batchId, uint256 protocolVaultId) = vault.openCspBatch(quote, sig, 1e8, 2000e6);

        assertEq(batchId, 1);
        assertEq(protocolVaultId, 1);
        assertEq(controller.vaultCount(address(vault)), 1);
        assertEq(settler.vaultMM(address(vault), protocolVaultId), mm);
        assertEq(usdc.allowance(address(vault), address(pool)), 0);
        assertTrue(settler.physicalDeliveryReservedVault(address(vault), protocolVaultId));
        assertEq(settler.reservedPhysicalDeliveryBalance(mm, putToken), 1e8);
        assertEq(vault.activeCollateral(), 2000e6);
        assertEq(vault.totalManagedAssets(), 10_063e6);
    }

    function test_strategyAdapterDoesNotPullUnderlyingFromArbitrarySource() public {
        _installStrategyAdapter(type(uint256).max);
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        weth.mint(operator, 1e18);
        vm.prank(operator);
        weth.approve(address(vault), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert();
        vault.settleCspBatch(1, 0, 1e18);

        assertEq(weth.balanceOf(address(vault)), 0);

        weth.mint(mm, 1e18);
        vm.prank(mm);
        weth.approve(address(vault), 1e18);
        vm.prank(operator);
        vault.settleCspBatch(1, 0, 1e18);

        assertEq(weth.balanceOf(address(vault)), 1e18);
    }

    function test_cspReservationsStayOffLegacyBatchSettler() public {
        _depositAndOpenOnePut();
        address oToken = _currentBatchOToken(1);

        assertEq(addressBook.batchSettler(), address(legacySettler));
        assertTrue(settler.physicalDeliveryReservedVault(address(vault), 1));
        assertEq(settler.reservedPhysicalDeliveryBalance(mm, oToken), 1e8);
        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8);
        assertEq(OToken(oToken).balanceOf(address(settler)), 1e8);
        assertEq(legacySettler.mmOTokenBalance(mm, oToken), 0);
        assertEq(OToken(oToken).balanceOf(address(legacySettler)), 0);

        vm.prank(alice);
        vm.expectRevert(CspBatchSettler.PhysicalDeliveryVaultNotAuthorized.selector);
        settler.releasePhysicalDelivery(1);
    }

    function test_vaultSettlementReleasesReservedPhysicalDelivery() public {
        _depositAndOpenOnePut();
        address oToken = _currentBatchOToken(1);
        assertEq(settler.reservedPhysicalDeliveryBalance(mm, oToken), 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 1e18);

        assertFalse(settler.physicalDeliveryReservedVault(address(vault), 1));
        assertEq(settler.reservedPhysicalDeliveryBalance(mm, oToken), 0);
    }

    function test_strategyAdapterCapBoundsAllocator() public {
        _installStrategyAdapter(1500e6);

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function test_strategyAdapterCapBoundsAggregateExposure() public {
        _installStrategyAdapter(2500e6);

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 75_000_000, 1500e6);

        assertEq(vault.activeAdapterCollateral(address(strategyAdapter)), 1500e6);

        (quote, sig) = _signQuote(putToken, 70e6, 100e8);
        vm.prank(operator);
        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.openCspBatch(quote, sig, 75_000_000, 1500e6);
    }

    function test_strategyAdapterCannotChangeWhileBatchesAreActive() public {
        _installStrategyAdapter(type(uint256).max);

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);

        EthCspStrategyAdapter newAdapter = new EthCspStrategyAdapter();
        vm.expectRevert(EthCspVault.OpenBatches.selector);
        vault.setStrategyAdapter(address(newAdapter), type(uint256).max);
    }

    function test_strategyAdapterCapCannotBeLoweredBelowActiveExposure() public {
        _installStrategyAdapter(type(uint256).max);

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);

        vm.expectRevert(EthCspVault.StrategyConstraint.selector);
        vault.setStrategyAdapterCap(address(strategyAdapter), 1999e6);
    }

    function test_strategyAdapterSettlementKeepsAssignedUnderlyingScopedToExposedShares() public {
        _installStrategyAdapter(type(uint256).max);
        _depositAndOpenOnePut();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        _settleVaultBatch(1, 1, 0, 1e18);
        vm.prank(operator);
        vault.closeEpoch();

        vm.prank(bob);
        uint256 minted = vault.deposit(1_000e6);
        assertGt(minted, 0);

        vm.prank(bob);
        vm.expectRevert(EthCspVault.InvalidAmount.selector);
        vault.claimAssignedUnderlying(bob);

        vm.prank(alice);
        assertEq(vault.claimAssignedUnderlying(alice), 1e18);
    }

    function test_strategyAdapterCannotFakeVaultAccounting() public {
        BadEthCspStrategyAdapter badAdapter = new BadEthCspStrategyAdapter();
        vault.setStrategyAdapter(address(badAdapter), type(uint256).max);

        vm.prank(alice);
        vault.deposit(10_000e6);

        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vm.expectRevert(EthCspVault.CollateralAccountingMismatch.selector);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function test_activateDepositsSkipsUsersWithoutPendingAssets() public {
        _depositAndOpenOnePut();

        vm.prank(bob);
        vault.deposit(1_000e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);
        _settleVaultBatch(1, 1, 2000e6, 0);
        vm.prank(operator);
        vault.closeEpoch();

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;

        vm.prank(operator);
        uint256 minted = vault.activateDeposits(users);

        assertEq(minted, 993_739_441);
        assertEq(vault.pendingDepositAssets(bob), 0);
        assertEq(vault.totalPendingDepositAssets(), 0);
        assertEq(vault.sharesOf(bob), 993_739_441);
    }

    function test_dustPendingDepositRefundsInsteadOfBlockingBatches() public {
        _depositAndOpenOnePut();

        vm.prank(bob);
        vm.expectRevert(EthCspVault.InvalidAmount.selector);
        vault.deposit(1);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);
        _settleVaultBatch(1, 1, 2000e6, 0);
        vm.prank(operator);
        vault.closeEpoch();

        assertEq(vault.pendingDepositAssets(bob), 0);
        assertEq(vault.totalPendingDepositAssets(), 0);
        assertEq(vault.sharesOf(bob), 0);

        _computeExpiry();
        address putToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(putToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2_000e6);
    }

    function _depositAndOpenOnePut() internal {
        vm.prank(alice);
        vault.deposit(10_000e6);

        address oToken = _createPut();
        (CspBatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, 100e8);

        vm.prank(operator);
        vault.openCspBatch(quote, sig, 1e8, 2000e6);
    }

    function _installStrategyAdapter(uint256 cap) internal {
        vault.setStrategyAdapter(address(strategyAdapter), cap);
        assertTrue(settler.orderExecutor(address(vault), address(strategyAdapter)));
        assertFalse(settler.settlementExecutor(address(vault), address(strategyAdapter)));
        assertEq(vault.strategyAdapter(), address(strategyAdapter));
        assertEq(vault.strategyAdapterCap(address(strategyAdapter)), cap);
    }

    function _settleVaultBatch(
        uint256 batchId,
        uint256 expectedVaultId,
        uint256 expectedCollateralReturned,
        uint256 expectedUnderlyingReceived
    ) internal returns (uint256 returned) {
        (,, uint256 protocolVaultId,,,,,) = vault.batches(batchId);
        assertEq(protocolVaultId, expectedVaultId);

        if (expectedUnderlyingReceived > 0) {
            weth.mint(mm, expectedUnderlyingReceived);
            vm.prank(mm);
            weth.approve(address(vault), expectedUnderlyingReceived);
        }

        vm.prank(operator);
        vault.settleCspBatch(batchId, expectedCollateralReturned, expectedUnderlyingReceived);

        returned = expectedCollateralReturned;
    }

    function _createPut() internal returns (address) {
        return factory.createOToken(address(weth), address(usdc), address(usdc), STRIKE, expiry, true);
    }

    function _createPutWithStrike(uint256 strike) internal returns (address) {
        return factory.createOToken(address(weth), address(usdc), address(usdc), strike, expiry, true);
    }

    function _currentBatchOToken(uint256 batchId) internal view returns (address oToken) {
        (, oToken,,,,,,) = vault.batches(batchId);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 maxAmount)
        internal
        returns (CspBatchSettler.Quote memory quote, bytes memory sig)
    {
        quote = CspBatchSettler.Quote({
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
