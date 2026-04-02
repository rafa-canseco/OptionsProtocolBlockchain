// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/MarginPool.sol";
import "../src/core/AddressBook.sol";
import "../src/interfaces/IAaveV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Mock aToken that tracks deposits and simulates yield via `addYield`.
contract MockAToken is ERC20 {
    address public underlying;

    constructor(address _underlying) ERC20("aUSDC", "aUSDC") {
        underlying = _underlying;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @dev Mock Aave V3 Pool. Holds underlying, mints/burns aTokens.
contract MockAavePool is IAaveV3Pool {
    mapping(address => MockAToken) public aTokens;
    bool public shouldRevert;

    function setAToken(address asset, address aToken) external {
        aTokens[asset] = MockAToken(aToken);
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /* referralCode */
    )
        external
        override
    {
        require(!shouldRevert, "AavePool: reverted");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aTokens[asset].mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        require(!shouldRevert, "AavePool: reverted");
        aTokens[asset].burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    /// @dev Simulate yield accrual by minting extra aTokens + funding pool
    function simulateYield(address asset, address holder, uint256 yieldAmount) external {
        aTokens[asset].mint(holder, yieldAmount);
        // Fund the pool with underlying so withdraw works
        MockUSDC(asset).mint(address(this), yieldAmount);
    }
}

contract MarginPoolAaveTest is Test {
    AddressBook public addressBook;
    MarginPool public pool;
    MockUSDC public usdc;
    MockAToken public aUsdc;
    MockAavePool public aavePool;

    address public controller = makeAddr("controller");
    address public user = makeAddr("user");
    address public operator = makeAddr("operator");
    address public owner;

    function setUp() public {
        owner = address(this);

        // Deploy AddressBook
        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (owner))))
        );
        addressBook.setController(controller);

        // Deploy MarginPool behind proxy
        pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );

        // Deploy mocks
        usdc = new MockUSDC();
        aUsdc = new MockAToken(address(usdc));
        aavePool = new MockAavePool();
        aavePool.setAToken(address(usdc), address(aUsdc));

        // Fund user
        usdc.mint(user, 100_000e6);
        vm.prank(user);
        usdc.approve(address(pool), type(uint256).max);

        // Configure Aave on MarginPool (empty array — no prior pool)
        pool.setAavePool(address(aavePool));
        pool.setOperator(operator);
        pool.setYieldRecipient(operator);
        pool.setAToken(address(usdc), address(aUsdc));
        pool.setAaveEnabled(address(usdc), true);

        // Pool needs to approve Aave for supply
        pool.approveAave(address(usdc));
    }

    // ============================================================
    //                    BASIC AAVE ROUTING
    // ============================================================

    function test_transferToPool_depositsIntoAave() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // USDC should be in Aave pool, not in MarginPool
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(address(aavePool)), 1000e6);
        // MarginPool should hold aTokens
        assertEq(aUsdc.balanceOf(address(pool)), 1000e6);
    }

    function test_transferToUser_withdrawsFromAave() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 400e6);

        assertEq(usdc.balanceOf(user), 99_400e6);
        assertEq(aUsdc.balanceOf(address(pool)), 600e6);
    }

    // ============================================================
    //                  totalDeposited ACCOUNTING
    // ============================================================

    function test_totalDeposited_incrementsOnDeposit() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        assertEq(pool.totalDeposited(address(usdc)), 1000e6);
    }

    function test_totalDeposited_decrementsOnWithdraw() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 400e6);

        assertEq(pool.totalDeposited(address(usdc)), 600e6);
    }

    function test_totalDeposited_multipleDepositsAndWithdraws() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 2000e6);

        assertEq(pool.totalDeposited(address(usdc)), 3000e6);

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 1500e6);

        assertEq(pool.totalDeposited(address(usdc)), 1500e6);
    }

    // ============================================================
    //                  getStoredBalance SEMANTICS
    // ============================================================

    function test_getStoredBalance_returnsTotalDeposited() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // Simulate yield — aToken balance grows but getStoredBalance should NOT
        aavePool.simulateYield(address(usdc), address(pool), 50e6);

        // getStoredBalance returns liabilities (principal), not real balance
        assertEq(pool.getStoredBalance(address(usdc)), 1000e6);
    }

    // ============================================================
    //                    YIELD VIEW FUNCTIONS
    // ============================================================

    function test_getATokenBalance_includesYield() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        aavePool.simulateYield(address(usdc), address(pool), 50e6);

        assertEq(pool.getATokenBalance(address(usdc)), 1050e6);
    }

    function test_getAccruedYield_returnsYieldDelta() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        aavePool.simulateYield(address(usdc), address(pool), 50e6);

        assertEq(pool.getAccruedYield(address(usdc)), 50e6);
    }

    function test_getAccruedYield_zeroWhenNoYield() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        assertEq(pool.getAccruedYield(address(usdc)), 0);
    }

    // ============================================================
    //                      HARVEST YIELD
    // ============================================================

    function test_harvestYield_sendsToOperator() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        aavePool.simulateYield(address(usdc), address(pool), 50e6);

        pool.harvestYield(address(usdc));

        assertEq(usdc.balanceOf(operator), 50e6);
        assertEq(pool.getAccruedYield(address(usdc)), 0);
    }

    function test_harvestYield_doesNothingWhenNoYield() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        pool.harvestYield(address(usdc));

        assertEq(usdc.balanceOf(operator), 0);
    }

    function test_harvestYield_callableByOperator() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);
        aavePool.simulateYield(address(usdc), address(pool), 50e6);

        vm.prank(operator);
        pool.harvestYield(address(usdc));

        assertEq(usdc.balanceOf(operator), 50e6);
    }

    function test_harvestYield_callableByOwner() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);
        aavePool.simulateYield(address(usdc), address(pool), 50e6);

        pool.harvestYield(address(usdc));

        assertEq(usdc.balanceOf(operator), 50e6);
    }

    function test_harvestYield_rejectsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.harvestYield(address(usdc));
    }

    function test_harvestYield_doesNotAffectPrincipal() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        aavePool.simulateYield(address(usdc), address(pool), 50e6);

        pool.harvestYield(address(usdc));

        // Principal untouched
        assertEq(pool.totalDeposited(address(usdc)), 1000e6);
        assertEq(pool.getStoredBalance(address(usdc)), 1000e6);

        // User can still withdraw their full principal
        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 1000e6);
        assertEq(usdc.balanceOf(user), 100_000e6);
    }

    // ============================================================
    //                  isAaveEnabled CIRCUIT BREAKER
    // ============================================================

    function test_aaveDisabled_holdsDirectly() public {
        pool.setAaveEnabled(address(usdc), false);

        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // USDC stays in the pool, not Aave
        assertEq(usdc.balanceOf(address(pool)), 1000e6);
        assertEq(usdc.balanceOf(address(aavePool)), 0);
        assertEq(aUsdc.balanceOf(address(pool)), 0);
    }

    function test_aaveDisabled_transferToUserUsesDirectTransfer() public {
        pool.setAaveEnabled(address(usdc), false);

        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 500e6);

        assertEq(usdc.balanceOf(user), 99_500e6);
        assertEq(usdc.balanceOf(address(pool)), 500e6);
    }

    function test_aaveDisabled_getStoredBalance_usesRawBalance() public {
        pool.setAaveEnabled(address(usdc), false);

        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // totalDeposited=0 + balanceOf=1000 = 1000
        assertEq(pool.getStoredBalance(address(usdc)), 1000e6);
    }

    function test_setAaveEnabled_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.setAaveEnabled(address(usdc), false);
    }

    // ============================================================
    //               AAVE WITHDRAW REVERT → ATOKEN FALLBACK
    // ============================================================

    function test_transferToUser_fallbackToAToken_onAaveRevert() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // Aave goes down
        aavePool.setShouldRevert(true);

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 500e6);

        // User receives aTokens instead of USDC
        assertEq(aUsdc.balanceOf(user), 500e6);
        // totalDeposited still decremented
        assertEq(pool.totalDeposited(address(usdc)), 500e6);
    }

    // ============================================================
    //                    ADMIN FUNCTIONS
    // ============================================================

    function test_setYieldRecipient_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.setYieldRecipient(user);
    }

    function test_setYieldRecipient_updatesRecipient() public {
        address newOp = makeAddr("newOperator");
        pool.setYieldRecipient(newOp);
        assertEq(pool.yieldRecipient(), newOp);
    }

    function test_setAavePool_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.setAavePool(address(0x1));
    }

    function test_setAavePool_revertsIfNotDrained() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                MarginPool.AaveNotDrained.selector,
                address(usdc),
                1000e6
            )
        );
        pool.setAavePool(address(0x1));
    }

    function test_setAaveEnabled_revertsIfPoolNotSet() public {
        // Deploy fresh pool (no aavePool configured)
        MarginPool freshPool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()),
                    abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );
        vm.expectRevert(MarginPool.AaveNotConfigured.selector);
        freshPool.setAaveEnabled(address(usdc), true);
    }

    function test_setAToken_revertsOnZeroAddress() public {
        vm.expectRevert(MarginPool.InvalidAddress.selector);
        pool.setAToken(address(usdc), address(0));

        vm.expectRevert(MarginPool.InvalidAddress.selector);
        pool.setAToken(address(0), address(aUsdc));
    }

    function test_approveAave_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.approveAave(address(usdc));
    }

    // ============================================================
    //              ACCOUNTING INVARIANT (FUZZ)
    // ============================================================

    function testFuzz_accountingInvariant(uint256 deposit1, uint256 deposit2, uint256 withdrawAmt, uint256 yieldAmt)
        public
    {
        deposit1 = bound(deposit1, 1e6, 50_000e6);
        deposit2 = bound(deposit2, 1e6, 50_000e6);
        uint256 totalDep = deposit1 + deposit2;
        withdrawAmt = bound(withdrawAmt, 0, totalDep);
        yieldAmt = bound(yieldAmt, 0, 1000e6);

        // Fund extra
        usdc.mint(user, deposit1 + deposit2);
        vm.prank(user);
        usdc.approve(address(pool), type(uint256).max);

        vm.prank(controller);
        pool.transferToPool(address(usdc), user, deposit1);

        vm.prank(controller);
        pool.transferToPool(address(usdc), user, deposit2);

        aavePool.simulateYield(address(usdc), address(pool), yieldAmt);

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, withdrawAmt);

        // Invariant: totalDeposited tracks exact principal
        assertEq(pool.totalDeposited(address(usdc)), totalDep - withdrawAmt);

        // Invariant: aToken balance >= totalDeposited
        assertGe(aUsdc.balanceOf(address(pool)), pool.totalDeposited(address(usdc)));
    }

    // ============================================================
    //               FIX #1: revokeAave
    // ============================================================

    function test_revokeAave_zerosAllowance() public {
        uint256 allowance = usdc.allowance(address(pool), address(aavePool));
        assertEq(allowance, type(uint256).max);

        pool.revokeAave(address(usdc));

        allowance = usdc.allowance(address(pool), address(aavePool));
        assertEq(allowance, 0);
    }

    function test_revokeAave_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.revokeAave(address(usdc));
    }

    // ============================================================
    //       FIX #2: harvestYield reverts on zero yieldRecipient
    // ============================================================

    function test_harvestYield_revertsIfYieldRecipientNotSet() public {
        pool.setYieldRecipient(address(0x1)); // set to valid first
        // Deploy fresh pool without yieldRecipient set
        MarginPool freshPool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()),
                    abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );
        // yieldRecipient is address(0) by default
        vm.expectRevert(MarginPool.InvalidAddress.selector);
        freshPool.harvestYield(address(usdc));
    }

    // ============================================================
    //  MIXED STATE: pre-Aave positions coexist with Aave
    // ============================================================

    function test_enableAave_withExistingDirectBalance() public {
        // Pre-Aave: positions deposited directly
        pool.setAaveEnabled(address(usdc), false);
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 50_000e6);
        assertEq(usdc.balanceOf(address(pool)), 50_000e6);

        // Enable Aave while direct balance exists
        pool.setAaveEnabled(address(usdc), true);

        // New deposit goes to Aave
        address bob = makeAddr("bob");
        usdc.mint(bob, 10_000e6);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(controller);
        pool.transferToPool(address(usdc), bob, 10_000e6);

        // State: 50k direct + 10k Aave
        assertEq(pool.totalDeposited(address(usdc)), 10_000e6);
        assertEq(usdc.balanceOf(address(pool)), 50_000e6);
        assertEq(pool.getStoredBalance(address(usdc)), 60_000e6);

        // Old position settles 20k → 10k from Aave + 10k direct
        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 20_000e6);

        assertEq(pool.totalDeposited(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(pool)), 40_000e6);
        assertEq(usdc.balanceOf(user), 70_000e6);

        // Remaining old positions settle 40k → all direct
        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 40_000e6);

        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(user), 100_000e6 + 10_000e6);

        // Bob settles — nothing left in Aave or direct, but bob's 10k
        // was already pulled from Aave in the first withdrawal above.
        // Bob's USDC came from Aave withdraw. All accounted for.
    }

    function test_mixedState_splitWithdrawal() public {
        // Deposit 1000 via Aave
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // Disable Aave, deposit 500 directly
        pool.setAaveEnabled(address(usdc), false);
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 500e6);

        // getStoredBalance = 1000 (Aave) + 500 (direct) = 1500
        assertEq(pool.getStoredBalance(address(usdc)), 1500e6);

        // Withdraw 1200 → 1000 from Aave + 200 from direct
        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 1200e6);

        assertEq(pool.totalDeposited(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(pool)), 300e6);
        assertEq(usdc.balanceOf(user), 99_700e6);
    }

    function test_circuitBreaker_disableWithDeposits() public {
        // Alice deposits via Aave
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 5000e6);

        // Admin disables Aave (crisis)
        pool.setAaveEnabled(address(usdc), false);

        // New deposits go direct
        address bob = makeAddr("bob");
        usdc.mint(bob, 50_000e6);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(controller);
        pool.transferToPool(address(usdc), bob, 3000e6);

        // getStoredBalance returns both sources
        assertEq(pool.getStoredBalance(address(usdc)), 8000e6);

        // Old Aave deposits still withdraw from Aave
        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 5000e6);
        assertEq(usdc.balanceOf(user), 100_000e6);
        assertEq(pool.totalDeposited(address(usdc)), 0);

        // Bob's direct deposit withdraws directly
        vm.prank(controller);
        pool.transferToUser(address(usdc), bob, 3000e6);
        assertEq(usdc.balanceOf(bob), 50_000e6);
    }

    // ============================================================
    //  NEM-3: ATokenFallback event on partial transfer
    // ============================================================

    function test_aTokenFallback_emitsOnPartialTransfer() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // Burn some aTokens to simulate Aave loss (aBalance < amount)
        aUsdc.burn(address(pool), 200e6);

        // Make Aave withdraw revert to trigger fallback
        aavePool.setShouldRevert(true);

        // Withdraw 1000 but only 800 aTokens available
        vm.expectEmit(true, true, false, true);
        emit MarginPool.ATokenFallback(
            address(usdc), user, 1000e6, 800e6
        );

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 1000e6);

        // User got 800 aTokens (not 1000)
        assertEq(aUsdc.balanceOf(user), 800e6);

        // FIX #1: totalDeposited restored by shortfall (200e6)
        assertEq(pool.totalDeposited(address(usdc)), 200e6);
    }

    function test_aTokenFallback_noEventOnFullTransfer() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        aavePool.setShouldRevert(true);

        // Full aToken balance available → no event
        vm.recordLogs();
        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 500e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != keccak256(
                    "ATokenFallback(address,address,uint256,uint256)"
                ),
                "Should not emit ATokenFallback"
            );
        }
    }

    // ============================================================
    //  NEM-4: NoYieldToHarvest error removed (compile-time check)
    // ============================================================
    // The dead error was removed from the contract. If it still
    // existed, adding a reference here would compile. Its absence
    // is verified by the build succeeding without it.

    // ============================================================
    //  PAV-1: Fallback accounting fix — totalDeposited restored
    // ============================================================

    function test_fallbackAccounting_restoresTotalDeposited() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // Simulate Aave loss: burn 600 aTokens so only 400 remain
        aUsdc.burn(address(pool), 600e6);
        aavePool.setShouldRevert(true);

        vm.prank(controller);
        pool.transferToUser(address(usdc), user, 1000e6);

        // User got 400 aTokens (all that was available)
        assertEq(aUsdc.balanceOf(user), 400e6);
        // Shortfall of 600 restored to totalDeposited
        assertEq(pool.totalDeposited(address(usdc)), 600e6);
    }

    // ============================================================
    //  PAV-3: setAavePool checks all tracked assets automatically
    // ============================================================

    function test_setAavePool_checksAllTrackedAssets() public {
        // Deposit into Aave
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 1000e6);

        // Try to swap pool — should revert (USDC auto-tracked)
        vm.expectRevert(
            abi.encodeWithSelector(
                MarginPool.AaveNotDrained.selector,
                address(usdc),
                1000e6
            )
        );
        pool.setAavePool(address(0x1));
    }

    // ============================================================
    //  PAV-6: drainAave withdraws all from Aave to pool
    // ============================================================

    function test_drainAave_withdrawsAll() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 5000e6);

        assertEq(pool.totalDeposited(address(usdc)), 5000e6);
        assertEq(usdc.balanceOf(address(pool)), 0);

        pool.drainAave(address(usdc));

        assertEq(pool.totalDeposited(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(pool)), 5000e6);
    }

    function test_drainAave_thenMigrate() public {
        vm.prank(controller);
        pool.transferToPool(address(usdc), user, 5000e6);

        // Drain first
        pool.drainAave(address(usdc));
        assertEq(pool.totalDeposited(address(usdc)), 0);

        // Now migration succeeds
        pool.setAavePool(address(0x1));
    }

    function test_drainAave_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.drainAave(address(usdc));
    }

    function test_drainAave_noop_whenZero() public {
        pool.drainAave(address(usdc));
        assertEq(pool.totalDeposited(address(usdc)), 0);
    }
}
