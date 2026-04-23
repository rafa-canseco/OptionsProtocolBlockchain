// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/OToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ForkSmokePostUpgrade
 * @notice Post-V4/V5 smoke test. Runs against the ALREADY UPGRADED
 *         mainnet state (no upgrade simulation — just exercises the
 *         live contracts) to verify nothing is broken.
 *
 *         Run:
 *         forge test --match-contract ForkSmokePostUpgrade \
 *           --fork-url $BASE_RPC_URL -vvv
 */
contract ForkSmokePostUpgrade is Test {
    Controller controller = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    MarginPool pool = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);
    OTokenFactory factory = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Oracle oracle = Oracle(0x09daa0194A3AF59b46C5443aF9C20fAd98347671);
    Whitelist whitelist = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    BatchSettler settler = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address owner;
    address factoryOperator;
    address operatorAddr;
    address user = address(0xCAFE);

    uint256 mmKey = 0xBB01;
    address mm;
    uint256 expiry;

    function setUp() public {
        if (block.chainid != 8453) {
            emit log("SKIPPED: requires --fork-url (Base 8453)");
            return;
        }

        owner = controller.owner();
        factoryOperator = factory.operator();
        operatorAddr = settler.operator();
        mm = vm.addr(mmKey);

        // Disable oracle checks for testing
        vm.startPrank(owner);
        oracle.setMaxOracleStaleness(0);
        oracle.setPriceDeviationThreshold(0);
        settler.setWhitelistedMM(mm, true);
        vm.stopPrank();

        // Expiry: next 08:00 UTC
        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        // Fund actors
        deal(USDC, user, 10_000_000e6);
        deal(WETH, user, 100e18);
        deal(CBBTC, user, 10e8);
        deal(USDC, mm, 10_000_000e6);
        deal(WETH, mm, 100e18);
        deal(CBBTC, mm, 10e8);

        vm.startPrank(user);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        IERC20(CBBTC).approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        IERC20(WETH).approve(address(settler), type(uint256).max);
        IERC20(CBBTC).approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    // ===== Full ETH PUT lifecycle =====

    function test_smoke_ethPutLifecycle() public {
        if (block.chainid != 8453) return;

        uint256 strike = 4567e8;
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        // User opens vault, deposits, mints via executeOrder
        _executeOrder(oToken, user, 1e8, 4567e6, true);

        // Verify state
        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8, "MM oToken balance");
        assertEq(controller.vaultCount(user), 1, "vault count");

        // Expire OTM
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 5000e8);

        // Settle
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        _settleVault(user, 1);
        assertEq(IERC20(USDC).balanceOf(user) - usdcBefore, 4567e6, "ETH PUT OTM: collateral returned");
    }

    // ===== Full cbBTC CALL lifecycle =====

    function test_smoke_cbbtcCallLifecycle() public {
        if (block.chainid != 8453) return;

        uint256 strike = 98765e8;
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(CBBTC, USDC, CBBTC, strike, expiry, false);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        _executeOrder(oToken, user, 1e8, 1e8, false);

        assertEq(settler.mmOTokenBalance(mm, oToken), 1e8, "MM oToken balance");

        // Expire OTM (below strike)
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(CBBTC, expiry, 85000e8);

        uint256 btcBefore = IERC20(CBBTC).balanceOf(user);
        _settleVault(user, 1);
        assertEq(IERC20(CBBTC).balanceOf(user) - btcBefore, 1e8, "cbBTC CALL OTM: collateral returned");
    }

    // ===== B1N-204 guard still active =====

    function test_smoke_zeroCollateralPutBlocked() public {
        if (block.chainid != 8453) return;

        uint256 strike = 1e8;
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, USDC, 1);
        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, 1, oToken, 1, user);
        vm.stopPrank();
    }

    // ===== MarginPool passthrough (Aave disabled) =====

    function test_smoke_poolPassthrough() public {
        if (block.chainid != 8453) return;

        uint256 poolUsdcBefore = IERC20(USDC).balanceOf(address(pool));

        uint256 strike = 7654e8;
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, USDC, 7654e6);
        vm.stopPrank();

        // USDC goes directly to pool (not Aave)
        assertEq(IERC20(USDC).balanceOf(address(pool)) - poolUsdcBefore, 7654e6, "USDC not in pool");
        assertEq(pool.totalDeposited(USDC), 0, "totalDeposited should be 0");
    }

    // ===== Cross-contract wiring =====

    function test_smoke_crossContractWiring() public {
        if (block.chainid != 8453) return;

        // Controller → AddressBook → MarginPool chain works
        address abFromCtrl = address(controller.addressBook());
        address abFromPool = address(pool.addressBook());
        assertEq(abFromCtrl, abFromPool, "AddressBook mismatch");
        assertEq(abFromCtrl, 0x48FE24a69417038a2D3d46B2B6B9De03b884eD72);

        // BatchSettler config preserved
        assertEq(settler.swapFeeTier(), 3000);
        assertEq(settler.protocolFeeBps(), 400);
        assertEq(settler.escapeDelay(), 259200);

        // Oracle config preserved
        assertEq(oracle.priceDeviationThresholdBps(), 0); // we set to 0 in setUp
        assertEq(oracle.operator(), operatorAddr);
    }

    // ===== Helpers =====

    function _executeOrder(address oToken, address buyer, uint256 amount, uint256 collateral, bool isPut) internal {
        vm.prank(buyer);
        IERC20(oToken).approve(address(settler), type(uint256).max);

        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: isPut ? 50e6 : 30e6,
            deadline: block.timestamp + 1 hours,
            quoteId: 1,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });

        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(buyer);
        settler.executeOrder(quote, sig, amount, collateral);
    }

    function _settleVault(address vaultOwner, uint256 vaultId) internal {
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = vaultOwner;
        ids[0] = vaultId;
        vm.prank(operatorAddr);
        settler.batchSettleVaults(owners, ids);
    }
}
