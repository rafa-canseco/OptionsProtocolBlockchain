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
import "../src/interfaces/IAaveV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ForkSmokeFinal
 * @notice Final verification against live mainnet with Aave ALREADY
 *         enabled. No simulation of enable — reads live state.
 *         Tests that real positions route through Aave and settle.
 *
 *         Run:
 *         forge test --match-contract ForkSmokeFinal \
 *           --fork-url $BASE_RPC_URL -vvv
 */
contract ForkSmokeFinal is Test {
    Controller controller = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    MarginPool pool = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);
    OTokenFactory factory = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Oracle oracle = Oracle(0x09daa0194A3AF59b46C5443aF9C20fAd98347671);
    Whitelist whitelist = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    BatchSettler settler = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant A_WETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address constant A_CBBTC = 0xBdb9300b7CDE636d9cD4AFF00f6F009fFBBc8EE6;

    address owner;
    address factoryOperator;
    address operatorAddr;
    address user = address(0xF1A1);

    uint256 mmKey = 0xDD01;
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

        vm.startPrank(owner);
        oracle.setMaxOracleStaleness(0);
        oracle.setPriceDeviationThreshold(0);
        settler.setWhitelistedMM(mm, true);
        vm.stopPrank();

        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

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

    /// @notice Verify Aave is enabled on live state (no simulation)
    function test_final_aaveEnabledOnChain() public {
        if (block.chainid != 8453) return;
        assertTrue(pool.isAaveEnabled(USDC), "USDC not enabled");
        assertTrue(pool.isAaveEnabled(WETH), "WETH not enabled");
        assertTrue(pool.isAaveEnabled(CBBTC), "cbBTC not enabled");
    }

    /// @notice ETH PUT: USDC collateral routes through Aave, settles OTM
    function test_final_ethPutViaAave() public {
        if (block.chainid != 8453) return;

        uint256 strike = 11111e8;
        address oToken = _createAndWhitelist(WETH, USDC, USDC, strike, true);
        _executeOrder(oToken, user, 1e8, 11111e6, true);

        assertEq(pool.totalDeposited(USDC), 11111e6, "USDC not in Aave");
        assertGe(IERC20(A_USDC).balanceOf(address(pool)), 11111e6 - 2, "aUSDC missing");

        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 15000e8);

        uint256 before = IERC20(USDC).balanceOf(user);
        _settleVault(user, 1);
        assertEq(IERC20(USDC).balanceOf(user) - before, 11111e6, "USDC not returned");
        assertEq(pool.totalDeposited(USDC), 0, "tracking not cleared");
    }

    /// @notice ETH CALL: WETH collateral routes through Aave, settles OTM
    function test_final_ethCallViaAave() public {
        if (block.chainid != 8453) return;

        uint256 strike = 22222e8;
        address oToken = _createAndWhitelist(WETH, USDC, WETH, strike, false);
        _executeOrder(oToken, user, 1e8, 1e18, false);

        assertEq(pool.totalDeposited(WETH), 1e18, "WETH not in Aave");
        assertGe(IERC20(A_WETH).balanceOf(address(pool)), 1e18 - 1, "aWETH missing");

        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 15000e8);

        uint256 before = IERC20(WETH).balanceOf(user);
        _settleVault(user, 1);
        assertEq(IERC20(WETH).balanceOf(user) - before, 1e18, "WETH not returned");
        assertEq(pool.totalDeposited(WETH), 0, "tracking not cleared");
    }

    /// @notice cbBTC CALL: cbBTC collateral routes through Aave, settles OTM
    function test_final_cbbtcCallViaAave() public {
        if (block.chainid != 8453) return;

        uint256 strike = 333333e8;
        address oToken = _createAndWhitelist(CBBTC, USDC, CBBTC, strike, false);
        _executeOrder(oToken, user, 1e8, 1e8, false);

        assertEq(pool.totalDeposited(CBBTC), 1e8, "cbBTC not in Aave");
        assertGe(IERC20(A_CBBTC).balanceOf(address(pool)), 1e8 - 1, "aCBBTC missing");

        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(CBBTC, expiry, 200000e8);

        uint256 before = IERC20(CBBTC).balanceOf(user);
        _settleVault(user, 1);
        assertEq(IERC20(CBBTC).balanceOf(user) - before, 1e8, "cbBTC not returned");
        assertEq(pool.totalDeposited(CBBTC), 0, "tracking not cleared");
    }

    /// @notice ETH PUT ITM: vault owner gets 0, MM redeems full collateral from Aave
    function test_final_ethPutITM_viaAave() public {
        if (block.chainid != 8453) return;

        uint256 strike = 20000e8;
        address oToken = _createAndWhitelist(WETH, USDC, USDC, strike, true);
        _executeOrder(oToken, user, 1e8, 20000e6, true);

        assertEq(pool.totalDeposited(USDC), 20000e6, "USDC not in Aave");

        // Expire ITM (price below strike for put)
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 15000e8);

        uint256 userBefore = IERC20(USDC).balanceOf(user);
        _settleVault(user, 1);

        // Vault owner gets 0 (fully ITM)
        assertEq(IERC20(USDC).balanceOf(user), userBefore, "vault owner should get 0");
        // Collateral still in Aave pending redemption
        assertEq(pool.totalDeposited(USDC), 20000e6, "tracking should stay");

        // MM redeems: settler holds oTokens, transfer to MM then redeem
        vm.prank(address(settler));
        IERC20(oToken).transfer(mm, 1e8);

        uint256 mmBefore = IERC20(USDC).balanceOf(mm);
        vm.prank(mm);
        controller.redeem(oToken, 1e8);

        assertEq(IERC20(USDC).balanceOf(mm) - mmBefore, 20000e6, "MM should get full collateral");
        assertEq(pool.totalDeposited(USDC), 0, "tracking not cleared after redeem");
    }

    /// @notice ETH CALL ITM: vault owner gets 0, MM redeems full WETH from Aave
    function test_final_ethCallITM_viaAave() public {
        if (block.chainid != 8453) return;

        uint256 strike = 10000e8;
        address oToken = _createAndWhitelist(WETH, USDC, WETH, strike, false);
        _executeOrder(oToken, user, 1e8, 1e18, false);

        assertEq(pool.totalDeposited(WETH), 1e18, "WETH not in Aave");

        // Expire ITM (price above strike for call)
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 15000e8);

        uint256 userBefore = IERC20(WETH).balanceOf(user);
        _settleVault(user, 1);

        // Vault owner gets 0 (fully ITM)
        assertEq(IERC20(WETH).balanceOf(user), userBefore, "vault owner should get 0");
        assertEq(pool.totalDeposited(WETH), 1e18, "tracking should stay");

        // MM redeems from Aave
        vm.prank(address(settler));
        IERC20(oToken).transfer(mm, 1e8);

        uint256 mmBefore = IERC20(WETH).balanceOf(mm);
        vm.prank(mm);
        controller.redeem(oToken, 1e8);

        assertEq(IERC20(WETH).balanceOf(mm) - mmBefore, 1e18, "MM should get full WETH");
        assertEq(pool.totalDeposited(WETH), 0, "tracking not cleared after redeem");
    }

    /// @notice cbBTC CALL ITM: vault owner gets 0, MM redeems full cbBTC from Aave
    function test_final_cbbtcCallITM_viaAave() public {
        if (block.chainid != 8453) return;

        uint256 strike = 80000e8;
        address oToken = _createAndWhitelist(CBBTC, USDC, CBBTC, strike, false);
        _executeOrder(oToken, user, 1e8, 1e8, false);

        assertEq(pool.totalDeposited(CBBTC), 1e8, "cbBTC not in Aave");

        // Expire ITM (price above strike for call)
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(CBBTC, expiry, 100000e8);

        uint256 userBefore = IERC20(CBBTC).balanceOf(user);
        _settleVault(user, 1);

        assertEq(IERC20(CBBTC).balanceOf(user), userBefore, "vault owner should get 0");
        assertEq(pool.totalDeposited(CBBTC), 1e8, "tracking should stay");

        // MM redeems from Aave
        vm.prank(address(settler));
        IERC20(oToken).transfer(mm, 1e8);

        uint256 mmBefore = IERC20(CBBTC).balanceOf(mm);
        vm.prank(mm);
        controller.redeem(oToken, 1e8);

        assertEq(IERC20(CBBTC).balanceOf(mm) - mmBefore, 1e8, "MM should get full cbBTC");
        assertEq(pool.totalDeposited(CBBTC), 0, "tracking not cleared after redeem");
    }

    /// @notice All 3 assets in parallel: open 3 vaults, settle all in one batch
    function test_final_batchSettleAllAssets() public {
        if (block.chainid != 8453) return;

        _openThreeVaults();

        // Verify all routed through Aave
        assertEq(pool.totalDeposited(USDC), 44444e6 + 66666e6, "USDC total wrong");
        assertEq(pool.totalDeposited(WETH), 1e18, "WETH total wrong");

        // Expire all OTM
        vm.warp(expiry + 1);
        vm.startPrank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 50000e8);
        oracle.setExpiryPrice(CBBTC, expiry, 100000e8);
        vm.stopPrank();

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        uint256 wethBefore = IERC20(WETH).balanceOf(user);

        _batchSettle3();

        // All collateral returned
        assertEq(IERC20(USDC).balanceOf(user) - usdcBefore, 44444e6 + 66666e6, "USDC batch settle wrong");
        assertEq(IERC20(WETH).balanceOf(user) - wethBefore, 1e18, "WETH batch settle wrong");

        // All tracking cleared
        assertEq(pool.totalDeposited(USDC), 0, "USDC tracking not cleared");
        assertEq(pool.totalDeposited(WETH), 0, "WETH tracking not cleared");
    }

    function _openThreeVaults() internal {
        // Vault 1: ETH PUT (USDC → Aave)
        _executeOrder(_createAndWhitelist(WETH, USDC, USDC, 44444e8, true), user, 1e8, 44444e6, true);
        // Vault 2: ETH CALL (WETH → Aave)
        _executeOrder(_createAndWhitelist(WETH, USDC, WETH, 55555e8, false), user, 1e8, 1e18, false);
        // Vault 3: cbBTC PUT (USDC → Aave)
        _executeOrder(_createAndWhitelist(CBBTC, USDC, USDC, 66666e8, true), user, 1e8, 66666e6, true);
    }

    function _batchSettle3() internal {
        address[] memory owners = new address[](3);
        uint256[] memory ids = new uint256[](3);
        owners[0] = user;
        owners[1] = user;
        owners[2] = user;
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        vm.prank(operatorAddr);
        settler.batchSettleVaults(owners, ids);
    }

    // ===== Helpers =====

    function _createAndWhitelist(
        address underlying,
        address strikeAsset,
        address collateral,
        uint256 strikePrice,
        bool isPut
    ) internal returns (address) {
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(underlying, strikeAsset, collateral, strikePrice, expiry, isPut);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

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

        bytes memory sig = _signQuote(quote);

        vm.prank(buyer);
        settler.executeOrder(quote, sig, amount, collateral);
    }

    function _signQuote(BatchSettler.Quote memory quote) internal view returns (bytes memory) {
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        return abi.encodePacked(r, s, v);
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
