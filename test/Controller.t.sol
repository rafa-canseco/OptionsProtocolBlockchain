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
    MockERC20 public wbtc;

    address public user = address(0xBEEF);
    address public buyer = address(0xCAFE);
    address public attacker = address(0xDEAD);

    uint256 public strikePrice = 2000e8; // $2000
    uint256 public btcStrikePrice = 90_000e8; // $90,000
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        // Deploy tokens
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        // Deploy protocol (behind UUPS proxies)
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

        // Wire everything together via AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));

        factory.setOperator(address(this));

        // Whitelist assets and products
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistUnderlying(address(wbtc));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistCollateral(address(wbtc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true); // ETH PUT
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false); // ETH CALL
        whitelist.whitelistProduct(address(wbtc), address(usdc), address(usdc), true); // BTC PUT
        whitelist.whitelistProduct(address(wbtc), address(usdc), address(wbtc), false); // BTC CALL

        // Set expiry
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        // Fund user
        usdc.mint(user, 1_000_000e6);
        weth.mint(user, 100e18);
        wbtc.mint(user, 100e8);
        vm.startPrank(user);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        wbtc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // --- Helper ---

    function _createPut() internal returns (address) {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _createCall() internal returns (address) {
        address oToken = factory.createOToken(address(weth), address(usdc), address(weth), strikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _createBtcPut() internal returns (address) {
        address oToken = factory.createOToken(address(wbtc), address(usdc), address(usdc), btcStrikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _createBtcCall() internal returns (address) {
        address oToken =
            factory.createOToken(address(wbtc), address(usdc), address(wbtc), btcStrikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    // --- Open Vault ---

    function test_openVault() public {
        vm.prank(user);
        uint256 vaultId = controller.openVault(user);
        assertEq(vaultId, 1);
        assertEq(controller.vaultCount(user), 1);
    }

    function test_openMultipleVaults() public {
        vm.prank(user);
        controller.openVault(user);
        vm.prank(user);
        controller.openVault(user);
        assertEq(controller.vaultCount(user), 2);
    }

    // --- Access Control ---

    function test_unauthorizedCannotOpenVault() public {
        vm.prank(attacker);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.openVault(user);
    }

    function test_unauthorizedCannotDepositCollateral() public {
        vm.prank(user);
        controller.openVault(user);

        vm.prank(attacker);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.depositCollateral(user, 1, address(usdc), 2000e6);
    }

    function test_unauthorizedCannotMintOtoken() public {
        address oToken = _createPut();
        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), 2000e6);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.mintOtoken(user, 1, oToken, 1e8, user);
    }

    function test_unauthorizedCannotSettleVault() public {
        address oToken = _createPut();
        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, address(usdc), 2000e6);
        controller.mintOtoken(user, 1, oToken, 1e8, user);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(attacker);
        vm.expectRevert(Controller.Unauthorized.selector);
        controller.settleVault(user, 1);
    }

    // --- PUT: Full Lifecycle ---

    function test_putLifecycle_expireOTM() public {
        address oToken = _createPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);

        assertEq(OToken(oToken).balanceOf(user), 1e8);
        assertEq(usdc.balanceOf(address(pool)), 2000e6);

        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(usdc.balanceOf(user), 1_000_000e6);

        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(usdc.balanceOf(buyer), 0);
    }

    function test_putLifecycle_expireITM() public {
        address oToken = _createPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Physical settlement: ITM put → user gets 0 collateral back
        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(usdc.balanceOf(user), 998_000e6); // 1_000_000 - 2000 deposited, 0 returned

        // Buyer redeems full collateral (physical settlement payout)
        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(usdc.balanceOf(buyer), 2000e6);
    }

    // --- CALL: Full Lifecycle ---

    function test_callLifecycle_expireOTM() public {
        address oToken = _createCall();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(weth), 1e18);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1900e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(weth.balanceOf(user), 100e18);

        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(weth.balanceOf(buyer), 0);
    }

    function test_callLifecycle_expireITM() public {
        address oToken = _createCall();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(weth), 1e18);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2500e8);

        // Physical settlement: ITM call → user gets 0 collateral back
        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(weth.balanceOf(user), 99e18); // 100 - 1 deposited, 0 returned

        // Buyer redeems full collateral (physical settlement payout)
        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(weth.balanceOf(buyer), 1e18);
    }

    // --- Edge Cases ---

    function test_cannotMintWithoutCollateral() public {
        address oToken = _createPut();
        vm.prank(user);
        controller.openVault(user);

        vm.prank(user);
        vm.expectRevert(Controller.CollateralMismatch.selector);
        controller.mintOtoken(user, 1, oToken, 1e8, user);
    }

    function test_cannotMintInsufficientCollateral() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 1000e6);

        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }

    function test_cannotRedeemBeforeExpiry() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(Controller.OptionNotExpired.selector);
        controller.redeem(oToken, 1e8);
    }

    function test_cannotSettleBeforeExpiry() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);

        vm.expectRevert(Controller.OptionNotExpired.selector);
        controller.settleVault(user, vaultId);
        vm.stopPrank();
    }

    function test_cannotSettleWithoutExpiryPrice() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();

        vm.warp(expiry + 1);

        vm.prank(user);
        vm.expectRevert(Controller.ExpiryPriceNotSet.selector);
        controller.settleVault(user, vaultId);
    }

    function test_cannotSettleTwice() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);

        vm.prank(user);
        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.settleVault(user, vaultId);
    }

    function test_cannotMintUnwhitelistedOToken() public {
        address fakeOToken = address(0xBAAD);

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);

        vm.expectRevert(Controller.OTokenNotWhitelisted.selector);
        controller.mintOtoken(user, vaultId, fakeOToken, 1e8, user);
        vm.stopPrank();
    }

    // --- Mint to different recipient ---

    function test_mintOtoken_sendsToRecipient() public {
        address oToken = _createPut();
        address recipient = address(0xDEAD);

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, recipient);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(recipient), 1e8);
        assertEq(OToken(oToken).balanceOf(user), 0);
    }

    // --- Expiry Guard ---

    function test_cannotMintAtExpiry() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        vm.stopPrank();

        vm.warp(expiry);
        vm.prank(user);
        vm.expectRevert(Controller.OptionExpired.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
    }

    function test_cannotMintAfterExpiry() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        vm.stopPrank();

        vm.warp(expiry + 1);
        vm.prank(user);
        vm.expectRevert(Controller.OptionExpired.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
    }

    function test_cannotMintAtExactExpiry() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        vm.stopPrank();

        vm.warp(expiry);
        vm.prank(user);
        vm.expectRevert(Controller.OptionExpired.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
    }

    function test_canMintOneSecondBeforeExpiry() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        vm.stopPrank();

        vm.warp(expiry - 1);
        vm.prank(user);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        assertEq(OToken(oToken).balanceOf(user), 1e8);
    }

    // --- Micro-options ---

    function test_microOption_1USDC() public {
        address oToken = _createPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        uint256 microAmount = 50000;
        uint256 microCollateral = 1e6;

        controller.depositCollateral(user, vaultId, address(usdc), microCollateral);
        controller.mintOtoken(user, vaultId, oToken, microAmount, user);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), microAmount);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1900e8);

        // Physical settlement: ITM put → user gets 0 back
        // microAmount = 50000, strike = 2000e8
        // payout = 50000 * 2000e8 / 1e10 = 1e6 (full collateral)
        // collateralToReturn = 1e6 - 1e6 = 0
        vm.prank(user);
        controller.settleVault(user, vaultId);

        assertEq(usdc.balanceOf(user), 1_000_000e6 - 1e6); // deposited 1 USDC, got 0 back
    }

    // --- Collateral Asset Validation (Finding 1 fix) ---

    function test_cannotMintWithWrongCollateralAsset() public {
        // Put oToken requires USDC collateral
        address oToken = _createPut();

        // Create a worthless token and fund the attacker
        MockERC20 worthless = new MockERC20("Worthless", "JUNK", 6);
        worthless.mint(attacker, 1_000_000e6);
        vm.prank(attacker);
        worthless.approve(address(pool), type(uint256).max);

        // Deposit worthless token as collateral
        vm.startPrank(attacker);
        uint256 vaultId = controller.openVault(attacker);
        controller.depositCollateral(attacker, vaultId, address(worthless), 2000e6);

        // Try to mint real oTokens — should revert CollateralMismatch
        vm.expectRevert(Controller.CollateralMismatch.selector);
        controller.mintOtoken(attacker, vaultId, oToken, 1e8, attacker);
        vm.stopPrank();
    }

    function test_canMintWithCorrectCollateralAsset() public {
        address oToken = _createPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), 1e8);
    }

    // --- Cumulative collateral check (multi-mint) ---

    function test_cannotMultiMintBeyondCollateral() public {
        address oToken = _createPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        // Deposit enough for 1 oToken but not 2
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);

        // Second mint should fail — cumulative check: 1e8 + 1e8 = 2e8 needs 4000 USDC
        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }

    function test_canMultiMintWithSufficientCollateral() public {
        address oToken = _createPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 4000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), 2e8);
    }

    // --- Redeem whitelist check ---

    function test_cannotRedeemUnwhitelistedOToken() public {
        address fakeOToken = address(0xBAAD);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(user);
        vm.expectRevert(Controller.OTokenNotWhitelisted.selector);
        controller.redeem(fakeOToken, 1e8);
    }

    // --- WBTC (8-decimal underlying): PUT Lifecycle ---

    function test_btcPutLifecycle_expireOTM() public {
        address oToken = _createBtcPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 90_000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(wbtc), expiry, 95_000e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(usdc.balanceOf(user), 1_000_000e6); // 90k returned

        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(usdc.balanceOf(buyer), 0);
    }

    function test_btcPutLifecycle_expireITM() public {
        address oToken = _createBtcPut();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 90_000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(wbtc), expiry, 80_000e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(usdc.balanceOf(user), 910_000e6); // 1M - 90k deposited, 0 returned

        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(usdc.balanceOf(buyer), 90_000e6);
    }

    // --- WBTC (8-decimal underlying): CALL Lifecycle ---

    function test_btcCallLifecycle_expireOTM() public {
        address oToken = _createBtcCall();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        // 1 WBTC = 1e8 (8 decimals). 1 option requires 1 WBTC.
        controller.depositCollateral(user, vaultId, address(wbtc), 1e8);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(wbtc), expiry, 85_000e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(wbtc.balanceOf(user), 100e8); // 1 WBTC returned

        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(wbtc.balanceOf(buyer), 0);
    }

    function test_btcCallLifecycle_expireITM() public {
        address oToken = _createBtcCall();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(wbtc), 1e8);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        OToken(oToken).transfer(buyer, 1e8);
        vm.stopPrank();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(wbtc), expiry, 100_000e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);
        assertEq(wbtc.balanceOf(user), 99e8); // 100 - 1, 0 returned

        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(wbtc.balanceOf(buyer), 1e8);
    }

    // --- WBTC: Collateral math edge cases ---

    function test_btcCallRequiresExact1BtcPerOption() public {
        address oToken = _createBtcCall();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        // Deposit 0.99 WBTC — should fail (needs exactly 1e8)
        controller.depositCollateral(user, vaultId, address(wbtc), 99e6);

        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }

    function test_btcCallFractionalOption() public {
        address oToken = _createBtcCall();

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        // 0.5 BTC option needs 0.5 BTC collateral = 5e7
        controller.depositCollateral(user, vaultId, address(wbtc), 5e7);
        controller.mintOtoken(user, vaultId, oToken, 5e7, user);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), 5e7);
    }

    // --- UnsupportedDecimals guard tests ---

    function test_cannotMintPutWithTruncatedZeroCollateral() public {
        // Strike $50 (50e8), amount=1, USDC collateral (6 dec)
        // required = (1 * 50e8) / 10^10 = 0 → should revert
        uint256 lowStrike = 50e8;
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), lowStrike, expiry, true);
        whitelist.whitelistOToken(oToken);

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 1e6); // deposit $1 to avoid CollateralMismatch

        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, vaultId, oToken, 1, user);
        vm.stopPrank();
    }

    function test_revertPutCollateralTooFewDecimals() public {
        MockERC20 lowDec = new MockERC20("Low", "LOW", 5);
        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(lowDec));
        whitelist.whitelistProduct(address(weth), address(usdc), address(lowDec), true);
        address oToken = factory.createOToken(address(weth), address(usdc), address(lowDec), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        lowDec.mint(user, 1_000_000e5);
        vm.startPrank(user);
        lowDec.approve(address(pool), type(uint256).max);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(lowDec), 1_000_000e5);
        vm.expectRevert(Controller.UnsupportedDecimals.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }

    function test_revertPutCollateralTooManyDecimals() public {
        MockERC20 highDec = new MockERC20("High", "HIGH", 17);
        whitelist.whitelistCollateral(address(highDec));
        whitelist.whitelistProduct(address(weth), address(usdc), address(highDec), true);
        address oToken = factory.createOToken(address(weth), address(usdc), address(highDec), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        highDec.mint(user, 1_000_000e17);
        vm.startPrank(user);
        highDec.approve(address(pool), type(uint256).max);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(highDec), 1_000_000e17);
        vm.expectRevert(Controller.UnsupportedDecimals.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }

    function test_revertCallCollateralTooFewDecimals() public {
        MockERC20 lowDec = new MockERC20("Low", "LOW", 7);
        whitelist.whitelistUnderlying(address(lowDec));
        whitelist.whitelistCollateral(address(lowDec));
        whitelist.whitelistProduct(address(lowDec), address(usdc), address(lowDec), false);
        address oToken =
            factory.createOToken(address(lowDec), address(usdc), address(lowDec), strikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);

        lowDec.mint(user, 1_000_000e7);
        vm.startPrank(user);
        lowDec.approve(address(pool), type(uint256).max);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(lowDec), 1_000_000e7);
        vm.expectRevert(Controller.UnsupportedDecimals.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }

    function test_revertCallCollateralTooManyDecimals() public {
        MockERC20 highDec = new MockERC20("High", "HIGH", 19);
        whitelist.whitelistUnderlying(address(highDec));
        whitelist.whitelistCollateral(address(highDec));
        whitelist.whitelistProduct(address(highDec), address(usdc), address(highDec), false);
        address oToken =
            factory.createOToken(address(highDec), address(usdc), address(highDec), strikePrice, expiry, false);
        whitelist.whitelistOToken(oToken);

        highDec.mint(user, 1_000_000e19);
        vm.startPrank(user);
        highDec.approve(address(pool), type(uint256).max);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(highDec), 1_000_000e19);
        vm.expectRevert(Controller.UnsupportedDecimals.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }
}
