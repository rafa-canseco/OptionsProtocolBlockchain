// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OToken.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        factory.setOperator(address(this));
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

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        uint256 requiredCollateral = (amount * strikePrice) / 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), requiredCollateral);
        controller.mintOtoken(user, 1, oToken, amount, user);
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

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), collateral);

        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, 1, oToken, amount, user);
        vm.stopPrank();
    }

    /// @notice CALL with any amount should require amount * 1e10 WETH
    function testFuzz_callMintWithSufficientCollateral(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e8);

        address oToken = factory.createOToken(address(weth), address(usdc), address(weth), strikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);

        uint256 requiredCollateral = amount * 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(weth), requiredCollateral);
        controller.mintOtoken(user, 1, oToken, amount, user);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), amount);
    }

    /// @notice PUT settlement (physical): OTM = full collateral back, ITM = 0 back
    function testFuzz_putSettlementPayout(uint256 expiryPrice) public {
        // Price between $1 and $100,000
        expiryPrice = bound(expiryPrice, 1e8, 100_000e8);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        uint256 amount = 1e8;
        uint256 collateral = (amount * strikePrice) / 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), collateral);
        controller.mintOtoken(user, 1, oToken, amount, user);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(user);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, expiryPrice);

        vm.prank(user);
        controller.settleVault(user, 1);

        uint256 userBalAfter = usdc.balanceOf(user);
        uint256 returned = userBalAfter - userBalBefore;

        assertLe(returned, collateral);

        if (expiryPrice >= strikePrice) {
            // OTM or ATM: full collateral back
            assertEq(returned, collateral);
        } else {
            // ITM (physical settlement): user gets 0 back
            // Full collateral stays in MarginPool for physical delivery
            assertEq(returned, 0);
        }
    }

    /// @notice CALL settlement (physical): OTM = full collateral back, ITM = 0 back
    function testFuzz_callSettlementPayout(uint256 expiryPrice) public {
        expiryPrice = bound(expiryPrice, 1e8, 100_000e8);

        address oToken = factory.createOToken(address(weth), address(usdc), address(weth), strikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);

        uint256 amount = 1e8;
        uint256 collateral = amount * 1e10;

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(weth), collateral);
        controller.mintOtoken(user, 1, oToken, amount, user);
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
            // OTM or ATM: full collateral back
            assertEq(returned, collateral);
        } else {
            // ITM (physical settlement): user gets 0 back
            assertEq(returned, 0);
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
        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );
        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), address(this)))
                )
            )
        );
    }

    /// @notice Any non-zero price can be set for expiry
    function testFuzz_setExpiryPrice(uint256 price) public {
        vm.assume(price > 0);
        address asset = address(0x1111);

        vm.warp(1700000000);
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
    function testFuzz_nonOwnerOrOperatorCannotSetExpiryPrice(address caller, uint256 price) public {
        vm.assume(caller != address(this));
        vm.assume(caller != oracle.operator());
        vm.assume(price > 0);

        vm.prank(caller);
        vm.expectRevert(Oracle.OnlyOwnerOrOperator.selector);
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

    MockERC20 public weth;
    MockERC20 public usdc;

    uint256 public mmKey = 0xAA01;
    address public mm;
    uint256 nextQuoteId = 1;

    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        mm = vm.addr(mmKey);

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

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
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), mm, address(this)))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        factory.setOperator(address(this));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        settler.setWhitelistedMM(mm, true);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        usdc.mint(mm, type(uint128).max);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: deadline,
            quoteId: nextQuoteId++,
            maxAmount: maxAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice N users execute orders, all valid. N bounded to avoid gas issues.
    function testFuzz_multipleUsersExecuteOrders(uint8 rawCount) public {
        uint256 count = bound(uint256(rawCount), 1, 10);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        (BatchSettler.Quote memory q, bytes memory sig) =
            _signQuote(oToken, 50e6, block.timestamp + 1 hours, count * 1e8);

        for (uint256 i = 0; i < count; i++) {
            address userAddr = address(uint160(0xF000 + i));
            usdc.mint(userAddr, 10_000e6);
            vm.startPrank(userAddr);
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();

            vm.prank(userAddr);
            settler.executeOrder(q, sig, 1e8, 2000e6);
        }

        // oTokens custodied in settler for MM
        assertEq(settler.mmOTokenBalance(mm, oToken), count * 1e8);
    }

    /// @notice Fuzz premium via bidPrice — user always receives (amount * bidPrice) / 1e8
    function testFuzz_premiumCalculation(uint256 bidPrice) public {
        bidPrice = bound(bidPrice, 1, 1_000e6); // $0.000001 to $1000 per oToken

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, bidPrice, block.timestamp + 1 hours, 100e8);

        address userAddr = address(0xF100);
        usdc.mint(userAddr, 10_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(userAddr);
        uint256 expectedPremium = (1e8 * bidPrice) / 1e8;

        vm.prank(userAddr);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        assertEq(usdc.balanceOf(userAddr), userBalBefore - 2000e6 + expectedPremium);
    }

    /// @notice executeOrder reverts on expired quote regardless of parameters
    function testFuzz_expiredQuoteAlwaysReverts(uint256 warpTime) public {
        warpTime = bound(warpTime, 1 hours + 1, 365 days);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 50e6, block.timestamp + 1 hours, 100e8);

        address userAddr = address(0xF200);
        usdc.mint(userAddr, 10_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + warpTime);

        vm.prank(userAddr);
        vm.expectRevert(BatchSettler.QuoteExpired.selector);
        settler.executeOrder(q, sig, 1e8, 2000e6);
    }

    /// @notice Fuzz premium with treasury + feeBps + amount — user receives netPremium, not grossPremium
    function testFuzz_premiumCalculation_withFee(uint256 bidPrice, uint256 feeBps, uint256 amount) public {
        bidPrice = bound(bidPrice, 1, 1_000e6);
        feeBps = bound(feeBps, 1, 2000);
        amount = bound(amount, 1e8, 100e8);

        address treasury = address(0x7EA5);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(feeBps);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        (BatchSettler.Quote memory q, bytes memory sig) =
            _signQuote(oToken, bidPrice, block.timestamp + 1 hours, 1000e8);

        uint256 collateral = (amount * strikePrice) / 1e10;

        address userAddr = address(0xF100);
        usdc.mint(userAddr, 1_000_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(userAddr);
        uint256 grossPremium = (amount * bidPrice) / 1e8;
        uint256 fee = (grossPremium * feeBps) / 10000;
        uint256 netPremium = grossPremium - fee;

        vm.prank(userAddr);
        settler.executeOrder(q, sig, amount, collateral);

        assertEq(usdc.balanceOf(userAddr) + collateral - userBalBefore, netPremium);
        assertEq(usdc.balanceOf(treasury), fee);
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

// =============================================================================
// Mock contracts for physical delivery fuzz testing
// =============================================================================

contract FuzzMockAavePool {
    using SafeERC20 for IERC20;

    uint256 public constant FLASH_LOAN_FEE_BPS = 5; // 0.05%

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    )
        external
    {
        IERC20(asset).safeTransfer(receiverAddress, amount);
        uint256 premium = (amount * FLASH_LOAN_FEE_BPS) / 10_000;
        bool success =
            IFlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, receiverAddress, params);
        require(success, "Flash loan callback failed");
        IERC20(asset).safeTransferFrom(receiverAddress, address(this), amount + premium);
    }
}

