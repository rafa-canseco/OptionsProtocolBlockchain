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

contract ControllerTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;

    MockERC20 public weth;
    MockERC20 public usdc;

    address public user = address(0xBEEF);
    address public buyer = address(0xCAFE);

    uint256 public strikePrice = 2000e8; // $2000
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

        // Wire everything together via AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));

        // Whitelist assets and products
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);  // PUT
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false); // CALL

        // Set expiry
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        // Fund user
        usdc.mint(user, 100_000e6);
        weth.mint(user, 100e18);
        vm.startPrank(user);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // --- Helper ---

    function _createPut() internal returns (address) {
        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _createCall() internal returns (address) {
        address oToken = factory.createOToken(
            address(weth), address(usdc), address(weth), strikePrice, expiry, false
        );
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    // --- Open Vault ---

    function test_openVault() public {
        uint256 vaultId = controller.openVault(user);
        assertEq(vaultId, 1);
        assertEq(controller.vaultCount(user), 1);
    }

    function test_openMultipleVaults() public {
        controller.openVault(user);
        controller.openVault(user);
        assertEq(controller.vaultCount(user), 2);
    }

    // --- PUT: Full Lifecycle ---

    function test_putLifecycle_expireOTM() public {
        address oToken = _createPut();

        // Open vault and deposit collateral
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);

        // Mint 1 oToken (1 PUT at $2000 = needs 2000 USDC)
        controller.mintOtoken(user, vaultId, oToken, 1e8);

        // Verify oTokens minted
        assertEq(OToken(oToken).balanceOf(user), 1e8);
        assertEq(usdc.balanceOf(address(pool)), 2000e6);

        // User sells oToken to buyer (simulating the trade)
        vm.prank(user);
        OToken(oToken).transfer(buyer, 1e8);

        // Time passes, option expires OTM (price > strike)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8); // $2100 > $2000 = OTM

        // Settle vault — user gets all collateral back
        controller.settleVault(user, vaultId);
        assertEq(usdc.balanceOf(user), 100_000e6); // got 2000 back (100000 - 2000 + 2000)

        // Buyer redeems — gets nothing (OTM)
        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(usdc.balanceOf(buyer), 0); // no payout
    }

    function test_putLifecycle_expireITM() public {
        address oToken = _createPut();

        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8);

        // Transfer to buyer
        vm.prank(user);
        OToken(oToken).transfer(buyer, 1e8);

        // Expires ITM: price $1800 < strike $2000
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Settle vault: writer gets collateral minus payout
        // Payout = 1e8 * (2000e8 - 1800e8) / 1e10 = 1e8 * 200e8 / 1e10 = 200e6 (200 USDC)
        controller.settleVault(user, vaultId);
        // User started with 100000, deposited 2000, gets back 2000-200=1800
        assertEq(usdc.balanceOf(user), 99_800e6);

        // Buyer redeems: gets 200 USDC
        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(usdc.balanceOf(buyer), 200e6);
    }

    // --- CALL: Full Lifecycle ---

    function test_callLifecycle_expireOTM() public {
        address oToken = _createCall();

        uint256 vaultId = controller.openVault(user);
        // CALL: collateral is WETH. 1 CALL = 1e18 WETH
        controller.depositCollateral(user, vaultId, address(weth), 1e18);
        controller.mintOtoken(user, vaultId, oToken, 1e8);

        vm.prank(user);
        OToken(oToken).transfer(buyer, 1e8);

        // Expires OTM: price $1900 < strike $2000
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1900e8);

        // Writer gets all WETH back
        controller.settleVault(user, vaultId);
        assertEq(weth.balanceOf(user), 100e18);

        // Buyer gets nothing
        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(weth.balanceOf(buyer), 0);
    }

    function test_callLifecycle_expireITM() public {
        address oToken = _createCall();

        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(weth), 1e18);
        controller.mintOtoken(user, vaultId, oToken, 1e8);

        vm.prank(user);
        OToken(oToken).transfer(buyer, 1e8);

        // Expires ITM: price $2500 > strike $2000
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);

        // Payout in WETH = 1e8 * (2500e8 - 2000e8) * 1e10 / 2500e8
        // = 1e8 * 500e8 * 1e10 / 2500e8 = 0.2e18 (0.2 WETH)
        controller.settleVault(user, vaultId);
        // User gets back 1 - 0.2 = 0.8 WETH
        assertEq(weth.balanceOf(user), 99e18 + 0.8e18);

        // Buyer gets 0.2 WETH
        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(weth.balanceOf(buyer), 0.2e18);
    }

    // --- Edge Cases ---

    function test_cannotMintWithoutCollateral() public {
        address oToken = _createPut();
        controller.openVault(user);

        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, 1, oToken, 1e8);
    }

    function test_cannotMintInsufficientCollateral() public {
        address oToken = _createPut();
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 1000e6); // only 1000, need 2000

        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8);
    }

    function test_cannotSettleBeforeExpiry() public {
        address oToken = _createPut();
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8);

        vm.expectRevert(Controller.OptionNotExpired.selector);
        controller.settleVault(user, vaultId);
    }

    function test_cannotSettleWithoutExpiryPrice() public {
        address oToken = _createPut();
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8);

        vm.warp(expiry + 1);
        // Don't set expiry price

        vm.expectRevert(Controller.ExpiryPriceNotSet.selector);
        controller.settleVault(user, vaultId);
    }

    function test_cannotSettleTwice() public {
        address oToken = _createPut();
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);
        controller.settleVault(user, vaultId);

        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.settleVault(user, vaultId);
    }

    function test_cannotMintUnwhitelistedOToken() public {
        // Create oToken but DON'T whitelist it
        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );

        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);

        vm.expectRevert(Controller.OTokenNotWhitelisted.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8);
    }

    // --- Micro-options ---

    function test_microOption_1USDC() public {
        address oToken = _createPut();

        uint256 vaultId = controller.openVault(user);
        // $1 CSP at $2000 strike: collateral = 1e8 * 2000e8 / 1e10 = ... wait
        // Actually, for $1 worth: amount = $1 / $2000 = 0.0005 ETH = 50000 (in 8 decimals)
        // Collateral = 50000 * 2000e8 / 1e10 = 50000 * 200000000000 / 10000000000 = 1000000 = 1e6 = $1 USDC
        uint256 microAmount = 50000; // 0.0005 oTokens in 8 decimals
        uint256 microCollateral = 1e6; // $1 USDC

        controller.depositCollateral(user, vaultId, address(usdc), microCollateral);
        controller.mintOtoken(user, vaultId, oToken, microAmount);

        assertEq(OToken(oToken).balanceOf(user), microAmount);

        // Expire ITM at $1900
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1900e8);

        // Payout = 50000 * (2000e8 - 1900e8) / 1e10 = 50000 * 100e8 / 1e10 = 50000
        // That's 0.05 USDC ($0.05) — correct: $1 * ($200/$2000) = $0.10... let me recalc
        // Actually: 50000 * 10000000000 / 10000000000 = 50000 = $0.05
        // Hmm, the proportion: (2000-1900)/2000 = 5%, $1 * 5% = $0.05. Yes, correct.
        controller.settleVault(user, vaultId);

        // User deposited 1e6, gets back 1e6 - 50000 = 950000
        assertEq(usdc.balanceOf(user), 100_000e6 - 1e6 + 950000);
    }
}
