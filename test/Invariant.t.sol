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
        factory.setOperator(address(this));
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

    /// @notice Call operatorRedeemForMM with a random subset of oTokens.
    ///         Some may have zero custodial balance (already redeemed).
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
        try settler.operatorRedeemForMM(mm, selected, amounts) {}
        catch (bytes memory reason) {
            batchRedeemReverted = true;
            emit log_named_bytes("operatorRedeemForMM revert reason", reason);
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
        factory.setOperator(address(this));
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

struct LifecycleContracts {
    AddressBook addressBook;
    Controller controller;
    MarginPool pool;
    Oracle oracle;
    Whitelist whitelist;
    BatchSettler settler;
    MockERC20 usdc;
    MockERC20 weth;
    MockChainlinkFeed priceFeed;
}

struct LifecycleConfig {
    address putOToken;
    address callOToken;
    uint256 expiry;
    uint256 strikePrice;
    uint256 mmKey;
    address admin;
    address treasury;
}

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
    address public admin;
    address public treasury;

    address public putOToken;
    address public callOToken;
    uint256 public expiry;
    uint256 public strikePrice;

    address[] public users;
    uint256 constant NUM_USERS = 5;
    uint256 constant BID_PRICE = 50e6;
    uint256 constant MAX_QUOTE = 100e8;

    // Lifecycle
    bool public isExpired;
    uint256 public settlementPrice;

    // Accounting (tracked per asset)
    uint256 public totalPoolInflowUsdc;
    uint256 public totalPoolOutflowUsdc;
    uint256 public totalPoolInflowWeth;
    uint256 public totalPoolOutflowWeth;
    uint256 public totalGrossPremium;
    uint256 public totalNetPremium;
    uint256 public totalFees;
    uint256 public totalPutOTokensBurned;
    uint256 public totalCallOTokensBurned;

    // Vault tracking (parallel arrays)
    address[] public allVaultOwners;
    uint256[] public allVaultIds;
    bool[] public allVaultIsPut;

    // Quote tracking
    uint256 nextQuoteId = 1;
    bytes32[] public executedQuoteHashes;

    // Physical delivery tracking
    struct Delivery {
        address user;
        uint256 expectedContraAmount;
        uint256 actualContraReceived;
    }
    Delivery[] public deliveries;

    // Violation flags
    bool public expiredMintSucceeded;
    bool public doubleSettleSucceeded;
    bool public oracleOverwriteSucceeded;
    bool public accessControlBypassed;
    bool public callbackTamperSucceeded;
    bool public staleNonceQuoteFilled;

    constructor(LifecycleContracts memory c, LifecycleConfig memory cfg) {
        addressBook = c.addressBook;
        controller = c.controller;
        pool = c.pool;
        oracle = c.oracle;
        whitelist = c.whitelist;
        settler = c.settler;
        usdc = c.usdc;
        weth = c.weth;
        priceFeed = c.priceFeed;
        putOToken = cfg.putOToken;
        callOToken = cfg.callOToken;
        expiry = cfg.expiry;
        strikePrice = cfg.strikePrice;
        mmKey = cfg.mmKey;
        mm = vm.addr(cfg.mmKey);
        admin = cfg.admin;
        treasury = cfg.treasury;

        for (uint256 i = 0; i < NUM_USERS; i++) {
            address u = address(uint160(0xC000 + i));
            users.push(u);
            usdc.mint(u, 100_000_000e6);
            weth.mint(u, 100_000e18);
            vm.startPrank(u);
            usdc.approve(address(pool), type(uint256).max);
            weth.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _signQuote(address _oToken)
        internal
        returns (BatchSettler.Quote memory q, bytes memory sig, bytes32 digest)
    {
        q = BatchSettler.Quote({
            oToken: _oToken,
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

    // --- Pre-expiry: execute order (randomly picks put or call) ---
    function executeOrder(uint256 userIdx, uint256 amount, uint256 optionSeed) external {
        if (isExpired) return;
        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        amount = bound(amount, 1, 10e8);

        bool isPut = (optionSeed % 2 == 0);
        address token = isPut ? putOToken : callOToken;
        address u = users[userIdx];

        // Put: USDC collateral = amount * strike / 1e10
        // Call: WETH collateral = amount * 1e10
        uint256 collateral = isPut ? (amount * strikePrice) / 1e10 : amount * 1e10;

        (BatchSettler.Quote memory q, bytes memory sig, bytes32 digest) = _signQuote(token);

        vm.prank(u);
        uint256 vaultId = settler.executeOrder(q, sig, amount, collateral);

        allVaultOwners.push(u);
        allVaultIds.push(vaultId);
        allVaultIsPut.push(isPut);

        uint256 premium = (amount * BID_PRICE) / 1e8;
        uint256 feeBps = settler.protocolFeeBps();
        uint256 fee = 0;
        if (feeBps > 0 && treasury != address(0)) {
            fee = (premium * feeBps) / 10000;
        }
        totalGrossPremium += premium;
        totalNetPremium += (premium - fee);
        totalFees += fee;
        if (isPut) {
            totalPoolInflowUsdc += collateral;
        } else {
            totalPoolInflowWeth += collateral;
        }
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

        uint256 usdcBefore = usdc.balanceOf(address(pool));
        uint256 wethBefore = weth.balanceOf(address(pool));

        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = vOwner;
        ids[0] = vid;

        vm.prank(mm);
        settler.batchSettleVaults(owners, ids);

        totalPoolOutflowUsdc += usdcBefore - usdc.balanceOf(address(pool));
        totalPoolOutflowWeth += wethBefore - weth.balanceOf(address(pool));
    }

    // --- Post-expiry: redeem oTokens (operator redeems for MM) ---
    function redeemTokens(uint256 amount, uint256 tokenSeed) external {
        if (!isExpired) return;

        // Pick put or call based on seed, fallback to whichever has balance
        bool pickPut = (tokenSeed % 2 == 0);
        address token;
        if (pickPut && settler.mmOTokenBalance(mm, putOToken) > 0) {
            token = putOToken;
        } else if (settler.mmOTokenBalance(mm, callOToken) > 0) {
            token = callOToken;
        } else if (settler.mmOTokenBalance(mm, putOToken) > 0) {
            token = putOToken;
        } else {
            return;
        }

        uint256 bal = settler.mmOTokenBalance(mm, token);
        amount = bound(amount, 1, bal);

        uint256 usdcBefore = usdc.balanceOf(address(pool));
        uint256 wethBefore = weth.balanceOf(address(pool));
        uint256 supplyBefore = OToken(token).totalSupply();

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = token;
        amounts[0] = amount;

        vm.prank(mm);
        settler.operatorRedeemForMM(mm, tokens, amounts);

        totalPoolOutflowUsdc += usdcBefore - usdc.balanceOf(address(pool));
        totalPoolOutflowWeth += wethBefore - weth.balanceOf(address(pool));
        if (token == putOToken) {
            totalPutOTokensBurned += supplyBefore - OToken(token).totalSupply();
        } else {
            totalCallOTokensBurned += supplyBefore - OToken(token).totalSupply();
        }
    }

    // --- Post-expiry, ITM: physical delivery (put or call) ---
    function physicalRedeemPut(uint256 userIdx, uint256 amount) external {
        if (!isExpired) return;
        if (settlementPrice >= strikePrice) return; // Put OTM
        _physicalRedeem(putOToken, true, userIdx, amount);
    }

    function physicalRedeemCall(uint256 userIdx, uint256 amount) external {
        if (!isExpired) return;
        if (settlementPrice <= strikePrice) return; // Call OTM
        _physicalRedeem(callOToken, false, userIdx, amount);
    }

    function _physicalRedeem(address token, bool isPut, uint256 userIdx, uint256 amount) private {
        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        address u = users[userIdx];

        uint256 mmBal = settler.mmOTokenBalance(mm, token);
        if (mmBal == 0) return;
        amount = bound(amount, 1, mmBal);

        uint256 usdcBefore = usdc.balanceOf(address(pool));
        uint256 wethBefore = weth.balanceOf(address(pool));
        uint256 supplyBefore = OToken(token).totalSupply();

        // Put: user receives WETH (underlying), contra = amount * 1e10
        // Call: user receives USDC (strikeAsset), contra = (amount * strike) / 1e10
        address contraAsset = isPut ? address(weth) : address(usdc);
        uint256 expectedContra = isPut ? amount * 1e10 : (amount * strikePrice) / 1e10;
        uint256 userContraBefore = IERC20(contraAsset).balanceOf(u);

        // slippageParam: put=maxCollateralSpent (USDC), call=minAmountOut (USDC)
        uint256 maxSpent = (amount * strikePrice) / 1e10;

        vm.prank(mm);
        settler.physicalRedeem(token, u, amount, maxSpent, mm);

        uint256 actualReceived = IERC20(contraAsset).balanceOf(u) - userContraBefore;
        deliveries.push(Delivery({user: u, expectedContraAmount: expectedContra, actualContraReceived: actualReceived}));

        totalPoolOutflowUsdc += usdcBefore - usdc.balanceOf(address(pool));
        totalPoolOutflowWeth += wethBefore - weth.balanceOf(address(pool));
        if (isPut) {
            totalPutOTokensBurned += supplyBefore - OToken(token).totalSupply();
        } else {
            totalCallOTokensBurned += supplyBefore - OToken(token).totalSupply();
        }
    }

    // --- Negative: try mint after expiry (should revert) ---
    function tryMintExpired(uint256 userIdx, uint256 tokenSeed) external {
        if (!isExpired) return;
        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        address u = users[userIdx];
        if (controller.vaultCount(u) == 0) return;

        address token = (tokenSeed % 2 == 0) ? putOToken : callOToken;
        vm.prank(u);
        try controller.mintOtoken(u, 1, token, 1, u) {
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
            try controller.setPartialPauser(attacker) {
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
    function tryCallbackTamper(
        uint256 /* tokenSeed */
    )
        external
    {
        if (!isExpired) return;

        // Test with put if ITM, else call if ITM, else skip
        address token;
        if (settlementPrice < strikePrice) {
            token = putOToken;
        } else if (settlementPrice > strikePrice) {
            token = callOToken;
        } else {
            return; // ATM, no ITM token
        }

        address attacker = address(0xDEAD);
        bytes memory fakeParams = abi.encode(token, attacker, uint256(1e8), uint256(2000e6));

        // Attempt 1: random caller (not aavePool)
        vm.prank(attacker);
        try settler.executeOperation(address(weth), 1e18, 0, address(settler), fakeParams) {
            callbackTamperSucceeded = true;
        } catch {}

        // Attempt 2: correct aavePool but wrong initiator
        address aave = settler.aavePool();
        vm.prank(aave);
        try settler.executeOperation(address(weth), 1e18, 0, attacker, fakeParams) {
            callbackTamperSucceeded = true;
        } catch {}
    }

    // --- Negative: makerNonce invalidation (circuit breaker) ---
    function tryStaleNonceQuote(uint256 userIdx, uint256 amount, uint256 tokenSeed) external {
        if (isExpired) return;
        userIdx = bound(userIdx, 0, NUM_USERS - 1);
        amount = bound(amount, 1, 10e8);

        bool isPut = (tokenSeed % 2 == 0);
        address token = isPut ? putOToken : callOToken;
        address u = users[userIdx];
        uint256 collateral = isPut ? (amount * strikePrice) / 1e10 : amount * 1e10;

        // 1. Sign a valid quote at the current nonce
        (BatchSettler.Quote memory q, bytes memory sig,) = _signQuote(token);

        // 2. MM increments nonce (circuit breaker)
        vm.prank(mm);
        settler.incrementMakerNonce();

        // 3. Try to fill the now-stale quote — must revert
        vm.prank(u);
        try settler.executeOrder(q, sig, amount, collateral) {
            staleNonceQuoteFilled = true;
        } catch {}
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

    address putOToken;
    address callOToken;
    uint256 expiry;
    uint256 strikePrice = 2000e8;

    function setUp() public {
        vm.warp(1700000000);
        mm = vm.addr(mmKey);

        _deployMocks();
        _deployProtocol();
        _configureProtocol();
        _createOptionsAndHandler();
    }

    function _deployMocks() private {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        priceFeed = new MockChainlinkFeed(2000e8);
        aavePool = new MockAavePool();
        swapRouter = new MockSwapRouter(address(usdc));
        swapRouter.setPriceFeed(address(weth), address(priceFeed));
    }

    function _deployProtocol() private {
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
        factory.setOperator(address(this));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    function _configureProtocol() private {
        settler.setWhitelistedMM(mm, true);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400);
        settler.setAavePool(address(aavePool));
        settler.setSwapRouter(address(swapRouter));
        settler.setSwapFeeTier(3000);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);
    }

    function _createOptionsAndHandler() private {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        putOToken = factory.createOToken(address(weth), address(usdc), address(usdc), strikePrice, expiry, true);
        callOToken = factory.createOToken(address(weth), address(usdc), address(weth), strikePrice, expiry, false);
        whitelist.whitelistOToken(putOToken);
        whitelist.whitelistOToken(callOToken);

        usdc.mint(mm, 100_000_000e6);
        weth.mint(mm, 100_000e18);
        vm.startPrank(mm);
        usdc.approve(address(settler), type(uint256).max);
        weth.approve(address(settler), type(uint256).max);
        vm.stopPrank();

        handler = new FullLifecycleHandler(
            LifecycleContracts({
                addressBook: addressBook,
                controller: controller,
                pool: pool,
                oracle: oracle,
                whitelist: whitelist,
                settler: settler,
                usdc: usdc,
                weth: weth,
                priceFeed: priceFeed
            }),
            LifecycleConfig({
                putOToken: putOToken,
                callOToken: callOToken,
                expiry: expiry,
                strikePrice: strikePrice,
                mmKey: mmKey,
                admin: address(this),
                treasury: treasury
            })
        );

        targetContract(address(handler));
    }

    /// @notice INV-1: Controller rejects minting after expiry
    function invariant_noExpiredMint() public view {
        assertFalse(handler.expiredMintSucceeded());
    }

    /// @notice INV-2: Pool balance = total deposited - total outflows (both assets)
    function invariant_collateralConservation() public view {
        uint256 expectedUsdc = handler.totalPoolInflowUsdc() - handler.totalPoolOutflowUsdc();
        assertEq(usdc.balanceOf(address(pool)), expectedUsdc, "USDC pool mismatch");
        uint256 expectedWeth = handler.totalPoolInflowWeth() - handler.totalPoolOutflowWeth();
        assertEq(weth.balanceOf(address(pool)), expectedWeth, "WETH pool mismatch");
    }

    /// @notice INV-3: gross premium = net premium + fee (no dust)
    function invariant_premiumConservation() public view {
        assertEq(handler.totalGrossPremium(), handler.totalNetPremium() + handler.totalFees());
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

    /// @notice INV-7: ITM settled vaults have collateral = full payout
    function invariant_itmSettleReturnsZero() public view {
        if (!handler.isExpired()) return;

        for (uint256 i = 0; i < handler.vaultCount(); i++) {
            address vOwner = handler.allVaultOwners(i);
            uint256 vid = handler.allVaultIds(i);
            if (!controller.vaultSettled(vOwner, vid)) continue;

            bool isPut = handler.allVaultIsPut(i);
            uint256 price = handler.settlementPrice();

            // Only check ITM vaults
            if (isPut && price >= strikePrice) continue;
            if (!isPut && price <= strikePrice) continue;

            MarginVault.Vault memory v = controller.getVault(vOwner, vid);
            // Put ITM payout = amount * strike / 1e10 (full USDC collateral)
            // Call ITM payout = amount * 1e10 (full WETH collateral)
            uint256 payout = isPut ? (v.shortAmount * strikePrice) / 1e10 : v.shortAmount * 1e10;
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

    /// @notice INV-9: sum(vault.shortAmount) = totalSupply + totalBurned (per oToken)
    function invariant_vaultOTokenConsistency() public view {
        uint256 totalPutShort = 0;
        uint256 totalCallShort = 0;
        for (uint256 i = 0; i < handler.vaultCount(); i++) {
            MarginVault.Vault memory v = controller.getVault(handler.allVaultOwners(i), handler.allVaultIds(i));
            if (handler.allVaultIsPut(i)) {
                totalPutShort += v.shortAmount;
            } else {
                totalCallShort += v.shortAmount;
            }
        }
        assertEq(
            totalPutShort, OToken(putOToken).totalSupply() + handler.totalPutOTokensBurned(), "put oToken mismatch"
        );
        assertEq(
            totalCallShort, OToken(callOToken).totalSupply() + handler.totalCallOTokensBurned(), "call oToken mismatch"
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
            (, uint256 expected, uint256 actual) = handler.deliveries(i);
            assertEq(actual, expected, "delivery amount mismatch");
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

// =============================================================================
// Pause/Emergency Handler — drives pause toggles + emergency withdraw sequences
// =============================================================================

contract PauseEmergencyHandler is Test {
    Controller public controller;
    MarginPool public pool;
    MockERC20 public usdc;
    MockERC20 public weth;

    address public admin;
    address public pauser;

    address[] public vaultOwners;
    uint256[] public vaultIds;
    bool[] public vaultIsPut;
    uint256 constant NUM_USERS = 3;

    // Violation flags
    bool public entrySucceededWhilePartiallyPaused;
    bool public anyOpSucceededWhileFullyPaused;
    bool public emergencyWithdrawSucceededWhenNotFullyPaused;
    bool public emergencyWithdrawByNonOwnerSucceeded;
    bool public emergencyWithdrawOnSettledSucceeded;
    bool public doubleEmergencyWithdrawSucceeded;

    // Tracking
    uint256 public emergencyWithdrawCount;

    address public oToken;

    constructor(
        Controller _controller,
        MarginPool _pool,
        MockERC20 _usdc,
        MockERC20 _weth,
        address _admin,
        address _pauser,
        address _oToken
    ) {
        controller = _controller;
        pool = _pool;
        usdc = _usdc;
        weth = _weth;
        admin = _admin;
        pauser = _pauser;
        oToken = _oToken;

        for (uint256 i = 0; i < NUM_USERS; i++) {
            vaultOwners.push(address(uint160(0xE000 + i)));
        }
    }

    function registerVault(address owner, uint256 vaultId, bool isPut) external {
        vaultOwners.push(owner);
        vaultIds.push(vaultId);
        vaultIsPut.push(isPut);
    }

    function vaultCount() external view returns (uint256) {
        return vaultIds.length;
    }

    // --- Action: toggle partial pause ---
    function togglePartialPause(bool pause) external {
        vm.prank(pauser);
        controller.setSystemPartiallyPaused(pause);
    }

    // --- Action: toggle full pause ---
    function toggleFullPause(bool pause) external {
        vm.prank(admin);
        controller.setSystemFullyPaused(pause);
    }

    // --- Probe: try entry ops while partially paused ---
    function tryEntryWhilePartiallyPaused(uint256 vaultIdx, uint256 opIdx) external {
        if (!controller.systemPartiallyPaused()) return;
        if (vaultIds.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, vaultIds.length - 1);
        opIdx = bound(opIdx, 0, 2);

        address owner = vaultOwners[vaultIdx];
        uint256 vid = vaultIds[vaultIdx];

        vm.startPrank(owner);
        if (opIdx == 0) {
            try controller.depositCollateral(owner, vid, address(usdc), 1e6) {
                entrySucceededWhilePartiallyPaused = true;
            } catch {}
        } else if (opIdx == 1) {
            try controller.openVault(owner) {
                entrySucceededWhilePartiallyPaused = true;
            } catch {}
        } else {
            try controller.mintOtoken(owner, vid, oToken, 1, owner) {
                entrySucceededWhilePartiallyPaused = true;
            } catch {}
        }
        vm.stopPrank();
    }

    // --- Probe: try any op while fully paused ---
    function tryOpsWhileFullyPaused(uint256 vaultIdx, uint256 opIdx) external {
        if (!controller.systemFullyPaused()) return;
        if (vaultIds.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, vaultIds.length - 1);
        opIdx = bound(opIdx, 0, 4);

        address owner = vaultOwners[vaultIdx];
        uint256 vid = vaultIds[vaultIdx];

        vm.startPrank(owner);
        if (opIdx == 0) {
            try controller.openVault(owner) {
                anyOpSucceededWhileFullyPaused = true;
            } catch {}
        } else if (opIdx == 1) {
            try controller.depositCollateral(owner, vid, address(usdc), 1e6) {
                anyOpSucceededWhileFullyPaused = true;
            } catch {}
        } else if (opIdx == 2) {
            try controller.mintOtoken(owner, vid, oToken, 1, owner) {
                anyOpSucceededWhileFullyPaused = true;
            } catch {}
        } else if (opIdx == 3) {
            try controller.settleVault(owner, vid) {
                anyOpSucceededWhileFullyPaused = true;
            } catch {}
        } else {
            try controller.redeem(oToken, 1) {
                anyOpSucceededWhileFullyPaused = true;
            } catch {}
        }
        vm.stopPrank();
    }

    // --- Probe: emergency withdraw when NOT fully paused ---
    function tryEmergencyWithdrawWhenNotPaused(uint256 vaultIdx) external {
        if (controller.systemFullyPaused()) return;
        if (vaultIds.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, vaultIds.length - 1);

        address owner = vaultOwners[vaultIdx];
        uint256 vid = vaultIds[vaultIdx];

        vm.prank(owner);
        try controller.emergencyWithdrawVault(vid) {
            emergencyWithdrawSucceededWhenNotFullyPaused = true;
        } catch (bytes memory) {}
    }

    // --- Probe: emergency withdraw by non-owner ---
    function tryEmergencyWithdrawByNonOwner(uint256 vaultIdx) external {
        if (!controller.systemFullyPaused()) return;
        if (vaultIds.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, vaultIds.length - 1);

        uint256 vid = vaultIds[vaultIdx];
        address attacker = address(0xDEAD);

        vm.prank(attacker);
        try controller.emergencyWithdrawVault(vid) {
            emergencyWithdrawByNonOwnerSucceeded = true;
        } catch (bytes memory) {}
    }

    // --- Probe: emergency withdraw on already-settled vault ---
    function tryEmergencyWithdrawOnSettled(uint256 vaultIdx) external {
        if (!controller.systemFullyPaused()) return;
        if (vaultIds.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, vaultIds.length - 1);

        address owner = vaultOwners[vaultIdx];
        uint256 vid = vaultIds[vaultIdx];

        if (!controller.vaultSettled(owner, vid)) return;

        vm.prank(owner);
        try controller.emergencyWithdrawVault(vid) {
            emergencyWithdrawOnSettledSucceeded = true;
        } catch (bytes memory) {}
    }

    // --- Action: valid emergency withdraw + double-claim check ---
    function doEmergencyWithdrawAndRetry(uint256 vaultIdx) external {
        if (!controller.systemFullyPaused()) return;
        if (vaultIds.length == 0) return;
        vaultIdx = bound(vaultIdx, 0, vaultIds.length - 1);

        address owner = vaultOwners[vaultIdx];
        uint256 vid = vaultIds[vaultIdx];

        if (controller.vaultSettled(owner, vid)) return;

        // First withdraw (should succeed if vault has collateral)
        vm.prank(owner);
        try controller.emergencyWithdrawVault(vid) {
            emergencyWithdrawCount++;

            // Immediately retry — must fail (double-claim)
            vm.prank(owner);
            try controller.emergencyWithdrawVault(vid) {
                doubleEmergencyWithdrawSucceeded = true;
            } catch (bytes memory) {}
        } catch (bytes memory reason) {
            emit log_named_bytes("first emergency withdraw failed", reason);
        }
    }
}

// =============================================================================
// Pause/Emergency Invariant Test
// =============================================================================

contract PauseEmergencyInvariantTest is Test {
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

    PauseEmergencyHandler handler;

    uint256 nextQuoteId = 1;
    address admin;
    address pauser = address(0xDA05);
    uint256 mmKey = 0xBEEF;
    address mm;
    address treasury = address(0xFEE);

    uint256 expiry;
    address putOToken;

    function setUp() public {
        vm.warp(1700000000);
        admin = address(this);
        mm = vm.addr(mmKey);

        _deployMocks();
        _deployProtocol();
        _configureProtocol();
        _createVaultsAndHandler();
    }

    function _deployMocks() private {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        priceFeed = new MockChainlinkFeed(2000e8);
        aavePool = new MockAavePool();
        swapRouter = new MockSwapRouter(address(usdc));
        swapRouter.setPriceFeed(address(weth), address(priceFeed));
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
        factory.setOperator(address(this));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    function _configureProtocol() private {
        settler.setWhitelistedMM(mm, true);
        settler.setTreasury(treasury);
        settler.setProtocolFeeBps(400);
        settler.setAavePool(address(aavePool));
        settler.setSwapRouter(address(swapRouter));
        settler.setSwapFeeTier(3000);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);

        controller.setPartialPauser(pauser);
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        private
        returns (BatchSettler.Quote memory q, bytes memory sig)
    {
        q = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: deadline,
            quoteId: nextQuoteId++,
            maxAmount: maxAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(q);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _createVaultsAndHandler() private {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;

        putOToken = factory.createOToken(address(weth), address(usdc), address(usdc), 2000e8, expiry, true);
        whitelist.whitelistOToken(putOToken);

        usdc.mint(mm, 10_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);

        handler = new PauseEmergencyHandler(controller, pool, usdc, weth, admin, pauser, putOToken);

        // Create 3 vaults with collateral via executeOrder
        for (uint256 i = 0; i < 3; i++) {
            address user = address(uint160(0xE000 + i));
            uint256 collateral = 2000e6;
            usdc.mint(user, collateral);
            vm.startPrank(user);
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();

            (BatchSettler.Quote memory q, bytes memory sig) =
                _signQuote(putOToken, 50e6, block.timestamp + 1 hours, 100e8);
            vm.prank(user);
            settler.executeOrder(q, sig, 1e8, collateral);

            handler.registerVault(user, 1, true);
        }

        targetContract(address(handler));
    }

    /// @notice INV-14: Partial pause blocks entry ops (deposit, mint)
    function invariant_partialPauseBlocksEntry() public view {
        assertFalse(handler.entrySucceededWhilePartiallyPaused());
    }

    /// @notice INV-15: Full pause blocks all 5 vault operations
    function invariant_fullPauseBlocksAll() public view {
        assertFalse(handler.anyOpSucceededWhileFullyPaused());
    }

    /// @notice INV-16: Emergency withdraw only when fully paused
    function invariant_emergencyWithdrawOnlyWhenFullyPaused() public view {
        assertFalse(handler.emergencyWithdrawSucceededWhenNotFullyPaused());
    }

    /// @notice INV-17: Emergency withdraw only for vault owner
    function invariant_emergencyWithdrawOnlyForVaultOwner() public view {
        assertFalse(handler.emergencyWithdrawByNonOwnerSucceeded());
    }

    /// @notice INV-18: Emergency withdraw reverts on settled vaults
    function invariant_emergencyWithdrawOnlyForUnsettled() public view {
        assertFalse(handler.emergencyWithdrawOnSettledSucceeded());
    }

    /// @notice INV-19: Emergency withdraw marks vault settled (no double-claim)
    function invariant_emergencyWithdrawMarksSettled() public view {
        assertFalse(handler.doubleEmergencyWithdrawSucceeded());
    }
}
