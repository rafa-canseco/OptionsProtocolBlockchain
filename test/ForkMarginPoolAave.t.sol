// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/core/AddressBook.sol";
import "../src/core/MarginPool.sol";
import "../src/interfaces/IAaveV3Pool.sol";

/// @notice Minimal interface to query Aave reserve data for aToken address
interface IAavePoolFull {
    struct ReserveData {
        //stores the reserve configuration
        uint256 configuration;
        //the liquidity index. Expressed in ray
        uint128 liquidityIndex;
        //the current supply rate. Expressed in ray
        uint128 currentLiquidityRate;
        //variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        //the current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        // DEPRECATED in v3.1
        uint128 currentStableBorrowRate;
        //timestamp of last update
        uint40 lastUpdateTimestamp;
        //the id of the reserve
        uint16 id;
        //aToken address
        address aTokenAddress;
        // DEPRECATED in v3.1
        address stableDebtTokenAddress;
        //variableDebtToken address
        address variableDebtTokenAddress;
        //address of the interest rate strategy
        address interestRateStrategyAddress;
        //the current treasury balance, scaled
        uint128 accruedToTreasury;
        //the outstanding unbacked aTokens minted through the bridging feature
        uint128 unbacked;
        //the outstanding debt borrowed against this asset in isolation mode
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
}

/**
 * @title ForkMarginPoolAave
 * @notice Fork tests for MarginPool Aave V3 integration on Base mainnet.
 *         Tests deposit → yield accrual → settlement → harvest with real Aave.
 *         Pinned to a known-good block where Aave V3 rate model is stable.
 *
 *         Run:
 *         forge test --match-contract ForkMarginPoolAave \
 *           --fork-url $BASE_RPC_URL --fork-block-number 25000000 -vvv
 */
contract ForkMarginPoolAave is Test {
    // --- Base mainnet addresses ---
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    // Pin to block 25_000_000 (~Feb 2025). Aave V3 rate model overflows
    // at certain recent blocks due to extreme reserve parameters.
    uint256 constant FORK_BLOCK = 25_000_000;

    // --- Protocol ---
    AddressBook addressBook;
    MarginPool pool;

    // --- Actors ---
    address deployer = makeAddr("deployer");
    address controller = makeAddr("controller");
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    // --- Aave ---
    address aUsdc;

    function setUp() public {
        // Skip if no fork is active (run with --fork-url to enable)
        try vm.activeFork() {}
        catch {
            vm.skip(true);
        }

        // Pin to known-good block for Aave V3 stability
        vm.rollFork(FORK_BLOCK);

        // Get aUSDC address from Aave
        IAavePoolFull aavePoolFull = IAavePoolFull(AAVE_V3_POOL);
        aUsdc = aavePoolFull.getReserveData(USDC).aTokenAddress;
        require(aUsdc != address(0), "aUSDC not found on Aave");

        vm.startPrank(deployer);

        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (deployer))))
        );
        addressBook.setController(controller);

        pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );

        // Configure Aave (empty array — no prior pool)
        pool.setAavePool(AAVE_V3_POOL);
        pool.setYieldRecipient(operator);
        pool.setAToken(USDC, aUsdc);
        pool.setAaveEnabled(USDC, true);
        pool.approveAave(USDC);

        vm.stopPrank();

        // Fund alice with USDC (deal works on Base fork)
        deal(USDC, alice, 100_000e6);
        vm.prank(alice);
        IERC20(USDC).approve(address(pool), type(uint256).max);
    }

    function test_depositIntoRealAave() public {
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 10_000e6);

        // USDC left the pool (sent to Aave)
        assertEq(IERC20(USDC).balanceOf(address(pool)), 0);
        // Pool holds aUSDC
        assertGe(IERC20(aUsdc).balanceOf(address(pool)), 10_000e6 - 1);
        // totalDeposited tracks principal
        assertEq(pool.totalDeposited(USDC), 10_000e6);
        // getStoredBalance returns liabilities
        assertEq(pool.getStoredBalance(USDC), 10_000e6);
    }

    function test_withdrawFromRealAave() public {
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 10_000e6);

        vm.prank(controller);
        pool.transferToUser(USDC, alice, 4_000e6);

        assertEq(IERC20(USDC).balanceOf(alice), 94_000e6);
        assertEq(pool.totalDeposited(USDC), 6_000e6);
    }

    function test_yieldAccruesOverTime() public {
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 10_000e6);

        uint256 aBalanceBefore = IERC20(aUsdc).balanceOf(address(pool));

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);
        // Roll forward blocks (~2s per block on Base)
        vm.roll(block.number + (30 days / 2));

        uint256 aBalanceAfter = IERC20(aUsdc).balanceOf(address(pool));

        // aToken balance should have grown (yield accrued)
        assertGt(aBalanceAfter, aBalanceBefore, "Yield should accrue over 30 days");

        // getAccruedYield should reflect the delta
        uint256 yield_ = pool.getAccruedYield(USDC);
        assertGt(yield_, 0, "getAccruedYield should be > 0 after 30 days");

        // totalDeposited unchanged
        assertEq(pool.totalDeposited(USDC), 10_000e6);
    }

    function test_harvestYieldFromRealAave() public {
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 10_000e6);

        // Warp 30 days for yield
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 2));

        uint256 yieldBefore = pool.getAccruedYield(USDC);
        assertGt(yieldBefore, 0, "Should have yield to harvest");

        // Harvest
        vm.prank(deployer);
        pool.harvestYield(USDC);

        // Operator received USDC
        assertGe(IERC20(USDC).balanceOf(operator), yieldBefore - 1);
        // Yield cleared (within dust)
        assertLe(pool.getAccruedYield(USDC), 1);
        // Principal untouched
        assertEq(pool.totalDeposited(USDC), 10_000e6);
    }

    function test_fullLifecycle_depositYieldSettleHarvest() public {
        // 1. Deposit
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 10_000e6);

        // 2. Time passes (yield accrues)
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 2));

        uint256 yieldMidway = pool.getAccruedYield(USDC);
        assertGt(yieldMidway, 0, "Yield should accrue");

        // 3. Settlement: return principal to user
        vm.prank(controller);
        pool.transferToUser(USDC, alice, 10_000e6);

        assertEq(IERC20(USDC).balanceOf(alice), 100_000e6);
        assertEq(pool.totalDeposited(USDC), 0);

        // 4. Harvest remaining yield to operator
        uint256 remainingYield = pool.getAccruedYield(USDC);
        assertGt(remainingYield, 0, "Yield should remain after principal withdrawal");

        vm.prank(deployer);
        pool.harvestYield(USDC);

        assertGe(IERC20(USDC).balanceOf(operator), remainingYield - 1);
        assertLe(pool.getAccruedYield(USDC), 1);
    }

    function test_circuitBreaker_newDepositsSkipAave() public {
        // Disable Aave
        vm.prank(deployer);
        pool.setAaveEnabled(USDC, false);

        // Deposit goes directly to pool (no Aave)
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 5_000e6);

        assertEq(IERC20(USDC).balanceOf(address(pool)), 5_000e6);
        assertEq(IERC20(aUsdc).balanceOf(address(pool)), 0);

        // Withdraw uses direct transfer
        vm.prank(controller);
        pool.transferToUser(USDC, alice, 5_000e6);
        assertEq(IERC20(USDC).balanceOf(alice), 100_000e6);
    }

    function test_fallback_sendsATokens_whenWithdrawReverts() public {
        // Deposit into real Aave
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 5_000e6);

        uint256 aBalBefore = IERC20(aUsdc).balanceOf(alice);
        assertEq(aBalBefore, 0);

        // Mock Aave withdraw to revert (simulates liquidity crunch)
        vm.mockCallRevert(AAVE_V3_POOL, abi.encodeWithSelector(IAaveV3Pool.withdraw.selector), "INSUFFICIENT_LIQUIDITY");

        // Withdraw triggers fallback → user gets aTokens
        vm.prank(controller);
        pool.transferToUser(USDC, alice, 5_000e6);

        // User received aTokens (not USDC)
        assertEq(IERC20(USDC).balanceOf(alice), 95_000e6, "No USDC received");
        assertGt(IERC20(aUsdc).balanceOf(alice), 0, "Should have aTokens");

        // totalDeposited correctly decremented
        assertEq(pool.totalDeposited(USDC), 0);

        // Clear mock so alice can redeem aTokens
        vm.clearMockedCalls();

        // Alice redeems aTokens via Aave directly
        uint256 aTokenBal = IERC20(aUsdc).balanceOf(alice);
        vm.startPrank(alice);
        IAaveV3Pool(AAVE_V3_POOL).withdraw(USDC, aTokenBal, alice);
        vm.stopPrank();

        // Alice got her USDC back (minus any dust)
        assertGe(IERC20(USDC).balanceOf(alice), 99_999e6);
    }

    function test_multipleUsersYieldAccounting() public {
        address bob = makeAddr("bob");
        deal(USDC, bob, 50_000e6);
        vm.prank(bob);
        IERC20(USDC).approve(address(pool), type(uint256).max);

        // Alice deposits 10k
        vm.prank(controller);
        pool.transferToPool(USDC, alice, 10_000e6);

        // Bob deposits 20k
        vm.prank(controller);
        pool.transferToPool(USDC, bob, 20_000e6);

        assertEq(pool.totalDeposited(USDC), 30_000e6);

        // Time passes
        vm.warp(block.timestamp + 14 days);
        vm.roll(block.number + (14 days / 2));

        // Both settle
        vm.prank(controller);
        pool.transferToUser(USDC, alice, 10_000e6);
        vm.prank(controller);
        pool.transferToUser(USDC, bob, 20_000e6);

        assertEq(pool.totalDeposited(USDC), 0);
        assertEq(IERC20(USDC).balanceOf(alice), 100_000e6);
        assertEq(IERC20(USDC).balanceOf(bob), 50_000e6);

        // Yield remains in pool as aTokens
        uint256 yield_ = pool.getAccruedYield(USDC);
        assertGt(yield_, 0, "Combined yield should remain");
    }
}
