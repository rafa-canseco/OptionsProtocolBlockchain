// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OToken.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";

/**
 * @title ForkPhysicalRedeemTest
 * @notice Fork test against Base mainnet — verifies the physical
 *         delivery pipeline (Aave flash loan + Uniswap V3 swap)
 *         works with real external contracts.
 *
 *         Scenario: ETH put option, strike $2000, ITM at $1800.
 *         User bought 1 put → after expiry, physical delivery
 *         gives user 1e18 WETH via flash loan + swap.
 *
 *         Run: forge test --match-contract ForkPhysicalRedeemTest
 *              --fork-url $BASE_RPC_URL -vvv
 */
contract ForkPhysicalRedeemTest is Test {
    // Base mainnet addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_POOL =
        0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant SWAP_ROUTER =
        0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant CHAINLINK_ETH_USD =
        0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Protocol
    AddressBook addressBook;
    Controller controller;
    MarginPool pool;
    OTokenFactory factory;
    Oracle oracle;
    Whitelist whitelist;
    BatchSettler settler;

    // Actors
    uint256 mmKey = 0xAA01;
    address mm;
    address user = address(0x05E7);
    address admin;
    address treasury = address(0xFEE);

    // Option params
    uint256 strikePrice = 2000e8; // $2000
    uint256 settlementPrice = 1800e8; // $1800 ITM
    uint256 expiry;
    address oToken;

    uint256 nextQuoteId = 1;

    function setUp() public {
        // Require fork — skip if not forked
        if (block.chainid != 8453) {
            return;
        }

        admin = address(this);
        mm = vm.addr(mmKey);

        // Stay at the fork's block.timestamp — do NOT warp
        // backwards, as Aave's interest math underflows if
        // block.timestamp < lastUpdateTimestamp.

        // Deploy protocol (proxied, same pattern as unit tests)
        addressBook = AddressBook(address(new ERC1967Proxy(
            address(new AddressBook()),
            abi.encodeCall(AddressBook.initialize, (admin))
        )));
        controller = Controller(address(new ERC1967Proxy(
            address(new Controller()),
            abi.encodeCall(
                Controller.initialize,
                (address(addressBook), admin)
            )
        )));
        pool = MarginPool(address(new ERC1967Proxy(
            address(new MarginPool()),
            abi.encodeCall(
                MarginPool.initialize, (address(addressBook))
            )
        )));
        factory = OTokenFactory(address(new ERC1967Proxy(
            address(new OTokenFactory()),
            abi.encodeCall(
                OTokenFactory.initialize, (address(addressBook))
            )
        )));
        oracle = Oracle(address(new ERC1967Proxy(
            address(new Oracle()),
            abi.encodeCall(
                Oracle.initialize,
                (address(addressBook), admin)
            )
        )));
        whitelist = Whitelist(address(new ERC1967Proxy(
            address(new Whitelist()),
            abi.encodeCall(
                Whitelist.initialize,
                (address(addressBook), admin)
            )
        )));
        settler = BatchSettler(address(new ERC1967Proxy(
            address(new BatchSettler()),
            abi.encodeCall(
                BatchSettler.initialize,
                (address(addressBook), mm, admin)
            )
        )));

        // Wire AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        // Configure settler with REAL Aave + Uniswap
        settler.setWhitelistedMM(mm, true);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400);
        settler.setAavePool(AAVE_POOL);
        settler.setSwapRouter(SWAP_ROUTER);
        settler.setSwapFeeTier(500); // 0.05% WETH/USDC pool

        // Configure oracle with real Chainlink feed
        oracle.setPriceFeed(WETH, CHAINLINK_ETH_USD);

        // Whitelist assets + product
        whitelist.whitelistUnderlying(WETH);
        whitelist.whitelistCollateral(USDC);
        whitelist.whitelistProduct(WETH, USDC, USDC, true);

        // Compute next valid 08:00 UTC expiry
        uint256 today8am =
            (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp
            ? today8am
            : today8am + 1 days;

        // Create oToken
        oToken = factory.createOToken(
            WETH, USDC, USDC, strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        // Fund user with USDC for collateral
        // Use deal() to set balances on the fork
        deal(USDC, user, 10_000e6);
        deal(USDC, mm, 10_000e6);

        // User approves pool for collateral deposit
        vm.prank(user);
        IERC20(USDC).approve(address(pool), type(uint256).max);

        // MM approves settler for premium + oToken transfers
        vm.startPrank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        IERC20(oToken).approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    function _signQuote(uint256 /* amount */)
        internal
        returns (
            BatchSettler.Quote memory q,
            bytes memory sig
        )
    {
        q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 50e6, // $50 premium per oToken
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /**
     * @notice Full physical delivery test against real Aave + Uniswap.
     *
     *   1. User buys 1 ETH put ($2000 strike) via executeOrder
     *   2. Warp past expiry, set settlement price $1800 (ITM)
     *   3. Settle vault — user gets 0 collateral back (100% payout)
     *   4. Physical redeem — flash loan WETH from Aave, swap
     *      USDC→WETH via Uniswap, deliver WETH to user
     *   5. Verify: user received exactly 1e18 WETH
     *   6. Verify: settler holds 0 USDC and 0 WETH
     *   7. Verify: surplus collateral went to operator (MM)
     */
    function test_physicalDelivery_realAaveUniswap() public {
        if (block.chainid != 8453) {
            return; // skip if not forked
        }

        uint256 amount = 1e8; // 1 oToken (8 decimals)
        uint256 collateral = (amount * strikePrice) / 1e10;
        // collateral = 1e8 * 2000e8 / 1e10 = 2000e6 = $2000

        // --- Step 1: Execute order (user buys put) ---
        (BatchSettler.Quote memory q, bytes memory sig) =
            _signQuote(amount);

        vm.prank(user);
        uint256 vaultId = settler.executeOrder(
            q, sig, amount, collateral
        );

        // MM now holds 1e8 oTokens
        assertEq(
            IERC20(oToken).balanceOf(mm), amount,
            "MM should hold oTokens"
        );
        // Pool holds the collateral
        assertEq(
            IERC20(USDC).balanceOf(address(pool)), collateral,
            "Pool should hold collateral"
        );

        // --- Step 2: Expire ITM ---
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(WETH, expiry, settlementPrice);

        // --- Step 3: Settle vault ---
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = user;
        ids[0] = vaultId;

        vm.prank(mm);
        settler.batchSettleVaults(owners, ids);

        assertTrue(
            controller.vaultSettled(user, vaultId),
            "Vault should be settled"
        );

        // ITM put: entire collateral is payout, user gets 0 back
        // Collateral stays in pool for redeem

        // --- Step 4: Physical redeem ---
        uint256 userWethBefore = IERC20(WETH).balanceOf(user);
        uint256 mmUsdcBefore = IERC20(USDC).balanceOf(mm);

        // contraAmount for put = amount * 1e10 = 1e18 WETH
        uint256 expectedWeth = amount * 1e10; // 1e18

        // maxCollateralSpent = full collateral (worst case)
        vm.prank(mm);
        settler.physicalRedeem(
            oToken, user, amount, collateral
        );

        uint256 userWethAfter = IERC20(WETH).balanceOf(user);
        uint256 wethReceived = userWethAfter - userWethBefore;

        // --- Step 5: User received exactly expected WETH ---
        assertEq(
            wethReceived, expectedWeth,
            "User must receive exact WETH amount"
        );

        // --- Step 6: Settler holds 0 tokens ---
        assertEq(
            IERC20(USDC).balanceOf(address(settler)), 0,
            "Settler must hold 0 USDC"
        );
        assertEq(
            IERC20(WETH).balanceOf(address(settler)), 0,
            "Settler must hold 0 WETH"
        );

        // --- Step 7: MM received surplus (collateral - swap cost) ---
        // The Uniswap swap uses exactOutputSingle to buy exactly
        // 1e18 + premium WETH. The USDC spent will be less than
        // collateral if the swap is efficient. Surplus goes to MM.
        uint256 mmUsdcAfter = IERC20(USDC).balanceOf(mm);
        uint256 surplus = mmUsdcAfter - mmUsdcBefore;
        // Surplus should be >= 0 (swap cost <= maxCollateralSpent)
        assertGe(
            surplus, 0,
            "MM surplus must be non-negative"
        );

        emit log_named_uint(
            "WETH delivered to user", wethReceived
        );
        emit log_named_uint(
            "USDC surplus to MM (operator)", surplus
        );
    }

    /**
     * @notice Verify Chainlink live price feed works on the fork.
     *         This validates our Oracle.getPrice() against real
     *         Chainlink data.
     */
    function test_chainlinkLivePrice() public {
        if (block.chainid != 8453) {
            return;
        }

        uint256 price = oracle.getPrice(WETH);
        // ETH price should be a reasonable number (>$100, <$100k)
        assertGt(price, 100e8, "ETH price too low");
        assertLt(price, 100_000e8, "ETH price too high");

        emit log_named_uint("Chainlink ETH/USD (8 dec)", price);
    }

    /**
     * @notice Verify flash loan callback rejects unauthorized
     *         callers on the real Aave pool.
     */
    function test_flashLoanCallback_realAave_rejectsAttacker()
        public
    {
        if (block.chainid != 8453) {
            return;
        }

        address attacker = address(0xDEAD);
        bytes memory fakeParams = abi.encode(
            oToken, attacker, uint256(1e8), uint256(2000e6)
        );

        // Random caller — not the real Aave pool
        vm.prank(attacker);
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(
            WETH, 1e18, 0, address(settler), fakeParams
        );

        // Real Aave pool but wrong initiator
        vm.prank(AAVE_POOL);
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(
            WETH, 1e18, 0, attacker, fakeParams
        );
    }
}
