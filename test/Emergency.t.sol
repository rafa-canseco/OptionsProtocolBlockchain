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

contract MockSettler {
    mapping(address => mapping(uint256 => address)) public vaultMM;
    mapping(address => mapping(address => uint256)) public mmOTokenBalance;

    function setVaultMM(address _owner, uint256 _vaultId, address _mm) external {
        vaultMM[_owner][_vaultId] = _mm;
    }

    function setMMBalance(address _mm, address _oToken, uint256 _bal) external {
        mmOTokenBalance[_mm][_oToken] = _bal;
    }

    function clearMMBalanceForVault(address _vaultOwner, uint256 _vaultId, address _oToken, uint256 _amount) external {
        address mm = vaultMM[_vaultOwner][_vaultId];
        if (mm == address(0)) return;
        uint256 balance = mmOTokenBalance[mm][_oToken];
        uint256 toClear = _amount < balance ? _amount : balance;
        if (toClear > 0) {
            mmOTokenBalance[mm][_oToken] = balance - toClear;
        }
    }
}

contract MockERC20E is ERC20 {
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

contract EmergencyTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;

    MockERC20E public weth;
    MockERC20E public usdc;

    address public admin = address(this);
    address public user = address(0xBEEF);
    address public buyer = address(0xCAFE);
    address public attacker = address(0xDEAD);
    address public pauser = address(0xABCD);

    uint256 public strikePrice = 2000e8;
    uint256 public expiry;

    function setUp() public {
        vm.warp(1700000000);

        weth = new MockERC20E("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20E("USD Coin", "USDC", 6);

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

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        factory.setOperator(admin);
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        usdc.mint(user, 100_000e6);
        weth.mint(user, 100e18);
        vm.startPrank(user);
        usdc.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        controller.setPartialPauser(pauser);
    }

    // --- Helpers ---

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

    function _openAndFundVault() internal returns (address oToken, uint256 vaultId) {
        oToken = _createPut();
        vm.startPrank(user);
        vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();
    }

    // ==========================================
    // Partial Pause
    // ==========================================

    function test_partialPause_blocksOpenVault() public {
        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsPartiallyPaused.selector);
        controller.openVault(user);
    }

    function test_partialPause_blocksDeposit() public {
        vm.prank(user);
        uint256 vaultId = controller.openVault(user);

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsPartiallyPaused.selector);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
    }

    function test_partialPause_blocksMint() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        vm.stopPrank();

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsPartiallyPaused.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
    }

    function test_partialPause_allowsSettle() public {
        (, uint256 vaultId) = _openAndFundVault();

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);

        assertTrue(controller.vaultSettled(user, vaultId));
    }

    function test_partialPause_allowsRedeem() public {
        (address oToken, uint256 vaultId) = _openAndFundVault();

        vm.prank(user);
        OToken(oToken).transfer(buyer, 1e8);

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);

        vm.prank(buyer);
        controller.redeem(oToken, 1e8);
        assertEq(usdc.balanceOf(buyer), 2000e6);
    }

    // ==========================================
    // Full Pause
    // ==========================================

    function test_fullPause_blocksOpenVault() public {
        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsFullyPaused.selector);
        controller.openVault(user);
    }

    function test_fullPause_blocksDeposit() public {
        vm.prank(user);
        uint256 vaultId = controller.openVault(user);

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsFullyPaused.selector);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
    }

    function test_fullPause_blocksMint() public {
        address oToken = _createPut();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        vm.stopPrank();

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsFullyPaused.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
    }

    function test_fullPause_blocksSettle() public {
        (, uint256 vaultId) = _openAndFundVault();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsFullyPaused.selector);
        controller.settleVault(user, vaultId);
    }

    function test_fullPause_blocksRedeem() public {
        (address oToken, uint256 vaultId) = _openAndFundVault();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsFullyPaused.selector);
        controller.redeem(oToken, 1e8);
    }

    // ==========================================
    // Unpause
    // ==========================================

    function test_unpause_partialResumesOperations() public {
        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(false);

        vm.prank(user);
        uint256 vaultId = controller.openVault(user);
        assertEq(vaultId, 1);
    }

    function test_unpause_fullResumesOperations() public {
        controller.setSystemFullyPaused(true);
        controller.setSystemFullyPaused(false);

        vm.prank(user);
        uint256 vaultId = controller.openVault(user);
        assertEq(vaultId, 1);
    }

    // ==========================================
    // Emergency Withdraw
    // ==========================================

    function test_emergencyWithdraw_returnsCollateral() public {
        _openAndFundVault();

        controller.setSystemFullyPaused(true);

        uint256 balBefore = usdc.balanceOf(user);

        vm.prank(user);
        controller.emergencyWithdrawVault(1);

        assertEq(usdc.balanceOf(user), balBefore + 2000e6);
        assertTrue(controller.vaultSettled(user, 1));
    }

    function test_emergencyWithdraw_callOption() public {
        address oToken = _createCall();
        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(weth), 1e18);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
        vm.stopPrank();

        controller.setSystemFullyPaused(true);

        uint256 balBefore = weth.balanceOf(user);

        vm.prank(user);
        controller.emergencyWithdrawVault(vaultId);

        assertEq(weth.balanceOf(user), balBefore + 1e18);
        assertTrue(controller.vaultSettled(user, vaultId));
    }

    function test_emergencyWithdraw_emitsEvent() public {
        _openAndFundVault();

        controller.setSystemFullyPaused(true);

        vm.expectEmit(true, false, false, true);
        emit Controller.EmergencyWithdraw(user, 1, address(usdc), 2000e6);

        vm.prank(user);
        controller.emergencyWithdrawVault(1);
    }

    function test_emergencyWithdraw_revertsWhenNotPaused() public {
        _openAndFundVault();

        vm.prank(user);
        vm.expectRevert(Controller.SystemNotFullyPaused.selector);
        controller.emergencyWithdrawVault(1);
    }

    function test_emergencyWithdraw_revertsForSettledVault() public {
        (, uint256 vaultId) = _openAndFundVault();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.emergencyWithdrawVault(vaultId);
    }

    function test_emergencyWithdraw_revertsForInvalidVault() public {
        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.InvalidVault.selector);
        controller.emergencyWithdrawVault(999);
    }

    function test_emergencyWithdraw_revertsDoubleClaim() public {
        _openAndFundVault();

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        controller.emergencyWithdrawVault(1);

        vm.prank(user);
        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.emergencyWithdrawVault(1);
    }

    function test_emergencyWithdraw_revertsNoCollateral() public {
        vm.prank(user);
        controller.openVault(user);

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.NoCollateral.selector);
        controller.emergencyWithdrawVault(1);
    }

    function test_emergencyWithdraw_onlyVaultOwner() public {
        _openAndFundVault();

        controller.setSystemFullyPaused(true);

        vm.prank(attacker);
        vm.expectRevert(Controller.InvalidVault.selector);
        controller.emergencyWithdrawVault(1);
    }

    // ==========================================
    // Access Control — Pause Functions
    // ==========================================

    function test_setPartialPauser_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Controller.OnlyOwner.selector);
        controller.setPartialPauser(attacker);
    }

    function test_setPartiallyPaused_byPauser() public {
        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);
        assertTrue(controller.systemPartiallyPaused());
    }

    function test_setPartiallyPaused_byOwner() public {
        controller.setSystemPartiallyPaused(true);
        assertTrue(controller.systemPartiallyPaused());
    }

    function test_setPartiallyPaused_revertsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(Controller.OnlyPartialPauser.selector);
        controller.setSystemPartiallyPaused(true);
    }

    function test_setFullyPaused_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Controller.OnlyOwner.selector);
        controller.setSystemFullyPaused(true);
    }

    function test_setFullyPaused_byOwner() public {
        controller.setSystemFullyPaused(true);
        assertTrue(controller.systemFullyPaused());
    }

    // ==========================================
    // Events — Pause State Changes
    // ==========================================

    function test_partialPause_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Controller.SystemPartiallyPaused(pauser);

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);
    }

    function test_fullPause_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Controller.SystemFullyPaused(admin);

        controller.setSystemFullyPaused(true);
    }

    function test_unpause_emitsEvent() public {
        controller.setSystemFullyPaused(true);

        vm.expectEmit(true, false, false, false);
        emit Controller.SystemUnpaused(admin);

        controller.setSystemFullyPaused(false);
    }

    function test_setPartialPauser_emitsEvent() public {
        address newPauser = address(0x1234);

        vm.expectEmit(true, true, false, false);
        emit Controller.PartialPauserUpdated(pauser, newPauser);

        controller.setPartialPauser(newPauser);
    }

    // ==========================================
    // Both pauses active simultaneously
    // ==========================================

    function test_bothPauses_openVaultReverts() public {
        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);
        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsPartiallyPaused.selector);
        controller.openVault(user);
    }

    function test_bothPauses_settleReverts() public {
        (, uint256 vaultId) = _openAndFundVault();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);
        controller.setSystemFullyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemIsFullyPaused.selector);
        controller.settleVault(user, vaultId);
    }

    // ==========================================
    // Emergency Withdraw — partial pause only
    // ==========================================

    function test_emergencyWithdraw_revertsUnderPartialPauseOnly() public {
        _openAndFundVault();

        vm.prank(pauser);
        controller.setSystemPartiallyPaused(true);

        vm.prank(user);
        vm.expectRevert(Controller.SystemNotFullyPaused.selector);
        controller.emergencyWithdrawVault(1);
    }

    // ==========================================
    // Settled vault guards
    // ==========================================

    function test_depositIntoSettledVault_reverts() public {
        (, uint256 vaultId) = _openAndFundVault();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);

        vm.prank(user);
        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.depositCollateral(user, vaultId, address(usdc), 1000e6);
    }

    function test_mintOnSettledVault_reverts() public {
        (address oToken, uint256 vaultId) = _openAndFundVault();

        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        vm.prank(user);
        controller.settleVault(user, vaultId);

        vm.prank(user);
        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.mintOtoken(user, vaultId, oToken, 1e8, user);
    }

    function test_depositAfterEmergencyWithdraw_reverts() public {
        _openAndFundVault();

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        controller.emergencyWithdrawVault(1);

        controller.setSystemFullyPaused(false);

        vm.prank(user);
        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.depositCollateral(user, 1, address(usdc), 1000e6);
    }

    function test_mintAfterEmergencyWithdraw_reverts() public {
        (address oToken,) = _openAndFundVault();

        controller.setSystemFullyPaused(true);

        vm.prank(user);
        controller.emergencyWithdrawVault(1);

        controller.setSystemFullyPaused(false);

        vm.prank(user);
        vm.expectRevert(Controller.VaultAlreadySettledError.selector);
        controller.mintOtoken(user, 1, oToken, 1e8, user);
    }

    // ==========================================
    // Pauser role rotation
    // ==========================================

    function test_setPartialPauser_toZeroRevokesRole() public {
        controller.setPartialPauser(address(0));
        assertEq(controller.partialPauser(), address(0));

        vm.prank(pauser);
        vm.expectRevert(Controller.OnlyPartialPauser.selector);
        controller.setSystemPartiallyPaused(true);
    }

    // ==========================================
    // NM-001: Cross-Vault Double-Claim Prevention
    // ==========================================

    function test_emergencyWithdraw_blocksAfterMMRedemption() public {
        address oToken = _createPut();
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        address mm1 = address(0xAA01);
        address mm2 = address(0xAA02);

        MockSettler mockSettler = new MockSettler();
        addressBook.setBatchSettler(address(mockSettler));

        usdc.mint(alice, 2000e6);
        usdc.mint(bob, 2000e6);
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);

        // Alice opens vault, deposits, mints oTokens to settler
        vm.startPrank(alice);
        uint256 vaultA = controller.openVault(alice);
        controller.depositCollateral(alice, vaultA, address(usdc), 2000e6);
        controller.mintOtoken(alice, vaultA, oToken, 1e8, address(mockSettler));
        vm.stopPrank();

        // Bob opens vault, deposits, mints oTokens to settler
        vm.startPrank(bob);
        uint256 vaultB = controller.openVault(bob);
        controller.depositCollateral(bob, vaultB, address(usdc), 2000e6);
        controller.mintOtoken(bob, vaultB, oToken, 1e8, address(mockSettler));
        vm.stopPrank();

        // Configure mock settler: vault→MM mappings and balances
        mockSettler.setVaultMM(alice, vaultA, mm1);
        mockSettler.setVaultMM(bob, vaultB, mm2);
        mockSettler.setMMBalance(mm1, oToken, 1e8);
        mockSettler.setMMBalance(mm2, oToken, 1e8);

        // settler holds 2e8 oTokens, MarginPool holds 4000 USDC
        assertEq(OToken(oToken).balanceOf(address(mockSettler)), 2e8);
        assertEq(usdc.balanceOf(address(pool)), 4000e6);

        // Option expires ITM (put: expiryPrice < strike)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1800e8);

        // Simulate operatorRedeemForMM: redeem MM1's oTokens
        vm.prank(address(mockSettler));
        controller.redeem(oToken, 1e8);
        // settler now has 1e8 oTokens (Bob's), pool paid 2000 USDC
        mockSettler.setMMBalance(mm1, oToken, 0);

        assertEq(OToken(oToken).balanceOf(address(mockSettler)), 1e8);
        assertEq(usdc.balanceOf(address(pool)), 2000e6);

        // System fully paused
        controller.setSystemFullyPaused(true);

        // Alice tries emergency withdraw — BLOCKED by per-MM check
        // (MM1's balance is 0, shortAmount is 1e8)
        vm.prank(alice);
        vm.expectRevert(Controller.OTokensAlreadyRedeemed.selector);
        controller.emergencyWithdrawVault(vaultA);

        // Bob can still withdraw — MM2's balance is intact
        vm.prank(bob);
        controller.emergencyWithdrawVault(vaultB);
        assertEq(usdc.balanceOf(bob), 2000e6);
    }

    function test_emergencyWithdraw_preMigrationVaultFallsBack() public {
        // Pre-migration vault: vaultMM returns address(0)
        // Falls back to aggregate balance check
        address oToken = _createPut();
        MockSettler mockSettler = new MockSettler();
        addressBook.setBatchSettler(address(mockSettler));

        usdc.mint(user, 2000e6);

        vm.startPrank(user);
        uint256 vaultId = controller.openVault(user);
        controller.depositCollateral(user, vaultId, address(usdc), 2000e6);
        controller.mintOtoken(user, vaultId, oToken, 1e8, address(mockSettler));
        vm.stopPrank();

        // vaultMM not set → returns address(0) (pre-migration)
        // settler holds 1e8 oTokens → aggregate check passes
        controller.setSystemFullyPaused(true);

        vm.prank(user);
        controller.emergencyWithdrawVault(vaultId);
        assertTrue(controller.vaultSettled(user, vaultId));
    }
}
