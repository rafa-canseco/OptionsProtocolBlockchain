// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OToken.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/PriceSheet.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

// =============================================================================
// Fuzz Tests — Controller
// =============================================================================

contract ControllerFuzzTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;

    MockERC20 public weth;
    MockERC20 public usdc;

    address public user = address(0xBEEF);
    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        addressBook = new AddressBook();
        controller = new Controller(address(addressBook));
        pool = new MarginPool(address(addressBook));
        factory = new OTokenFactory(address(addressBook));
        oracle = new Oracle(address(addressBook));
        whitelist = new Whitelist(address(addressBook));

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        usdc.mint(user, type(uint128).max);
        weth.mint(user, type(uint128).max);
        vm.startPrank(user);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Any PUT amount with correct collateral should mint successfully
    function testFuzz_putMintWithSufficientCollateral(uint256 amount) public {
        // Bound: 1 unit to 1M oTokens (avoid overflow in collateral calc)
        amount = bound(amount, 1, 1_000_000e8);

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        uint256 requiredCollateral = (amount * strikePrice) / 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), requiredCollateral);
        controller.mintOtoken(user, 1, oToken, amount);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), amount);
        assertEq(usdc.balanceOf(address(pool)), requiredCollateral);
    }

    /// @notice Any PUT amount with LESS collateral should revert
    function testFuzz_putMintInsufficientCollateralReverts(uint256 amount, uint256 collateral) public {
        amount = bound(amount, 1e8, 1_000_000e8);
        uint256 requiredCollateral = (amount * strikePrice) / 1e10;
        // Ensure collateral is strictly less than required
        collateral = bound(collateral, 0, requiredCollateral - 1);

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), collateral);

        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, 1, oToken, amount);
        vm.stopPrank();
    }

    /// @notice CALL with any amount should require amount * 1e10 WETH
    function testFuzz_callMintWithSufficientCollateral(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e8);

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(weth), strikePrice, expiry, false
        );
        whitelist.whitelistOToken(oToken);

        uint256 requiredCollateral = amount * 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(weth), requiredCollateral);
        controller.mintOtoken(user, 1, oToken, amount);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), amount);
    }

    /// @notice PUT settlement: user always gets back (collateral - payout), payout >= 0
    function testFuzz_putSettlementPayout(uint256 expiryPrice) public {
        // Price between $1 and $100,000
        expiryPrice = bound(expiryPrice, 1e8, 100_000e8);

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        uint256 amount = 1e8;
        uint256 collateral = (amount * strikePrice) / 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), collateral);
        controller.mintOtoken(user, 1, oToken, amount);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(user);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, expiryPrice);

        vm.prank(user);
        controller.settleVault(user, 1);

        uint256 userBalAfter = usdc.balanceOf(user);
        uint256 returned = userBalAfter - userBalBefore;

        // Returned collateral is always <= deposited
        assertLe(returned, collateral);

        if (expiryPrice >= strikePrice) {
            // OTM: full collateral back
            assertEq(returned, collateral);
        } else {
            // ITM: partial collateral back
            uint256 payout = (amount * (strikePrice - expiryPrice)) / 1e10;
            assertEq(returned, collateral - payout);
        }
    }

    /// @notice CALL settlement: payout math is correct for any expiry price
    function testFuzz_callSettlementPayout(uint256 expiryPrice) public {
        expiryPrice = bound(expiryPrice, 1e8, 100_000e8);

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(weth), strikePrice, expiry, false
        );
        whitelist.whitelistOToken(oToken);

        uint256 amount = 1e8;
        uint256 collateral = amount * 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(weth), collateral);
        controller.mintOtoken(user, 1, oToken, amount);
        vm.stopPrank();

        uint256 userBalBefore = weth.balanceOf(user);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, expiryPrice);

        vm.prank(user);
        controller.settleVault(user, 1);

        uint256 userBalAfter = weth.balanceOf(user);
        uint256 returned = userBalAfter - userBalBefore;

        assertLe(returned, collateral);

        if (expiryPrice <= strikePrice) {
            assertEq(returned, collateral);
        } else {
            uint256 payout = (amount * (expiryPrice - strikePrice) * 1e10) / expiryPrice;
            assertEq(returned, collateral - payout);
        }
    }

    /// @notice Random callers cannot open vaults for other users
    function testFuzz_unauthorizedCannotOpenVault(address caller) public {
        vm.assume(caller != user);
        vm.assume(caller != addressBook.batchSettler());

        vm.prank(caller);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.openVault(user);
    }
}

// =============================================================================
// Fuzz Tests — Oracle
// =============================================================================

contract OracleFuzzTest is Test {
    AddressBook public addressBook;
    Oracle public oracle;

    function setUp() public {
        addressBook = new AddressBook();
        oracle = new Oracle(address(addressBook));
    }

    /// @notice Any non-zero price can be set for expiry
    function testFuzz_setExpiryPrice(uint256 price) public {
        vm.assume(price > 0);
        address asset = address(0x1111);

        oracle.setExpiryPrice(asset, 1700000000, price);

        (uint256 stored, bool isSet) = oracle.getExpiryPrice(asset, 1700000000);
        assertEq(stored, price);
        assertTrue(isSet);
    }

    /// @notice Zero price always reverts
    function testFuzz_zeroExpiryPriceReverts(uint256 expiry) public {
        vm.expectRevert(Oracle.InvalidPrice.selector);
        oracle.setExpiryPrice(address(0x1111), expiry, 0);
    }

    /// @notice Non-owner can never set prices
    function testFuzz_nonOwnerCannotSetExpiryPrice(address caller, uint256 price) public {
        vm.assume(caller != address(this));
        vm.assume(price > 0);

        vm.prank(caller);
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setExpiryPrice(address(0x1111), 1700000000, price);
    }
}