/// @dev Uses token addresses (not amount magnitude) to determine swap direction.
///      The original MockSwapRouter in BatchSettler.t.sol uses a >1e12 heuristic
///      that breaks when USDC amounts exceed $1M (e.g. 1M oTokens * $2000 strike).
contract FuzzMockSwapRouter {
    using SafeERC20 for IERC20;

    uint256 public mockEthPriceUsdc;
    address public weth;
    address public usdc;

    constructor(uint256 _mockEthPriceUsdc, address _weth, address _usdc) {
        mockEthPriceUsdc = _mockEthPriceUsdc;
        weth = _weth;
        usdc = _usdc;
    }

    function setMockPrice(uint256 _price) external {
        mockEthPriceUsdc = _price;
    }

    function exactOutputSingle(ISwapRouter.ExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn)
    {
        if (params.tokenOut == weth) {
            // Buying WETH with USDC: amountIn (USDC) = amountOut (WETH) * price / 1e18
            amountIn = (params.amountOut * mockEthPriceUsdc) / 1e18;
        } else {
            // Buying USDC with WETH: amountIn (WETH) = amountOut (USDC) * 1e18 / price
            amountIn = (params.amountOut * 1e18) / mockEthPriceUsdc;
        }

        require(amountIn <= params.amountInMaximum, "Too much slippage");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, params.amountOut);

        return amountIn;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        if (params.tokenIn == weth) {
            // Selling WETH for USDC: amountOut (USDC) = amountIn (WETH) * price / 1e18
            amountOut = (params.amountIn * mockEthPriceUsdc) / 1e18;
        } else {
            // Selling USDC for WETH: amountOut (WETH) = amountIn (USDC) * 1e18 / price
            amountOut = (params.amountIn * 1e18) / mockEthPriceUsdc;
        }

        require(amountOut >= params.amountOutMinimum, "Too much slippage");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);

        return amountOut;
    }
}

