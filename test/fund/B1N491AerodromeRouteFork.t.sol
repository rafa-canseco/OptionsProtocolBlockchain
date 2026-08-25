// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

interface IERC20Fork {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUsdcProxyFork {
    function implementation() external view returns (address);
}

interface ICLFactoryFork {
    function getPool(address, address, int24) external view returns (address);
    function getSwapFee(address) external view returns (uint24);
    function getUnstakedFee(address) external view returns (uint24);
    function isPool(address) external view returns (bool);
}

interface ICLPoolFork {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function factory() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
    function tickBitmap(int16) external view returns (uint256);
}

interface ISwapRouterFork {
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
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256 amountIn);
}

interface IQuoterV2Fork {
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
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
    function quoteExactOutputSingle(QuoteExactOutputSingleParams calldata)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface IAggregatorV3Fork {
    function decimals() external view returns (uint8);
    function aggregator() external view returns (address);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IB20Fork is IERC20Fork {
    function multiplier() external view returns (uint256);
    function pausedFeatures() external view returns (uint8[] memory);
    function isPaused(uint8) external view returns (bool);
    function TRANSFER_SENDER_POLICY() external view returns (bytes32);
    function TRANSFER_RECEIVER_POLICY() external view returns (bytes32);
    function TRANSFER_EXECUTOR_POLICY() external view returns (bytes32);
    function policyId(bytes32) external view returns (uint64);
}

interface IPolicyRegistryFork {
    function isAuthorized(uint64, address) external view returns (bool);
}

interface IOracleRegistryFork {
    function getOracleParams(address) external view returns (uint256 multiplier, bool paused);
}

contract B1N491ContractRecipient {
    function pull(IERC20Fork token, address from, address to, uint256 amount) external returns (bool) {
        return token.transferFrom(from, to, amount);
    }
}

/// @notice Read-only qualification of the canonical Aerodrome NVDAc/USDC route at a finalized Base block.
/// @dev Run: forge test --match-contract B1N491AerodromeRouteForkTest -vvv
contract B1N491AerodromeRouteForkTest is Test {
    uint256 private constant PINNED_BLOCK = 50_400_001;
    uint256 private constant PINNED_TIMESTAMP = 1_787_589_349;
    bytes32 private constant PARENT_BLOCK_HASH = 0x08c2707d24192e903e1f9700cffa1c55479e4972e6f05c993f418191ae3420ad;

    IERC20Fork private constant USDC = IERC20Fork(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IB20Fork private constant NVDAC = IB20Fork(0xb20000000000000000000078ee7ce2fE4908108C);
    ICLPoolFork private constant POOL = ICLPoolFork(0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9);
    ICLFactoryFork private constant FACTORY = ICLFactoryFork(0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef);
    ISwapRouterFork private constant ROUTER = ISwapRouterFork(0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F);
    IQuoterV2Fork private constant QUOTER = IQuoterV2Fork(0x514c8B5f54112481E28028F1166Bd78501089259);
    IAggregatorV3Fork private constant NVDA_USD = IAggregatorV3Fork(0x04689a41629776563E6822F76f2e57D148d28513);
    IOracleRegistryFork private constant ORACLE_REGISTRY =
        IOracleRegistryFork(0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD);
    IPolicyRegistryFork private constant POLICY_REGISTRY =
        IPolicyRegistryFork(0x8453000000000000000000000000000000000002);

    address private constant NVDAC_HOLDER = 0xA561f0A080e6de58AAF9d174E06e842693978412;
    address private constant DEPLOYED_SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address private constant USDC_IMPLEMENTATION = 0x2Ce6311ddAE708829bc0784C967b7d77D19FD779;
    address private constant NVDA_USD_AGGREGATOR = 0xF72B1eB5932800F3d2a5EeC5f99e6cD586479675;

    bytes32 private constant NVDAC_CODEHASH = 0x309b8896ee4c1ff7ec1966155373dee42663b6b40c3fedc70ba501684848d2a3;
    bytes32 private constant USDC_CODEHASH = 0xa6705a10bb756b5dea144591118be77d7af0c3eee3bf2dfe2583dcb0364fefab;
    bytes32 private constant USDC_IMPLEMENTATION_CODEHASH =
        0x11b75a237997ab8328f65b2d5a55c10f0346d0a175741ed42ddf4f2c66b9e873;
    bytes32 private constant POOL_CODEHASH = 0xad8972486d67a48db1f32f254a4c2f4be28df0b5f399559d1e7cd8fbcfbedc96;
    bytes32 private constant FACTORY_CODEHASH = 0x4961963494e47f363617ab9a0f3999a28b33c519e51392952db06350cce700bd;
    bytes32 private constant ROUTER_CODEHASH = 0xfedc4e21e1097b0ec1b4f1aa901cf645c22f9e5d297727b0f37275ee1d083df4;
    bytes32 private constant QUOTER_CODEHASH = 0x4c4c43e0024343e65597f0f0a1b829aaf69e5a6c0a0148fb63d28ff5730be551;

    B1N491ContractRecipient private recipient;
    uint256 private oraclePrice;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"), PINNED_BLOCK);
        assertEq(block.chainid, 8_453);
        assertEq(block.number, PINNED_BLOCK);
        assertEq(block.timestamp, PINNED_TIMESTAMP);
        assertEq(blockhash(PINNED_BLOCK - 1), PARENT_BLOCK_HASH);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = NVDA_USD.latestRoundData();
        assertGt(answer, 0);
        assertGe(answeredInRound, roundId);
        assertLe(block.timestamp - updatedAt, 86_400);
        oraclePrice = uint256(answer);
        recipient = new B1N491ContractRecipient();
    }

    function test_canonicalIdentitiesAbiOracleAndPoolState() public view {
        assertEq(address(NVDAC).codehash, NVDAC_CODEHASH);
        assertEq(address(USDC).codehash, USDC_CODEHASH);
        assertEq(address(POOL).codehash, POOL_CODEHASH);
        assertEq(address(FACTORY).codehash, FACTORY_CODEHASH);
        assertEq(address(ROUTER).codehash, ROUTER_CODEHASH);
        assertEq(address(QUOTER).codehash, QUOTER_CODEHASH);
        assertEq(IUsdcProxyFork(address(USDC)).implementation(), USDC_IMPLEMENTATION);
        assertEq(USDC_IMPLEMENTATION.codehash, USDC_IMPLEMENTATION_CODEHASH);

        assertEq(ISwapRouterFork.exactInputSingle.selector, bytes4(0xa026383e));
        assertEq(ISwapRouterFork.exactOutputSingle.selector, bytes4(0xc714e838));
        assertEq(IQuoterV2Fork.quoteExactInputSingle.selector, bytes4(0x9e7defe6));
        assertEq(IQuoterV2Fork.quoteExactOutputSingle.selector, bytes4(0xfa6af908));

        assertEq(USDC.decimals(), 6);
        assertEq(POOL.token0(), address(USDC));
        assertEq(POOL.token1(), address(NVDAC));
        assertEq(POOL.tickSpacing(), 10);
        assertEq(POOL.factory(), address(FACTORY));
        assertEq(FACTORY.getPool(address(NVDAC), address(USDC), 10), address(POOL));
        assertTrue(FACTORY.isPool(address(POOL)));
        assertEq(ROUTER.factory(), address(FACTORY));
        assertEq(QUOTER.factory(), address(FACTORY));
        assertEq(POOL.fee(), 500);
        assertEq(FACTORY.getSwapFee(address(POOL)), 500);
        assertEq(FACTORY.getUnstakedFee(address(POOL)), 100_000);
        assertGt(POOL.liquidity(), 0);

        assertEq(NVDA_USD.decimals(), 8);
        assertEq(NVDA_USD.aggregator(), NVDA_USD_AGGREGATOR);
    }

    function test_b20NativeViewsAndOracleRegistry() public view {
        assertEq(NVDAC.decimals(), 8);
        (uint256 registryMultiplier, bool oraclePaused) = ORACLE_REGISTRY.getOracleParams(address(NVDAC));
        assertEq(registryMultiplier, NVDAC.multiplier());
        assertEq(registryMultiplier, 1e18);
        assertFalse(oraclePaused);
    }

    function test_b20TransferPauseEligibilityAndContractMatrix() public {
        _fundFromRealHolder();
        assertEq(NVDAC.pausedFeatures().length, 0);
        for (uint8 feature; feature < 3; ++feature) {
            assertFalse(NVDAC.isPaused(feature));
        }

        bytes32[3] memory scopes =
            [NVDAC.TRANSFER_SENDER_POLICY(), NVDAC.TRANSFER_RECEIVER_POLICY(), NVDAC.TRANSFER_EXECUTOR_POLICY()];
        address[3] memory actors = [NVDAC_HOLDER, address(ROUTER), DEPLOYED_SETTLER];
        for (uint256 i; i < scopes.length; ++i) {
            uint64 policy = NVDAC.policyId(scopes[i]);
            assertEq(policy, 5);
            for (uint256 j; j < actors.length; ++j) {
                assertTrue(POLICY_REGISTRY.isAuthorized(policy, actors[j]));
            }
        }

        uint256 snapshot = vm.snapshotState();
        uint256 beforeBalance = NVDAC.balanceOf(address(recipient));
        assertTrue(NVDAC.transfer(address(recipient), 1));
        assertEq(NVDAC.balanceOf(address(recipient)) - beforeBalance, 1);
        assertTrue(vm.revertToState(snapshot));

        assertTrue(NVDAC.approve(address(recipient), 1));
        assertEq(NVDAC.allowance(address(this), address(recipient)), 1);
        assertTrue(recipient.pull(NVDAC, address(this), address(recipient), 1));
        assertEq(NVDAC.allowance(address(this), address(recipient)), 0);
        assertTrue(vm.revertToState(snapshot));

        uint256 sourceBaseline = NVDAC.balanceOf(address(this));
        uint256 recipientBaseline = NVDAC.balanceOf(address(recipient));
        for (uint256 i; i < actors.length; ++i) {
            assertEq(NVDAC.balanceOf(address(this)), sourceBaseline);
            assertEq(NVDAC.balanceOf(address(recipient)), recipientBaseline);
            assertEq(NVDAC.allowance(address(this), actors[i]), 0);
            assertTrue(NVDAC.approve(actors[i], 1));
            vm.prank(actors[i]);
            assertTrue(NVDAC.transferFrom(address(this), address(recipient), 1));
            assertEq(NVDAC.balanceOf(address(this)), sourceBaseline - 1);
            assertEq(NVDAC.balanceOf(address(recipient)), recipientBaseline + 1);
            assertEq(NVDAC.allowance(address(this), actors[i]), 0);
            assertTrue(vm.revertToState(snapshot));
            assertEq(NVDAC.balanceOf(address(this)), sourceBaseline);
            assertEq(NVDAC.balanceOf(address(recipient)), recipientBaseline);
            assertEq(NVDAC.allowance(address(this), actors[i]), 0);
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function test_all16IsolatedLiveRouterScenariosAndObservedNegativeLimits() public {
        uint256[4] memory notionals = [uint256(100), 1_000, 5_000, 10_000];
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 mode; mode < 2; ++mode) {
                for (uint256 i; i < notionals.length; ++i) {
                    _runScenario(direction == 0, mode == 0, notionals[i]);
                }
            }
        }
    }

    function test_directionalDepthAt10_25_50BpsWithTenUsdcResolution() public {
        // Fail visibly on stock Foundry instead of misclassifying runner failure as zero depth.
        assertEq(NVDAC.decimals(), 8);
        uint256[3] memory guards = [uint256(10), 25, 50];
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 i; i < guards.length; ++i) {
                (uint256 depth, bool quoteFailedAtBoundary, bool ceilingReached) =
                    _directionalDepth(direction == 0, guards[i]);
                emit log_named_string("depth_direction", direction == 0 ? "USDC->NVDAc" : "NVDAc->USDC");
                emit log_named_uint("depth_guard_bps", guards[i]);
                emit log_named_uint("depth_or_lower_bound_usdc_equivalent", depth);
                emit log_named_uint("depth_resolution_usdc", 10);
                emit log_named_uint("depth_is_lower_bound_ceiling_reached", ceilingReached ? 1 : 0);
                emit log_named_uint("quote_failed_at_boundary", quoteFailedAtBoundary ? 1 : 0);
            }
        }
    }

