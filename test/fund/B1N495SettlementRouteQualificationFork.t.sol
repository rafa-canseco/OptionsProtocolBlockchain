// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PairRoutingSwapRouter} from "../../src/routers/PairRoutingSwapRouter.sol";
import {AerodromeSlipstreamAdapter} from "../../src/routers/AerodromeSlipstreamAdapter.sol";
import {B1N495RoutePreflight} from "../../script/B1N495RoutePreflight.sol";
import {B1N495RouteToolsBase} from "../../script/B1N495RouteTools.s.sol";

interface IB1N495Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

interface IB1N495AerodromeFactory {
    function getPool(address, address, int24) external view returns (address);
    function getSwapFee(address) external view returns (uint24);
    function isPool(address) external view returns (bool);
}

interface IB1N495AerodromeRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }
    function factory() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256);
}

interface IB1N495AerodromeQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }
    function factory() external view returns (address);
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata)
        external
        returns (uint256, uint160, uint32, uint256);
    function quoteExactOutputSingle(QuoteExactOutputSingleParams calldata)
        external
        returns (uint256, uint160, uint32, uint256);
}

interface IB1N495UniswapFactory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IB1N495UniswapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256);
}

interface IB1N495UniswapQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata)
        external
        returns (uint256, uint160, uint32, uint256);
    function quoteExactOutputSingle(QuoteExactOutputSingleParams calldata)
        external
        returns (uint256, uint160, uint32, uint256);
}