// =============================================================================
// Fuzz Tests — Physical Delivery
// =============================================================================

contract PhysicalRedeemFuzzTest is Test {
    using SafeERC20 for IERC20;

    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;

    MockERC20 public weth;
    MockERC20 public usdc;
    FuzzMockAavePool public mockAave;
    FuzzMockSwapRouter public mockRouter;

    uint256 public mmKey = 0xAA01;
    address public mm;
    uint256 nextQuoteId = 1;

    address public alice = address(0xA11CE);
    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        mm = vm.addr(mmKey);

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        mockAave = new FuzzMockAavePool();
        mockRouter = new FuzzMockSwapRouter(1800e6, address(weth), address(usdc));

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
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), mm, address(this)))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        factory.setOperator(address(this));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        settler.setWhitelistedMM(mm, true);
        settler.setAavePool(address(mockAave));
        settler.setSwapRouter(address(mockRouter));
        settler.setSwapFeeTier(500);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        // Fund everyone generously for any fuzzed amount
        usdc.mint(mm, type(uint128).max);
        weth.mint(mm, type(uint128).max);
        vm.startPrank(mm);
        usdc.approve(address(settler), type(uint256).max);
        weth.approve(address(settler), type(uint256).max);
        vm.stopPrank();

        usdc.mint(alice, type(uint128).max);
        weth.mint(alice, type(uint128).max);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        weth.mint(address(mockAave), type(uint128).max);
        usdc.mint(address(mockAave), type(uint128).max);
        weth.mint(address(mockRouter), type(uint128).max);
        usdc.mint(address(mockRouter), type(uint128).max);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: deadline,
            quoteId: nextQuoteId++,
            maxAmount: maxAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice PUT ITM: user receives exactly amount * 1e10 WETH for any amount
    function testFuzz_physicalRedeem_putITM_amount(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e8);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        uint256 collateral = (amount * strikePrice) / 1e10;

        // Use bidPrice = 1e8 to avoid premium truncation for tiny amounts
        (BatchSettler.Quote memory q, bytes memory sig) =
            _signQuote(oToken, 1e8, block.timestamp + 1 hours, type(uint128).max);

        vm.prank(alice);
        settler.executeOrder(q, sig, amount, collateral);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);

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

        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Physical delivery
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, amount, collateral, mm);

        // User receives exactly amount * 1e10 WETH
        assertEq(weth.balanceOf(alice), aliceWethBefore + amount * 1e10);

        // Settler retains no residual tokens
        assertEq(weth.balanceOf(address(settler)), 0);
        assertEq(usdc.balanceOf(address(settler)), 0);
    }

    /// @notice CALL ITM: user receives exactly (amount * strikePrice) / 1e10 USDC for any amount
    function testFuzz_physicalRedeem_callITM_amount(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e8);

        address oToken = factory.createOToken(address(weth), address(usdc), address(weth), strikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);

        uint256 collateral = amount * 1e10;

        (BatchSettler.Quote memory q, bytes memory sig) =
            _signQuote(oToken, 1e8, block.timestamp + 1 hours, type(uint128).max);

        vm.prank(alice);
        settler.executeOrder(q, sig, amount, collateral);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        // Expire ITM (ETH > strike)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);
        mockRouter.setMockPrice(2500e6);

        // Settle vault
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Physical delivery — slippageParam = minAmountOut for calls
        uint256 minOut = (amount * strikePrice) / 1e10;
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, amount, minOut, mm);

        // User receives exactly (amount * strikePrice) / 1e10 USDC
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + (amount * strikePrice) / 1e10);

        // Settler retains no residual tokens
        assertEq(weth.balanceOf(address(settler)), 0);
        assertEq(usdc.balanceOf(address(settler)), 0);
    }

    /// @notice PUT ITM: physicalRedeem succeeds for any ITM expiry price
    function testFuzz_physicalRedeem_putITM_expiryPrice(uint256 expiryPrice) public {
        // Upper bound leaves margin for Aave flash loan fee (5 bps).
        // At expiryPrice ≈ strike, swap cost ≈ collateral + flash loan fee > collateral → reverts.
        expiryPrice = bound(expiryPrice, 1e8, strikePrice * 9990 / 10000);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        uint256 amount = 1e8;
        uint256 collateral = (amount * strikePrice) / 1e10;

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        settler.executeOrder(q, sig, amount, collateral);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, expiryPrice);
        mockRouter.setMockPrice(expiryPrice / 100);

        // Settle vault
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 aliceWethBefore = weth.balanceOf(alice);

        // Physical delivery
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, amount, collateral, mm);

        // User receives exactly amount * 1e10 WETH
        assertEq(weth.balanceOf(alice), aliceWethBefore + amount * 1e10);

        // Settler retains no residual tokens
        assertEq(weth.balanceOf(address(settler)), 0);
        assertEq(usdc.balanceOf(address(settler)), 0);
    }

    /// @notice CALL ITM: physicalRedeem succeeds for any ITM expiry price
    function testFuzz_physicalRedeem_callITM_expiryPrice(uint256 expiryPrice) public {
        // Lower bound leaves margin for Aave flash loan fee (5 bps).
        // At expiryPrice ≈ strike, swap cost ≈ collateral + flash loan fee > collateral → reverts.
        expiryPrice = bound(expiryPrice, strikePrice * 10010 / 10000, 100_000e8);

        address oToken = factory.createOToken(address(weth), address(usdc), address(weth), strikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);

        uint256 amount = 1e8;
        uint256 collateral = amount * 1e10;

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, 50e6, block.timestamp + 1 hours, 100e8);

        vm.prank(alice);
        settler.executeOrder(q, sig, amount, collateral);

        vm.prank(mm);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, expiryPrice);
        mockRouter.setMockPrice(expiryPrice / 100);

        // Settle vault
        address[] memory owners = new address[](1);
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = alice;
        vaultIds[0] = 1;
        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        // Physical delivery — slippageParam = minAmountOut for calls
        uint256 minOut = (amount * strikePrice) / 1e10;
        vm.prank(mm);
        settler.physicalRedeem(oToken, alice, amount, minOut, mm);

        // User receives exactly (amount * strikePrice) / 1e10 USDC
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + (amount * strikePrice) / 1e10);

        // Settler retains no residual tokens
        assertEq(weth.balanceOf(address(settler)), 0);
        assertEq(usdc.balanceOf(address(settler)), 0);
    }
}

