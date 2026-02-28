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
 *         works with real external contracts for both PUT and CALL.
 *
 *         Pinned to block 42733000 for deterministic results.
 *
 *         Run: forge test --match-contract ForkPhysicalRedeemTest
 *              --fork-url $BASE_RPC_URL -vvv
 */
contract ForkPhysicalRedeemTest is Test {
    // Base mainnet addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    // Pinned block for deterministic fork
    uint256 constant FORK_BLOCK = 42733000;

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
    uint256 strikePrice = 2000e8;
    uint256 expiry;
    address putOToken;
    address callOToken;

    uint256 nextQuoteId = 1;

    modifier onlyFork() {
        if (block.chainid != 8453) {
            emit log("SKIPPED: requires --fork-url (Base chainId 8453)");
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 8453) return;

        // Pin to specific block for determinism
        vm.rollFork(FORK_BLOCK);

        admin = address(this);
        mm = vm.addr(mmKey);

        _deployProtocol();
        _configureSettler();
        _createOptions();
        _fundActors();
    }

    function _deployProtocol() private {
        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (admin))))
        );
        controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), admin))
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
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), admin))
                )
            )
        );
        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), admin))
                )
            )
        );
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), mm, admin))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    function _configureSettler() private {
        settler.setWhitelistedMM(mm, true);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400);
        settler.setAavePool(AAVE_POOL);
        settler.setSwapRouter(SWAP_ROUTER);
        settler.setSwapFeeTier(500);

        oracle.setPriceFeed(WETH, CHAINLINK_ETH_USD);

        whitelist.whitelistUnderlying(WETH);
        whitelist.whitelistCollateral(USDC);
        whitelist.whitelistCollateral(WETH);
        whitelist.whitelistProduct(WETH, USDC, USDC, true);
        whitelist.whitelistProduct(WETH, USDC, WETH, false);
    }

    function _createOptions() private {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        putOToken = factory.createOToken(WETH, USDC, USDC, strikePrice, expiry, true);
        callOToken = factory.createOToken(WETH, USDC, WETH, strikePrice, expiry, false);
        whitelist.whitelistOToken(putOToken);
        whitelist.whitelistOToken(callOToken);
    }

    function _fundActors() private {
        deal(USDC, user, 100_000e6);
        deal(USDC, mm, 100_000e6);
        deal(WETH, user, 100e18);
        deal(WETH, mm, 100e18);

        vm.startPrank(user);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        IERC20(WETH).approve(address(settler), type(uint256).max);
        IERC20(putOToken).approve(address(settler), type(uint256).max);
        IERC20(callOToken).approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    function _signQuote(address _oToken) internal returns (BatchSettler.Quote memory q, bytes memory sig) {
        q = BatchSettler.Quote({
            oToken: _oToken,
            bidPrice: 50e6,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // --- PUT physical delivery (collateral=USDC, user receives WETH) ---

    function test_physicalDelivery_put_realAaveUniswap() public onlyFork {
        uint256 amount = 1e8;
        uint256 collateral = (amount * strikePrice) / 1e10; // 2000 USDC

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(putOToken);
        vm.prank(user);
        uint256 vaultId = settler.executeOrder(q, sig, amount, collateral);

        // Expire ITM (put: price < strike)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(WETH, expiry, 1800e8);

        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = user;
        ids[0] = vaultId;
        vm.prank(mm);
        settler.batchSettleVaults(owners, ids);

        uint256 userWethBefore = IERC20(WETH).balanceOf(user);
        uint256 expectedWeth = amount * 1e10; // 1e18

        vm.prank(mm);
        settler.physicalRedeem(putOToken, user, amount, collateral);

        uint256 wethReceived = IERC20(WETH).balanceOf(user) - userWethBefore;
        assertEq(wethReceived, expectedWeth, "User must receive exact WETH");
        assertEq(IERC20(USDC).balanceOf(address(settler)), 0, "Settler 0 USDC");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "Settler 0 WETH");

        emit log_named_uint("PUT: WETH delivered to user", wethReceived);
    }

    // --- CALL physical delivery (collateral=WETH, user receives USDC) ---

    function test_physicalDelivery_call_realAaveUniswap() public onlyFork {
        uint256 amount = 1e8; // 1 call option
        uint256 collateral = amount * 1e10; // 1e18 WETH

        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(callOToken);
        vm.prank(user);
        uint256 vaultId = settler.executeOrder(q, sig, amount, collateral);

        assertEq(IERC20(callOToken).balanceOf(mm), amount, "MM holds call oTokens");
        assertEq(IERC20(WETH).balanceOf(address(pool)), collateral, "Pool holds WETH collateral");

        // Expire ITM (call: price > strike)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(WETH, expiry, 2200e8);

        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = user;
        ids[0] = vaultId;
        vm.prank(mm);
        settler.batchSettleVaults(owners, ids);
        assertTrue(controller.vaultSettled(user, vaultId), "Vault settled");

        // Physical delivery: user receives USDC (strikeAsset)
        // contraAmount = (amount * strike) / 1e10 = 2000e6
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(user);
        uint256 expectedUsdc = (amount * strikePrice) / 1e10;

        vm.prank(mm);
        settler.physicalRedeem(callOToken, user, amount, collateral);

        uint256 usdcReceived = IERC20(USDC).balanceOf(user) - userUsdcBefore;
        assertEq(usdcReceived, expectedUsdc, "User must receive exact USDC");
        assertEq(IERC20(USDC).balanceOf(address(settler)), 0, "Settler 0 USDC");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "Settler 0 WETH");

        emit log_named_uint("CALL: USDC delivered to user", usdcReceived);
    }

    // --- Chainlink price sanity ---

    function test_chainlinkLivePrice() public onlyFork {
        uint256 price = oracle.getPrice(WETH);
        assertGt(price, 100e8, "ETH price too low");
        assertLt(price, 100_000e8, "ETH price too high");

        emit log_named_uint("Chainlink ETH/USD (8 dec)", price);
    }

    // --- Flash loan callback rejection ---

    function test_flashLoanCallback_realAave_rejectsAttacker() public onlyFork {
        address attacker = address(0xDEAD);
        bytes memory fakeParams = abi.encode(putOToken, attacker, uint256(1e8), uint256(2000e6));

        vm.prank(attacker);
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(WETH, 1e18, 0, address(settler), fakeParams);

        vm.prank(AAVE_POOL);
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(WETH, 1e18, 0, attacker, fakeParams);
    }
}
