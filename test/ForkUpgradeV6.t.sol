// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Controller.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/MarginPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ForkUpgradeV6
 * @notice Fork test against Base mainnet verifying B1N-303 upgrade safety.
 *         Simulates the live BatchSettler upgrade, checks config preservation,
 *         and exercises ITM physical delivery without flash loans.
 *
 *         Run:
 *         forge test --match-contract ForkUpgradeV6 \
 *           --fork-url $BASE_RPC_URL -vvv
 */
contract ForkUpgradeV6 is Test {
    BatchSettler settler = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);
    Controller controller = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    OTokenFactory factory = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Oracle oracle = Oracle(0x09daa0194A3AF59b46C5443aF9C20fAd98347671);
    Whitelist whitelist = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    MarginPool pool = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant TREASURY = 0x0744e5Abb82A0337B2F6ac65aC83D1e9861C9740;

    address owner;
    address operatorAddr;
    address factoryOperator;
    address user = address(0xB10303);

    uint256 mmKey = 0x303;
    address mm;
    uint256 nextQuoteId = 1;
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

        vm.startPrank(owner);

        BatchSettler newImpl = new BatchSettler();
        settler.upgradeToAndCall(address(newImpl), "");

        oracle.setMaxOracleStaleness(0);
        oracle.setPriceDeviationThreshold(0);
        settler.setWhitelistedMM(mm, true);

        vm.stopPrank();

        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        deal(USDC, user, 250_000e6);
        deal(WETH, user, 100e18);
        deal(USDC, mm, 250_000e6);
        deal(WETH, mm, 100e18);

        vm.startPrank(user);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
        IERC20(WETH).approve(address(settler), type(uint256).max);
        vm.stopPrank();
    }

    function test_upgradePreservesExistingConfig() public {
        if (block.chainid != 8453) return;

        assertEq(settler.swapFeeTier(), 3000, "swapFeeTier corrupted");
        assertEq(settler.assetSwapFeeTier(CBBTC), 500, "cbBTC fee tier corrupted");
        assertEq(settler.protocolFeeBps(), 400, "protocolFeeBps corrupted");
        assertEq(settler.escapeDelay(), 259200, "escapeDelay corrupted");
        assertEq(settler.owner(), owner, "owner corrupted");
        assertEq(settler.operator(), operatorAddr, "operator corrupted");
        assertEq(settler.treasury(), TREASURY, "treasury corrupted");
        assertEq(settler.aavePool(), AAVE_V3_POOL, "aavePool corrupted");
        assertEq(settler.swapRouter(), SWAP_ROUTER, "swapRouter corrupted");
    }

    function test_putPhysicalRedeem_ITM_noFlashLoan() public {
        if (block.chainid != 8453) return;

        uint256 strike = 5000e8;
        uint256 amount = 1e8;
        uint256 collateral = 5000e6;

        address oToken = _createOtoken(WETH, USDC, USDC, strike, true);
        uint256 vaultId = _executeOrder(oToken, amount, collateral, 50e6);

        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 1800e8);

        _settleVault(user, vaultId);

        uint256 userWethBefore = IERC20(WETH).balanceOf(user);
        uint256 mmUsdcBefore = IERC20(USDC).balanceOf(mm);

        vm.prank(operatorAddr);
        settler.physicalRedeem(oToken, user, amount, collateral, mm);

        assertEq(IERC20(WETH).balanceOf(user) - userWethBefore, 1e18, "user did not receive exact WETH");
        assertGt(IERC20(USDC).balanceOf(mm), mmUsdcBefore, "MM did not receive surplus USDC");
        assertEq(settler.mmOTokenBalance(mm, oToken), 0, "MM oToken balance not cleared");
        assertEq(IERC20(USDC).balanceOf(address(settler)), 0, "settler retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "settler retained WETH");
    }

    function test_callPhysicalRedeem_ITM_noFlashLoan() public {
        if (block.chainid != 8453) return;

        uint256 strike = 1000e8;
        uint256 amount = 1e8;
        uint256 collateral = 1e18;
        uint256 expectedUsdc = 1000e6;

        address oToken = _createOtoken(WETH, USDC, WETH, strike, false);
        uint256 vaultId = _executeOrder(oToken, amount, collateral, 30e6);

        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 2200e8);

        _settleVault(user, vaultId);

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(user);
        uint256 mmUsdcBefore = IERC20(USDC).balanceOf(mm);

        vm.prank(operatorAddr);
        settler.physicalRedeem(oToken, user, amount, 0, mm);

        assertEq(IERC20(USDC).balanceOf(user) - userUsdcBefore, expectedUsdc, "user did not receive exact USDC");
        assertGt(IERC20(USDC).balanceOf(mm), mmUsdcBefore, "MM did not receive surplus USDC");
        assertEq(settler.mmOTokenBalance(mm, oToken), 0, "MM oToken balance not cleared");
        assertEq(IERC20(USDC).balanceOf(address(settler)), 0, "settler retained USDC");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "settler retained WETH");
    }

    function test_otmStillReverts() public {
        if (block.chainid != 8453) return;

        uint256 strike = 5000e8;
        uint256 amount = 1e8;
        uint256 collateral = 5000e6;

        address oToken = _createOtoken(WETH, USDC, USDC, strike, true);
        uint256 vaultId = _executeOrder(oToken, amount, collateral, 50e6);

        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 7000e8);

        _settleVault(user, vaultId);

        vm.startPrank(operatorAddr);
        vm.expectRevert(BatchSettler.OptionNotITM.selector);
        settler.physicalRedeem(oToken, user, amount, collateral, mm);
        vm.stopPrank();
    }

    function test_executeOperationStillDeadSurface() public {
        if (block.chainid != 8453) return;

        vm.prank(AAVE_V3_POOL);
        vm.expectRevert(BatchSettler.FlashLoanUnauthorized.selector);
        settler.executeOperation(WETH, 1e18, 0, address(settler), "");
    }

    function _createOtoken(address underlying, address strikeAsset, address collateralAsset, uint256 strike, bool isPut)
        internal
        returns (address oToken)
    {
        vm.prank(factoryOperator);
        oToken = factory.createOToken(underlying, strikeAsset, collateralAsset, strike, expiry, isPut);

        vm.prank(owner);
        whitelist.whitelistOToken(oToken);
    }

    function _executeOrder(address oToken, uint256 amount, uint256 collateral, uint256 bidPrice)
        internal
        returns (uint256 vaultId)
    {
        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: block.timestamp + 1 hours,
            quoteId: nextQuoteId++,
            maxAmount: 100e8,
            makerNonce: settler.makerNonce(mm)
        });

        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vaultId = settler.executeOrder(quote, sig, amount, collateral);
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
