// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Controller.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ForkUpgradeV3
 * @notice Fork test against Base mainnet verifying B1N-188 upgrade safety.
 *         Simulates the full upgrade, validates storage integrity, and
 *         runs end-to-end vault operations for both ETH and cbBTC.
 *
 *         Physical delivery DEX swaps are tested in unit tests with
 *         MockSwapRouter. This fork test validates everything else
 *         against real mainnet state.
 *
 *         Run: forge test --match-contract ForkUpgradeV3
 *              --fork-url $BASE_RPC_URL -vvv
 */
contract ForkUpgradeV3 is Test {
    // --- Mainnet proxies ---
    BatchSettler settler = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);
    Controller controller = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    OTokenFactory factory = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Oracle oracle = Oracle(0x09daa0194A3AF59b46C5443aF9C20fAd98347671);
    Whitelist whitelist = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    MarginPool pool = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);

    // --- External addresses ---
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IERC20 usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 cbbtc = IERC20(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);

    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address owner;
    address operatorAddr;
    address factoryOperator;
    address user = address(0xBEEF);

    // MM setup
    uint256 mmKey = 0xAA01;
    address mm;

    uint256 expiry;

    function setUp() public {
        if (block.chainid != 8453) {
            emit log("SKIPPED: requires --fork-url (Base chainId 8453)");
            return;
        }

        owner = settler.owner();
        operatorAddr = settler.operator();
        factoryOperator = factory.operator();
        mm = vm.addr(mmKey);

        // --- Execute the upgrade (simulates UpgradeMainnetV3) ---
        vm.startPrank(owner);

        BatchSettler newImpl = new BatchSettler();
        settler.upgradeToAndCall(address(newImpl), "");
        settler.setAssetSwapFeeTier(CBBTC, 500);

        // Disable oracle staleness and price deviation for testing
        oracle.setMaxOracleStaleness(0);
        oracle.setPriceDeviationThreshold(0);

        // Whitelist MM
        settler.setWhitelistedMM(mm, true);

        vm.stopPrank();

        // Expiry: next 08:00 UTC
        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        // Fund user
        deal(address(weth), user, 100e18);
        deal(address(usdc), user, 10_000_000e6);
        deal(address(cbbtc), user, 10e8);

        // Fund MM
        deal(address(usdc), mm, 10_000_000e6);
        deal(address(weth), mm, 100e18);
        deal(address(cbbtc), mm, 10e8);

        // Approvals
        vm.startPrank(user);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        cbbtc.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(mm);
        usdc.approve(address(settler), type(uint256).max);
        weth.approve(address(settler), type(uint256).max);
        cbbtc.approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    // ===== Storage integrity after upgrade =====

    function test_upgradePreservesExistingConfig() public {
        if (block.chainid != 8453) return;

        assertEq(settler.swapFeeTier(), 3000, "global swapFeeTier corrupted");
        assertEq(settler.protocolFeeBps(), 400, "protocolFeeBps corrupted");
        assertEq(settler.escapeDelay(), 259200, "escapeDelay corrupted");
        assertEq(settler.owner(), owner, "owner corrupted");
        assertEq(settler.operator(), operatorAddr, "operator corrupted");
        assertEq(
            settler.treasury(),
            0x0744e5Abb82A0337B2F6ac65aC83D1e9861C9740,
            "treasury corrupted"
        );
        assertEq(
            settler.aavePool(),
            0xA238Dd80C259a72e81d7e4664a9801593F98d1c5,
            "aavePool corrupted"
        );
        assertEq(
            settler.swapRouter(),
            0x2626664c2603336E57B271c5C0b26F421741e481,
            "swapRouter corrupted"
        );
    }

    function test_upgradeSetsCbbtcFeeTier() public {
        if (block.chainid != 8453) return;

        assertEq(settler.assetSwapFeeTier(CBBTC), 500, "cbBTC fee tier not set");
        assertEq(
            settler.assetSwapFeeTier(address(weth)), 0,
            "WETH should have no override"
        );
    }

    // ===== ETH vault + order execution still works post-upgrade =====

    function test_ethPutSettlement_postUpgrade() public {
        if (block.chainid != 8453) return;

        uint256 strike = 2000e8;
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(
            address(weth), address(usdc), address(usdc),
            strike, expiry, true
        );

        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        // executeOrder: user opens vault, MM signs quote
        _executeOrder(oToken, user, 1e8, 2000e6, true);

        // Verify oTokens minted to settler (for MM)
        assertEq(
            settler.mmOTokenBalance(mm, oToken), 1e8,
            "MM oToken balance should be 1e8"
        );

        // Expire OTM (price stays above strike)
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(address(weth), expiry, 2200e8);

        // Settle vault — OTM put, full collateral returned to vault owner
        uint256 usdcBefore = usdc.balanceOf(user);
        _settleVault(user, 1);

        assertEq(
            usdc.balanceOf(user) - usdcBefore, 2000e6,
            "ETH PUT OTM: full collateral returned"
        );
    }

    // ===== cbBTC vault + order execution works post-upgrade =====

    function test_cbbtcPutSettlement_postUpgrade() public {
        if (block.chainid != 8453) return;

        uint256 strike = 71_337e8;
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(
            CBBTC, address(usdc), address(usdc),
            strike, expiry, true
        );

        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        _executeOrder(oToken, user, 1e8, 71_337e6, true);

        assertEq(
            settler.mmOTokenBalance(mm, oToken), 1e8,
            "MM oToken balance should be 1e8"
        );

        // Expire OTM (price stays above strike)
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(CBBTC, expiry, 80_000e8);

        // Settle vault — OTM put, full collateral returned
        uint256 usdcBefore = usdc.balanceOf(user);
        _settleVault(user, 1);

        assertEq(
            usdc.balanceOf(user) - usdcBefore, 71_337e6,
            "cbBTC PUT OTM: full collateral returned"
        );
    }

    function test_cbbtcCallSettlement_postUpgrade() public {
        if (block.chainid != 8453) return;

        uint256 strike = 71_337e8;
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(
            CBBTC, address(usdc), address(cbbtc),
            strike, expiry, false
        );

        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        // Call: collateral = cbBTC
        _executeOrder(oToken, user, 1e8, 1e8, false);

        assertEq(
            settler.mmOTokenBalance(mm, oToken), 1e8,
            "MM oToken balance should be 1e8"
        );

        // Expire OTM (price stays below strike)
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(CBBTC, expiry, 65_000e8);

        // Settle vault — OTM call, full collateral returned
        uint256 btcBefore = cbbtc.balanceOf(user);
        _settleVault(user, 1);

        assertEq(
            cbbtc.balanceOf(user) - btcBefore, 1e8,
            "cbBTC CALL OTM: full collateral returned"
        );
    }

    // ===== Fee tier resolution verified via storage =====

    function test_feeTierResolution_postUpgrade() public {
        if (block.chainid != 8453) return;

        // cbBTC has override = 500
        assertEq(settler.assetSwapFeeTier(CBBTC), 500);

        // WETH has no override = 0 (falls back to global 3000)
        assertEq(settler.assetSwapFeeTier(address(weth)), 0);

        // Global fee tier preserved
        assertEq(settler.swapFeeTier(), 3000);

        // Can update cbBTC fee tier
        vm.prank(owner);
        settler.setAssetSwapFeeTier(CBBTC, 3000);
        assertEq(settler.assetSwapFeeTier(CBBTC), 3000);

        // Can clear override
        vm.prank(owner);
        settler.setAssetSwapFeeTier(CBBTC, 0);
        assertEq(settler.assetSwapFeeTier(CBBTC), 0);

        // Restore for other tests
        vm.prank(owner);
        settler.setAssetSwapFeeTier(CBBTC, 500);
        assertEq(settler.assetSwapFeeTier(CBBTC), 500);
    }

    // ===== Helpers =====

    function _executeOrder(
        address oToken,
        address buyer,
        uint256 amount,
        uint256 collateral,
        bool isPut
    ) internal {
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
        uint256[] memory vaultIds = new uint256[](1);
        owners[0] = vaultOwner;
        vaultIds[0] = vaultId;
        vm.prank(operatorAddr);
        settler.batchSettleVaults(owners, vaultIds);
    }
}
