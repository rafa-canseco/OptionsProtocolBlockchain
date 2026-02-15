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
        uint256 premium,
        uint256 collateral,
        uint256 vaultId
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
        _publishPutQuote(oToken, 70e6, 100_000e6);

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
        priceSheet.publishQuote(oToken, 50e6, 52e6, block.timestamp + 1 hours, 100e18);

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
        _publishPutQuote(oToken, 70e6, 100_000e6);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // 2.5 oTokens → premium = (2.5e8 * 70e6) / 1e8 = 175e6
        vm.prank(alice);
        settler.executeOrder(oToken, 2.5e8, 5000e6);

        assertEq(usdc.balanceOf(alice), aliceBefore - 5000e6 + 175e6);
    }

    function test_executeOrder_multipleUsersProgressiveFill() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 6000e6); // max capacity $6000

        // Alice fills $2000
        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        (, , , uint256 filled1, ) = priceSheet.getQuote(oToken);
        assertEq(filled1, 2000e6);

        // Bob fills $4000
        vm.prank(bob);
        settler.executeOrder(oToken, 2e8, 4000e6);

        (, , , uint256 filled2, ) = priceSheet.getQuote(oToken);
        assertEq(filled2, 6000e6);
    }

    function test_executeOrder_revertsOnCapacityExceeded() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 3000e6); // max $3000

        // Alice fills $2000
        vm.prank(alice);
        settler.executeOrder(oToken, 1e8, 2000e6);

        // Bob tries $2000 more → exceeds capacity
        vm.prank(bob);
        vm.expectRevert(PriceSheet.CapacityExceeded.selector);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    function test_executeOrder_revertsOnExpiredQuote() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100_000e6);

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
        _publishPutQuote(oToken, 70e6, 100_000e6);

        vm.prank(mm);
        priceSheet.invalidateQuote(oToken);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.QuoteInvalid.selector);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    function test_executeOrder_emitsEvent() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _publishPutQuote(oToken, 70e6, 100_000e6);

        vm.prank(alice);
        // premium = (1e8 * 70e6) / 1e8 = 70e6
        vm.expectEmit(true, true, false, true);
        emit OrderExecuted(alice, oToken, 1e8, 70e6, 2000e6, 1);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }

    // ===== Full E2E: executeOrder → Expiry → Settle → Redeem =====

    function test_fullE2E_executeOrderToRedeem() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 100_000e6);

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

        // Alice: -2000 collateral + 70 premium + 1800 returned
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + 70e6 + 1800e6);
        // Bob: -4000 collateral + 140 premium + 3600 returned
        assertEq(usdc.balanceOf(bob), 50_000e6 - 4000e6 + 140e6 + 3600e6);

        // MM redeems
        vm.prank(mm);
        controller.redeem(oToken, 3e8);
        // Payout: $200 per oToken * 3 = $600
        assertEq(usdc.balanceOf(mm), 1_000_000e6 - 70e6 - 140e6 + 600e6);

        // Pool empty
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    // ===== Post-expiry batch settlement =====

    function test_batchSettleVaults() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _publishPutQuote(oToken, 70e6, 100_000e6);

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

        // Both users got collateral back (OTM → full refund)
        assertEq(usdc.balanceOf(alice), 10_000e6 + 70e6);
        assertEq(usdc.balanceOf(bob), 50_000e6 + 70e6);
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
}
