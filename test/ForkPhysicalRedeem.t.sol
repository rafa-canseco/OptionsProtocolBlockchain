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
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

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
    uint256 settlementPrice = 1800e8;
    uint256 expiry;
    address oToken;

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

        admin = address(this);
        mm = vm.addr(mmKey);

        _deployProtocol();
        _configureSettler();
        _createOption();
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
        whitelist.whitelistProduct(WETH, USDC, USDC, true);
    }

    function _createOption() private {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        oToken = factory.createOToken(WETH, USDC, USDC, strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);
    }

    function _fundActors() private {
        deal(USDC, user, 10_000e6);
        deal(USDC, mm, 10_000e6);

        vm.prank(user);
        IERC20(USDC).approve(address(pool), type(uint256).max);

        vm.startPrank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        IERC20(oToken).approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    function _signQuote() internal returns (BatchSettler.Quote memory q, bytes memory sig) {
        q = BatchSettler.Quote({
            oToken: oToken,
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

    function test_physicalDelivery_realAaveUniswap() public onlyFork {
        uint256 amount = 1e8;
        uint256 collateral = (amount * strikePrice) / 1e10;

        // Step 1: Execute order (user buys put)
        (BatchSettler.Quote memory q, bytes memory sig) = _signQuote();

        vm.prank(user);
        uint256 vaultId = settler.executeOrder(q, sig, amount, collateral);

        assertEq(IERC20(oToken).balanceOf(mm), amount, "MM should hold oTokens");
        assertEq(IERC20(USDC).balanceOf(address(pool)), collateral, "Pool should hold collateral");

        // Step 2: Expire ITM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(WETH, expiry, settlementPrice);

        // Step 3: Settle vault
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = user;
        ids[0] = vaultId;

        vm.prank(mm);
        settler.batchSettleVaults(owners, ids);
        assertTrue(controller.vaultSettled(user, vaultId), "Vault should be settled");

        // Step 4: Physical redeem
        uint256 userWethBefore = IERC20(WETH).balanceOf(user);
        uint256 expectedWeth = amount * 1e10;

        vm.prank(mm);
        settler.physicalRedeem(oToken, user, amount, collateral);

        uint256 wethReceived = IERC20(WETH).balanceOf(user) - userWethBefore;

        // Step 5: User received exactly expected WETH
        assertEq(wethReceived, expectedWeth, "User must receive exact WETH amount");

        // Step 6: Settler holds 0 tokens
        assertEq(IERC20(USDC).balanceOf(address(settler)), 0, "Settler must hold 0 USDC");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "Settler must hold 0 WETH");

        emit log_named_uint("WETH delivered to user", wethReceived);
    }

    function test_chainlinkLivePrice() public onlyFork {
        uint256 price = oracle.getPrice(WETH);
        assertGt(price, 100e8, "ETH price too low");
        assertLt(price, 100_000e8, "ETH price too high");

        emit log_named_uint("Chainlink ETH/USD (8 dec)", price);
    }

    function test_flashLoanCallback_realAave_rejectsAttacker() public onlyFork {
        address attacker = address(0xDEAD);
        bytes memory fakeParams = abi.encode(oToken, attacker, uint256(1e8), uint256(2000e6));

        vm.prank(attacker);
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(WETH, 1e18, 0, address(settler), fakeParams);

        vm.prank(AAVE_POOL);
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(WETH, 1e18, 0, attacker, fakeParams);
    }
}