    function test_sequentialProductGateCapacityWithinGlobalCeiling() public {
        // Fail visibly on stock Foundry instead of publishing synthetic sequential capacity.
        assertEq(NVDAC.decimals(), 8);
        _runSequentialProductGate(true, false); // PUT: USDC -> NVDAc exact-output
        _runSequentialProductGate(false, true); // CALL: NVDAc -> USDC exact-input
    }

    function _runScenario(bool usdcToNvda, bool exactInput, uint256 notional) private {
        IERC20Fork tokenIn = usdcToNvda ? USDC : NVDAC;
        IERC20Fork tokenOut = usdcToNvda ? NVDAC : USDC;
        uint256 usdcAmount = notional * 1e6;
        uint256 nvdaAmount = _usdcToNvda(usdcAmount);
        uint256 requested = usdcToNvda ? usdcAmount : nvdaAmount;
        uint256 desired = usdcToNvda ? nvdaAmount : usdcAmount;

        uint256 snapshot = vm.snapshotState();
        _fundFromRealHolder();
        (uint256 quote, uint160 quotedSqrtAfter, uint32 ticksCrossed) =
            exactInput ? _quoteExactInput(tokenIn, tokenOut, requested) : _quoteExactOutput(tokenIn, tokenOut, desired);
        uint256 routerInputBaseline = tokenIn.balanceOf(address(ROUTER));
        uint256 routerOutputBaseline = tokenOut.balanceOf(address(ROUTER));
        uint256 actorInputBaseline = tokenIn.balanceOf(address(this));
        uint256 recipientOutputBaseline = tokenOut.balanceOf(address(recipient));
        uint256 poolInputBaseline = tokenIn.balanceOf(address(POOL));
        uint256 poolOutputBaseline = tokenOut.balanceOf(address(POOL));
        uint128 liquidityBefore = POOL.liquidity();
        uint24 feePips = FACTORY.getSwapFee(address(POOL));
        (uint160 sqrtBefore, int24 tickBefore,,,,) = POOL.slot0();

        uint256 approval = exactInput ? requested : quote;
        assertTrue(tokenIn.approve(address(ROUTER), approval));
        uint256 returned = exactInput
            ? _swapExactInput(tokenIn, tokenOut, requested, 0)
            : _swapExactOutput(tokenIn, tokenOut, desired, quote);

        uint256 actualInput = actorInputBaseline - tokenIn.balanceOf(address(this));
        uint256 actualOutput = tokenOut.balanceOf(address(recipient)) - recipientOutputBaseline;
        assertEq(returned, exactInput ? actualOutput : actualInput);
        assertEq(actualInput, exactInput ? requested : returned);
        assertEq(actualOutput, exactInput ? returned : desired);
        assertLe(actualInput, approval);
        assertEq(tokenIn.balanceOf(address(POOL)) - poolInputBaseline, actualInput);
        assertEq(poolOutputBaseline - tokenOut.balanceOf(address(POOL)), actualOutput);
        assertEq(tokenIn.balanceOf(address(ROUTER)), routerInputBaseline);
        assertEq(tokenOut.balanceOf(address(ROUTER)), routerOutputBaseline);
        assertTrue(tokenIn.approve(address(ROUTER), 0));
        assertEq(tokenIn.allowance(address(this), address(ROUTER)), 0);

        (uint160 sqrtAfter, int24 tickAfter,,,,) = POOL.slot0();
        assertEq(sqrtAfter, quotedSqrtAfter);
        uint256 expected = exactInput
            ? (usdcToNvda ? _usdcToNvda(actualInput) : _nvdaToUsdc(actualInput))
            : (usdcToNvda ? _nvdaToUsdc(actualOutput) : _usdcToNvda(actualOutput));
        uint256 observed = exactInput ? actualOutput : actualInput;
        uint256 oracleDeviationBps = _deviationBps(observed, expected);
        uint256 endpointSpotMovementBps = _sqrtPriceImpactBps(sqrtBefore, sqrtAfter);
        uint256 preSwapSpotPriceE8 = _spotPriceE8(sqrtBefore);
        uint256 executionPriceE8 = usdcToNvda ? actualInput * 1e10 / actualOutput : actualOutput * 1e10 / actualInput;
        uint256 executionPriceImpactBps = _deviationBps(executionPriceE8, preSwapSpotPriceE8);
        uint256 quoteToExecutionBps = _deviationBps(exactInput ? actualOutput : actualInput, quote);
        uint128 liquidityAfter = POOL.liquidity();
        uint32 initializedBoundariesStrictlyCrossed = _initializedBoundariesStrictlyCrossed(tickBefore, tickAfter);

        emit log_named_string(
            "scenario",
            string.concat(usdcToNvda ? "USDC->NVDAc" : "NVDAc->USDC", exactInput ? " exact-input" : " exact-output")
        );
        emit log_named_uint("notional_usdc", notional);
        emit log_named_uint("requested_input", exactInput ? requested : quote);
        emit log_named_uint("actual_input", actualInput);
        emit log_named_uint("requested_output", exactInput ? quote : desired);
        emit log_named_uint("actual_output", actualOutput);
        emit log_named_uint("pre_swap_spot_price_usdc_per_nvdac_e8", preSwapSpotPriceE8);
        emit log_named_uint("execution_price_usdc_per_nvdac_e8", executionPriceE8);
        emit log_named_uint("execution_price_impact_bps_vs_pre_spot", executionPriceImpactBps);
        emit log_named_uint("fee_pips_separate_not_subtracted", feePips);
        emit log_named_uint("oracle_deviation_bps", oracleDeviationBps);
        emit log_named_uint("quote_to_execution_slippage_bps", quoteToExecutionBps);
        emit log_named_uint("endpoint_spot_movement_bps", endpointSpotMovementBps);
        emit log_named_uint("active_liquidity_before", liquidityBefore);
        emit log_named_uint("active_liquidity_after", liquidityAfter);
        emit log_named_uint("initial_active_range_exhausted", initializedBoundariesStrictlyCrossed > 0 ? 1 : 0);
        emit log_named_uint("terminal_zero_liquidity", liquidityAfter == 0 ? 1 : 0);
        emit log_named_int("tick_before", tickBefore);
        emit log_named_int("tick_after", tickAfter);
        emit log_named_uint("quoter_initialized_ticks_crossed_raw", ticksCrossed);
        emit log_named_uint("initialized_boundaries_strictly_crossed", initializedBoundariesStrictlyCrossed);

        assertTrue(vm.revertToState(snapshot));
        _fundFromRealHolder();
        assertEq(tokenIn.balanceOf(address(this)), actorInputBaseline);
        assertEq(tokenOut.balanceOf(address(recipient)), recipientOutputBaseline);
        assertEq(tokenIn.balanceOf(address(ROUTER)), routerInputBaseline);
        assertEq(tokenOut.balanceOf(address(ROUTER)), routerOutputBaseline);
        assertEq(tokenIn.balanceOf(address(POOL)), poolInputBaseline);
        assertEq(tokenOut.balanceOf(address(POOL)), poolOutputBaseline);
        assertEq(tokenIn.allowance(address(this), address(ROUTER)), 0);
        assertTrue(tokenIn.approve(address(ROUTER), approval));
        vm.expectRevert();
        if (exactInput) {
            _swapExactInput(tokenIn, tokenOut, requested, actualOutput + 1);
        } else {
            _swapExactOutput(tokenIn, tokenOut, desired, actualInput - 1);
        }
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _initializedBoundariesStrictlyCrossed(int24 tickBefore, int24 tickAfter)
        private
        view
        returns (uint32 count)
    {
        int24 lower = tickBefore < tickAfter ? tickBefore : tickAfter;
        int24 upper = tickBefore < tickAfter ? tickAfter : tickBefore;
        int24 spacing = POOL.tickSpacing();
        int24 compressedLower = lower / spacing;
        if (lower < 0 && lower % spacing != 0) --compressedLower;

        for (int24 boundary = (compressedLower + 1) * spacing; boundary < upper; boundary += spacing) {
            int24 compressed = boundary / spacing;
            int16 wordPosition = int16(compressed >> 8);
            uint8 bitPosition = uint8(uint24(compressed));
            if (POOL.tickBitmap(wordPosition) & (uint256(1) << bitPosition) != 0) ++count;
        }
    }

    function _directionalDepth(bool usdcToNvda, uint256 guardBps)
        private
        returns (uint256 depthUsdc, bool quoteFailedAtBoundary, bool ceilingReached)
    {
        uint256 low;
        uint256 high = 1;
        uint256 maxChunks = 10_000; // 100,000 USDC search ceiling in exact 10 USDC increments.
        (bool within,, bool quoteFailed) = _quoteWithinImpact(usdcToNvda, high * 10, guardBps);
        while (within && high < maxChunks) {
            low = high;
            high = high * 2 > maxChunks ? maxChunks : high * 2;
            (within,, quoteFailed) = _quoteWithinImpact(usdcToNvda, high * 10, guardBps);
        }
        if (within) return (high * 10, false, true);

        quoteFailedAtBoundary = quoteFailed;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            (within,, quoteFailed) = _quoteWithinImpact(usdcToNvda, mid * 10, guardBps);
            if (within) {
                low = mid;
            } else {
                high = mid;
                quoteFailedAtBoundary = quoteFailed;
            }
        }
        return (low * 10, quoteFailedAtBoundary, false);
    }

