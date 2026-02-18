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

contract BatchSettlerTest is Test {
    event OrderExecuted(
        address indexed user,
        address indexed oToken,
        uint256 amount,
        uint256 grossPremium,
        uint256 netPremium,
        uint256 fee,
        uint256 collateral,
        uint256 vaultId
    );
    event VaultSettleFailed(address indexed vaultOwner, uint256 vaultId, bytes reason);
    event RedeemFailed(address indexed oToken, uint256 amount, bytes reason);

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

    address public mm = address(0xAA00);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B0);
    address public carol = address(0xCA201);

    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        // Deploy tokens
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

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

        // Whitelist
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        // Expiry
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        // Fund MM with USDC for premiums
        usdc.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);

        // Fund users with USDC (for puts) and approve MarginPool
        _fundUser(alice, 10_000e6, 10e18);
        _fundUser(bob, 50_000e6, 50e18);
        _fundUser(carol, 1_000e6, 1e18);
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

    function _approveOToken(address user, address oToken) internal {
        vm.prank(user);
        IERC20(oToken).approve(address(settler), type(uint256).max);
    }

    function _publishPutQuote(address oToken, uint256 bidPrice, uint256 maxAmount) internal {
        vm.prank(mm);
        priceSheet.publishQuote(oToken, bidPrice, bidPrice + 2e6, block.timestamp + 1 hours, maxAmount);
    }

    // ===== executeOrder (instant settlement) =====

    function test_executeOrder_singlePut() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8); // max 100 oTokens

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 mmBefore = usdc.balanceOf(mm);

        vm.prank(alice);
        uint256 vaultId = settler.executeOrder(oToken, 1e8, 2000e6);

        assertEq(vaultId, 1);
        // Alice: -2000 collateral, +70 premium
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + 70e6);
        // MM: -70 premium, +1 oToken
        assertEq(usdc.balanceOf(mm), mmBefore - 70e6);
        assertEq(OToken(oToken).balanceOf(mm), 1e8);
        // Pool: holds 2000 collateral
        assertEq(usdc.balanceOf(address(pool)), 2000e6);
    }

    function test_executeOrder_singleCall() public {
        address oToken = _createCall(2300e8);
        _approveOToken(bob, oToken);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 50e6, 52e6, block.timestamp + 1 hours, 100e8);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        uint256 bobWethBefore = weth.balanceOf(bob);

        vm.prank(bob);
        settler.executeOrder(oToken, 1e8, 1e18);

        // Bob: -1 WETH collateral, +50 USDC premium
        assertEq(weth.balanceOf(bob), bobWethBefore - 1e18);
        assertEq(usdc.balanceOf(bob), bobUsdcBefore + 50e6);
        // MM got oToken
        assertEq(OToken(oToken).balanceOf(mm), 1e8);
    }

    function test_executeOrder_premiumCalculation() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // 2.5 oTokens -> premium = (2.5e8 * 70e6) / 1e8 = 175e6
        vm.prank(alice);
        settler.executeOrder(oToken, 2.5e8, 5000e6);

        assertEq(usdc.balanceOf(alice), aliceBefore - 5000e6 + 175e6);
    }

    function test_executeOrder_multipleUsersProgressiveFill() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 3e8); // max 3 oTokens

        // Alice fills 1 oToken
        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        (, , , uint256 filled1, ) = priceSheet.getQuote(oToken);
        assertEq(filled1, 1e8);

        // Bob fills 2 oTokens
        vm.prank(bob);
        settler.executeOrder(oToken, 2e8, 4000e6);

        (, , , uint256 filled2, ) = priceSheet.getQuote(oToken);
        assertEq(filled2, 3e8);
    }

    function test_executeOrder_revertsOnCapacityExceeded() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 1.5e8); // max 1.5 oTokens

        // Alice fills 1 oToken
        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        // Bob tries 1 more -> exceeds capacity (1e8 + 1e8 > 1.5e8)
        vm.prank(bob);
        vm.expectRevert(PriceSheet.CapacityExceeded.selector);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnExpiredQuote() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.QuoteInvalid.selector);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnNoQuote() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        // No quote published

        vm.prank(alice);
        vm.expectRevert(BatchSettler.QuoteInvalid.selector);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnInvalidatedQuote() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        vm.prank(mm);
        priceSheet.invalidateQuote(oToken);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.QuoteInvalid.selector);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnZeroAmount() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.InvalidAmount.selector);
        settler.executeOrder(oToken, 0, 2000e6);
    }

    function test_executeOrder_emitsEvent() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        vm.prank(alice);
        // premium = (1e8 * 70e6) / 1e8 = 70e6, fee = 0 (no treasury/feeBps set)
        vm.expectEmit(true, true, false, true);
        emit OrderExecuted(alice, oToken, 1e8, 70e6, 70e6, 0, 2000e6, 1);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    // ===== Full E2E: executeOrder -> Expiry -> Settle -> Redeem =====

    function test_fullE2E_executeOrderToRedeem() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        // Alice and Bob sell puts via executeOrder
        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        vm.prank(bob);
        settler.executeOrder(oToken, 2e8, 4000e6);

        // MM has 3 oTokens total
        assertEq(OToken(oToken).balanceOf(mm), 3e8);

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

        // Physical settlement: ITM put → users get 0 collateral back
        // Alice: -2000 collateral + 70 premium + 0 returned
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + 70e6);
        // Bob: -4000 collateral + 140 premium + 0 returned
        assertEq(usdc.balanceOf(bob), 50_000e6 - 4000e6 + 140e6);

        // MM redeems via batchRedeem
        vm.prank(mm);
        OToken(oToken).approve(address(settler), 3e8);

        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 3e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm);
        settler.batchRedeem(oTokens, amounts);

        // Physical settlement: full collateral payout = $2000 * 3 = $6000
        assertEq(usdc.balanceOf(mm), mmBefore + 6000e6);

        // Pool empty
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    // ===== Post-expiry batch settlement =====

    function test_batchSettleVaults() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(oToken, 1e8, 2000e6);

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
        _publishPutQuote(oToken, 70e6, 100e8);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(oToken, 1e8, 2000e6);

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

        // Now batch with Alice (already settled) + Bob (valid) — Alice should emit failure event
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

    function test_batchRedeem_singleOtoken() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        // Alice sells put
        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

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

        // MM redeems via batchRedeem
        vm.prank(mm);
        OToken(oToken).approve(address(settler), 1e8);

        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm);
        settler.batchRedeem(oTokens, amounts);

        // Physical settlement: full collateral payout = $2000
        assertEq(usdc.balanceOf(mm), mmBefore + 2000e6);
        // oTokens burned
        assertEq(OToken(oToken).balanceOf(mm), 0);
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

    function test_constructorRevertsOnZeroAddress() public {
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        new BatchSettler(address(0), mm);

        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        new BatchSettler(address(addressBook), address(0));
    }

    // ===== Premium edge cases =====

    function test_executeOrder_zeroBidPrice() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 0, 2e6, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        // Alice gets zero premium (intentional), only loses collateral
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6);
        assertEq(OToken(oToken).balanceOf(mm), 1e8);
    }

    function test_executeOrder_revertsOnPremiumTruncation() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        // bidPrice = 50e6, amount = 1 (smallest unit) -> premium = (1 * 50e6) / 1e8 = 0
        vm.prank(mm);
        priceSheet.publishQuote(oToken, 50e6, 52e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.PremiumTooSmall.selector);
        settler.executeOrder(oToken, 1, 1);
    }

    // ===== batchRedeem edge cases =====

    function test_batchRedeem_multipleOtokensSameCollateral() public {
        // Two different PUT strikes, both USDC-collateralized
        address oToken1 = _createPut(2000e8);
        address oToken2 = _createPut(2500e8);
        _approveOToken(alice, oToken1);
        _approveOToken(bob, oToken2);
        _publishPutQuote(oToken1, 70e6, 100e8);
        _publishPutQuote(oToken2, 90e6, 100e8);

        vm.prank(alice);
        settler.executeOrder(oToken1, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(oToken2, 1e8, 2500e6);

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

        // MM redeems both oTokens in a single batchRedeem
        vm.startPrank(mm);
        OToken(oToken1).approve(address(settler), 1e8);
        OToken(oToken2).approve(address(settler), 1e8);
        vm.stopPrank();

        address[] memory oTokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        oTokens[0] = oToken1;
        oTokens[1] = oToken2;
        amounts[0] = 1e8;
        amounts[1] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm);
        settler.batchRedeem(oTokens, amounts);

        // Physical settlement: full collateral payouts
        // oToken1 payout: 2000e6 (full collateral)
        // oToken2 payout: 2500e6 (full collateral)
        assertEq(usdc.balanceOf(mm), mmBefore + 2000e6 + 2500e6);
        // No residual left in settler
        assertEq(usdc.balanceOf(address(settler)), 0);
    }

    function test_batchRedeem_otmZeroPayout() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

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

        // MM redeems OTM oToken — zero payout but should not revert
        vm.prank(mm);
        OToken(oToken).approve(address(settler), 1e8);

        address[] memory oTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        oTokens[0] = oToken;
        amounts[0] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm);
        settler.batchRedeem(oTokens, amounts);

        // Zero payout, balance unchanged
        assertEq(usdc.balanceOf(mm), mmBefore);
        // oTokens burned
        assertEq(OToken(oToken).balanceOf(mm), 0);
    }

    function test_batchRedeem_continuesOnPullFailure() public {
        address oToken1 = _createPut(2000e8);
        address oToken2 = _createPut(2500e8);
        _approveOToken(alice, oToken1);
        _approveOToken(bob, oToken2);
        _publishPutQuote(oToken1, 70e6, 100e8);
        _publishPutQuote(oToken2, 90e6, 100e8);

        vm.prank(alice);
        settler.executeOrder(oToken1, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(oToken2, 1e8, 2500e6);

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

        // Redeem oToken1 first so MM has 0 balance of it
        vm.startPrank(mm);
        OToken(oToken1).approve(address(settler), 1e8);
        OToken(oToken2).approve(address(settler), 1e8);
        vm.stopPrank();

        address[] memory oTokens1 = new address[](1);
        uint256[] memory amounts1 = new uint256[](1);
        oTokens1[0] = oToken1;
        amounts1[0] = 1e8;
        vm.prank(mm);
        settler.batchRedeem(oTokens1, amounts1);

        // Now batch both: oToken1 pull fails (0 balance, no approval), oToken2 succeeds
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
        settler.batchRedeem(oTokens, amounts);

        // Physical: oToken2 full collateral = $2500, oToken1 failed but didn't kill the batch
        assertEq(usdc.balanceOf(mm), mmBefore + 2500e6);
    }

    function test_batchRedeem_continuesOnRevokedApproval() public {
        address oToken1 = _createPut(2000e8);
        address oToken2 = _createPut(2500e8);
        _approveOToken(alice, oToken1);
        _approveOToken(bob, oToken2);
        _publishPutQuote(oToken1, 70e6, 100e8);
        _publishPutQuote(oToken2, 90e6, 100e8);

        vm.prank(alice);
        settler.executeOrder(oToken1, 1e8, 2000e6);
        vm.prank(bob);
        settler.executeOrder(oToken2, 1e8, 2500e6);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle both
        address[] memory settleOwners = new address[](2);
        uint256[] memory settleVaults = new uint256[](2);
        settleOwners[0] = alice;
        settleOwners[1] = bob;
        settleVaults[0] = 1;
        settleVaults[1] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(settleOwners, settleVaults);

        // MM approves oToken2 but revokes oToken1 approval
        vm.startPrank(mm);
        OToken(oToken1).approve(address(settler), 0);
        OToken(oToken2).approve(address(settler), 1e8);
        vm.stopPrank();

        address[] memory oTokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        oTokens[0] = oToken1;
        oTokens[1] = oToken2;
        amounts[0] = 1e8;
        amounts[1] = 1e8;

        uint256 mmBefore = usdc.balanceOf(mm);
        vm.prank(mm);
        settler.batchRedeem(oTokens, amounts);

        // oToken1 failed (revoked approval), oToken2 succeeded (physical: full $2500 payout)
        assertEq(usdc.balanceOf(mm), mmBefore + 2500e6);
        // MM still has oToken1 (pull failed, not burned)
        assertEq(OToken(oToken1).balanceOf(mm), 1e8);
    }

    // ===== New validation tests =====

    function test_executeOrder_revertsOnZeroAddress() public {
        _publishPutQuote(address(0x1), 70e6, 100e8); // dummy, won't reach PriceSheet

        vm.prank(alice);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.executeOrder(address(0), 1e8, 2000e6);
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
        _publishPutQuote(oToken, 70e6, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 mmBefore = usdc.balanceOf(mm);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        // grossPremium = 70e6, fee = 70e6 * 400 / 10000 = 2.8e6, netPremium = 67.2e6
        uint256 expectedFee = (70e6 * 400) / 10000; // 2_800_000
        uint256 expectedNet = 70e6 - expectedFee;     // 67_200_000

        // Alice gets net premium
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + expectedNet);
        // MM pays gross premium (net + fee)
        assertEq(usdc.balanceOf(mm), mmBefore - 70e6);
        // Treasury gets fee
        assertEq(usdc.balanceOf(treasury), expectedFee);
    }

    function test_executeOrder_zeroFee_noBps() public {
        // feeBps = 0, treasury set → no fee
        address treasury = address(0x7EA5);
        settler.setTreasury(treasury);
        // protocolFeeBps defaults to 0

        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        // Full premium to alice, 0 to treasury
        assertEq(usdc.balanceOf(alice), aliceBefore - 2000e6 + 70e6);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_executeOrder_zeroFee_noTreasury() public {
        // feeBps set, treasury = address(0) → no fee
        settler.setProtocolFeeBps(400);
        // treasury defaults to address(0)

        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

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
        vm.prank(mm);
        priceSheet.publishQuote(oToken, 1, 2, block.timestamp + 1 hours, 100e8);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

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
        _publishPutQuote(oToken, 70e6, 100e8);

        uint256 expectedFee = (70e6 * 400) / 10000;
        uint256 expectedNet = 70e6 - expectedFee;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit OrderExecuted(alice, oToken, 1e8, 70e6, expectedNet, expectedFee, 2000e6, 1);
        settler.executeOrder(oToken, 1e8, 2000e6);
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
    ) external {
        // Transfer asset to receiver
        IERC20(asset).safeTransfer(receiverAddress, amount);

        // Calculate fee
        uint256 premium = (amount * FLASH_LOAN_FEE_BPS) / 10_000;

        // Call executeOperation on receiver
        bool success = IFlashLoanSimpleReceiver(receiverAddress).executeOperation(
            asset, amount, premium, receiverAddress, params
        );
        require(success, "Flash loan callback failed");

        // Pull repayment
        IERC20(asset).safeTransferFrom(receiverAddress, address(this), amount + premium);
    }
}

contract MockSwapRouter {
    using SafeERC20 for IERC20;

    // Mock exchange rate: how many units of tokenOut per 1e18 tokenIn
    // For USDC→WETH: rate = ethPrice (e.g., 1800e6 USDC per 1e18 WETH → set as 1e18 * 1e18 / 1800e6)
    // Simpler: we set a fixed price and compute amountIn from amountOut
    uint256 public mockEthPriceUsdc; // e.g., 1800e6 = $1800 per ETH

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
        // Determine the direction: USDC→WETH or WETH→USDC
        // We compute amountIn based on the mock price
        // For USDC→WETH (put delivery): amountIn (USDC) = amountOut (WETH) * price / 1e18
        // For WETH→USDC (call delivery): amountIn (WETH) = amountOut (USDC) * 1e18 / price

        // Simple heuristic: if tokenIn has fewer decimals, it's USDC→WETH
        // We check by amount magnitude instead
        if (params.amountOut > 1e12) {
            // Large amountOut → this is WETH (18 decimals)
            // amountIn is USDC (6 decimals)
            // amountIn = amountOut * mockEthPriceUsdc / 1e18
            amountIn = (params.amountOut * mockEthPriceUsdc) / 1e18;
        } else {
            // Small amountOut → this is USDC (6 decimals)
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
}

// =============================================================================
// Physical Delivery Tests
// =============================================================================

contract PhysicalRedeemTest is Test {
    using SafeERC20 for IERC20;

    event PhysicalDelivery(
        address indexed oToken,
        address indexed user,
        uint256 contraAmount,
        uint256 collateralUsed
    );
    event PhysicalRedeemFailed(address indexed oToken, address indexed user, uint256 amount, bytes reason);

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
    MockAavePool public mockAave;
    MockSwapRouter public mockRouter;

    address public mm = address(0xAA00);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B0);

    uint256 public strikePrice = 2000e8; // $2000
    uint256 public expiry;
    uint256 public constant MOCK_ETH_PRICE = 1800e6; // $1800

    function setUp() public {
        vm.warp(1700000000);

        // Deploy tokens
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mocks
        mockAave = new MockAavePool();
        mockRouter = new MockSwapRouter(MOCK_ETH_PRICE);

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

        // Expiry
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

        // Fund mock Aave pool with liquidity for flash loans
        weth.mint(address(mockAave), 1_000e18);
        usdc.mint(address(mockAave), 10_000_000e6);

        // Fund mock swap router with liquidity
        weth.mint(address(mockRouter), 1_000e18);
        usdc.mint(address(mockRouter), 10_000_000e6);
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

        // MM approves settler for oTokens (needed for physicalRedeem)
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
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Physical delivery: alice should receive 1 ETH
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        // Alice received 1 WETH
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);
        // oTokens burned (MM had 1e8, now 0)
        assertEq(OToken(oToken).balanceOf(mm), 0);
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
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Physical delivery: alice should receive $2000 USDC (strike amount)
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 1e18);

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

        vm.prank(mm);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
    }

    // ===== Reverts on ATM (expiryPrice == strike) =====

    function test_physicalRedeem_revertsOnATM() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2000e8); // exactly at strike

        vm.prank(mm);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
    }

    // ===== Reverts on not expired =====

    function test_physicalRedeem_revertsOnNotExpired() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        // Don't warp past expiry
        vm.prank(mm);
        vm.expectRevert(BatchSettler.OptionNotExpired.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
    }

    // ===== Reverts on non-operator =====

    function test_physicalRedeem_revertsOnNonOperator() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOperator.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
    }

    // ===== Operator receives surplus =====

    function test_physicalRedeem_operatorReceivesSurplus() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 mmUsdcBefore = usdc.balanceOf(mm);

        // Physical delivery
        // Collateral from redeem: 2000 USDC
        // Flash loan: 1 WETH, fee = 1e18 * 5 / 10000 = 5e14
        // Swap: need 1e18 + 5e14 WETH. At $1800, cost = (1e18 + 5e14) * 1800e6 / 1e18 ≈ 1800.9e6 USDC
        // Surplus ≈ 2000e6 - 1800.9e6 ≈ 199.1e6 USDC → goes to MM
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        uint256 mmUsdcAfter = usdc.balanceOf(mm);
        uint256 surplus = mmUsdcAfter - mmUsdcBefore;

        // MM should have received surplus (approximately $199 USDC)
        assertGt(surplus, 0);
        // Surplus should be less than full collateral (some went to swap)
        assertLt(surplus, 2000e6);
    }

    // ===== Batch physical redeem =====

    function test_batchPhysicalRedeem_multipleUsers() public {
        address oToken = _createPut(strikePrice);

        // Setup positions for alice and bob
        // Alice first
        vm.prank(alice);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 70e6, 72e6, block.timestamp + 1 hours, 1000e8);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        vm.prank(bob);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.prank(bob);
        settler.executeOrder(oToken, 1e8, 2000e6);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);

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
        vm.prank(mm);
        settler.batchSettleVaults(settleOwners, settleVaults);

        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 bobWethBefore = weth.balanceOf(bob);

        // Batch physical delivery
        address[] memory oTokens = new address[](2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory maxSpents = new uint256[](2);
        oTokens[0] = oToken;
        oTokens[1] = oToken;
        users[0] = alice;
        users[1] = bob;
        amounts[0] = 1e8;
        amounts[1] = 1e8;
        maxSpents[0] = 2000e6;
        maxSpents[1] = 2000e6;

        vm.prank(mm);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents);

        // Both received 1 WETH each
        assertEq(weth.balanceOf(alice), aliceWethBefore + 1e18);
        assertEq(weth.balanceOf(bob), bobWethBefore + 1e18);
    }

    // ===== Batch continues on failure =====

    function test_batchPhysicalRedeem_continuesOnFailure() public {
        address oToken = _createPut(strikePrice);

        vm.prank(alice);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 70e6, 72e6, block.timestamp + 1 hours, 1000e8);

        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        address[] memory settleOwners = new address[](1);
        uint256[] memory settleVaults = new uint256[](1);
        settleOwners[0] = alice;
        settleVaults[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(settleOwners, settleVaults);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Batch: first item is a bogus oToken (will fail), second is valid
        address bogusToken = address(0xDEAD);

        address[] memory oTokens = new address[](2);
        address[] memory users = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory maxSpents = new uint256[](2);
        oTokens[0] = bogusToken;
        oTokens[1] = oToken;
        users[0] = bob;
        users[1] = alice;
        amounts[0] = 1e8;
        amounts[1] = 1e8;
        maxSpents[0] = 2000e6;
        maxSpents[1] = 2000e6;

        vm.prank(mm);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents);

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
        BatchSettler freshSettler = new BatchSettler(address(addressBook), mm);
        addressBook.setBatchSettler(address(freshSettler));
        freshSettler.setSwapRouter(address(mockRouter));
        freshSettler.setSwapFeeTier(500);

        address oToken = _createPut(strikePrice);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(mm);
        vm.expectRevert(BatchSettler.AavePoolNotSet.selector);
        freshSettler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        // Restore original settler
        addressBook.setBatchSettler(address(settler));
    }

    function test_physicalRedeem_revertsOnSwapRouterNotSet() public {
        BatchSettler freshSettler = new BatchSettler(address(addressBook), mm);
        addressBook.setBatchSettler(address(freshSettler));
        freshSettler.setAavePool(address(mockAave));
        // swapRouter left as address(0)

        address oToken = _createPut(strikePrice);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(mm);
        vm.expectRevert(BatchSettler.SwapRouterNotSet.selector);
        freshSettler.physicalRedeem(oToken, alice, 1e8, 2000e6);

        addressBook.setBatchSettler(address(settler));
    }

    function test_physicalRedeem_revertsOnZeroAmount() public {
        address oToken = _createPut(strikePrice);
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(mm);
        vm.expectRevert(BatchSettler.InvalidAmount.selector);
        settler.physicalRedeem(oToken, alice, 0, 2000e6);
    }

    function test_physicalRedeem_revertsOnExpiryPriceNotSet() public {
        address oToken = _createPut(strikePrice);
        _setupPutPosition(alice, oToken, 1e8);
        vm.warp(expiry + 1);
        // oracle price NOT set

        vm.prank(mm);
        vm.expectRevert(BatchSettler.ExpiryPriceNotSet.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 2000e6);
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
        vm.prank(mm);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler._physicalRedeemSingle(address(0x1), alice, 1e8, 2000e6);
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
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // maxCollateralSpent = 1 USDC (way too low to buy 1 ETH)
        vm.prank(mm);
        vm.expectRevert(); // "Too much slippage" from MockSwapRouter
        settler.physicalRedeem(oToken, alice, 1e8, 1e6);
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
        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setSwapFeeTier(500);
    }

    // ===== address(0) validation =====

    function test_physicalRedeem_revertsOnZeroOToken() public {
        vm.warp(expiry + 1);
        vm.prank(mm);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.physicalRedeem(address(0), alice, 1e8, 2000e6);
    }

    function test_physicalRedeem_revertsOnZeroUser() public {
        address oToken = _createPut(strikePrice);
        vm.warp(expiry + 1);
        vm.prank(mm);
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.physicalRedeem(oToken, address(0), 1e8, 2000e6);
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

        vm.prank(mm);
        vm.expectRevert(BatchSettler.LengthMismatch.selector);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents);
    }

    function test_batchPhysicalRedeem_revertsOnEmptyArrays() public {
        address[] memory oTokens = new address[](0);
        address[] memory users = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory maxSpents = new uint256[](0);

        vm.prank(mm);
        vm.expectRevert(BatchSettler.EmptyArray.selector);
        settler.batchPhysicalRedeem(oTokens, users, amounts, maxSpents);
    }

    // ===== CALL ATM boundary =====

    function test_physicalRedeem_callATM_revertsNotITM() public {
        address oToken = _createCall(strikePrice);
        _setupCallPosition(alice, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2000e8); // exactly at strike

        vm.prank(mm);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, alice, 1e8, 1e18);
    }
}
