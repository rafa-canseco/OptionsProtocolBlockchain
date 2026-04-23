// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/OToken.sol";
import "../src/interfaces/IAaveV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ForkSmokeAaveEnable
 * @notice End-to-end smoke test that verifies:
 *         1. Old positions (pre-Aave) settle correctly
 *         2. Aave enable works for USDC, WETH, cbBTC
 *         3. New positions route through Aave
 *         4. Mixed settlement (old direct + new Aave) in one batch
 *
 *         Run:
 *         forge test --match-contract ForkSmokeAaveEnable \
 *           --fork-url $BASE_RPC_URL -vvv
 */
contract ForkSmokeAaveEnable is Test {
    Controller controller = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    MarginPool pool = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);
    OTokenFactory factory = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Oracle oracle = Oracle(0x09daa0194A3AF59b46C5443aF9C20fAd98347671);
    Whitelist whitelist = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    BatchSettler settler = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant A_WETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address constant A_CBBTC = 0xBdb9300b7CDE636d9cD4AFF00f6F009fFBBc8EE6;

    address owner;
    address factoryOperator;
    address operatorAddr;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 mmKey = 0xCC01;
    address mm;
    uint256 expiry;

    function setUp() public {
        if (block.chainid != 8453) {
            emit log("SKIPPED: requires --fork-url (Base 8453)");
            return;
        }

        owner = controller.owner();
        factoryOperator = factory.operator();
        operatorAddr = settler.operator();
        mm = vm.addr(mmKey);

        vm.startPrank(owner);
        oracle.setMaxOracleStaleness(0);
        oracle.setPriceDeviationThreshold(0);
        settler.setWhitelistedMM(mm, true);
        vm.stopPrank();

        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        // Fund Alice (old positions, before Aave)
        deal(USDC, alice, 10_000_000e6);
        deal(WETH, alice, 100e18);
        deal(CBBTC, alice, 10e8);

        // Fund Bob (new positions, after Aave)
        deal(USDC, bob, 10_000_000e6);
        deal(WETH, bob, 100e18);
        deal(CBBTC, bob, 10e8);

        // Fund MM
        deal(USDC, mm, 10_000_000e6);
        deal(WETH, mm, 100e18);
        deal(CBBTC, mm, 10e8);

        // Approvals
        _approveAll(alice);
        _approveAll(bob);

        vm.startPrank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        IERC20(WETH).approve(address(settler), type(uint256).max);
        IERC20(CBBTC).approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Full mixed-mode test: old positions (direct) + new positions
    ///         (Aave-routed) settle together in one batch.
    function test_mixedSettlement_oldDirectAndNewAave() public {
        if (block.chainid != 8453) return;

        // ============ PHASE 1: Old positions (Aave disabled) ============

        // Alice opens ETH PUT (USDC collateral, direct in pool)
        uint256 strikeOld = 5678e8;
        address oTokenOld = _createOToken(WETH, USDC, USDC, strikeOld, true);
        _executeOrder(oTokenOld, alice, 1e8, 5678e6, true);

        // Verify: USDC went directly to pool, not Aave
        assertEq(pool.totalDeposited(USDC), 0, "Phase 1: totalDeposited should be 0");

        // ============ PHASE 2: Enable Aave for all 3 assets ============

        vm.startPrank(owner);
        pool.setAaveEnabled(USDC, true);
        pool.setAaveEnabled(WETH, true);
        pool.setAaveEnabled(CBBTC, true);
        vm.stopPrank();

        assertTrue(pool.isAaveEnabled(USDC), "USDC not enabled");
        assertTrue(pool.isAaveEnabled(WETH), "WETH not enabled");
        assertTrue(pool.isAaveEnabled(CBBTC), "cbBTC not enabled");

        // ============ PHASE 3: New positions (Aave routed) ============

        // Bob opens ETH PUT (USDC collateral → Aave)
        uint256 strikeNew = 6789e8;
        address oTokenNew = _createOToken(WETH, USDC, USDC, strikeNew, true);
        _executeOrder(oTokenNew, bob, 1e8, 6789e6, true);

        // Verify: Bob's USDC routed to Aave
        assertEq(pool.totalDeposited(USDC), 6789e6, "Phase 3: totalDeposited should be Bob's deposit");
        assertGe(IERC20(A_USDC).balanceOf(address(pool)), 6789e6 - 1, "aUSDC not in pool");

        // ============ PHASE 4: Settle BOTH in one batch ============

        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 8000e8); // OTM for both puts

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);

        // Batch settle both vaults at once
        address[] memory owners = new address[](2);
        uint256[] memory ids = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        ids[0] = 1;
        ids[1] = 1;
        vm.prank(operatorAddr);
        settler.batchSettleVaults(owners, ids);

        // Alice gets her collateral back (was in pool directly)
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, 5678e6, "Alice collateral not returned");
        // Bob gets his collateral back (was in Aave)
        assertEq(IERC20(USDC).balanceOf(bob) - bobUsdcBefore, 6789e6, "Bob collateral not returned from Aave");
        // Aave tracking cleared
        assertEq(pool.totalDeposited(USDC), 0, "totalDeposited not cleared after settle");
    }

    /// @notice WETH call with Aave routing
    function test_wethCallWithAave() public {
        if (block.chainid != 8453) return;

        // Enable Aave for WETH
        vm.prank(owner);
        pool.setAaveEnabled(WETH, true);

        // Bob opens ETH CALL (WETH collateral → Aave)
        uint256 strike = 12345e8;
        address oToken = _createOToken(WETH, USDC, WETH, strike, false);
        _executeOrder(oToken, bob, 1e8, 1e18, false);

        // Verify routing
        assertEq(pool.totalDeposited(WETH), 1e18, "WETH totalDeposited");
        assertGe(IERC20(A_WETH).balanceOf(address(pool)), 1e18 - 1, "aWETH not in pool");

        // Settle OTM
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 10000e8);

        uint256 wethBefore = IERC20(WETH).balanceOf(bob);
        _settleVault(bob, 1);
        assertEq(IERC20(WETH).balanceOf(bob) - wethBefore, 1e18, "WETH not returned from Aave");
        assertEq(pool.totalDeposited(WETH), 0, "WETH totalDeposited not cleared");
    }

    /// @notice cbBTC put with Aave routing
    function test_cbbtcPutWithAave() public {
        if (block.chainid != 8453) return;

        // Enable Aave for USDC (cbBTC put uses USDC collateral)
        vm.prank(owner);
        pool.setAaveEnabled(USDC, true);

        uint256 strike = 87654e8;
        address oToken = _createOToken(CBBTC, USDC, USDC, strike, true);
        _executeOrder(oToken, bob, 1e8, 87654e6, true);

        assertEq(pool.totalDeposited(USDC), 87654e6, "USDC totalDeposited for cbBTC put");
        assertGe(IERC20(A_USDC).balanceOf(address(pool)), 87654e6 - 1, "aUSDC not in pool");

        // Settle OTM
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(CBBTC, expiry, 95000e8);

        uint256 usdcBefore = IERC20(USDC).balanceOf(bob);
        _settleVault(bob, 1);
        assertEq(IERC20(USDC).balanceOf(bob) - usdcBefore, 87654e6, "USDC not returned from Aave for cbBTC put");
        assertEq(pool.totalDeposited(USDC), 0, "totalDeposited not cleared");
    }

    /// @notice cbBTC call with Aave routing (cbBTC collateral)
    function test_cbbtcCallWithAave() public {
        if (block.chainid != 8453) return;

        vm.prank(owner);
        pool.setAaveEnabled(CBBTC, true);

        uint256 strike = 99999e8;
        address oToken = _createOToken(CBBTC, USDC, CBBTC, strike, false);
        _executeOrder(oToken, bob, 1e8, 1e8, false);

        assertEq(pool.totalDeposited(CBBTC), 1e8, "cbBTC totalDeposited");
        assertGe(IERC20(A_CBBTC).balanceOf(address(pool)), 1e8 - 1, "aCBBTC not in pool");

        // Settle OTM
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(CBBTC, expiry, 90000e8);

        uint256 btcBefore = IERC20(CBBTC).balanceOf(bob);
        _settleVault(bob, 1);
        assertEq(IERC20(CBBTC).balanceOf(bob) - btcBefore, 1e8, "cbBTC not returned from Aave");
        assertEq(pool.totalDeposited(CBBTC), 0, "cbBTC totalDeposited not cleared");
    }

    // ===== Helpers =====

    function _approveAll(address user) internal {
        vm.startPrank(user);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        IERC20(CBBTC).approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _createOToken(address underlying, address strike, address collateral, uint256 strikePrice, bool isPut)
        internal
        returns (address)
    {
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(underlying, strike, collateral, strikePrice, expiry, isPut);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _executeOrder(address oToken, address buyer, uint256 amount, uint256 collateral, bool isPut) internal {
        vm.prank(buyer);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: isPut ? 50e6 : 30e6,
            deadline: block.timestamp + 1 hours,
            quoteId: 1,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });

        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(buyer);
        settler.executeOrder(quote, sig, amount, collateral);
    }

    function _settleVault(address vaultOwner, uint256 vaultId) internal {
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = vaultOwner;
        ids[0] = vaultId;
        vm.prank(operatorAddr);
        settler.batchSettleVaults(owners, ids);
    }
}
