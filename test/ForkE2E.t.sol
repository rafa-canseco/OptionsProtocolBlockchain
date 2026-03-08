// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/OToken.sol";

/**
 * @title ForkE2E
 * @notice Supplementary fork tests for scenarios NOT covered by
 *         ForkPhysicalRedeem.t.sol: escape hatch, emergency withdraw,
 *         multi-MM ledgers, oracle deviation guard, and user PnL.
 *
 *         Run:
 *         forge test --match-contract ForkE2E --fork-url $BASE_RPC_URL -vvv
 */
contract ForkE2E is Test {
    // --- Base mainnet addresses ---
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    uint24 constant SWAP_FEE_TIER = 3000;

    // --- Protocol contracts ---
    AddressBook addressBook;
    Controller controller;
    MarginPool pool;
    OTokenFactory factory;
    Oracle oracle;
    Whitelist whitelist;
    BatchSettler settler;

    // --- Actors ---
    address deployer = makeAddr("deployer");
    address operatorBot = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address mm;

    uint256 mmPrivateKey = 0xBEEF;

    // --- Option params ---
    uint256 expiry;
    uint256 strikePrice = 2000e8;

    // --- Protocol fee ---
    uint256 constant FEE_BPS = 400;

    function setUp() public {
        mm = vm.addr(mmPrivateKey);
        vm.label(mm, "MM");

        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        vm.startPrank(deployer);

        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (deployer))))
        );

        controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), deployer))
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
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), deployer))
                )
            )
        );

        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), deployer))
                )
            )
        );

        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operatorBot, deployer))
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

        whitelist.whitelistUnderlying(WETH);
        whitelist.whitelistCollateral(USDC);
        whitelist.whitelistCollateral(WETH);
        whitelist.whitelistProduct(WETH, USDC, USDC, true);
        whitelist.whitelistProduct(WETH, USDC, WETH, false);

        oracle.setPriceFeed(WETH, CHAINLINK_ETH_USD);
        oracle.setPriceDeviationThreshold(1000);
        oracle.setMaxOracleStaleness(3600);

        settler.setAavePool(AAVE_V3_POOL);
        settler.setSwapRouter(UNISWAP_ROUTER);
        settler.setSwapFeeTier(SWAP_FEE_TIER);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(FEE_BPS);
        settler.setWhitelistedMM(mm, true);
        settler.setEscapeDelay(3 days);

        controller.setPartialPauser(operatorBot);

        vm.stopPrank();

        deal(USDC, alice, 100_000e6);
        deal(WETH, alice, 50e18);
        deal(USDC, mm, 100_000e6);
        deal(WETH, mm, 50e18);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        IERC20(WETH).approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    // ================================================================
    //                      HELPER FUNCTIONS
    // ================================================================

    function _mockChainlinkFresh(uint256 price) internal {
        vm.mockCall(
            CHAINLINK_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1))
        );
    }

    function _createPut(uint256 strike) internal returns (address) {
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(deployer);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _signQuote(BatchSettler.Quote memory quote) internal view returns (bytes memory) {
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _executeOrder(address oToken, uint256 amount, uint256 bidPrice, uint256 collateral)
        internal
        returns (uint256 vaultId)
    {
        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: block.timestamp + 1 hours,
            quoteId: 0,
            maxAmount: amount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes memory sig = _signQuote(quote);

        vm.prank(alice);
        vaultId = settler.executeOrder(quote, sig, amount, collateral);
    }

    function _settleVault(address owner, uint256 vaultId) internal {
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = owner;
        ids[0] = vaultId;
        vm.prank(operatorBot);
        settler.batchSettleVaults(owners, ids);
    }

    function _redeemForMM(address oToken, uint256 amount) internal {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = oToken;
        amounts[0] = amount;
        vm.prank(operatorBot);
        settler.operatorRedeemForMM(mm, tokens, amounts);
    }

    // ================================================================
    //              TEST: MM ESCAPE HATCH (self-redeem)
    // ================================================================

    function test_mmSelfRedeem_afterEscapeDelay() public {
        address oToken = _createPut(strikePrice);
        uint256 amount = 1e8;
        uint256 bidPrice = 50e6;
        uint256 collateral = 2000e6;

        uint256 vaultId = _executeOrder(oToken, amount, bidPrice, collateral);

        // ITM
        vm.warp(expiry + 1);
        _mockChainlinkFresh(1800e8);
        vm.prank(deployer);
        oracle.setExpiryPrice(WETH, expiry, 1800e8);
        _settleVault(alice, vaultId);

        // Too early — should revert
        vm.warp(expiry + 1 days);
        vm.prank(mm);
        vm.expectRevert(abi.encodeWithSignature("EscapeNotReady()"));
        settler.mmSelfRedeem(oToken, amount);

        // After escape delay (3 days)
        vm.warp(expiry + 3 days + 1);
        uint256 mmUsdcBefore = IERC20(USDC).balanceOf(mm);
        vm.prank(mm);
        settler.mmSelfRedeem(oToken, amount);

        assertEq(IERC20(USDC).balanceOf(mm) - mmUsdcBefore, collateral, "mm self-redeems full collateral");
        assertEq(settler.mmOTokenBalance(mm, oToken), 0, "mm ledger cleared");
    }

    // ================================================================
    //              TEST: EMERGENCY WITHDRAW
    // ================================================================

    function test_emergencyWithdraw_returnsCollateral() public {
        address oToken = _createPut(strikePrice);
        uint256 amount = 1e8;
        uint256 bidPrice = 50e6;
        uint256 collateral = 2000e6;

        _executeOrder(oToken, amount, bidPrice, collateral);

        vm.prank(deployer);
        controller.setSystemFullyPaused(true);

        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        controller.emergencyWithdrawVault(1);

        assertEq(
            IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, collateral, "alice gets full collateral back in emergency"
        );

        assertEq(settler.mmOTokenBalance(mm, oToken), 0, "mm ledger cleared after emergency");
    }

    // ================================================================
    //         TEST: MULTIPLE MMs ON SAME OTOKEN
    // ================================================================

    function test_multipleMMs_independentLedgers() public {
        uint256 mm2Key = 0xCAFE;
        address mm2 = vm.addr(mm2Key);
        vm.label(mm2, "MM2");
        deal(USDC, mm2, 100_000e6);
        vm.prank(mm2);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        vm.prank(deployer);
        settler.setWhitelistedMM(mm2, true);

        address oToken = _createPut(strikePrice);
        uint256 amount = 1e8;
        uint256 bidPrice = 50e6;
        uint256 collateral = 2000e6;

        // Order 1: alice writes, mm1 buys
        _executeOrder(oToken, amount, bidPrice, collateral);

        // Order 2: alice writes again, mm2 buys
        BatchSettler.Quote memory quote2 = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: block.timestamp + 1 hours,
            quoteId: 0,
            maxAmount: amount,
            makerNonce: settler.makerNonce(mm2)
        });
        bytes32 digest2 = settler.hashQuote(quote2);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(mm2Key, digest2);
        bytes memory sig2 = abi.encodePacked(r2, s2, v2);

        vm.prank(alice);
        settler.executeOrder(quote2, sig2, amount, collateral);

        // Verify independent ledgers
        assertEq(settler.mmOTokenBalance(mm, oToken), amount, "mm1 has 1 oToken");
        assertEq(settler.mmOTokenBalance(mm2, oToken), amount, "mm2 has 1 oToken");
        assertEq(IERC20(oToken).balanceOf(address(settler)), 2 * amount, "settler holds total");

        // ITM settlement
        vm.warp(expiry + 1);
        _mockChainlinkFresh(1800e8);
        vm.prank(deployer);
        oracle.setExpiryPrice(WETH, expiry, 1800e8);
        _settleVault(alice, 1);
        _settleVault(alice, 2);

        // Redeem mm1 only
        _redeemForMM(oToken, amount);
        assertEq(settler.mmOTokenBalance(mm, oToken), 0, "mm1 cleared");
        assertEq(settler.mmOTokenBalance(mm2, oToken), amount, "mm2 untouched");

        // Redeem mm2
        address[] memory tokens = new address[](1);
        uint256[] memory amts = new uint256[](1);
        tokens[0] = oToken;
        amts[0] = amount;
        vm.prank(operatorBot);
        settler.operatorRedeemForMM(mm2, tokens, amts);
        assertEq(settler.mmOTokenBalance(mm2, oToken), 0, "mm2 cleared");
    }

    // ================================================================
    //         TEST: CHAINLINK PRICE DEVIATION GUARD
    // ================================================================

    function test_oracleDeviationGuard_reverts() public {
        _createPut(strikePrice);

        vm.warp(expiry + 1);

        // Mock Chainlink fresh at $2000, then try to set $1000 (50% deviation > 10% threshold)
        _mockChainlinkFresh(2000e8);
        vm.prank(deployer);
        vm.expectRevert();
        oracle.setExpiryPrice(WETH, expiry, 1000e8);
    }

    // ================================================================
    //         TEST: FULL E2E — USER PERSPECTIVE
    // ================================================================

    function test_userPerspective_putWriterNetPnL() public {
        address oToken = _createPut(strikePrice);
        uint256 amount = 1e8;
        uint256 bidPrice = 50e6;
        uint256 collateral = 2000e6;

        uint256 aliceUsdcStart = IERC20(USDC).balanceOf(alice);

        uint256 vaultId = _executeOrder(oToken, amount, bidPrice, collateral);

        // OTM expiry — alice profits from premium
        vm.warp(expiry + 1);
        _mockChainlinkFresh(2100e8);
        vm.prank(deployer);
        oracle.setExpiryPrice(WETH, expiry, 2100e8);

        _settleVault(alice, vaultId);

        uint256 aliceUsdcEnd = IERC20(USDC).balanceOf(alice);

        uint256 grossPremium = (amount * bidPrice) / 1e8;
        uint256 fee = (grossPremium * FEE_BPS) / 10000;
        uint256 netPremium = grossPremium - fee;

        assertEq(aliceUsdcEnd - aliceUsdcStart, netPremium, "writer net profit = net premium (OTM)");
    }
}
