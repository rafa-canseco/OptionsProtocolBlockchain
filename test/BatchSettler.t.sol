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
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;

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

        // Wire AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

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
        // Approve settler to move oTokens from user to MM
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

    // --- Core Batch Settlement ---

    function test_batchSettleSingleOrder() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);

        BatchSettler.Order[] memory orders = new BatchSettler.Order[](1);
        orders[0] = BatchSettler.Order({
            user: alice,
            oToken: oToken,
            amount: 1e8,           // 1 PUT
            premium: 70e6,         // $70 USDC premium
            collateral: 2000e6     // $2000 USDC collateral
        });

        vm.prank(mm);
        settler.settleBatch(orders, address(usdc));

        // Alice: deposited 2000 USDC collateral, received 70 USDC premium
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + 70e6);
        // MM: received 1 oToken, paid 70 USDC
        assertEq(OToken(oToken).balanceOf(mm), 1e8);
        assertEq(usdc.balanceOf(mm), 1_000_000e6 - 70e6);
        // Pool: holds 2000 USDC collateral
        assertEq(usdc.balanceOf(address(pool)), 2000e6);
    }

    function test_batchSettleMultipleOrders() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);
        _approveOToken(carol, oToken);

        BatchSettler.Order[] memory orders = new BatchSettler.Order[](3);

        // Alice: $5000 CSP
        orders[0] = BatchSettler.Order({
            user: alice,
            oToken: oToken,
            amount: 2.5e8,
            premium: 175e6,
            collateral: 5000e6
        });

        // Bob: $20000 CSP
        orders[1] = BatchSettler.Order({
            user: bob,
            oToken: oToken,
            amount: 10e8,
            premium: 700e6,
            collateral: 20_000e6
        });

        // Carol: $100 micro-option CSP
        orders[2] = BatchSettler.Order({
            user: carol,
            oToken: oToken,
            amount: 50000,        // 0.0005 oTokens = $1 exposure... let's do $100
            premium: 3.5e6,       // $3.50 premium
            collateral: 100e6     // $100 USDC
        });
        // Recalc Carol: $100 / $2000 = 0.05 ETH = 0.05e8 = 5000000 oToken units
        orders[2].amount = 5000000;

        vm.prank(mm);
        settler.settleBatch(orders, address(usdc));

        // All users got their premiums
        assertEq(usdc.balanceOf(alice), 10_000e6 - 5000e6 + 175e6);
        assertEq(usdc.balanceOf(bob), 50_000e6 - 20_000e6 + 700e6);
        assertEq(usdc.balanceOf(carol), 1_000e6 - 100e6 + 3.5e6);

        // MM got all oTokens
        uint256 totalOTokens = 2.5e8 + 10e8 + 5000000;
        assertEq(OToken(oToken).balanceOf(mm), totalOTokens);

        // Pool holds all collateral
        assertEq(usdc.balanceOf(address(pool)), 5000e6 + 20_000e6 + 100e6);

        // Batch nonce incremented
        assertEq(settler.batchNonce(), 1);
    }

    function test_batchWithMixedPutsAndCalls() public {
        address putToken = _createPut(2000e8);
        address callToken = _createCall(2300e8);
        _approveOToken(alice, putToken);
        _approveOToken(bob, callToken);

        BatchSettler.Order[] memory orders = new BatchSettler.Order[](2);

        // Alice sells a PUT
        orders[0] = BatchSettler.Order({
            user: alice,
            oToken: putToken,
            amount: 1e8,
            premium: 70e6,
            collateral: 2000e6
        });

        // Bob sells a CALL (collateral is WETH)
        orders[1] = BatchSettler.Order({
            user: bob,
            oToken: callToken,
            amount: 1e8,
            premium: 50e6,        // $50 premium in USDC
            collateral: 1e18      // 1 WETH
        });

        vm.prank(mm);
        settler.settleBatch(orders, address(usdc));

        // Alice got premium
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + 70e6);
        // Bob got premium in USDC, deposited WETH
        assertEq(usdc.balanceOf(bob), 50_000e6 + 50e6);
        assertEq(weth.balanceOf(bob), 50e18 - 1e18);

        // MM has both oTokens
        assertEq(OToken(putToken).balanceOf(mm), 1e8);
        assertEq(OToken(callToken).balanceOf(mm), 1e8);
    }

    // --- Failed Order in Batch ---

    function test_failedOrderDoesNotRevertBatch() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        BatchSettler.Order[] memory orders = new BatchSettler.Order[](2);

        // Alice: valid order
        orders[0] = BatchSettler.Order({
            user: alice,
            oToken: oToken,
            amount: 1e8,
            premium: 70e6,
            collateral: 2000e6
        });

        // Bob: insufficient collateral (will fail)
        orders[1] = BatchSettler.Order({
            user: bob,
            oToken: oToken,
            amount: 1e8,
            premium: 70e6,
            collateral: 500e6     // Not enough! Need 2000
        });

        vm.prank(mm);
        settler.settleBatch(orders, address(usdc));

        // Alice's order went through
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + 70e6);
        assertEq(OToken(oToken).balanceOf(mm), 1e8);

        // Bob's order failed — his balance is unchanged
        assertEq(usdc.balanceOf(bob), 50_000e6);
    }

    // --- Batch Vault Settlement (post-expiry) ---

    function test_batchSettleVaults() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        // Settle batch first
        BatchSettler.Order[] memory orders = new BatchSettler.Order[](2);
        orders[0] = BatchSettler.Order({
            user: alice, oToken: oToken, amount: 1e8, premium: 70e6, collateral: 2000e6
        });
        orders[1] = BatchSettler.Order({
            user: bob, oToken: oToken, amount: 1e8, premium: 70e6, collateral: 2000e6
        });

        vm.prank(mm);
        settler.settleBatch(orders, address(usdc));

        // Expire OTM
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        // Batch settle vaults
        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;
        vaultIds[1] = 1;

        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // Both users got collateral back
        assertEq(usdc.balanceOf(alice), 10_000e6 + 70e6); // original + premium (collateral returned)
        assertEq(usdc.balanceOf(bob), 50_000e6 + 70e6);
    }

    // --- Access Control ---

    function test_onlyOperatorCanSettleBatch() public {
        BatchSettler.Order[] memory orders = new BatchSettler.Order[](0);

        vm.prank(alice);
        vm.expectRevert(BatchSettler.OnlyOperator.selector);
        settler.settleBatch(orders, address(usdc));
    }

    function test_emptyBatchReverts() public {
        BatchSettler.Order[] memory orders = new BatchSettler.Order[](0);

        vm.prank(mm);
        vm.expectRevert(BatchSettler.EmptyBatch.selector);
        settler.settleBatch(orders, address(usdc));
    }

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

    // --- Full E2E: Batch → Expiry → Settle → Redeem ---

    function test_fullE2E_batchToRedeem() public {
        address oToken = _createPut(strikePrice);
        _approveOToken(alice, oToken);
        _approveOToken(bob, oToken);

        // 1. Batch settlement: Alice and Bob sell PUTs
        BatchSettler.Order[] memory orders = new BatchSettler.Order[](2);
        orders[0] = BatchSettler.Order({
            user: alice, oToken: oToken, amount: 1e8, premium: 70e6, collateral: 2000e6
        });
        orders[1] = BatchSettler.Order({
            user: bob, oToken: oToken, amount: 2e8, premium: 140e6, collateral: 4000e6
        });

        vm.prank(mm);
        settler.settleBatch(orders, address(usdc));

        // MM has 3 oTokens total
        assertEq(OToken(oToken).balanceOf(mm), 3e8);

        // 2. Expire ITM: price = $1800
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // 3. Settle vaults
        address[] memory owners = new address[](2);
        uint256[] memory vaultIds = new uint256[](2);
        owners[0] = alice;
        owners[1] = bob;
        vaultIds[0] = 1;
        vaultIds[1] = 1;

        vm.prank(mm);
        settler.batchSettleVaults(owners, vaultIds);

        // Alice: deposited 2000, payout = 200 (10% ITM), gets back 1800
        assertEq(usdc.balanceOf(alice), 10_000e6 - 2000e6 + 70e6 + 1800e6);
        // Bob: deposited 4000, payout = 400, gets back 3600
        assertEq(usdc.balanceOf(bob), 50_000e6 - 4000e6 + 140e6 + 3600e6);

        // 4. MM redeems oTokens for payout
        // Payout per oToken: (2000-1800)/2000 * $2000 = $200 per oToken
        // 3 oTokens = $600 total
        vm.prank(mm);
        controller.redeem(oToken, 3e8);
        assertEq(usdc.balanceOf(mm), 1_000_000e6 - 70e6 - 140e6 + 600e6);

        // Verify pool is empty (all collateral distributed)
        assertEq(usdc.balanceOf(address(pool)), 0);
    }
}
