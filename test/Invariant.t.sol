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
        controller.mintOtoken(u, vaultId, oToken, amount, u);
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
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        whitelist.whitelistOToken(oToken);

        handler =
            new ProtocolHandler(addressBook, controller, pool, factory, oracle, whitelist, usdc, weth, oToken, expiry);

        // Only target the handler — Foundry will call its functions randomly
        targetContract(address(handler));
    }

    /// @notice INVARIANT: Pool USDC balance always equals total deposited collateral
    function invariant_poolBalanceMatchesDeposits() public view {
        assertEq(usdc.balanceOf(address(pool)), handler.totalDeposited());
    }

    /// @notice INVARIANT: Total oToken supply equals total minted
    function invariant_oTokenSupplyMatchesMinted() public view {
        assertEq(OToken(oToken).totalSupply(), handler.totalMinted());
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

// =============================================================================
// BatchRedeem Invariant: batch with random approval revocations never reverts
// =============================================================================

contract BatchRedeemHandler is Test {
    BatchSettler public settler;
    address public mm;
    address[] public oTokenList;
    uint256 public tokenCount;
    bool public batchRedeemReverted;

    constructor(BatchSettler _settler, address _mm, address[] memory _tokens) {
        settler = _settler;
        mm = _mm;
        tokenCount = _tokens.length;
        for (uint256 i = 0; i < _tokens.length; i++) {
            oTokenList.push(_tokens[i]);
        }
    }

    /// @notice Randomly toggle approval for one oToken
    function toggleApproval(uint256 idx) external {
        idx = bound(idx, 0, tokenCount - 1);
        address token = oTokenList[idx];
        uint256 current = IERC20(token).allowance(mm, address(settler));
        vm.prank(mm);
        if (current > 0) {
            IERC20(token).approve(address(settler), 0);
        } else {
            IERC20(token).approve(address(settler), type(uint256).max);
        }
    }

    /// @notice Call batchRedeem with a random subset of oTokens.
    ///         Some may have revoked approval or zero balance (already redeemed).
    ///         The batch must never revert completely.
    function redeemBatch(uint256 seed) external {
        uint256 count = 0;
        for (uint256 i = 0; i < tokenCount; i++) {
            if ((seed >> i) & 1 == 1) count++;
        }
        if (count == 0) return;

        address[] memory selected = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < tokenCount; i++) {
            if ((seed >> i) & 1 == 1) {
                selected[j] = oTokenList[i];
                amounts[j] = 1e8;
                j++;
            }
        }

        vm.prank(mm);
        try settler.batchRedeem(selected, amounts) {
        // Success — batch processed without reverting
        }
        catch {
            batchRedeemReverted = true;
        }
    }
}

contract BatchRedeemInvariantTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;

    MockERC20 public usdc;
    MockERC20 public weth;

    BatchRedeemHandler public batchHandler;

    uint256 public mmKey = 0xAA01;
    address public mm;
    uint256 public expiry;
    uint256 constant NUM_TOKENS = 5;

    uint256 nextQuoteId = 1;

    function _signQuote(address _oToken, uint256 _bidPrice, uint256 _deadline, uint256 _maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        quote = BatchSettler.Quote({
            oToken: _oToken,
            bidPrice: _bidPrice,
            deadline: _deadline,
            quoteId: nextQuoteId++,
            maxAmount: _maxAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function setUp() public {
        vm.warp(1700000000);

        mm = vm.addr(mmKey);

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);

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
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        settler.setWhitelistedMM(mm, true);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        // Fund MM with USDC for premiums
        usdc.mint(mm, 10_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);

        // Create N oTokens with different strikes, execute orders, then settle
        address[] memory oTokens = new address[](NUM_TOKENS);
        address[] memory users = new address[](NUM_TOKENS);
        uint256[5] memory strikes = [uint256(1800e8), 1900e8, 2000e8, 2100e8, 2200e8];

        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            oTokens[i] = factory.createOToken(address(weth), address(usdc), address(usdc), strikes[i], expiry, true);
            whitelist.whitelistOToken(oTokens[i]);

            users[i] = address(uint160(0xB000 + i));
            uint256 collateral = (strikes[i] * 1e6) / 1e8;
            usdc.mint(users[i], collateral * 2);
            vm.startPrank(users[i]);
            usdc.approve(address(pool), type(uint256).max);
            IERC20(oTokens[i]).approve(address(settler), type(uint256).max);
            vm.stopPrank();

            (BatchSettler.Quote memory q, bytes memory sig) =
                _signQuote(oTokens[i], 50e6, block.timestamp + 1 hours, 100e8);
            vm.prank(users[i]);
            settler.executeOrder(q, sig, 1e8, collateral);
        }

        // Expire ITM (all puts in the money at $1500)
        vm.warp(expiry + 1);
        oracle.setExpiryPrice(address(weth), expiry, 1500e8);

        // Settle all vaults
        address[] memory settleOwners = new address[](NUM_TOKENS);
        uint256[] memory settleVaults = new uint256[](NUM_TOKENS);
        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            settleOwners[i] = users[i];
            settleVaults[i] = 1;
        }
        vm.prank(mm);
        settler.batchSettleVaults(settleOwners, settleVaults);

        // MM approves all oTokens to settler
        vm.startPrank(mm);
        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            IERC20(oTokens[i]).approve(address(settler), type(uint256).max);
        }
        vm.stopPrank();

        // Create handler and target it
        batchHandler = new BatchRedeemHandler(settler, mm, oTokens);
        targetContract(address(batchHandler));
    }

    /// @notice INVARIANT: batchRedeem with random approval states never reverts completely.
    ///         Valid items get processed, invalid items emit RedeemFailed.
    function invariant_batchRedeemNeverRevertsCompletely() public view {
        assertFalse(batchHandler.batchRedeemReverted());
    }
}
