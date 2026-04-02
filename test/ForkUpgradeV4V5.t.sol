// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/OToken.sol";
import "../src/core/BatchSettler.sol";
import "../src/interfaces/IAaveV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Full Aave reserve data for aToken lookup
interface IAavePoolFull {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
}

/**
 * @title ForkUpgradeV4V5
 * @notice Fork test against Base mainnet verifying B1N-204
 *         (Controller) and B1N-267 (MarginPool Aave) upgrades.
 *
 *         Run:
 *         forge test --match-contract ForkUpgradeV4V5 \
 *           --fork-url $BASE_RPC_URL -vvv
 */
contract ForkUpgradeV4V5 is Test {
    // --- Mainnet proxies ---
    Controller controller = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    MarginPool pool = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);
    OTokenFactory factory = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Oracle oracle = Oracle(0x09daa0194A3AF59b46C5443aF9C20fAd98347671);
    Whitelist whitelist = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    BatchSettler settler = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);

    // --- External addresses ---
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant OPERATOR = 0x0bbD599cEB63b4603c2F007c5122e33f7b12364c;

    // aToken addresses (verified on-chain 2026-04-02)
    address constant A_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant A_WETH = 0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7;
    address constant A_CBBTC = 0xBdb9300b7CDE636d9cD4AFF00f6F009fFBBc8EE6;

    address owner;
    address factoryOperator;
    address user = address(0xBEEF);
    uint256 expiry;

    function setUp() public {
        if (block.chainid != 8453) {
            emit log("SKIPPED: requires --fork-url (Base 8453)");
            return;
        }

        owner = controller.owner();
        factoryOperator = factory.operator();

        // --- V4: Controller upgrade ---
        vm.startPrank(owner);

        Controller controllerImpl = new Controller();
        controller.upgradeToAndCall(address(controllerImpl), "");

        // --- V5: MarginPool upgrade + Aave config ---
        MarginPool poolImpl = new MarginPool();
        pool.upgradeToAndCall(address(poolImpl), "");

        pool.setAavePool(AAVE_V3_POOL);
        pool.setYieldRecipient(OPERATOR);
        pool.setOperator(OPERATOR);
        pool.setAToken(USDC, A_USDC);
        pool.setAToken(WETH, A_WETH);
        pool.setAToken(CBBTC, A_CBBTC);
        pool.approveAave(USDC);
        pool.approveAave(WETH);
        pool.approveAave(CBBTC);

        // Disable oracle checks for testing
        oracle.setMaxOracleStaleness(0);
        oracle.setPriceDeviationThreshold(0);

        vm.stopPrank();

        // Expiry: next 08:00 UTC
        uint256 nextDay = block.timestamp + 1 days;
        expiry = nextDay - (nextDay % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        // Fund user
        deal(USDC, user, 10_000_000e6);
        deal(WETH, user, 100e18);
        deal(CBBTC, user, 10e8);

        // Approvals
        vm.startPrank(user);
        IERC20(USDC).approve(address(pool), type(uint256).max);
        IERC20(WETH).approve(address(pool), type(uint256).max);
        IERC20(CBBTC).approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    // ========== Controller Tests (V4) ==========

    function test_controllerUpgrade_preservesState() public {
        if (block.chainid != 8453) return;

        assertEq(controller.owner(), owner, "owner corrupted");
        assertFalse(controller.systemFullyPaused(), "fullPause corrupted");
        assertFalse(controller.systemPartiallyPaused(), "partialPause corrupted");
    }

    function test_controllerUpgrade_blocksZeroCollateralPut() public {
        if (block.chainid != 8453) return;

        // Create a put option with low strike
        uint256 strike = 1e8; // $1 strike
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        // Deposit 1 wei of USDC to set the collateral type, then
        // try to mint amount=1. With strike=1e8 (=$1):
        //   required = (1 * 1e8) / 1e10 = 0
        // B1N-204 guard: required==0 && amount>0 → revert
        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, USDC, 1);
        vm.expectRevert(Controller.InsufficientCollateral.selector);
        controller.mintOtoken(user, 1, oToken, 1, user);
        vm.stopPrank();
    }

    function test_controllerUpgrade_normalMintingWorks() public {
        if (block.chainid != 8453) return;

        uint256 strike = 1337e8; // Unique strike to avoid OTokenAlreadyExists
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, USDC, 1337e6);
        controller.mintOtoken(user, 1, oToken, 1e8, user);
        vm.stopPrank();

        assertEq(OToken(oToken).balanceOf(user), 1e8, "oToken not minted");
    }

    // ========== MarginPool Tests (V5) ==========

    function test_marginPoolUpgrade_preservesState() public {
        if (block.chainid != 8453) return;

        assertEq(address(pool.addressBook()), 0x48FE24a69417038a2D3d46B2B6B9De03b884eD72, "addressBook corrupted");
    }

    function test_marginPoolUpgrade_aaveConfigured() public {
        if (block.chainid != 8453) return;

        assertEq(address(pool.aavePool()), AAVE_V3_POOL, "aavePool not set");
        assertEq(pool.yieldRecipient(), OPERATOR, "yieldRecipient not set");
        assertEq(pool.operator(), OPERATOR, "operator not set");
    }

    function test_marginPoolUpgrade_aaveDisabledByDefault() public {
        if (block.chainid != 8453) return;

        assertFalse(pool.isAaveEnabled(USDC), "USDC should be disabled");
        assertFalse(pool.isAaveEnabled(WETH), "WETH should be disabled");
        assertFalse(pool.isAaveEnabled(CBBTC), "cbBTC should be disabled");
    }

    function test_marginPoolUpgrade_aTokenMappings() public {
        if (block.chainid != 8453) return;

        // Verify our hardcoded aToken addresses match Aave
        IAavePoolFull aave = IAavePoolFull(AAVE_V3_POOL);

        assertEq(aave.getReserveData(USDC).aTokenAddress, A_USDC, "aUSDC mismatch");
        assertEq(aave.getReserveData(WETH).aTokenAddress, A_WETH, "aWETH mismatch");
        assertEq(aave.getReserveData(CBBTC).aTokenAddress, A_CBBTC, "aCBBTC mismatch");
    }

    function test_marginPoolUpgrade_passthroughWorks() public {
        if (block.chainid != 8453) return;

        // With Aave disabled, transferToPool/transferToUser
        // should work as pure passthrough
        uint256 strike = 2345e8; // Unique strike
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        // Deposit and mint (uses transferToPool under the hood)
        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, USDC, 2345e6);
        controller.mintOtoken(user, 1, oToken, 1e8, user);
        vm.stopPrank();

        // USDC should be in pool directly (not Aave)
        assertGe(IERC20(USDC).balanceOf(address(pool)), 2345e6, "USDC not in pool");
        assertEq(pool.totalDeposited(USDC), 0, "totalDeposited should be 0 with Aave disabled");

        // Settle OTM → collateral returned via transferToUser
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 2500e8);

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = user;
        ids[0] = 1;
        vm.prank(settler.operator());
        settler.batchSettleVaults(owners, ids);

        assertEq(IERC20(USDC).balanceOf(user) - usdcBefore, 2345e6, "Collateral not returned");
    }

    function test_marginPoolUpgrade_aaveEnableWorks() public {
        if (block.chainid != 8453) return;

        // Enable USDC routing
        vm.prank(owner);
        pool.setAaveEnabled(USDC, true);
        assertTrue(pool.isAaveEnabled(USDC));

        // Deposit via vault → should route to Aave
        uint256 strike = 3456e8; // Unique strike
        vm.prank(factoryOperator);
        address oToken = factory.createOToken(WETH, USDC, USDC, strike, expiry, true);
        vm.prank(owner);
        whitelist.whitelistOToken(oToken);

        vm.startPrank(user);
        controller.openVault(user);
        controller.depositCollateral(user, 1, USDC, 3456e6);
        controller.mintOtoken(user, 1, oToken, 1e8, user);
        vm.stopPrank();

        // USDC should be in Aave (pool holds aTokens)
        assertEq(pool.totalDeposited(USDC), 3456e6, "totalDeposited wrong");
        assertGe(IERC20(A_USDC).balanceOf(address(pool)), 3456e6 - 1, "aUSDC not in pool");

        // Settle OTM → collateral withdrawn from Aave
        vm.warp(expiry + 1);
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, 4000e8);

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        address[] memory owners = new address[](1);
        uint256[] memory ids = new uint256[](1);
        owners[0] = user;
        ids[0] = 1;
        vm.prank(settler.operator());
        settler.batchSettleVaults(owners, ids);

        assertEq(IERC20(USDC).balanceOf(user) - usdcBefore, 3456e6, "Collateral not returned from Aave");
        assertEq(pool.totalDeposited(USDC), 0, "totalDeposited not cleared");
    }
}
