// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {AsyncRedeemVaultHarness} from "./FundStandardsSpec.t.sol";

contract FundStateHandler is Test {
    MockERC20 public immutable asset;
    AsyncRedeemVaultHarness public immutable vault;
    address public immutable alice;
    address public immutable bob;
    address public immutable accounting;

    constructor(MockERC20 asset_, AsyncRedeemVaultHarness vault_, address alice_, address bob_, address accounting_) {
        asset = asset_;
        vault = vault_;
        alice = alice_;
        bob = bob_;
        accounting = accounting_;
    }

    function request(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actorSeed % 2 == 0 ? alice : bob;
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0 || vault.pendingRedeemRequest(0, actor) != 0) return;
        uint256 shares = bound(sharesSeed, 1, balance);
        vm.prank(actor);
        vault.requestRedeem(shares, actor, actor);
    }

    function process(uint256 sharesSeed) external {
        if (vault.unaccountedBalance() != 0) return;
        uint256 pending = vault.batchPendingShares(vault.nextProcessBatchId());
        if (pending == 0) return;
        vault.processBatch(bound(sharesSeed, 1, pending));
    }

    function claim(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actorSeed % 2 == 0 ? alice : bob;
        uint256 claimable = vault.maxRedeem(actor);
        if (claimable == 0) return;
        uint256 shares = bound(sharesSeed, 1, claimable);
        vm.prank(actor);
        vault.redeem(shares, actor, actor);
    }

    function cancel(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = actorSeed % 2 == 0 ? alice : bob;
        uint256 pending = vault.pendingRedeemRequest(0, actor);
        if (pending == 0 || !vault.isCancellationAvailable(actor)) return;
        vm.prank(actor);
        vault.cancelPending(bound(sharesSeed, 1, pending));
    }

    function transferShares(uint256 actorSeed, uint256 sharesSeed) external {
        address from = actorSeed % 2 == 0 ? alice : bob;
        address to = from == alice ? bob : alice;
        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;
        vm.prank(from);
        assertTrue(vault.transfer(to, bound(sharesSeed, 1, balance)));
    }

    function donate(uint96 assets) external {
        asset.mint(address(vault), assets);
    }

    function syncDonation() external {
        uint64 nextNonce = vault.lastDonationReportNonce() + 1;
        vm.prank(accounting);
        vault.syncDonation(nextNonce);
    }
}

contract FundStateInvariantTest is StdInvariant, Test {
    MockERC20 internal asset;
    AsyncRedeemVaultHarness internal vault;
    FundStateHandler internal handler;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        asset = new MockERC20("Mock USDC", "mUSDC", 6);
        vault = new AsyncRedeemVaultHarness(asset);

        asset.mint(alice, 1_000e6);
        asset.mint(bob, 1_000e6);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, bob);
        vm.stopPrank();

        handler = new FundStateHandler(asset, vault, alice, bob, address(this));
        targetContract(address(handler));
    }

    function invariant_shareSupplyReconciles() public view {
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(address(vault)));
        assertEq(vault.balanceOf(address(vault)), vault.totalPendingShares());
    }

    function invariant_pendingSharesReconcileByController() public view {
        assertEq(vault.totalPendingShares(), vault.pendingRedeemRequest(0, alice) + vault.pendingRedeemRequest(0, bob));
    }

    function invariant_claimReservesReconcile() public view {
        assertEq(vault.totalReservedAssets(), vault.claimableAssets(alice) + vault.claimableAssets(bob));
        assertLe(vault.totalReservedAssets(), vault.accountedGrossAssets());
    }

    function invariant_navExcludesClaimsAndUnaccountedDonations() public view {
        assertEq(vault.totalAssets() + vault.totalReservedAssets(), vault.accountedGrossAssets());
        assertEq(asset.balanceOf(address(vault)), vault.accountedGrossAssets() + vault.unaccountedBalance());
    }

    function test_handlerCanSynchronizeDonationWithFreshNonce() public {
        asset.mint(address(vault), 1e6);
        handler.syncDonation();

        assertEq(vault.unaccountedBalance(), 0);
        assertEq(vault.lastDonationReportNonce(), 1);
    }
}