    function _quoteWithinImpact(bool usdcToNvda, uint256 usdcEquivalent, uint256 guardBps)
        private
        returns (bool within, uint256 impactBps, bool quoteFailed)
    {
        IERC20Fork tokenIn = usdcToNvda ? USDC : NVDAC;
        IERC20Fork tokenOut = usdcToNvda ? NVDAC : USDC;
        uint256 amountIn = usdcToNvda ? usdcEquivalent * 1e6 : _usdcToNvda(usdcEquivalent * 1e6);
        (uint160 sqrtBefore,,,,,) = POOL.slot0();
        try QUOTER.quoteExactInputSingle(
            IQuoterV2Fork.QuoteExactInputSingleParams(address(tokenIn), address(tokenOut), amountIn, 10, 0)
        ) returns (
            uint256 amountOut, uint160 sqrtAfter, uint32, uint256
        ) {
            if (amountOut == 0) return (false, type(uint256).max, true);
            impactBps = _sqrtPriceImpactBps(sqrtBefore, sqrtAfter);
            return (impactBps <= guardBps, impactBps, false);
        } catch {
            return (false, type(uint256).max, true);
        }
    }

    function _runSequentialProductGate(bool usdcToNvda, bool exactInput) private {
        uint256 snapshot = vm.snapshotState();
        _fundFromRealHolder();
        IERC20Fork tokenIn = usdcToNvda ? USDC : NVDAC;
        IERC20Fork tokenOut = usdcToNvda ? NVDAC : USDC;
        uint256 demonstratedCapacity;
        uint256 executedCapacity;
        uint256 boundaryUsdc;
        uint256 maxOracleDeviationBps;
        uint256 maxExecutionImpactBps;
        bool prefixSafe = true;
        bool quoteOrSwapFailed;

        for (uint256 chunk = 1; chunk <= 10; ++chunk) {
            uint256 usdcAmount = 100e6;
            uint256 nvdaAmount = _usdcToNvda(usdcAmount);
            uint256 requested = usdcToNvda ? usdcAmount : nvdaAmount;
            uint256 desired = usdcToNvda ? nvdaAmount : usdcAmount;
            (bool quoteOk, uint256 quote) = _trySequentialQuote(tokenIn, tokenOut, exactInput, requested, desired);
            if (!quoteOk) {
                boundaryUsdc = chunk * 100;
                quoteOrSwapFailed = true;
                break;
            }

            (uint160 sqrtBefore,,,,,) = POOL.slot0();
            assertTrue(tokenIn.approve(address(ROUTER), exactInput ? requested : quote));
            (bool swapOk, uint256 actual) = _trySequentialSwap(tokenIn, tokenOut, exactInput, requested, desired, quote);
            assertTrue(tokenIn.approve(address(ROUTER), 0));
            if (!swapOk) {
                boundaryUsdc = chunk * 100;
                quoteOrSwapFailed = true;
                break;
            }
            executedCapacity = chunk * 100;

            uint256 expected = exactInput
                ? (usdcToNvda ? _usdcToNvda(requested) : _nvdaToUsdc(requested))
                : (usdcToNvda ? _nvdaToUsdc(desired) : _usdcToNvda(desired));
            uint256 oracleDeviationBps = _deviationBps(actual, expected);
            uint256 executionPriceE8 = exactInput ? actual * 1e10 / requested : actual * 1e10 / desired;
            uint256 executionImpactBps = _deviationBps(executionPriceE8, _spotPriceE8(sqrtBefore));
            if (oracleDeviationBps > maxOracleDeviationBps) maxOracleDeviationBps = oracleDeviationBps;
            if (executionImpactBps > maxExecutionImpactBps) maxExecutionImpactBps = executionImpactBps;

            bool chunkSafe = oracleDeviationBps <= 50 && executionImpactBps <= 50 && POOL.liquidity() > 0;
            if (prefixSafe && chunkSafe) {
                demonstratedCapacity = chunk * 100;
            } else {
                prefixSafe = false;
                if (boundaryUsdc == 0) boundaryUsdc = chunk * 100;
            }
        }

        emit log_named_string("sequential_product_gate", usdcToNvda ? "PUT exact-output" : "CALL exact-input");
        emit log_named_uint("sequential_executed_usdc_equivalent", executedCapacity);
        emit log_named_uint("sequential_safe_prefix_usdc_equivalent", demonstratedCapacity);
        emit log_named_uint("sequential_boundary_usdc_equivalent", boundaryUsdc);
        emit log_named_uint("sequential_quote_or_swap_failed", quoteOrSwapFailed ? 1 : 0);
        emit log_named_uint("sequential_max_oracle_deviation_bps", maxOracleDeviationBps);
        emit log_named_uint("sequential_max_execution_impact_bps", maxExecutionImpactBps);
        emit log_named_uint("global_expiry_ceiling_usdc_equivalent", 1_000);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _trySequentialQuote(
        IERC20Fork tokenIn,
        IERC20Fork tokenOut,
        bool exactInput,
        uint256 requested,
        uint256 desired
    ) private returns (bool ok, uint256 quote) {
        if (exactInput) {
            try QUOTER.quoteExactInputSingle(
                IQuoterV2Fork.QuoteExactInputSingleParams(address(tokenIn), address(tokenOut), requested, 10, 0)
            ) returns (
                uint256 amountOut, uint160, uint32, uint256
            ) {
                return (true, amountOut);
            } catch {
                return (false, 0);
            }
        }
        try QUOTER.quoteExactOutputSingle(
            IQuoterV2Fork.QuoteExactOutputSingleParams(address(tokenIn), address(tokenOut), desired, 10, 0)
        ) returns (
            uint256 amountIn, uint160, uint32, uint256
        ) {
            return (true, amountIn);
        } catch {
            return (false, 0);
        }
    }

    function _trySequentialSwap(
        IERC20Fork tokenIn,
        IERC20Fork tokenOut,
        bool exactInput,
        uint256 requested,
        uint256 desired,
        uint256 quote
    ) private returns (bool ok, uint256 actual) {
        if (exactInput) {
            try ROUTER.exactInputSingle(
                ISwapRouterFork.ExactInputSingleParams(
                    address(tokenIn), address(tokenOut), 10, address(recipient), block.timestamp + 1, requested, 0, 0
                )
            ) returns (
                uint256 amountOut
            ) {
                return (true, amountOut);
            } catch {
                return (false, 0);
            }
        }
        try ROUTER.exactOutputSingle(
            ISwapRouterFork.ExactOutputSingleParams(
                address(tokenIn), address(tokenOut), 10, address(recipient), block.timestamp + 1, desired, quote, 0
            )
        ) returns (
            uint256 amountIn
        ) {
            return (true, amountIn);
        } catch {
            return (false, 0);
        }
    }

    function _fundFromRealHolder() private {
        vm.prank(NVDAC_HOLDER);
        assertTrue(USDC.transfer(address(this), 12_000e6));
        vm.prank(NVDAC_HOLDER);
        assertTrue(NVDAC.transfer(address(this), 50e8));
    }

    function _quoteExactInput(IERC20Fork tokenIn, IERC20Fork tokenOut, uint256 amount)
        private
        returns (uint256 quote, uint160 sqrtAfter, uint32 ticksCrossed)
    {
        (quote, sqrtAfter, ticksCrossed,) = QUOTER.quoteExactInputSingle(
            IQuoterV2Fork.QuoteExactInputSingleParams(address(tokenIn), address(tokenOut), amount, 10, 0)
        );
    }

    function _quoteExactOutput(IERC20Fork tokenIn, IERC20Fork tokenOut, uint256 amount)
        private
        returns (uint256 quote, uint160 sqrtAfter, uint32 ticksCrossed)
    {
        (quote, sqrtAfter, ticksCrossed,) = QUOTER.quoteExactOutputSingle(
            IQuoterV2Fork.QuoteExactOutputSingleParams(address(tokenIn), address(tokenOut), amount, 10, 0)
        );
    }

    function _swapExactInput(IERC20Fork tokenIn, IERC20Fork tokenOut, uint256 amountIn, uint256 amountOutMinimum)
        private
        returns (uint256)
    {
        return ROUTER.exactInputSingle(
            ISwapRouterFork.ExactInputSingleParams(
                address(tokenIn),
                address(tokenOut),
                10,
                address(recipient),
                block.timestamp + 1,
                amountIn,
                amountOutMinimum,
                0
            )
        );
    }

    function _swapExactOutput(IERC20Fork tokenIn, IERC20Fork tokenOut, uint256 amountOut, uint256 amountInMaximum)
        private
        returns (uint256)
    {
        return ROUTER.exactOutputSingle(
            ISwapRouterFork.ExactOutputSingleParams(
                address(tokenIn),
                address(tokenOut),
                10,
                address(recipient),
                block.timestamp + 1,
                amountOut,
                amountInMaximum,
                0
            )
        );
    }

    function _usdcToNvda(uint256 usdcAmount) private view returns (uint256) {
        return usdcAmount * 1e10 / oraclePrice;
    }

    function _nvdaToUsdc(uint256 nvdaAmount) private view returns (uint256) {
        return nvdaAmount * oraclePrice / 1e10;
    }

    function _spotPriceE8(uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 inverseSqrtE18 = (uint256(1) << 96) * 1e18 / uint256(sqrtPriceX96);
        return inverseSqrtE18 * inverseSqrtE18 * 1e10 / 1e36;
    }

    function _sqrtPriceImpactBps(uint160 beforePrice, uint160 afterPrice) private pure returns (uint256) {
        uint256 sqrtRatio = uint256(afterPrice) * 1e18 / uint256(beforePrice);
        return _deviationBps(sqrtRatio * sqrtRatio / 1e18, 1e18);
    }

    function _deviationBps(uint256 observed, uint256 expected) private pure returns (uint256) {
        return (observed > expected ? observed - expected : expected - observed) * 10_000 / expected;
    }
}