interface IB1N495Aggregator {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IB494BatchSettlerView {
    function swapRouter() external view returns (address);
}

interface IB1N495OracleRegistry {
    function getOracleParams(address token) external view returns (uint256 multiplier, bool paused);
}

interface IB1N495PolicyRegistry {
    function policyExists(uint64 policyId) external view returns (bool);
    function isAuthorized(uint64 policyId, address account) external view returns (bool);
}

interface IB1N495B20 is IERC20Metadata {
    function multiplier() external view returns (uint256);
    function pausedFeatures() external view returns (uint8[] memory);
    function isPaused(uint8) external view returns (bool);
    function TRANSFER_SENDER_POLICY() external view returns (bytes32);
    function TRANSFER_RECEIVER_POLICY() external view returns (bytes32);
    function TRANSFER_EXECUTOR_POLICY() external view returns (bytes32);
    function policyId(bytes32) external view returns (uint64);
}

contract B1N495RoutePreflightHarness is B1N495RoutePreflight {
    function deviationBps(uint256 observed, uint256 expected) external pure returns (uint256) {
        return _deviationBps(observed, expected);
    }
}

contract B1N495RouteToolsHarness is B1N495RouteToolsBase {
    function deploy(address owner) external returns (Addresses memory) {
        return _deploy(owner);
    }

    function proposeApproved(Addresses calldata addresses_) external {
        _proposeApproved(addresses_);
    }

    function activateEligible(Addresses calldata addresses_) external {
        _activatePreserved(addresses_);
    }
}

/// @notice Pinned, read-only qualification evidence. It deploys nothing and submits no transaction.
/// @dev Base-native B20 execution requires base-forge v1.1.0 commit 6130ccf6af0b3399777aee3876486e2ba9ebb38f.
contract B1N495SettlementRouteQualificationForkTest is Test {
    uint256 private constant PINNED_BLOCK = 50_780_000;
    uint256 private constant PINNED_TIMESTAMP = 1_788_349_347;
    bytes32 private constant PARENT_HASH = 0x25fe310773dc0da61c61050b004c8fad9279b093ac804f45cc99857788e79db2;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant IMPACT_LIMIT_BPS = 30;
    bytes4 private constant SLOT0_SELECTOR = bytes4(keccak256("slot0()"));

    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant WETH = 0x4200000000000000000000000000000000000006;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address private constant MARGIN_POOL = 0xa1e04873F6d112d84824C88c9D6937bE38811657;
    address private constant ORACLE_REGISTRY = 0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD;
    address private constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    address private constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address private constant CBZEC = 0xB2000000000000000000008501b13360000cb2EC;
    address private constant CBHYPE = 0xB200000000000000000000451d033a5000cb479e;
    address private constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    address private constant AERO_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address private constant AERO_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address private constant AERO_QUOTER = 0x514c8B5f54112481E28028F1166Bd78501089259;
    address private constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private constant UNI_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address private constant UNI_QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    address private constant NVDAC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    address private constant CBZEC_POOL = 0x0Fc47C17AF86078d809358db1b4db2DeBC988566;
    address private constant CBHYPE_POOL = 0xD5Eaea9da564217EA101D1E369fDA168A3025686;
    address private constant VVV_POOL = 0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530;
    address private constant NVDAC_FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    address private constant VVV_FEED = 0xaABc55Ca55D70B034e4daA2551A224239890282F;
    address private constant NVDAC_HOLDER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address private constant COINBASE_HOT_WALLET = 0x40EbC1Ac8d4Fedd2E144b75fe9C0420BE82750c6;
    address private constant CBZEC_SECOND_HOLDER = 0x4B5c71082d027D16d2A146465d66f9EEC11634F6;

    struct Route {
        string symbol;
        address asset;
        address pool;
        int24 spacing;
        uint24 fee;
        uint8 decimals;
        bool aerodrome;
        address feed;
        uint8 feedDecimals;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"), PINNED_BLOCK);
        assertEq(block.chainid, 8453);
        assertEq(block.number, PINNED_BLOCK);
        assertEq(block.timestamp, PINNED_TIMESTAMP);
        assertEq(blockhash(PINNED_BLOCK - 1), PARENT_HASH);
    }

    function test_canonicalIdentitiesOrderedRoutesAndOracleAvailability() public view {
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        assertEq(IB1N495AerodromeRouter(AERO_ROUTER).factory(), AERO_FACTORY);
        assertEq(IB1N495AerodromeQuoter(AERO_QUOTER).factory(), AERO_FACTORY);
        for (uint256 i; i < 4; ++i) {
            Route memory route = _route(i);
            IB1N495Pool pool = IB1N495Pool(route.pool);
            assertEq(IERC20Metadata(route.asset).decimals(), route.decimals);
            assertEq(pool.token0(), USDC);
            assertEq(pool.token1(), route.asset);
            assertEq(pool.factory(), route.aerodrome ? AERO_FACTORY : UNI_FACTORY);
            assertEq(pool.tickSpacing(), route.spacing);
            assertEq(pool.fee(), route.fee);
            assertGt(pool.liquidity(), 0);
            if (route.aerodrome) {
                assertEq(IB1N495AerodromeFactory(AERO_FACTORY).getPool(route.asset, USDC, route.spacing), route.pool);
                assertEq(IB1N495AerodromeFactory(AERO_FACTORY).getSwapFee(route.pool), route.fee);
                assertTrue(IB1N495AerodromeFactory(AERO_FACTORY).isPool(route.pool));
            } else {
                assertEq(IB1N495UniswapFactory(UNI_FACTORY).getPool(route.asset, USDC, route.fee), route.pool);
            }
            // Production route order is intentionally asymmetric.
            assertEq(_routeKey(USDC, route.asset, 1), keccak256(abi.encode(USDC, route.asset, uint8(1))));
            assertEq(_routeKey(route.asset, USDC, 0), keccak256(abi.encode(route.asset, USDC, uint8(0))));
        }

        assertEq(IB1N495Aggregator(NVDAC_FEED).decimals(), 8);
        assertEq(IB1N495Aggregator(VVV_FEED).decimals(), 18);
        assertTrue(_freshPositive(NVDAC_FEED));
        assertTrue(_freshPositive(VVV_FEED));
        assertNotEq(IB1N495Aggregator(VVV_FEED).decimals(), 8); // Oracle.sol consumes raw answers as 8 decimals.
    }

    function test_b20PolicyPauseMultiplierDecimalsAndRawTransfers() public {
        PairRoutingSwapRouter facade = new PairRoutingSwapRouter(SETTLER, address(this));
        for (uint256 i; i < 3; ++i) {
            Route memory route = _route(i);
            IB1N495B20 token = IB1N495B20(route.asset);
            AerodromeSlipstreamAdapter adapter = new AerodromeSlipstreamAdapter(
                address(facade), AERO_ROUTER, AERO_FACTORY, route.pool, route.asset, USDC, route.spacing
            );
            assertEq(token.decimals(), route.decimals);
            assertEq(token.multiplier(), 1e18);
            (uint256 oracleMultiplier, bool oraclePaused) =
                IB1N495OracleRegistry(ORACLE_REGISTRY).getOracleParams(route.asset);
            assertEq(oracleMultiplier, token.multiplier());
            assertFalse(oraclePaused);
            assertEq(token.pausedFeatures().length, 0);
            for (uint8 feature; feature < 3; ++feature) {
                assertFalse(token.isPaused(feature));
            }
            uint64 expectedPolicy = uint64(i == 0 ? 5 : 117 + i);
            assertEq(token.policyId(token.TRANSFER_SENDER_POLICY()), expectedPolicy);
            assertEq(token.policyId(token.TRANSFER_RECEIVER_POLICY()), expectedPolicy);
            assertEq(token.policyId(token.TRANSFER_EXECUTOR_POLICY()), expectedPolicy);
            assertTrue(IB1N495PolicyRegistry(POLICY_REGISTRY).policyExists(expectedPolicy));
            assertEq(uint8(expectedPolicy >> 56), 0); // BLOCKLIST type tag.
            address holder = route.asset == NVDAC ? NVDAC_HOLDER : COINBASE_HOT_WALLET;
            address[8] memory participants = [
                SETTLER, MARGIN_POOL, address(facade), address(adapter), AERO_ROUTER, route.pool, address(this), holder
            ];
            for (uint256 participant; participant < participants.length; ++participant) {
                assertTrue(
                    IB1N495PolicyRegistry(POLICY_REGISTRY).isAuthorized(expectedPolicy, participants[participant])
                );
            }
            if (route.asset == CBZEC) {
                assertTrue(IB1N495PolicyRegistry(POLICY_REGISTRY).isAuthorized(expectedPolicy, CBZEC_SECOND_HOLDER));
            }

            uint256 snapshot = vm.snapshotState();
            uint256 beforeBalance = token.balanceOf(address(this));
            _fund(route, route.asset, 1);
            assertEq(token.balanceOf(address(this)), beforeBalance + 1);
            uint256 sinkBefore = token.balanceOf(address(0x495));
            assertTrue(token.transfer(address(0x495), 1));
            assertEq(token.balanceOf(address(0x495)), sinkBefore + 1);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_routeToolsAreDeterministicIdempotentDelayedAndKeepNewRoutesDisabled() public {
        B1N495RouteToolsHarness tools = new B1N495RouteToolsHarness();
        B1N495RouteToolsBase.Addresses memory deployed = tools.deploy(address(tools));
        B1N495RouteToolsBase.Addresses memory reused = tools.deploy(address(tools));
        assertEq(keccak256(abi.encode(deployed)), keccak256(abi.encode(reused)));
        assertEq(IB494BatchSettlerView(SETTLER).swapRouter(), UNI_ROUTER);

        tools.proposeApproved(deployed);
        tools.proposeApproved(deployed);
        PairRoutingSwapRouter facade = PairRoutingSwapRouter(payable(deployed.facade));
        _assertRoute(facade, WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), deployed.uniswapAdapter);
        _assertRoute(
            facade, USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput, address(0), deployed.uniswapAdapter
        );
        _assertRoute(
            facade, CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), deployed.uniswapAdapter
        );
        _assertRoute(
            facade, USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput, address(0), deployed.uniswapAdapter
        );
        _assertRoute(facade, NVDAC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        _assertRoute(facade, USDC, NVDAC, PairRoutingSwapRouter.SwapKind.ExactOutput, address(0), address(0));
        _assertRoute(facade, CBHYPE, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        _assertRoute(facade, USDC, CBHYPE, PairRoutingSwapRouter.SwapKind.ExactOutput, address(0), address(0));
        _assertRoute(facade, CBZEC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        _assertRoute(facade, USDC, CBZEC, PairRoutingSwapRouter.SwapKind.ExactOutput, address(0), address(0));
        _assertRoute(facade, VVV, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        _assertRoute(facade, USDC, VVV, PairRoutingSwapRouter.SwapKind.ExactOutput, address(0), address(0));

        vm.expectRevert();
        tools.activateEligible(deployed);
        vm.warp(block.timestamp + 1 days);
        tools.activateEligible(deployed);
        tools.activateEligible(deployed);
        _assertRoute(facade, WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, deployed.uniswapAdapter, address(0));
        _assertRoute(facade, NVDAC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        _assertRoute(facade, CBHYPE, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        _assertRoute(facade, CBZEC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        _assertRoute(facade, VVV, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), address(0));
        assertEq(IB494BatchSettlerView(SETTLER).swapRouter(), UNI_ROUTER);
    }

    function test_routeToolsRejectExcludedPendingRoute() public {
        B1N495RouteToolsHarness tools = new B1N495RouteToolsHarness();
        B1N495RouteToolsBase.Addresses memory deployed = tools.deploy(address(tools));
        vm.prank(address(tools));
        PairRoutingSwapRouter(payable(deployed.facade))
            .proposeRoute(CBZEC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, deployed.cbzecAdapter);
        vm.expectRevert();
        tools.proposeApproved(deployed);
    }

    function test_routeToolsRejectForeignPendingReplacementOverExpectedActiveRoute() public {
        B1N495RouteToolsHarness tools = new B1N495RouteToolsHarness();
        B1N495RouteToolsBase.Addresses memory deployed = tools.deploy(address(tools));
        tools.proposeApproved(deployed);
        vm.warp(block.timestamp + 1 days);
        tools.activateEligible(deployed);
        vm.prank(address(tools));
        PairRoutingSwapRouter(payable(deployed.facade))
            .proposeRoute(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, deployed.cbzecAdapter);
        vm.expectRevert();
        tools.proposeApproved(deployed);
    }

    function test_preflightFailsClosedAndReportsPinnedEligibility() public {
        B1N495RouteToolsHarness tools = new B1N495RouteToolsHarness();
        B1N495RouteToolsBase.Addresses memory deployed = tools.deploy(address(tools));
        B1N495RoutePreflight preflight = new B1N495RoutePreflight();
        B1N495RoutePreflight.Deployment memory deployment = B1N495RoutePreflight.Deployment({
            routeOwner: address(tools),
            settlementRecipient: address(this),
            facade: deployed.facade,
            nvdacAdapter: deployed.nvdacAdapter,
            cbzecAdapter: deployed.cbzecAdapter,
            cbhypeAdapter: deployed.cbhypeAdapter,
            uniswapAdapter: deployed.uniswapAdapter
        });
        B1N495RoutePreflight.OracleEvidence memory evidence = B1N495RoutePreflight.OracleEvidence({
            observedAt: block.timestamp,
            cbzecPrice8: _spotPrice8(CBZEC_POOL, 8),
            cbzecUpdatedAt: block.timestamp - 1 hours - 1,
            cbhypePrice8: _spotPrice8(CBHYPE_POOL, 18),
            cbhypeUpdatedAt: block.timestamp
        });
        B1N495RoutePreflight.Result memory result = preflight.check(deployment, evidence);
        assertFalse(result.nvdacEligible); // Pinned NVDA round is older than the deployment-time one-hour policy.
        assertFalse(result.cbzecEvidencePass);
        assertTrue(result.cbhypeEligible);
        assertTrue(result.vvvEvidencePass); // Historical evidence only; this release never proposes VVV.

        vm.mockCall(
            POLICY_REGISTRY,
            abi.encodeCall(IB1N495PolicyRegistry.isAuthorized, (uint64(119), address(tools))),
            abi.encode(false)
        );
        vm.expectRevert(
            abi.encodeWithSelector(B1N495RoutePreflight.PreflightFailed.selector, bytes32("B20_AUTHORIZATION"))
        );
        preflight.check(deployment, evidence);
    }

    function test_preflightDeviationRoundsUpAtPolicyBoundary() public {
        B1N495RoutePreflightHarness preflight = new B1N495RoutePreflightHarness();
        uint256 expected = 100_000_000;

        assertEq(preflight.deviationBps(101_000_000, expected), 100);
        assertEq(preflight.deviationBps(99_000_000, expected), 100);
        assertEq(preflight.deviationBps(101_000_001, expected), 101);
        assertEq(preflight.deviationBps(98_999_999, expected), 101);
    }

    function test_amountMatrixAndDeterministicEconomicBoundaries() public {
        uint256[4] memory sizes = [uint256(100), 1_000, 5_000, 10_000];
        for (uint256 i; i < 4; ++i) {
            Route memory route = _route(i);
            for (uint256 direction; direction < 2; ++direction) {
                for (uint256 mode; mode < 2; ++mode) {
                    for (uint256 n; n < sizes.length; ++n) {
                        this.matrixScenario(route, direction == 0, mode == 0, sizes[n]);
                    }
                }
                uint256[3] memory guards = [uint256(30), 50, 100];
                for (uint256 guardIndex; guardIndex < guards.length; ++guardIndex) {
                    (uint256 boundary, bool venueFailed, bool ceilingReached) =
                        _findBoundary(route, direction == 0, guards[guardIndex]);
                    emit log_named_string("boundary_asset", route.symbol);
                    emit log_named_string("boundary_direction", direction == 0 ? "USDC->asset" : "asset->USDC");
                    emit log_named_uint("boundary_guard_bps", guards[guardIndex]);
                    emit log_named_uint("last_qualified_usdc", boundary);
                    emit log_named_uint("boundary_is_lower_bound", ceilingReached ? 1 : 0);
                    emit log_named_uint("next_10_usdc_quote_failed", venueFailed ? 1 : 0);
                    (uint256 expectedBoundary, bool expectedLowerBound) = _expectedBoundary(i, direction, guardIndex);
                    assertEq(boundary, expectedBoundary);
                    assertEq(ceilingReached, expectedLowerBound);
                    assertFalse(venueFailed);
                }
            }
        }
    }

    function test_adverseMovePassesInsideAndRevertsOutsideForBothSwapModes() public {
        for (uint256 i; i < 4; ++i) {
            Route memory route = _route(i);
            _adverseBoundary(route, true, false); // PUT: USDC -> asset exact-output
            _adverseBoundary(route, false, true); // CALL: asset -> USDC exact-input
        }
    }

    function matrixScenario(Route calldata route, bool usdcToAsset, bool exactInput, uint256 notional) external {
        require(msg.sender == address(this));
        uint256 snapshot = vm.snapshotState();
        uint256 usdcAmount = notional * 1e6;
        uint256 assetAmount = _assetForUsdcEquivalent(route, usdcAmount);
        address tokenIn = usdcToAsset ? USDC : route.asset;
        address tokenOut = usdcToAsset ? route.asset : USDC;
        uint256 requested = usdcToAsset ? usdcAmount : assetAmount;
        uint256 desired = usdcToAsset ? assetAmount : usdcAmount;
        uint160 sqrtBefore = _sqrtPrice(route.pool);
        (uint256 quote,, uint32 ticks) = _quote(route, tokenIn, tokenOut, exactInput, exactInput ? requested : desired);
        uint256 poolInBefore = IERC20(tokenIn).balanceOf(route.pool);
        uint256 poolOutBefore = IERC20(tokenOut).balanceOf(route.pool);
        _fund(route, tokenIn, exactInput ? requested : quote);
        assertEq(IERC20(tokenIn).balanceOf(route.pool), poolInBefore);
        assertEq(IERC20(tokenOut).balanceOf(route.pool), poolOutBefore);
        uint256 beforeOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 actual =
            _swap(route, tokenIn, tokenOut, exactInput, exactInput ? requested : desired, exactInput ? 0 : quote);
        uint256 delivered = IERC20(tokenOut).balanceOf(address(this)) - beforeOut;
        if (exactInput) assertEq(actual, delivered);
        else assertEq(delivered, desired);
        uint256 actualInput = exactInput ? requested : actual;
        assertEq(IERC20(tokenIn).balanceOf(route.pool) - poolInBefore, actualInput);
        assertEq(poolOutBefore - IERC20(tokenOut).balanceOf(route.pool), delivered);

        uint256 observed = exactInput ? delivered : actual;
        uint256 expected =
            exactInput ? _spotOutput(sqrtBefore, tokenIn, requested) : _spotInput(sqrtBefore, tokenIn, desired);
        uint256 impact = _deviationBps(observed, expected);
        uint256 oracleDeviation =
            _oracleDeviation(route, usdcToAsset, exactInput, requested, desired, actual, delivered);
        emit log_named_string("matrix_asset", route.symbol);
        emit log_named_string("matrix_direction", usdcToAsset ? "USDC->asset" : "asset->USDC");
        emit log_named_string("matrix_mode", exactInput ? "exact-input" : "exact-output");
        emit log_named_uint("matrix_usdc_equivalent", notional);
        emit log_named_uint("quote_raw", quote);
        emit log_named_uint("actual_input_raw", exactInput ? requested : actual);
        emit log_named_uint("actual_output_raw", exactInput ? delivered : desired);
        emit log_named_uint("venue_fee_pips", route.fee);
        emit log_named_uint("execution_impact_bps_vs_pre_swap_spot", impact);
        emit log_named_uint("initialized_ticks_crossed", ticks);
        emit log_named_uint("active_liquidity_after", IB1N495Pool(route.pool).liquidity());
        emit log_named_uint("independent_oracle_available", route.feed == address(0) ? 0 : 1);
        if (route.feed != address(0)) emit log_named_uint("independent_oracle_deviation_bps", oracleDeviation);
        assertEq(observed, quote);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _adverseBoundary(Route memory route, bool usdcToAsset, bool exactInput) private {
        uint256 snapshot = vm.snapshotState();
        address tokenIn = usdcToAsset ? USDC : route.asset;
        address tokenOut = usdcToAsset ? route.asset : USDC;
        uint256 amount = _assetForUsdcEquivalent(route, 100e6);
        if (usdcToAsset) amount = exactInput ? 100e6 : amount;
        else amount = exactInput ? amount : 100e6;
        (uint256 beforeQuote,,) = _quote(route, tokenIn, tokenOut, exactInput, amount);
        uint256 staleLimit =
            exactInput ? beforeQuote * (10_000 - IMPACT_LIMIT_BPS) / 10_000 : _withBps(beforeQuote, IMPACT_LIMIT_BPS);
        uint256 maxMoveUsdc = _maxFundableMoveUsdc(route, tokenIn, exactInput ? amount : staleLimit);
        (uint256 insideMove, uint256 outsideMove) =
            _findStaleBoundary(route, tokenIn, tokenOut, exactInput, amount, staleLimit, maxMoveUsdc);

        uint256 insideQuote =
            _executeAfterMove(route, tokenIn, tokenOut, exactInput, amount, staleLimit, insideMove, false);
        emit log_named_string("adverse_asset", route.symbol);
        emit log_named_string("adverse_mode", exactInput ? "CALL exact-input" : "PUT exact-output");
        emit log_named_uint("stale_quote", beforeQuote);
        emit log_named_uint("stale_limit", staleLimit);
        emit log_named_uint("inside_adversary_usdc", insideMove);
        emit log_named_uint("inside_moved_quote", insideQuote);
        emit log_named_uint("outside_boundary_available", outsideMove == 0 ? 0 : 1);

        if (outsideMove != 0) {
            uint256 outsideQuote =
                _executeAfterMove(route, tokenIn, tokenOut, exactInput, amount, staleLimit, outsideMove, true);
            emit log_named_uint("outside_adversary_usdc", outsideMove);
            emit log_named_uint("outside_moved_quote", outsideQuote);
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _findStaleBoundary(
        Route memory route,
        address tokenIn,
        address tokenOut,
        bool exactInput,
        uint256 amount,
        uint256 staleLimit,
        uint256 maxMoveUsdc
    ) private returns (uint256 low, uint256 high) {
        high = 10;
        if (high > maxMoveUsdc) high = maxMoveUsdc;
        while (high != 0 && _staleBoundHolds(route, tokenIn, tokenOut, exactInput, amount, staleLimit, high)) {
            low = high;
            if (high == maxMoveUsdc) return (low, 0);
            high = high * 2 > maxMoveUsdc ? maxMoveUsdc : high * 2;
        }
        while (high > low + 10) {
            uint256 mid = ((low + high) / 20) * 10;
            if (_staleBoundHolds(route, tokenIn, tokenOut, exactInput, amount, staleLimit, mid)) low = mid;
            else high = mid;
        }
    }

    function _staleBoundHolds(
        Route memory route,
        address tokenIn,
        address tokenOut,
        bool exactInput,
        uint256 amount,
        uint256 staleLimit,
        uint256 moveUsdc
    ) private returns (bool) {
        uint256 movedQuote = _quoteAfterMove(route, tokenIn, tokenOut, exactInput, amount, moveUsdc);
        return exactInput ? movedQuote >= staleLimit : movedQuote <= staleLimit;
    }

    function _quoteAfterMove(
        Route memory route,
        address tokenIn,
        address tokenOut,
        bool exactInput,
        uint256 amount,
        uint256 moveUsdc
    ) private returns (uint256 movedQuote) {
        uint256 snapshot = vm.snapshotState();
        uint256 moveInput = tokenIn == USDC ? moveUsdc * 1e6 : _assetForUsdc(route.pool, moveUsdc * 1e6);
        _fund(route, tokenIn, moveInput);
        _swap(route, tokenIn, tokenOut, true, moveInput, 0);
        (movedQuote,,) = _quote(route, tokenIn, tokenOut, exactInput, amount);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _executeAfterMove(
        Route memory route,
        address tokenIn,
        address tokenOut,
        bool exactInput,
        uint256 amount,
        uint256 staleLimit,
        uint256 moveUsdc,
        bool expectFailure
    ) private returns (uint256 movedQuote) {
        uint256 snapshot = vm.snapshotState();
        uint256 moveInput = tokenIn == USDC ? moveUsdc * 1e6 : _assetForUsdc(route.pool, moveUsdc * 1e6);
        uint256 poolInBefore = IERC20(tokenIn).balanceOf(route.pool);
        uint256 poolOutBefore = IERC20(tokenOut).balanceOf(route.pool);
        _fund(route, tokenIn, moveInput + (exactInput ? amount : _withBps(staleLimit, 100)));
        assertEq(IERC20(tokenIn).balanceOf(route.pool), poolInBefore);
        assertEq(IERC20(tokenOut).balanceOf(route.pool), poolOutBefore);
        _swap(route, tokenIn, tokenOut, true, moveInput, 0);
        (movedQuote,,) = _quote(route, tokenIn, tokenOut, exactInput, amount);
        if (expectFailure) {
            assertTrue(exactInput ? movedQuote < staleLimit : movedQuote > staleLimit);
            uint256 controlSnapshot = vm.snapshotState();
            assertEq(_swap(route, tokenIn, tokenOut, exactInput, amount, exactInput ? 0 : movedQuote), movedQuote);
            assertTrue(vm.revertToStateAndDelete(controlSnapshot));
            _expectSwapRevert(route, tokenIn, tokenOut, exactInput, amount, staleLimit);
        } else {
            assertTrue(exactInput ? movedQuote >= staleLimit : movedQuote <= staleLimit);
            assertEq(_swap(route, tokenIn, tokenOut, exactInput, amount, staleLimit), movedQuote);
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _maxFundableMoveUsdc(Route memory route, address tokenIn, uint256 reservedInput)
        private
        view
        returns (uint256)
    {
        if (tokenIn == USDC || tokenIn == VVV) return 100_000;
        uint256 available;
        if (tokenIn == NVDAC) {
            available = IERC20(tokenIn).balanceOf(NVDAC_HOLDER);
        } else if (tokenIn == CBHYPE) {
            available = IERC20(tokenIn).balanceOf(COINBASE_HOT_WALLET);
        } else {
            available = IERC20(tokenIn).balanceOf(COINBASE_HOT_WALLET) + IERC20(tokenIn).balanceOf(CBZEC_SECOND_HOLDER);
        }
        if (available <= reservedInput) return 0;
        return _usdcForAsset(route.pool, available - reservedInput) / 1e6 / 10 * 10;
    }

    function _expectedBoundary(uint256 asset, uint256 direction, uint256 guardIndex)
        private
        pure
        returns (uint256 depth, bool lowerBound)
    {
        if (asset == 0) {
            if (guardIndex == 0) return (direction == 0 ? 88_080 : 88_270, false);
            return (100_000, true);
        }
        if (asset == 1) {
            if (guardIndex == 0) return (480, false);
            if (guardIndex == 1) return (1_450, false);
            return (3_900, false);
        }
        if (asset == 2) {
            if (guardIndex == 0) return (340, false);
            if (guardIndex == 1) return (1_030, false);
            return (2_780, false);
        }
        if (guardIndex == 0) return (0, false);
        if (guardIndex == 1) return (1_330, false);
        return (direction == 0 ? 4_750 : 4_690, false);
    }

    function _findBoundary(Route memory route, bool usdcToAsset, uint256 guardBps)
        private
        returns (uint256, bool, bool)
    {
        uint256 low;
        uint256 high = 10;
        bool ok = _quoteWithinImpact(route, usdcToAsset, high, guardBps);
        while (ok && high < 100_000) {
            low = high;
            high = high * 2 > 100_000 ? 100_000 : high * 2;
            ok = _quoteWithinImpact(route, usdcToAsset, high, guardBps);
        }
        if (ok) return (high, false, true);
        while (high - low > 10) {
            uint256 mid = ((low + high) / 20) * 10;
            if (_quoteWithinImpact(route, usdcToAsset, mid, guardBps)) low = mid;
            else high = mid;
        }
        bool venueFailed = !_quoteExists(route, usdcToAsset, high);
        return (low, venueFailed, false);
    }

    function _quoteWithinImpact(Route memory route, bool usdcToAsset, uint256 notional, uint256 guardBps)
        private
        returns (bool)
    {
        uint256 usdcAmount = notional * 1e6;
        uint256 input = usdcToAsset ? usdcAmount : _assetForUsdc(route.pool, usdcAmount);
        address tokenIn = usdcToAsset ? USDC : route.asset;
        address tokenOut = usdcToAsset ? route.asset : USDC;
        uint160 sqrtBefore = _sqrtPrice(route.pool);
        try this.quoteExactInput(route, tokenIn, tokenOut, input) returns (uint256 output) {
            return output != 0 && _withinDeviationBps(output, _spotOutput(sqrtBefore, tokenIn, input), guardBps);
        } catch {
            return false;
        }
    }

    function _quoteExists(Route memory route, bool usdcToAsset, uint256 notional) private returns (bool) {
        uint256 usdcAmount = notional * 1e6;
        uint256 input = usdcToAsset ? usdcAmount : _assetForUsdc(route.pool, usdcAmount);
        try this.quoteExactInput(
            route, usdcToAsset ? USDC : route.asset, usdcToAsset ? route.asset : USDC, input
        ) returns (
            uint256 output
        ) {
            return output != 0;
        } catch {
            return false;
        }
    }

    function quoteExactInput(Route calldata route, address tokenIn, address tokenOut, uint256 amount)
        external
        returns (uint256 output)
    {
        require(msg.sender == address(this));
        (output,,) = _quote(route, tokenIn, tokenOut, true, amount);
    }

    function _quote(Route memory route, address tokenIn, address tokenOut, bool exactInput, uint256 amount)
        private
        returns (uint256 quote, uint160 sqrtAfter, uint32 ticks)
    {
        if (route.aerodrome) {
            if (exactInput) {
                (quote, sqrtAfter, ticks,) = IB1N495AerodromeQuoter(AERO_QUOTER)
                    .quoteExactInputSingle(
                        IB1N495AerodromeQuoter.QuoteExactInputSingleParams(tokenIn, tokenOut, amount, route.spacing, 0)
                    );
            } else {
                (quote, sqrtAfter, ticks,) = IB1N495AerodromeQuoter(AERO_QUOTER)
                    .quoteExactOutputSingle(
                        IB1N495AerodromeQuoter.QuoteExactOutputSingleParams(tokenIn, tokenOut, amount, route.spacing, 0)
                    );
            }
        } else {
            if (exactInput) {
                (quote, sqrtAfter, ticks,) = IB1N495UniswapQuoter(UNI_QUOTER)
                    .quoteExactInputSingle(
                        IB1N495UniswapQuoter.QuoteExactInputSingleParams(tokenIn, tokenOut, amount, route.fee, 0)
                    );
            } else {
                (quote, sqrtAfter, ticks,) = IB1N495UniswapQuoter(UNI_QUOTER)
                    .quoteExactOutputSingle(
                        IB1N495UniswapQuoter.QuoteExactOutputSingleParams(tokenIn, tokenOut, amount, route.fee, 0)
                    );
            }
        }
    }

    function _swap(
        Route memory route,
        address tokenIn,
        address tokenOut,
        bool exactInput,
        uint256 amount,
        uint256 limit
    ) private returns (uint256 actual) {
        address router = route.aerodrome ? AERO_ROUTER : UNI_ROUTER;
        IERC20(tokenIn).approve(router, exactInput ? amount : limit);
        if (route.aerodrome) {
            if (exactInput) {
                actual = IB1N495AerodromeRouter(router)
                    .exactInputSingle(
                        IB1N495AerodromeRouter.ExactInputSingleParams(
                            tokenIn, tokenOut, route.spacing, address(this), block.timestamp, amount, limit, 0
                        )
                    );
            } else {
                actual = IB1N495AerodromeRouter(router)
                    .exactOutputSingle(
                        IB1N495AerodromeRouter.ExactOutputSingleParams(
                            tokenIn, tokenOut, route.spacing, address(this), block.timestamp, amount, limit, 0
                        )
                    );
            }
        } else {
            if (exactInput) {
                actual = IB1N495UniswapRouter(router)
                    .exactInputSingle(
                        IB1N495UniswapRouter.ExactInputSingleParams(
                            tokenIn, tokenOut, route.fee, address(this), amount, limit, 0
                        )
                    );
            } else {
                actual = IB1N495UniswapRouter(router)
                    .exactOutputSingle(
                        IB1N495UniswapRouter.ExactOutputSingleParams(
                            tokenIn, tokenOut, route.fee, address(this), amount, limit, 0
                        )
                    );
            }
        }
        IERC20(tokenIn).approve(router, 0);
    }

    function _expectSwapRevert(
        Route memory route,
        address tokenIn,
        address tokenOut,
        bool exactInput,
        uint256 amount,
        uint256 limit
    ) private {
        address router = route.aerodrome ? AERO_ROUTER : UNI_ROUTER;
        IERC20(tokenIn).approve(router, exactInput ? amount : limit);
        vm.expectRevert();
        if (route.aerodrome) {
            if (exactInput) {
                IB1N495AerodromeRouter(router)
                    .exactInputSingle(
                        IB1N495AerodromeRouter.ExactInputSingleParams(
                            tokenIn, tokenOut, route.spacing, address(this), block.timestamp, amount, limit, 0
                        )
                    );
            } else {
                IB1N495AerodromeRouter(router)
                    .exactOutputSingle(
                        IB1N495AerodromeRouter.ExactOutputSingleParams(
                            tokenIn, tokenOut, route.spacing, address(this), block.timestamp, amount, limit, 0
                        )
                    );
            }
        } else {
            if (exactInput) {
                IB1N495UniswapRouter(router)
                    .exactInputSingle(
                        IB1N495UniswapRouter.ExactInputSingleParams(
                            tokenIn, tokenOut, route.fee, address(this), amount, limit, 0
                        )
                    );
            } else {
                IB1N495UniswapRouter(router)
                    .exactOutputSingle(
                        IB1N495UniswapRouter.ExactOutputSingleParams(
                            tokenIn, tokenOut, route.fee, address(this), amount, limit, 0
                        )
                    );
            }
        }
    }

    function _fund(Route memory, address token, uint256 amount) private {
        if (token == USDC || token == VVV) {
            deal(token, address(this), amount);
            return;
        }
        if (token == NVDAC) {
            _transferFromHolder(token, NVDAC_HOLDER, amount);
            return;
        }
        if (token == CBHYPE) {
            _transferFromHolder(token, COINBASE_HOT_WALLET, amount);
            return;
        }

        uint256 firstAmount = IERC20(token).balanceOf(COINBASE_HOT_WALLET);
        if (firstAmount > amount) firstAmount = amount;
        _transferFromHolder(token, COINBASE_HOT_WALLET, firstAmount);
        if (firstAmount < amount) _transferFromHolder(token, CBZEC_SECOND_HOLDER, amount - firstAmount);
    }

    function _transferFromHolder(address token, address holder, uint256 amount) private {
        uint256 holderBefore = IERC20(token).balanceOf(holder);
        uint256 recipientBefore = IERC20(token).balanceOf(address(this));
        vm.prank(holder);
        assertTrue(IERC20(token).transfer(address(this), amount));
        assertEq(holderBefore - IERC20(token).balanceOf(holder), amount);
        assertEq(IERC20(token).balanceOf(address(this)) - recipientBefore, amount);
    }

    function _spotOutput(uint160 sqrtPriceX96, address tokenIn, uint256 amountIn) private pure returns (uint256) {
        return tokenIn == USDC
            ? ((amountIn * uint256(sqrtPriceX96) / Q96) * uint256(sqrtPriceX96) / Q96)
            : ((amountIn * Q96 / uint256(sqrtPriceX96)) * Q96 / uint256(sqrtPriceX96));
    }

    function _spotInput(uint160 sqrtPriceX96, address tokenIn, uint256 amountOut) private pure returns (uint256) {
        return tokenIn == USDC
            ? ((amountOut * Q96 / uint256(sqrtPriceX96)) * Q96 / uint256(sqrtPriceX96))
            : ((amountOut * uint256(sqrtPriceX96) / Q96) * uint256(sqrtPriceX96) / Q96);
    }

    function _assetForUsdcEquivalent(Route memory route, uint256 usdcAmount) private view returns (uint256) {
        if (route.feed == address(0)) return _assetForUsdc(route.pool, usdcAmount);
        (, int256 answer,,,) = IB1N495Aggregator(route.feed).latestRoundData();
        return usdcAmount * (10 ** (route.decimals + route.feedDecimals)) / (uint256(answer) * 1e6);
    }

    function _assetForUsdc(address pool, uint256 usdcAmount) private view returns (uint256) {
        uint160 sqrtPriceX96 = _sqrtPrice(pool);
        return (usdcAmount * uint256(sqrtPriceX96) / Q96) * uint256(sqrtPriceX96) / Q96;
    }

    function _assertRoute(
        PairRoutingSwapRouter facade,
        address tokenIn,
        address tokenOut,
        PairRoutingSwapRouter.SwapKind kind,
        address expectedActive,
        address expectedPending
    ) private view {
        (address active, address pending,) = facade.routes(facade.routeKey(tokenIn, tokenOut, kind));
        assertEq(active, expectedActive);
        assertEq(pending, expectedPending);
    }

    function _spotPrice8(address pool, uint8 assetDecimals) private view returns (uint256) {
        return _usdcForAsset(pool, 10 ** assetDecimals) * 100;
    }

    function _usdcForAsset(address pool, uint256 assetAmount) private view returns (uint256) {
        uint160 sqrtPriceX96 = _sqrtPrice(pool);
        return (assetAmount * Q96 / uint256(sqrtPriceX96)) * Q96 / uint256(sqrtPriceX96);
    }

    function _sqrtPrice(address pool) private view returns (uint160 sqrtPriceX96) {
        (bool ok, bytes memory result) = pool.staticcall(abi.encodeWithSelector(SLOT0_SELECTOR));
        require(ok && result.length >= 32, "slot0");
        sqrtPriceX96 = abi.decode(result, (uint160));
    }

    function _oracleDeviation(
        Route memory route,
        bool usdcToAsset,
        bool exactInput,
        uint256 requested,
        uint256 desired,
        uint256 actualInput,
        uint256 actualOutput
    ) private view returns (uint256) {
        if (route.feed == address(0)) return type(uint256).max;
        (, int256 answer,,,) = IB1N495Aggregator(route.feed).latestRoundData();
        uint256 assetRaw = usdcToAsset ? (exactInput ? actualOutput : desired) : (exactInput ? requested : actualInput);
        uint256 usdcRaw = usdcToAsset ? (exactInput ? requested : actualInput) : (exactInput ? actualOutput : desired);
        uint256 oracleUsdc = assetRaw * uint256(answer) * 1e6 / (10 ** (route.decimals + route.feedDecimals));
        return _deviationBps(usdcRaw, oracleUsdc);
    }

    function _freshPositive(address feed) private view returns (bool) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IB1N495Aggregator(feed).latestRoundData();
        return answer > 0 && answeredInRound >= roundId && updatedAt <= block.timestamp
            && block.timestamp - updatedAt <= 1 days;
    }

    function _routeKey(address tokenIn, address tokenOut, uint8 kind) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut, kind));
    }

    function _withBps(uint256 amount, uint256 bps) private pure returns (uint256) {
        return (amount * (10_000 + bps) + 9_999) / 10_000;
    }

    function _deviationBps(uint256 observed, uint256 expected) private pure returns (uint256) {
        uint256 difference = observed > expected ? observed - expected : expected - observed;
        return difference * 10_000 / expected;
    }

    function _withinDeviationBps(uint256 observed, uint256 expected, uint256 maxBps) private pure returns (bool) {
        uint256 difference = observed > expected ? observed - expected : expected - observed;
        return difference * 10_000 <= expected * maxBps;
    }

    function _route(uint256 i) private pure returns (Route memory) {
        if (i == 0) return Route("NVDAc", NVDAC, NVDAC_POOL, 10, 500, 8, true, NVDAC_FEED, 8);
        if (i == 1) return Route("cbZEC", CBZEC, CBZEC_POOL, 200, 2000, 8, true, address(0), 0);
        if (i == 2) return Route("cbHYPE", CBHYPE, CBHYPE_POOL, 200, 2000, 18, true, address(0), 0);
        return Route("VVV", VVV, VVV_POOL, 60, 3000, 18, false, VVV_FEED, 18);
    }
}
