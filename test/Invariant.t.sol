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
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockAavePool.sol";
import "../src/mocks/MockSwapRouter.sol";
import "../src/mocks/MockChainlinkFeed.sol";

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

        addressBook = AddressBook(address(new ERC1967Proxy(
            address(new AddressBook()),
            abi.encodeCall(AddressBook.initialize, (address(this)))
        )));
        controller = Controller(address(new ERC1967Proxy(
            address(new Controller()),
            abi.encodeCall(Controller.initialize, (address(addressBook), address(this)))
        )));
        pool = MarginPool(address(new ERC1967Proxy(
            address(new MarginPool()),
            abi.encodeCall(MarginPool.initialize, (address(addressBook)))
        )));
        factory = OTokenFactory(address(new ERC1967Proxy(
            address(new OTokenFactory()),
            abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
        )));
        oracle = Oracle(address(new ERC1967Proxy(
            address(new Oracle()),
            abi.encodeCall(Oracle.initialize, (address(addressBook), address(this)))
        )));
        whitelist = Whitelist(address(new ERC1967Proxy(
            address(new Whitelist()),
            abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
        )));

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
        } catch {
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

        addressBook = AddressBook(address(new ERC1967Proxy(
            address(new AddressBook()),
            abi.encodeCall(AddressBook.initialize, (address(this)))
        )));
        controller = Controller(address(new ERC1967Proxy(
            address(new Controller()),
            abi.encodeCall(Controller.initialize, (address(addressBook), address(this)))
        )));
        pool = MarginPool(address(new ERC1967Proxy(
            address(new MarginPool()),
            abi.encodeCall(MarginPool.initialize, (address(addressBook)))
        )));
        factory = OTokenFactory(address(new ERC1967Proxy(
            address(new OTokenFactory()),
            abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
        )));
        oracle = Oracle(address(new ERC1967Proxy(
            address(new Oracle()),
            abi.encodeCall(Oracle.initialize, (address(addressBook), address(this)))
        )));
        whitelist = Whitelist(address(new ERC1967Proxy(
            address(new Whitelist()),
            abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
        )));
        settler = BatchSettler(address(new ERC1967Proxy(
            address(new BatchSettler()),
            abi.encodeCall(BatchSettler.initialize, (address(addressBook), mm, address(this)))
        )));

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
            oTokens[i] = factory.createOToken(
                address(weth), address(usdc), address(usdc), strikes[i], expiry, true
            );
            whitelist.whitelistOToken(oTokens[i]);

            users[i] = address(uint160(0xB000 + i));
            uint256 collateral = (strikes[i] * 1e6) / 1e8;
            usdc.mint(users[i], collateral * 2);
            vm.startPrank(users[i]);
            usdc.approve(address(pool), type(uint256).max);
            IERC20(oTokens[i]).approve(address(settler), type(uint256).max);
            vm.stopPrank();

            (BatchSettler.Quote memory q, bytes memory sig) = _signQuote(oTokens[i], 50e6, block.timestamp + 1 hours, 100e8);
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

// =============================================================================
// Full Lifecycle Handler — drives open → execute → settle → redeem → physical
// =============================================================================

contract FullLifecycleHandler is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;

    MockERC20 public usdc;
    MockERC20 public weth;
    MockChainlinkFeed public priceFeed;

    uint256 public mmKey;
    address public mm;
    address public admin; // test contract, owns protocol
    address public treasury;

    address public oToken;
    uint256 public expiry;
    uint256 public strikePrice;

    address[] public users;
    uint256 constant NUM_USERS = 5;
    uint256 constant BID_PRICE = 50e6;
    uint256 constant MAX_QUOTE = 100e8;

    // Lifecycle
    bool public isExpired;
    uint256 public settlementPrice;

    // Accounting
    uint256 public totalPoolInflow;
    uint256 public totalPoolOutflow;
    uint256 public totalGrossPremium;
    uint256 public totalNetPremium;
    uint256 public totalFees;
    uint256 public totalOTokensBurned;

    // Vault tracking (parallel arrays)
    address[] public allVaultOwners;
    uint256[] public allVaultIds;

    // Quote tracking
    uint256 nextQuoteId = 1;
    bytes32[] public executedQuoteHashes;

    // Physical delivery tracking
    struct Delivery {
        address user;
        uint256 expectedContraAmount; // exact amount user should receive
        uint256 actualContraReceived; // actual delta in user's balance
    }
    Delivery[] public deliveries;

    // Violation flags
    bool public expiredMintSucceeded;
    bool public doubleSettleSucceeded;
    bool public oracleOverwriteSucceeded;
    bool public accessControlBypassed;
    bool public callbackTamperSucceeded;
    bool public staleNonceQuoteFilled;

    constructor(
        AddressBook _ab,
        Controller _ctrl,
        MarginPool _pool,
        Oracle _oracle,
        Whitelist _wl,
        BatchSettler _settler,
        MockERC20 _usdc,
        MockERC20 _weth,
        MockChainlinkFeed _feed,
        address _oToken,
        uint256 _expiry,
        uint256 _strikePrice,
        uint256 _mmKey,
        address _admin,
        address _treasury
    ) {
        addressBook = _ab;
        controller = _ctrl;
        pool = _pool;
        oracle = _oracle;
        whitelist = _wl;
        settler = _settler;
        usdc = _usdc;
        weth = _weth;
        priceFeed = _feed;
        oToken = _oToken;
        expiry = _expiry;
        strikePrice = _strikePrice;
        mmKey = _mmKey;
        mm = vm.addr(_mmKey);
        admin = _admin;
        treasury = _treasury;

        for (uint256 i = 0; i < NUM_USERS; i++) {
            address u = address(uint160(0xC000 + i));
            users.push(u);
            usdc.mint(u, 100_000_000e6);
            vm.startPrank(u);
            usdc.approve(address(pool), type(uint256).max);
            IERC20(oToken).approve(address(settler), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _signQuote(uint256 amount)
        internal
        returns (
            BatchSettler.Quote memory q,
            bytes memory sig,
            bytes32 digest
        )
    {
        q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: BID_PRICE,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: MAX_QUOTE,
            makerNonce: settler.makerNonce(mm)
        });
        digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // --- Pre-expiry: execute order ---
    function executeOrder(uint256 userIdx, uint256 amount) external {
        if (isExpired) return;
        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        amount = bound(amount, 1, 10e8);

        address u = users[userIdx];
        uint256 collateral = (amount * strikePrice) / 1e10;

        (BatchSettler.Quote memory q, bytes memory sig, bytes32 digest) =
            _signQuote(amount);

        vm.prank(u);
        uint256 vaultId = settler.executeOrder(q, sig, amount, collateral);

        allVaultOwners.push(u);
        allVaultIds.push(vaultId);

        uint256 premium = (amount * BID_PRICE) / 1e8;
        uint256 feeBps = settler.protocolFeeBps();
        uint256 fee = 0;
        if (feeBps > 0 && treasury != address(0)) {
            fee = (premium * feeBps) / 10000;
        }
        totalGrossPremium += premium;
        totalNetPremium += (premium - fee);
        totalFees += fee;
        totalPoolInflow += collateral;
        executedQuoteHashes.push(digest);
    }

    // --- One-shot: expire and set price ---
    function expire(uint256 price) external {
        if (isExpired) return;
        if (allVaultOwners.length == 0) return;

        price = bound(price, 1000e8, 3000e8);
        isExpired = true;
        settlementPrice = price;

        vm.warp(expiry + 1);
        vm.prank(admin);
        oracle.setExpiryPrice(address(weth), expiry, price);
        priceFeed.setPrice(int256(price));
    }

    // --- Post-expiry: settle vault ---
    function settleVault(uint256 vaultIdx) external {
        if (!isExpired) return;
        if (allVaultOwners.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, allVaultOwners.length - 1);

        address vOwner = allVaultOwners[vaultIdx];
        uint256 vid = allVaultIds[vaultIdx];
        if (controller.vaultSettled(vOwner, vid)) return;

        uint256 poolBefore = usdc.balanceOf(address(pool));

        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = vOwner;
        ids[0] = vid;

        vm.prank(mm);
        settler.batchSettleVaults(owners, ids);

        totalPoolOutflow += poolBefore - usdc.balanceOf(address(pool));
    }

    // --- Post-expiry: redeem oTokens (MM redeems) ---
    function redeemTokens(uint256 amount) external {
        if (!isExpired) return;
        uint256 bal = IERC20(oToken).balanceOf(mm);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 supplyBefore = OToken(oToken).totalSupply();

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = oToken;
        amounts[0] = amount;

        vm.prank(mm);
        settler.batchRedeem(tokens, amounts);

        totalPoolOutflow += poolBefore - usdc.balanceOf(address(pool));
        totalOTokensBurned += supplyBefore - OToken(oToken).totalSupply();
    }

    // --- Post-expiry, ITM: physical delivery via flash loan + swap ---
    function physicalRedeem(uint256 userIdx, uint256 amount) external {
        if (!isExpired) return;
        if (settlementPrice >= strikePrice) return; // OTM, skip

        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        address u = users[userIdx];

        uint256 mmBal = IERC20(oToken).balanceOf(mm);
        if (mmBal == 0) return;
        amount = bound(amount, 1, mmBal);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 supplyBefore = OToken(oToken).totalSupply();

        // Put ITM: user receives underlying (WETH)
        // contraAmount = amount * 1e10 (WETH in 18 decimals)
        address contraAsset = OToken(oToken).underlying();
        uint256 expectedContra = amount * 1e10;
        uint256 userContraBefore = IERC20(contraAsset).balanceOf(u);

        uint256 maxSpent = (amount * strikePrice) / 1e10;

        vm.prank(mm);
        settler.physicalRedeem(oToken, u, amount, maxSpent);

        uint256 actualReceived =
            IERC20(contraAsset).balanceOf(u) - userContraBefore;

        deliveries.push(Delivery({
            user: u,
            expectedContraAmount: expectedContra,
            actualContraReceived: actualReceived
        }));

        totalPoolOutflow += poolBefore - usdc.balanceOf(address(pool));
        totalOTokensBurned += supplyBefore - OToken(oToken).totalSupply();
    }

    // --- Negative: try mint after expiry (should revert) ---
    function tryMintExpired(uint256 userIdx) external {
        if (!isExpired) return;
        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        address u = users[userIdx];
        if (controller.vaultCount(u) == 0) return;

        vm.prank(u);
        try controller.mintOtoken(u, 1, oToken, 1, u) {
            expiredMintSucceeded = true;
        } catch {}
    }

    // --- Negative: try double settle ---
    function tryDoubleSettle(uint256 vaultIdx) external {
        if (!isExpired) return;
        if (allVaultOwners.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, allVaultOwners.length - 1);

        address vOwner = allVaultOwners[vaultIdx];
        uint256 vid = allVaultIds[vaultIdx];
        if (!controller.vaultSettled(vOwner, vid)) return;

        vm.prank(vOwner);
        try controller.settleVault(vOwner, vid) {
            doubleSettleSucceeded = true;
        } catch {}
    }

    // --- Negative: try overwrite oracle price ---
    function tryOverwriteOracle() external {
        if (!isExpired) return;

        vm.prank(admin);
        try oracle.setExpiryPrice(address(weth), expiry, 9999e8) {
            oracleOverwriteSucceeded = true;
        } catch {}
    }

    // --- Negative: try unauthorized privileged calls ---
    function tryUnauthorizedCall(uint256 fnIdx) external {
        fnIdx = bound(fnIdx, 0, 5);
        address attacker = address(0xDEAD);

        vm.startPrank(attacker);
        if (fnIdx == 0) {
            try controller.setBetaMode(true) {
                accessControlBypassed = true;
            } catch {}
        } else if (fnIdx == 1) {
            try settler.setOperator(attacker) {
                accessControlBypassed = true;
            } catch {}
        } else if (fnIdx == 2) {
            try settler.setProtocolFeeBps(9999) {
                accessControlBypassed = true;
            } catch {}
        } else if (fnIdx == 3) {
            try oracle.setPriceFeed(address(0x1), address(0x2)) {
                accessControlBypassed = true;
            } catch {}
        } else if (fnIdx == 4) {
            try whitelist.whitelistCollateral(attacker) {
                accessControlBypassed = true;
            } catch {}
        } else {
            try controller.transferOwnership(attacker) {
                accessControlBypassed = true;
            } catch {}
        }
        vm.stopPrank();
    }

    // --- Negative: try calling executeOperation directly (callback tampering) ---
    function tryCallbackTamper() external {
        if (!isExpired) return;
        if (settlementPrice >= strikePrice) return; // need ITM

        address attacker = address(0xDEAD);
        bytes memory fakeParams = abi.encode(
            oToken, attacker, uint256(1e8), uint256(2000e6)
        );

        // Attempt 1: random caller (not aavePool)
        vm.prank(attacker);
        try settler.executeOperation(
            address(weth), 1e18, 0, address(settler), fakeParams
        ) {
            callbackTamperSucceeded = true;
        } catch {}

        // Attempt 2: correct aavePool but wrong initiator
        address aave = settler.aavePool();
        vm.prank(aave);
        try settler.executeOperation(
            address(weth), 1e18, 0, attacker, fakeParams
        ) {
            callbackTamperSucceeded = true;
        } catch {}
    }

    // --- Negative: makerNonce invalidation (circuit breaker) ---
    function tryStaleNonceQuote(uint256 userIdx, uint256 amount) external {
        if (isExpired) return;
        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        amount = bound(amount, 1, 10e8);

        address u = users[userIdx];
        uint256 collateral = (amount * strikePrice) / 1e10;

        // 1. Sign a valid quote at the current nonce
        (BatchSettler.Quote memory q, bytes memory sig,) =
            _signQuote(amount);

        // 2. MM increments nonce (circuit breaker)
        vm.prank(mm);
        settler.incrementMakerNonce();

        // 3. Try to fill the now-stale quote — must revert
        vm.prank(u);
        try settler.executeOrder(q, sig, amount, collateral) {
            staleNonceQuoteFilled = true;
        } catch {}

        // 4. Restore nonce state: sign a fresh no-op quote so
        //    the handler's other actions still work. The nonce
        //    has been permanently incremented; _signQuote reads
        //    the live nonce, so subsequent calls are fine.
    }

    // --- View helpers ---
    function deliveryCount() external view returns (uint256) {
        return deliveries.length;
    }
    function vaultCount() external view returns (uint256) {
        return allVaultOwners.length;
    }
    function quoteCount() external view returns (uint256) {
        return executedQuoteHashes.length;
    }
}

// =============================================================================
// Full Lifecycle Invariant Test — 10 new protocol invariants
// =============================================================================

contract FullLifecycleInvariantTest is Test {
    AddressBook addressBook;
    Controller controller;
    MarginPool pool;
    OTokenFactory factory;
    Oracle oracle;
    Whitelist whitelist;
    BatchSettler settler;

    MockERC20 usdc;
    MockERC20 weth;
    MockChainlinkFeed priceFeed;
    MockAavePool aavePool;
    MockSwapRouter swapRouter;

    FullLifecycleHandler handler;

    uint256 mmKey = 0xBB01;
    address mm;
    address treasury = address(0xFEE);

    address oToken;
    uint256 expiry;
    uint256 strikePrice = 2000e8;

    function setUp() public {
        vm.warp(1700000000);
        mm = vm.addr(mmKey);

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);

        priceFeed = new MockChainlinkFeed(2000e8);
        aavePool = new MockAavePool();
        swapRouter = new MockSwapRouter(
            address(priceFeed), address(weth), address(usdc)
        );

        addressBook = AddressBook(address(new ERC1967Proxy(
            address(new AddressBook()),
            abi.encodeCall(AddressBook.initialize, (address(this)))
        )));
        controller = Controller(address(new ERC1967Proxy(
            address(new Controller()),
            abi.encodeCall(
                Controller.initialize,
                (address(addressBook), address(this))
            )
        )));
        pool = MarginPool(address(new ERC1967Proxy(
            address(new MarginPool()),
            abi.encodeCall(MarginPool.initialize, (address(addressBook)))
        )));
        factory = OTokenFactory(address(new ERC1967Proxy(
            address(new OTokenFactory()),
            abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
        )));
        oracle = Oracle(address(new ERC1967Proxy(
            address(new Oracle()),
            abi.encodeCall(
                Oracle.initialize,
                (address(addressBook), address(this))
            )
        )));
        whitelist = Whitelist(address(new ERC1967Proxy(
            address(new Whitelist()),
            abi.encodeCall(
                Whitelist.initialize,
                (address(addressBook), address(this))
            )
        )));
        settler = BatchSettler(address(new ERC1967Proxy(
            address(new BatchSettler()),
            abi.encodeCall(
                BatchSettler.initialize,
                (address(addressBook), mm, address(this))
            )
        )));

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));

        settler.setWhitelistedMM(mm, true);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400);
        settler.setAavePool(address(aavePool));
        settler.setSwapRouter(address(swapRouter));
        settler.setSwapFeeTier(3000);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(
            address(weth), address(usdc), address(usdc), true
        );

        uint256 today8am =
            (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp
            ? today8am
            : today8am + 1 days;

        oToken = factory.createOToken(
            address(weth),
            address(usdc),
            address(usdc),
            strikePrice,
            expiry,
            true
        );
        whitelist.whitelistOToken(oToken);

        usdc.mint(mm, 100_000_000e6);
        vm.startPrank(mm);
        usdc.approve(address(settler), type(uint256).max);
        IERC20(oToken).approve(address(settler), type(uint256).max);
        vm.stopPrank();

        handler = new FullLifecycleHandler(
            addressBook,
            controller,
            pool,
            oracle,
            whitelist,
            settler,
            usdc,
            weth,
            priceFeed,
            oToken,
            expiry,
            strikePrice,
            mmKey,
            address(this),
            treasury
        );

        targetContract(address(handler));
    }

    /// @notice INV-1: Controller rejects minting after expiry
    function invariant_noExpiredMint() public view {
        assertFalse(handler.expiredMintSucceeded());
    }

    /// @notice INV-2: Pool balance = total deposited - total outflows
    function invariant_collateralConservation() public view {
        uint256 expected =
            handler.totalPoolInflow() - handler.totalPoolOutflow();
        assertEq(usdc.balanceOf(address(pool)), expected);
    }

    /// @notice INV-3: gross premium = net premium + fee (no dust)
    function invariant_premiumConservation() public view {
        assertEq(
            handler.totalGrossPremium(),
            handler.totalNetPremium() + handler.totalFees()
        );
    }

    /// @notice INV-4: Once set, expiry price cannot be overwritten
    function invariant_oracleImmutability() public view {
        assertFalse(handler.oracleOverwriteSucceeded());
    }

    /// @notice INV-5: Settler never accumulates tokens (physical delivery)
    function invariant_settlerHoldsNoTokens() public view {
        assertEq(usdc.balanceOf(address(settler)), 0);
        assertEq(weth.balanceOf(address(settler)), 0);
    }

    /// @notice INV-6: All privileged functions revert for unauthorized
    function invariant_accessControlExhaustive() public view {
        assertFalse(handler.accessControlBypassed());
    }

    /// @notice INV-7: ITM settled vaults return 0 collateral to writer
    function invariant_itmSettleReturnsZero() public view {
        if (!handler.isExpired()) return;
        if (handler.settlementPrice() >= strikePrice) return;

        for (uint256 i = 0; i < handler.vaultCount(); i++) {
            address vOwner = handler.allVaultOwners(i);
            uint256 vid = handler.allVaultIds(i);
            if (!controller.vaultSettled(vOwner, vid)) continue;

            MarginVault.Vault memory v = controller.getVault(vOwner, vid);
            uint256 payout = (v.shortAmount * strikePrice) / 1e10;
            assertEq(v.collateralAmount, payout);
        }
    }

    /// @notice INV-8: filledAmount never exceeds quote maxAmount
    function invariant_quoteFillNeverExceedsMax() public view {
        for (uint256 i = 0; i < handler.quoteCount(); i++) {
            bytes32 qHash = handler.executedQuoteHashes(i);
            (uint256 filled,) = settler.getQuoteState(mm, qHash);
            assertLe(filled, 100e8);
        }
    }

    /// @notice INV-9: sum(vault.shortAmount) = totalSupply + totalBurned
    function invariant_vaultOTokenConsistency() public view {
        uint256 totalShort = 0;
        for (uint256 i = 0; i < handler.vaultCount(); i++) {
            MarginVault.Vault memory v = controller.getVault(
                handler.allVaultOwners(i),
                handler.allVaultIds(i)
            );
            totalShort += v.shortAmount;
        }
        assertEq(
            totalShort,
            OToken(oToken).totalSupply() + handler.totalOTokensBurned()
        );
    }

    /// @notice INV-10: Settling an already-settled vault always reverts
    function invariant_noDoubleSettle() public view {
        assertFalse(handler.doubleSettleSucceeded());
    }

    /// @notice INV-11: Physical delivery sends exact contra-asset amount
    /// For puts: user receives exactly amount * 1e10 WETH
    function invariant_physicalDeliveryExactAmount() public view {
        for (uint256 i = 0; i < handler.deliveryCount(); i++) {
            (
                ,
                uint256 expected,
                uint256 actual
            ) = handler.deliveries(i);
            assertEq(
                actual,
                expected,
                "delivery amount mismatch"
            );
        }
    }

    /// @notice INV-12: Flash loan callback cannot be hijacked
    function invariant_noCallbackTampering() public view {
        assertFalse(handler.callbackTamperSucceeded());
    }

    /// @notice INV-13: makerNonce invalidation kills all prior quotes
    function invariant_makerNonceInvalidation() public view {
        assertFalse(handler.staleNonceQuoteFilled());
    }
}
