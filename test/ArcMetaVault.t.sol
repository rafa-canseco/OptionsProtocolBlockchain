// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {ArcMetaVault} from "../src/vaults/ArcMetaVault.sol";

contract ArcMetaVaultTest is Test {
    MockERC20 public usdc;
    ArcMetaVault public vault;

    address public owner = address(this);
    address public operator = address(0x0A0A);
    address public agent = address(0x0B0B);
    address public bridge = address(0xB111D6E);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public carol = address(0xCA201);
    address public receiver = address(0x1234);

    uint64 public constant EPOCH_DURATION = 1 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new ArcMetaVault(address(usdc), owner, operator, agent, EPOCH_DURATION);

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(carol, 100_000e6);
        usdc.mint(agent, 100_000e6);
        usdc.mint(operator, 100_000e6);

        _approve(alice);
        _approve(bob);
        _approve(carol);
        _approve(agent);
        _approve(operator);
    }

    function test_activeUserEarnsPremium() public {
        _depositAndActivate(alice, alice, 1_000e6);

        vm.prank(agent);
        vault.recordPremium(100e6);

        assertEq(vault.pendingPremium(alice), 100e6);

        vm.prank(alice);
        uint256 claimed = vault.claim(alice);

        assertEq(claimed, 100e6);
        assertEq(usdc.balanceOf(alice), 99_100e6);
        assertEq(vault.claimablePremium(alice), 0);
        assertEq(vault.rewardDebt(alice), 100e6);
    }

    function test_midEpochDepositDoesNotEarnOldPremium() public {
        _depositAndActivate(alice, alice, 1_000e6);

        vm.prank(agent);
        vault.recordPremium(100e6);

        vm.prank(bob);
        vault.deposit(1_000e6, bob);

        assertEq(vault.pendingPremium(alice), 100e6);
        assertEq(vault.pendingPremium(bob), 0);

        _startNextEpoch();
        vault.activatePending(bob, 3);

        assertEq(vault.pendingPremium(bob), 0);
        assertEq(vault.rewardDebt(bob), 100e6);

        vm.prank(agent);
        vault.recordPremium(100e6);

        assertEq(vault.pendingPremium(alice), 150e6);
        assertEq(vault.pendingPremium(bob), 50e6);
    }

    function test_intentIdCannotBeProcessedTwice() public {
        bytes32 intentId = keccak256("bridge-intent");
        usdc.mint(address(vault), 500e6);

        vm.prank(agent);
        vault.finalizeBridgeDeposit(intentId, alice, 500e6);

        vm.expectRevert(ArcMetaVault.IntentAlreadyProcessed.selector);
        vm.prank(agent);
        vault.finalizeBridgeDeposit(intentId, bob, 500e6);
    }

    function test_receiverCanDifferFromCaller() public {
        vm.prank(alice);
        vault.deposit(750e6, receiver);

        assertEq(vault.pendingShares(2, receiver), 750e18);
        assertEq(vault.totalPendingSharesOf(receiver), 750e18);
        assertEq(vault.pendingShares(2, alice), 0);

        _startNextEpoch();
        vault.activatePending(receiver, 2);

        assertEq(vault.activeShares(receiver), 750e18);
        assertEq(vault.activeShares(alice), 0);
    }

    function test_onlyAgentOrOperatorCanRecordPremiumAndDeployment() public {
        _depositAndActivate(alice, alice, 2_000e6);

        vm.expectRevert(ArcMetaVault.OnlyAgentOrOperator.selector);
        vm.prank(alice);
        vault.recordPremium(100e6);

        bytes32 intentId = keccak256("deploy-intent");
        vm.expectRevert(ArcMetaVault.OnlyAgentOrOperator.selector);
        vm.prank(alice);
        vault.recordDeployment(intentId, bridge, 100e6);

        vm.expectRevert(ArcMetaVault.OnlyAgentOrOperator.selector);
        vm.prank(alice);
        vault.finalizeBridgeDeposit(keccak256("unauthorized-bridge"), alice, 100e6);

        vm.prank(operator);
        vault.recordPremium(100e6);

        vm.prank(agent);
        vault.recordDeployment(intentId, bridge, 500e6);

        assertEq(vault.totalDeployedAssets(), 500e6);
        assertEq(usdc.balanceOf(bridge), 500e6);
        assertTrue(vault.processedIntent(intentId));
    }

    function test_claimUpdatesRewardDebt() public {
        _depositAndActivate(alice, alice, 1_000e6);

        vm.prank(agent);
        vault.recordPremium(40e6);

        vm.prank(alice);
        vault.claim(alice);

        assertEq(vault.rewardDebt(alice), 40e6);
        assertEq(vault.pendingPremium(alice), 0);

        vm.prank(agent);
        vault.recordPremium(60e6);

        assertEq(vault.pendingPremium(alice), 60e6);
    }

    function test_autoCompoundQueuesPremiumForNextEpoch() public {
        _depositAndActivate(alice, alice, 1_000e6);

        vm.prank(alice);
        vault.setAutoCompound(true);

        vm.prank(agent);
        vault.recordPremium(120e6);

        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 compounded = vault.claim(alice);

        assertEq(compounded, 120e6);
        assertEq(usdc.balanceOf(alice), balanceBefore);
        assertEq(vault.pendingShares(3, alice), 120e18);
        assertEq(vault.totalPendingAssets(), 120e6);
        assertEq(vault.claimablePremium(alice), 0);
        assertEq(vault.rewardDebt(alice), 120e6);
    }

    function test_pauseBlocksDepositsAndDeployments() public {
        _depositAndActivate(alice, alice, 1_000e6);

        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        vault.deposit(100e6, bob);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(agent);
        vault.recordDeployment(keccak256("paused-deploy"), bridge, 100e6);

        vault.unpause();

        vm.prank(bob);
        vault.deposit(100e6, bob);

        assertEq(vault.pendingShares(3, bob), 100e18);
    }

    function test_withdrawalQueueAccounting() public {
        _depositAndActivate(alice, alice, 1_000e6);

        vm.prank(alice);
        vault.requestWithdrawal(400e18);

        assertEq(vault.lockedWithdrawalShares(alice), 400e18);

        vm.prank(agent);
        uint256 claimable = vault.processWithdrawal(alice);

        assertEq(claimable, 400e6);
        assertEq(vault.activeShares(alice), 600e18);
        assertEq(vault.totalActivePrincipal(), 600e6);
        assertEq(vault.claimableWithdrawals(alice), 400e6);

        vm.prank(alice);
        uint256 withdrawn = vault.claimWithdrawal(receiver);

        assertEq(withdrawn, 400e6);
        assertEq(usdc.balanceOf(receiver), 400e6);
    }

    function test_finalizeBridgeDepositRequiresUnaccountedAssets() public {
        bytes32 intentId = keccak256("missing-usdc");

        vm.expectRevert(ArcMetaVault.InsufficientUnaccountedAssets.selector);
        vm.prank(agent);
        vault.finalizeBridgeDeposit(intentId, alice, 500e6);
    }

    function _depositAndActivate(address caller, address user, uint256 assets) internal {
        vm.prank(caller);
        vault.deposit(assets, user);

        _startNextEpoch();
        vault.activatePending(user, 2);
    }

    function _startNextEpoch() internal {
        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.prank(agent);
        vault.startNextEpoch();
    }

    function _approve(address user) internal {
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }
}
