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
// Handler — drives random valid sequences of vault operations
// =============================================================================

contract ProtocolHandler is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;

    MockERC20 public usdc;
    MockERC20 public weth;

    address public oToken;
    uint256 public expiry;
    uint256 public strikePrice = 2000e8;

    address[] public users;
    uint256 public totalDeposited;
    uint256 public totalMinted; // in oToken units

    constructor(
        AddressBook _ab,
        Controller _ctrl,
        MarginPool _pool,
        OTokenFactory _factory,
        Oracle _oracle,
        Whitelist _wl,
        MockERC20 _usdc,
        MockERC20 _weth,
        address _oToken,
        uint256 _expiry
    ) {
        addressBook = _ab;
        controller = _ctrl;
        pool = _pool;
        factory = _factory;
        oracle = _oracle;
        whitelist = _wl;
        usdc = _usdc;
        weth = _weth;
        oToken = _oToken;
        expiry = _expiry;

        // Pre-create 5 users
        for (uint256 i = 0; i < 5; i++) {
            address u = address(uint160(0xA000 + i));
            users.push(u);
            usdc.mint(u, 10_000_000e6);
            vm.prank(u);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    /// @notice Open vault + deposit + mint for a random user
    function openAndMint(uint256 userIdx, uint256 amount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        amount = bound(amount, 1, 100e8); // 1 unit to 100 oTokens

        address u = users[userIdx];
        uint256 collateral = (amount * strikePrice) / 1e10;

        vm.startPrank(u);
        controller.openVault(u);
        uint256 vaultId = controller.vaultCount(u);
        controller.depositCollateral(u, vaultId, address(usdc), collateral);
        controller.mintOtoken(u, vaultId, oToken, amount);
        vm.stopPrank();

        totalDeposited += collateral;
        totalMinted += amount;
    }

    /// @notice Deposit additional collateral to an existing vault
    function depositMore(uint256 userIdx, uint256 extraAmount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        address u = users[userIdx];

        uint256 vaults = controller.vaultCount(u);
        if (vaults == 0) return;

        extraAmount = bound(extraAmount, 1e6, 10_000e6);

        vm.prank(u);
        controller.depositCollateral(u, 1, address(usdc), extraAmount);

        totalDeposited += extraAmount;
    }
}

// =============================================================================
// Invariant Test Suite
// =============================================================================

contract InvariantTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;

    MockERC20 public usdc;
    MockERC20 public weth;

    ProtocolHandler public handler;

    address public oToken;
    uint256 public expiry;
    uint256 public strikePrice = 2000e8;

    function setUp() public {
        vm.warp(1700000000);

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);

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
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc), strikePrice, expiry, true
        );
        whitelist.whitelistOToken(oToken);

        handler = new ProtocolHandler(
            addressBook, controller, pool, factory, oracle, whitelist,
            usdc, weth, oToken, expiry
        );

        // Only target the handler — Foundry will call its functions randomly
        targetContract(address(handler));
    }

    /// @notice INVARIANT: Pool USDC balance always equals total deposited collateral
    function invariant_poolBalanceMatchesDeposits() public view {
        assertEq(
            usdc.balanceOf(address(pool)),
            handler.totalDeposited()
        );
    }

    /// @notice INVARIANT: Total oToken supply equals total minted
    function invariant_oTokenSupplyMatchesMinted() public view {
        assertEq(
            OToken(oToken).totalSupply(),
            handler.totalMinted()
        );
    }

    /// @notice INVARIANT: Pool balance is never negative (always >= 0 by definition,
    ///         but we check it's >= total obligations from minted oTokens)
    function invariant_poolCoversObligations() public view {
        uint256 poolBal = usdc.balanceOf(address(pool));
        // Max obligation = all oTokens ITM at price=0, payout = totalMinted * strikePrice / 1e10
        uint256 maxObligation = (handler.totalMinted() * strikePrice) / 1e10;
        assertGe(poolBal, maxObligation);
    }

    /// @notice INVARIANT: No user can have more vaults than the controller recorded
    function invariant_vaultCountConsistent() public view {
        for (uint256 i = 0; i < 5; i++) {
            address u = handler.users(i);
            uint256 count = controller.vaultCount(u);
            // Each vault ID from 1..count should be valid (non-reverting getVault)
            for (uint256 v = 1; v <= count; v++) {
                controller.getVault(u, v); // would revert if invalid
            }
        }
    }
}