// =============================================================================
// Fuzz Tests — BatchSettler (executeOrder)
// =============================================================================

contract BatchSettlerFuzzTest is Test {
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
    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        addressBook = new AddressBook();
        controller = new Controller(address(addressBook));
        pool = new MarginPool(address(addressBook));
        factory = new OTokenFactory(address(addressBook));
        oracle = new Oracle(address(addressBook));
        whitelist = new Whitelist(address(addressBook));
        settler = new BatchSettler(address(addressBook), mm);
        priceSheet = new PriceSheet(address(addressBook), mm);

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
        addressBook.setPriceSheet(address(priceSheet));

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        usdc.mint(mm, type(uint128).max);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);
    }

    /// @notice N users execute orders, all valid. N bounded to avoid gas issues.
    function testFuzz_multipleUsersExecuteOrders(uint8 rawCount) public {
        uint256 count = bound(uint256(rawCount), 1, 10);

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 50e6, 52e6, block.timestamp + 1 hours, count * 1e8);

        for (uint256 i = 0; i < count; i++) {
            address userAddr = address(uint160(0xF000 + i));
            usdc.mint(userAddr, 10_000e6);
            vm.startPrank(userAddr);
            usdc.approve(address(pool), type(uint256).max);
            IERC20(oToken).approve(address(settler), type(uint256).max);
            vm.stopPrank();

            vm.prank(userAddr);
            settler.executeOrder(oToken, 1e8, 2000e6);
        }

        // MM should have received all oTokens
        assertEq(OToken(oToken).balanceOf(mm), count * 1e8);
    }

    /// @notice Fuzz premium via bidPrice — user always receives (amount * bidPrice) / 1e8
    function testFuzz_premiumCalculation(uint256 bidPrice) public {
        bidPrice = bound(bidPrice, 1, 1_000e6); // $0.000001 to $1000 per oToken

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, bidPrice, bidPrice + 1, block.timestamp + 1 hours, 100e8);

        address userAddr = address(0xF100);
        usdc.mint(userAddr, 10_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        IERC20(oToken).approve(address(settler), type(uint256).max);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(userAddr);
        uint256 expectedPremium = (1e8 * bidPrice) / 1e8;

        vm.prank(userAddr);
        settler.executeOrder(oToken, 1e8, 2000e6);

        assertEq(usdc.balanceOf(userAddr), userBalBefore - 2000e6 + expectedPremium);
    }

    /// @notice executeOrder reverts on expired quote regardless of parameters
    function testFuzz_expiredQuoteAlwaysReverts(uint256 warpTime) public {
        warpTime = bound(warpTime, 1 hours + 1, 365 days);

        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        vm.prank(mm);
        priceSheet.publishQuote(oToken, 50e6, 52e6, block.timestamp + 1 hours, 100e8);

        address userAddr = address(0xF200);
        usdc.mint(userAddr, 10_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        IERC20(oToken).approve(address(settler), type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + warpTime);

        vm.prank(userAddr);
        vm.expectRevert(BatchSettler.QuoteInvalid.selector);
        settler.executeOrder(oToken, 1e8, 2000e6);
    }
}

// =============================================================================
// Fuzz Tests — MarginPool
// =============================================================================

contract MarginPoolFuzzTest is Test {
    AddressBook public addressBook;
    MarginPool public pool;
    Controller public controller;
    MockERC20 public usdc;

    address public user = address(0xBEEF);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        addressBook = new AddressBook();
        controller = new Controller(address(addressBook));
        pool = new MarginPool(address(addressBook));

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));

        usdc.mint(user, type(uint128).max);
        vm.prank(user);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @notice Any deposit amount increases pool balance correctly
    function testFuzz_depositIncreasesBalance(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);

        uint256 poolBefore = usdc.balanceOf(address(pool));

        vm.prank(address(controller));
        pool.transferToPool(address(usdc), user, amount);

        assertEq(usdc.balanceOf(address(pool)), poolBefore + amount);
    }

    /// @notice Non-controller can never call transferToPool
    function testFuzz_nonControllerCannotDeposit(address caller, uint256 amount) public {
        vm.assume(caller != address(controller));
        amount = bound(amount, 1, 1e18);

        vm.prank(caller);
        vm.expectRevert(MarginPool.OnlyController.selector);
        pool.transferToPool(address(usdc), user, amount);
    }

    /// @notice Non-controller can never call transferToUser
    function testFuzz_nonControllerCannotWithdraw(address caller, uint256 amount) public {
        vm.assume(caller != address(controller));
        amount = bound(amount, 1, 1e18);

        vm.prank(caller);
        vm.expectRevert(MarginPool.OnlyController.selector);
        pool.transferToUser(address(usdc), user, amount);
    }
}