// =============================================================================
// Fuzz Tests — Protocol Fee
// =============================================================================

contract ProtocolFeeFuzzTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;

    MockERC20 public weth;
    MockERC20 public usdc;

    uint256 public mmKey = 0xAA01;
    address public mm;
    uint256 nextQuoteId = 1;

    address public treasury = address(0x7EA5);
    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        mm = vm.addr(mmKey);

        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

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
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), mm, address(this)))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        factory.setOperator(address(this));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        settler.setWhitelistedMM(mm, true);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        usdc.mint(mm, type(uint128).max);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: deadline,
            quoteId: nextQuoteId++,
            maxAmount: maxAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice netPremium + fee == grossPremium for any bidPrice, feeBps, and amount
    function testFuzz_protocolFee_arithmetic(uint256 bidPrice, uint256 feeBps, uint256 amount) public {
        bidPrice = bound(bidPrice, 1, 1_000e6);
        feeBps = bound(feeBps, 0, 2000);
        amount = bound(amount, 1e8, 100e8);

        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(feeBps);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        (BatchSettler.Quote memory q, bytes memory sig) =
            _signQuote(oToken, bidPrice, block.timestamp + 1 hours, type(uint128).max);

        uint256 collateral = (amount * strikePrice) / 1e10;

        address userAddr = address(0xF100);
        usdc.mint(userAddr, collateral + 1_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(userAddr);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);
        uint256 mmBalBefore = usdc.balanceOf(mm);

        uint256 grossPremium = (amount * bidPrice) / 1e8;
        uint256 expectedFee = (grossPremium * feeBps) / 10000;
        uint256 expectedNet = grossPremium - expectedFee;

        vm.prank(userAddr);
        settler.executeOrder(q, sig, amount, collateral);

        uint256 actualNet = usdc.balanceOf(userAddr) + collateral - userBalBefore;
        uint256 actualFee = usdc.balanceOf(treasury) - treasuryBalBefore;

        // Core invariant: net + fee == gross
        assertEq(actualNet + actualFee, grossPremium);
        assertEq(actualNet, expectedNet);
        assertEq(actualFee, expectedFee);
        // MM always pays grossPremium
        assertEq(mmBalBefore - usdc.balanceOf(mm), grossPremium);
    }

    /// @notice feeBps=0 → fee=0, user receives full grossPremium
    function testFuzz_protocolFee_zeroBps(uint256 bidPrice) public {
        bidPrice = bound(bidPrice, 1, 1_000e6);

        settler.setTreasury(treasury);
        // protocolFeeBps defaults to 0

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, bidPrice, block.timestamp + 1 hours, 100e8);

        address userAddr = address(0xF100);
        usdc.mint(userAddr, 10_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(userAddr);
        uint256 grossPremium = bidPrice;

        vm.prank(userAddr);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        assertEq(usdc.balanceOf(userAddr), userBalBefore - 2000e6 + grossPremium);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    /// @notice treasury=address(0) → fee=0 regardless of feeBps
    function testFuzz_protocolFee_noTreasury(uint256 bidPrice, uint256 feeBps) public {
        bidPrice = bound(bidPrice, 1, 1_000e6);
        feeBps = bound(feeBps, 1, 2000);

        // treasury defaults to address(0), only set feeBps
        settler.setProtocolFeeBps(feeBps);

        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oToken, bidPrice, block.timestamp + 1 hours, 100e8);

        address userAddr = address(0xF100);
        usdc.mint(userAddr, 10_000e6);
        vm.startPrank(userAddr);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        uint256 userBalBefore = usdc.balanceOf(userAddr);
        uint256 grossPremium = bidPrice;

        vm.prank(userAddr);
        settler.executeOrder(q, sig, 1e8, 2000e6);

        // User receives full grossPremium despite feeBps being set
        assertEq(usdc.balanceOf(userAddr), userBalBefore - 2000e6 + grossPremium);
    }
}
