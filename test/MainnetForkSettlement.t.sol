// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Controller.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MainnetForkSettlement
 * @notice Fork test against Base mainnet verifying end-to-end
 *         settlement for ETH and cbBTC options (ITM + OTM).
 *
 *         Run: forge test --match-contract MainnetForkSettlement
 *              --fork-url $BASE_RPC_URL -vvv
 */
contract MainnetForkSettlement is Test {
    // --- Mainnet addresses ---
    Controller controller = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    OTokenFactory factory = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Oracle oracle = Oracle(0x09daa0194A3AF59b46C5443aF9C20fAd98347671);
    Whitelist whitelist = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    MarginPool pool = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);

    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 cbbtc = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);

    address owner;
    address operator;
    address user = address(0xBEEF);

    uint256 expiry;

    function setUp() public {
        owner = controller.owner();
        operator = oracle.operator();

        // Expiry: next 08:00 UTC
        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        // Disable oracle staleness check for fork testing
        vm.prank(owner);
        oracle.setMaxOracleStaleness(0);

        // Fund user with tokens (whale impersonation via deal)
        deal(address(weth), user, 100e18);
        deal(address(usdc), user, 10_000_000e6);
        deal(address(cbbtc), user, 10e8);

        // User approves MarginPool
        vm.startPrank(user);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        cbbtc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // --- ETH CALL: ITM (price rises above strike) ---
    function test_ethCall_ITM() public {
        uint256 strike = 2137e8;
        address oToken = _createOToken(address(weth), address(usdc), address(weth), strike, false);

        _openVaultAndMint(oToken, address(weth), 1e18, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(weth), expiry, 2300e8);

        uint256 wethBefore = weth.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        uint256 wethAfter = weth.balanceOf(user);
        // ITM call: payout = 1e8 * 10^10 = 1e18 (full collateral)
        assertEq(wethAfter, wethBefore, "ETH CALL ITM: no collateral return");
    }

    // --- ETH CALL: OTM (price stays below strike) ---
    function test_ethCall_OTM() public {
        uint256 strike = 2389e8;
        address oToken = _createOToken(address(weth), address(usdc), address(weth), strike, false);

        _openVaultAndMint(oToken, address(weth), 1e18, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(weth), expiry, 2200e8);

        uint256 wethBefore = weth.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        assertEq(weth.balanceOf(user) - wethBefore, 1e18, "ETH CALL OTM: full collateral returned");
    }

    // --- ETH PUT: ITM (price drops below strike) ---
    function test_ethPut_ITM() public {
        uint256 strike = 2263e8;
        address oToken = _createOToken(address(weth), address(usdc), address(usdc), strike, true);

        // collateral = 1e8 * 2263e8 / 1e10 = 2263e6
        uint256 collateral = 2263e6;
        _openVaultAndMint(oToken, address(usdc), collateral, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(weth), expiry, 2100e8);

        uint256 usdcBefore = usdc.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        // ITM put: full payout = collateral, nothing returned
        assertEq(usdc.balanceOf(user), usdcBefore, "ETH PUT ITM: no collateral return");
    }

    // --- ETH PUT: OTM (price stays above strike) ---
    function test_ethPut_OTM() public {
        uint256 strike = 2000e8;
        address oToken = _createOToken(address(weth), address(usdc), address(usdc), strike, true);

        uint256 collateral = 2000e6;
        _openVaultAndMint(oToken, address(usdc), collateral, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(weth), expiry, 2200e8);

        uint256 usdcBefore = usdc.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        assertEq(usdc.balanceOf(user) - usdcBefore, collateral, "ETH PUT OTM: full collateral returned");
    }

    // --- cbBTC CALL: ITM (price rises above strike) ---
    function test_cbbtcCall_ITM() public {
        // Strike below current (~$71500), price rises (ITM)
        uint256 strike = 68_000e8;
        address oToken = _createOToken(address(cbbtc), address(usdc), address(cbbtc), strike, false);

        // CALL 8-dec: collateral = 1e8 * 10^(8-8) = 1e8
        _openVaultAndMint(oToken, address(cbbtc), 1e8, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(cbbtc), expiry, 73_000e8);

        uint256 btcBefore = cbbtc.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        // ITM call: full collateral as payout
        assertEq(cbbtc.balanceOf(user), btcBefore, "cbBTC CALL ITM: no collateral return");
    }

    // --- cbBTC CALL: OTM (price stays below strike) ---
    function test_cbbtcCall_OTM() public {
        uint256 strike = 78_000e8;
        address oToken = _createOToken(address(cbbtc), address(usdc), address(cbbtc), strike, false);

        _openVaultAndMint(oToken, address(cbbtc), 1e8, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(cbbtc), expiry, 73_000e8);

        uint256 btcBefore = cbbtc.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        assertEq(cbbtc.balanceOf(user) - btcBefore, 1e8, "cbBTC CALL OTM: full collateral returned");
    }

    // --- cbBTC PUT: ITM (price drops below strike) ---
    function test_cbbtcPut_ITM() public {
        // Strike above current, price drops (ITM)
        uint256 strike = 75_000e8;
        address oToken = _createOToken(address(cbbtc), address(usdc), address(usdc), strike, true);

        // collateral = 1e8 * 75000e8 / 1e10 = 75000e6
        uint256 collateral = 75_000e6;
        _openVaultAndMint(oToken, address(usdc), collateral, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(cbbtc), expiry, 68_000e8);

        uint256 usdcBefore = usdc.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        assertEq(usdc.balanceOf(user), usdcBefore, "cbBTC PUT ITM: no collateral return");
    }

    // --- cbBTC PUT: OTM (price stays above strike) ---
    function test_cbbtcPut_OTM() public {
        uint256 strike = 65_000e8;
        address oToken = _createOToken(address(cbbtc), address(usdc), address(usdc), strike, true);

        uint256 collateral = 65_000e6;
        _openVaultAndMint(oToken, address(usdc), collateral, 1e8);

        vm.warp(expiry);
        vm.prank(operator);
        oracle.setExpiryPrice(address(cbbtc), expiry, 73_000e8);

        uint256 usdcBefore = usdc.balanceOf(user);
        vm.prank(user);
        controller.settleVault(user, 1);

        assertEq(usdc.balanceOf(user) - usdcBefore, collateral, "cbBTC PUT OTM: full collateral returned");
    }

    // --- Helpers ---

    function _createOToken(address underlying, address strikeAsset, address collateral, uint256 strike, bool isPut)
        internal
        returns (address)
    {
        vm.prank(operator);
        return factory.createOToken(underlying, strikeAsset, collateral, strike, expiry, isPut);
    }

    function _openVaultAndMint(address oToken, address collateral, uint256 collateralAmt, uint256 mintAmt) internal {
        vm.startPrank(user);
        controller.openVault(user);
        uint256 vaultId = controller.vaultCount(user);
        controller.depositCollateral(user, vaultId, collateral, collateralAmt);
        controller.mintOtoken(user, vaultId, oToken, mintAmt, user);
        vm.stopPrank();
    }
}
