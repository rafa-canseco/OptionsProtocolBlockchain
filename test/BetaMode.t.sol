// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/core/AddressBook.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OToken.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/PriceSheet.sol";
import "../src/core/Whitelist.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockChainlinkFeed.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockSwapRouter.sol";

contract BetaModeTest is Test {
    event BetaModeSet(bool enabled);
    event PhysicalDelivery(
        address indexed oToken,
        address indexed user,
        uint256 contraAmount,
        uint256 collateralUsed
    );

    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;
    PriceSheet public priceSheet;

    MockERC20 public weth;
    MockERC20 public usdc;
    MockChainlinkFeed public ethFeed;
    MockAavePool public mockAave;
    MockSwapRouter public mockRouter;

    address public mm = address(0xAA00);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B0);

    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        // Deploy tokens
        weth = new MockERC20("Loot ETH", "LETH", 18);
        usdc = new MockERC20("Loot USD", "LUSD", 6);

        // Deploy Chainlink feed ($2500)
        ethFeed = new MockChainlinkFeed(2500e8);

        // Deploy mocks (using src/mocks/ contracts that mint from nothing)
        mockAave = new MockAavePool();
        mockRouter = new MockSwapRouter(address(ethFeed), address(weth), address(usdc));

        // Deploy protocol
        addressBook = new AddressBook();
        controller = new Controller(address(addressBook));
        pool = new MarginPool(address(addressBook));
        factory = new OTokenFactory(address(addressBook));
        oracle = new Oracle(address(addressBook));
        whitelist = new Whitelist(address(addressBook));
        settler = new BatchSettler(address(addressBook), mm);
        priceSheet = new PriceSheet(address(addressBook), mm);

        // Wire AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
        addressBook.setPriceSheet(address(priceSheet));

        // Configure physical delivery
        settler.setAavePool(address(mockAave));
        settler.setSwapRouter(address(mockRouter));
        settler.setSwapFeeTier(500);

        // Whitelist
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        // Set Chainlink feed on Oracle
        oracle.setPriceFeed(address(weth), address(ethFeed));

        // Expiry: next 08:00 UTC (will be in the future)
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        // Fund MM
        usdc.mint(mm, 1_000_000e6);
        weth.mint(mm, 1_000e18);
        vm.startPrank(mm);
        usdc.approve(address(settler), type(uint256).max);
        weth.approve(address(settler), type(uint256).max);
        vm.stopPrank();

        // Fund users
        _fundUser(alice, 50_000e6, 50e18);
        _fundUser(bob, 50_000e6, 50e18);
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
        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strike, expiry, true
        );
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _createCall(uint256 strike) internal returns (address) {
        address oToken = factory.createOToken(
            address(weth), address(usdc), address(weth), strike, expiry, false
        );
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _setupPutPosition(address user, address oToken, uint256 amount) internal {
        uint256 collateral = (amount * strikePrice) / 1e10;

        vm.prank(user);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 70e6, 72e6, block.timestamp + 1 hours, 1000e8);

        vm.prank(user);
        settler.executeOrder(oToken, amount, collateral);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);
    }

    function _setupCallPosition(address user, address oToken, uint256 amount) internal {
        uint256 collateral = amount * 1e10;

        vm.prank(user);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 50e6, 52e6, block.timestamp + 1 hours, 1000e8);

        vm.prank(user);
        settler.executeOrder(oToken, amount, collateral);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);
    }

    function _settleVault(address user, uint256 vaultId) internal {
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = user;
        vaultIds[0] = vaultId;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);
    }

    // ===== setBetaMode access control =====

    function test_setBetaMode_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.setBetaMode(true);
    }

    function test_setBetaMode_ownerCanEnable() public {
        controller.setBetaMode(true);
        assertTrue(controller.betaMode());
    }

    function test_setBetaMode_ownerCanDisable() public {
        controller.setBetaMode(true);
        controller.setBetaMode(false);
        assertFalse(controller.betaMode());
    }

    function test_setBetaMode_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BetaModeSet(true);
        controller.setBetaMode(true);

        vm.expectEmit(false, false, false, true);
        emit BetaModeSet(false);
        controller.setBetaMode(false);
    }

    function test_betaMode_defaultsToFalse() public view {
        assertFalse(controller.betaMode());
    }

    function test_setBetaMode_operatorCannotSet() public {
        vm.prank(mm);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.setBetaMode(true);
    }

    // ===== settleVault: betaMode off (existing behavior) =====

    function test_settleVault_revertsBeforeExpiry_betaModeOff() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Set price but don't warp past expiry
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;

        // settleVault is called via batchSettleVaults which catches errors
        // So call Controller directly to test the revert
        vm.prank(address(settler));
        vm.expectRevert(Controller.OptionNotExpired.selector);
        controller.settleVault(alice, 1);
    }

    // ===== settleVault: betaMode on =====

    function test_settleVault_succeedsBeforeExpiry_betaModeOn() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Enable betaMode
        controller.setBetaMode(true);

        // Set price but DON'T warp past expiry — we're before expiry
        oracle.setExpiryPrice(address(weth), expiry, 2100e8); // OTM

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Should succeed even though block.timestamp < expiry
        _settleVault(alice, 1);

        // OTM: full collateral returned
        uint256 collateral = (1e8 * strikePrice) / 1e10; // 2000e6
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + collateral);
    }

    // ===== redeem: betaMode off (existing behavior) =====

    function test_redeem_revertsBeforeExpiry_betaModeOff() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // mm has oTokens, tries to redeem before expiry
        vm.prank(mm);
        vm.expectRevert(Controller.OptionNotExpired.selector);
        controller.redeem(oToken, 1e8);
    }

    // ===== redeem: betaMode on =====

    function test_redeem_succeedsBeforeExpiry_betaModeOn() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8); // ITM

        uint256 mmOTokenBefore = OToken(oToken).balanceOf(mm);
        uint256 mmUsdcBefore = usdc.balanceOf(mm);

        // mm redeems oTokens before expiry — should succeed with betaMode
        vm.prank(mm);
        controller.redeem(oToken, mmOTokenBefore);

        assertEq(OToken(oToken).balanceOf(mm), 0);
        // ITM put: full collateral payout = (amount * strike) / 1e10 = (1e8 * 2000e8) / 1e10 = 2000e6
        assertEq(usdc.balanceOf(mm), mmUsdcBefore + 2000e6);
    }

    // ===== physicalRedeem: betaMode off (existing behavior) =====

    function test_physicalRedeem_revertsBeforeExpiry_betaModeOff() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Don't warp past expiry
        vm.prank(mm);
        vm.expectRevert(BatchSettler.OptionNotExpired.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
    }

    // ===== physicalRedeem: betaMode on =====

    function test_physicalRedeem_putITM_beforeExpiry_betaModeOn() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Enable betaMode — NO vm.warp, we stay before expiry
        controller.setBetaMode(true);

        // Set expiry price ITM (ETH < strike)
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        // Set chainlink feed to match for swap router
        ethFeed.setPrice(1800e8);

        // Settle vault before expiry (betaMode allows it)
        _settleVault(alice, 1);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Physical delivery before expiry — should work with betaMode
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        // Alice received 1 WETH (contra-asset for ITM put)
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);
        // oTokens burned
        assertEq(OToken(oToken).balanceOf(mm), 0);
    }

    function test_physicalRedeem_callITM_beforeExpiry_betaModeOn() public {
        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);

        // Set expiry price ITM (ETH > strike for call)
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);
        ethFeed.setPrice(2500e8);

        // Settle vault before expiry
        _settleVault(alice, 1);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Physical delivery before expiry
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 1e18);

        // Alice received strike amount in USDC
        // For call: contraAmount = (amount * strike) / 1e10 = (1e8 * 2000e8) / 1e10 = 2000e6
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 2000e6);
    }

    // ===== Full E2E flow: executeOrder → betaMode → settle → physicalRedeem =====

    function test_e2e_fullBetaFlow_putITM() public {
        // 1. Create option
        address oToken = _createPut(strikePrice);

        // 2. User executes order (before expiry — this is normal)
        _setupPutPosition(alice, oToken, 1e8);

        // Verify: we are still before expiry
        assertLt(block.timestamp, OToken(oToken).expiry());

        // 3. Enable betaMode
        controller.setBetaMode(true);

        // 4. Set expiry price (simulating oracle update)
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        ethFeed.setPrice(1800e8);

        // 5. Settle vault — before expiry, betaMode allows it
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        _settleVault(alice, 1);

        // ITM put: alice gets 0 collateral back (retained for physical delivery)
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore);

        // 6. Physical delivery — before expiry, betaMode allows it
        uint256 aliceWethBefore = weth.balanceOf(alice);
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        // Alice received 1 WETH
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);

        // 7. Verify we're STILL before expiry (confirming betaMode did the bypass)
        assertLt(block.timestamp, OToken(oToken).expiry());
    }

    function test_e2e_fullBetaFlow_putOTM() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        assertLt(block.timestamp, OToken(oToken).expiry());

        controller.setBetaMode(true);

        // OTM: price above strike
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        _settleVault(alice, 1);

        // OTM: full collateral returned
        uint256 collateral = (1e8 * strikePrice) / 1e10;
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + collateral);

        // No physical delivery needed for OTM
        assertLt(block.timestamp, OToken(oToken).expiry());
    }

    function test_e2e_fullBetaFlow_callITM() public {
        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        assertLt(block.timestamp, OToken(oToken).expiry());

        controller.setBetaMode(true);

        oracle.setExpiryPrice(address(weth), expiry, 2500e8);
        ethFeed.setPrice(2500e8);

        uint256 aliceWethBefore = weth.balanceOf(alice);
        _settleVault(alice, 1);

        // ITM call: alice gets 0 collateral back
        assertEq(weth.balanceOf(alice), aliceWethBefore);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 1e18);

        // Alice received USDC = strike amount
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 2000e6);

        assertLt(block.timestamp, OToken(oToken).expiry());
    }

    // ===== Mock contracts: verify correct behavior =====

    function test_mockAavePool_mintsFromNothing() public {
        // MockAavePool should be able to flash loan without pre-funding
        uint256 poolBalanceBefore = weth.balanceOf(address(mockAave));
        assertEq(poolBalanceBefore, 0); // not pre-funded

        // Do a full flow that requires flash loan
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        ethFeed.setPrice(1800e8);

        _settleVault(alice, 1);

        uint256 aliceWethBefore = weth.balanceOf(alice);
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        // Flash loan worked despite pool having 0 initial balance
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);
    }

    function test_mockSwapRouter_usesChainlinkPrice() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);
        ethFeed.setPrice(1800e8);

        _settleVault(alice, 1);

        uint256 mmUsdcBefore = usdc.balanceOf(mm);

        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        // MM gets surplus: collateral (2000 USDC) minus swap cost
        // Flash loan: 1 WETH, premium = 1e18 * 5 / 10000 = 5e14
        // Swap: need (1e18 + 5e14) WETH. At $1800, cost = (1e18 + 5e14) * 1800e8 / 1e20
        // = (1e18 + 5e14) * 1800 / 1e12 ≈ 1_800_900_000 / 1e6 = 1800.9 USDC ≈ 1800900000 wei
        uint256 mmUsdcAfter = usdc.balanceOf(mm);
        uint256 surplus = mmUsdcAfter - mmUsdcBefore;

        // Surplus should be ~199.1 USDC (2000 - 1800.9)
        assertGt(surplus, 190e6); // at least $190
        assertLt(surplus, 210e6); // at most $210
    }

    function test_mockSwapRouter_priceChangeAffectsConversion() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);

        // Set a different price: $1900
        oracle.setExpiryPrice(address(weth), expiry, 1900e8);
        ethFeed.setPrice(1900e8);

        _settleVault(alice, 1);

        uint256 mmUsdcBefore = usdc.balanceOf(mm);

        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        uint256 surplus = usdc.balanceOf(mm) - mmUsdcBefore;

        // At $1900: swap cost ≈ 1900.95, surplus ≈ 99.05 USDC
        assertGt(surplus, 90e6);
        assertLt(surplus, 110e6);
    }

    // ===== betaMode does NOT bypass other checks =====

    function test_betaMode_doesNotBypassExpiryPriceNotSet() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);

        // Do NOT set expiry price
        vm.prank(address(settler));
        vm.expectRevert(Controller.ExpiryPriceNotSet.selector);
        controller.settleVault(alice, 1);
    }

    function test_betaMode_doesNotBypassITMCheck() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8); // OTM

        _settleVault(alice, 1);

        // physicalRedeem should still revert: option is OTM
        vm.prank(mm);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
    }

    function test_betaMode_doesNotBypassOperatorCheck() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        controller.setBetaMode(true);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Non-operator tries physicalRedeem
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOperator.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
    }

    // ===== Re-lock: disabling betaMode restores expiry enforcement =====

    function test_betaMode_disableRestoresExpiryCheck() public {
        address putToken = _createPut(strikePrice);
        _setupPutPosition(alice, putToken, 1e8);

        // Enable betaMode, settle alice's vault successfully before expiry
        controller.setBetaMode(true);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8); // OTM
        _settleVault(alice, 1);

        // Now set up bob's position (same oToken needs new quote)
        _fundUser(bob, 50_000e6, 50e18);
        vm.prank(bob);
        IERC20(putToken).approve(address(settler), type(uint256).max);
        vm.prank(mm);
        priceSheet.publishQuote(putToken, 70e6, 72e6, block.timestamp + 1 hours, 1000e8);
        vm.prank(bob);
        settler.executeOrder(putToken, 1e8, 2000e6);

        // Disable betaMode
        controller.setBetaMode(false);

        // Bob's vault should now revert — expiry check re-enforced
        vm.prank(address(settler));
        vm.expectRevert(Controller.OptionNotExpired.selector);
        controller.settleVault(bob, 1);

        // physicalRedeem should also revert
        vm.prank(mm);
        vm.expectRevert(BatchSettler.OptionNotExpired.selector);
        settler.physicalRedeem(putToken, bob, 1e8, 2000e6);
    }
}
