// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {
    AerodromeSlipstreamAdapter,
    IAerodromeSlipstreamFactory,
    IAerodromeSlipstreamPool,
    IAerodromeSlipstreamRouter
} from "../src/routers/AerodromeSlipstreamAdapter.sol";

contract MockSlipstreamFactory is IAerodromeSlipstreamFactory {
    address public pool;
    address public token0;
    address public token1;
    int24 public spacing;
    uint24 public fee;

    function configure(address pool_, address token0_, address token1_, int24 spacing_, uint24 fee_) external {
        pool = pool_;
        token0 = token0_;
        token1 = token1_;
        spacing = spacing_;
        fee = fee_;
    }

    function setFee(uint24 fee_) external {
        fee = fee_;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        bool matches = (tokenA == token0 && tokenB == token1) || (tokenA == token1 && tokenB == token0);
        return matches && tickSpacing == spacing ? pool : address(0);
    }

    function getSwapFee(address pool_) external view returns (uint24) {
        return pool_ == pool ? fee : 0;
    }
}

contract MockSlipstreamPool is IAerodromeSlipstreamPool {
    address public token0;
    address public token1;
    address public factory;
    int24 public tickSpacing;
    uint24 public fee;
    uint128 public liquidity;

    constructor(address token0_, address token1_, address factory_, int24 spacing_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        factory = factory_;
        tickSpacing = spacing_;
        fee = fee_;
        liquidity = 1e18;
    }

    function setFee(uint24 fee_) external {
        fee = fee_;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }
}

contract MockSlipstreamRouter is IAerodromeSlipstreamRouter {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address internal constant SINK = address(0xdead);

    constructor(address factory_) {
        factory = factory_;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, SINK, params.amountIn);
        MockERC20(params.tokenOut).mint(params.recipient, params.amountOutMinimum + 1);
        return 1;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn) {
        uint256 spent = params.amountInMaximum / 2;
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, SINK, spent);
        MockERC20(params.tokenOut).mint(params.recipient, params.amountOut);
        return type(uint256).max;
    }
}

contract AerodromeSlipstreamAdapterTest is Test {
    int24 internal constant SPACING = 200;
    uint24 internal constant FEE = 2000;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal other;
    MockSlipstreamFactory internal factory;
    MockSlipstreamPool internal pool;
    MockSlipstreamRouter internal venueRouter;
    PairRoutingSwapRouter internal facade;
    AerodromeSlipstreamAdapter internal adapter;
    address internal recipient = address(0xB0B);
    address internal outsider = address(0xBAD);

    function setUp() public {
        tokenA = new MockERC20("Token A", "A", 18);
        tokenB = new MockERC20("Token B", "B", 6);
        other = new MockERC20("Other", "OTHER", 18);
        factory = new MockSlipstreamFactory();
        pool = new MockSlipstreamPool(address(tokenA), address(tokenB), address(factory), SPACING, FEE);
        factory.configure(address(pool), address(tokenA), address(tokenB), SPACING, FEE);
        venueRouter = new MockSlipstreamRouter(address(factory));
        facade = new PairRoutingSwapRouter(address(this), address(this));
        adapter = new AerodromeSlipstreamAdapter(
            address(facade),
            address(venueRouter),
            address(factory),
            address(pool),
            address(tokenA),
            address(tokenB),
            SPACING
        );

        _activate(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        _activate(address(tokenB), address(tokenA), PairRoutingSwapRouter.SwapKind.ExactOutput);

        tokenA.mint(address(this), 1_000e18);
        tokenB.mint(address(this), 1_000_000e6);
        tokenA.approve(address(facade), type(uint256).max);
        tokenB.approve(address(facade), type(uint256).max);
    }

    function test_constructorBindsExactPoolGeneration() public view {
        assertEq(adapter.facade(), address(facade));
        assertEq(adapter.settler(), address(this));
        assertEq(adapter.venueRouter(), address(venueRouter));
        assertEq(adapter.factory(), address(factory));
        assertEq(adapter.pool(), address(pool));
        assertEq(adapter.tokenA(), address(tokenA));
        assertEq(adapter.tokenB(), address(tokenB));
        assertEq(adapter.tickSpacing(), SPACING);
        assertEq(adapter.effectiveFee(), FEE);
    }

    function test_exactInputIgnoresCompatibilityFeeAndCleansUp() public {
        uint256 beforeOut = tokenB.balanceOf(address(this));
        uint256 amountOut = facade.exactInputSingle(_exactInput(address(tokenA), address(tokenB), 999_999));

        assertEq(amountOut, 80e6 + 1);
        assertEq(tokenB.balanceOf(address(this)) - beforeOut, amountOut);
        _assertClean(tokenA, tokenB);
    }

    function test_exactOutputMeasuresSpendRefundsAndCleansUp() public {
        uint256 beforeIn = tokenB.balanceOf(address(this));
        uint256 amountIn = facade.exactOutputSingle(_exactOutput(address(tokenB), address(tokenA), FEE));

        assertEq(amountIn, 50e6);
        assertEq(beforeIn - tokenB.balanceOf(address(this)), 50e6);
        assertEq(tokenA.balanceOf(recipient), 1e18);
        _assertClean(tokenB, tokenA);
    }

    function test_exactOutputCapsToAvailableFacadeFunding() public {
        tokenB.approve(address(facade), 80e6);
        uint256 amountIn = facade.exactOutputSingle(_exactOutput(address(tokenB), address(tokenA), FEE));

        assertEq(amountIn, 40e6);
        assertEq(tokenB.allowance(address(this), address(facade)), 0);
        _assertClean(tokenB, tokenA);
    }

    function test_wrongPairAndRecipientFailWithoutMovingFunds() public {
        _activate(address(other), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        other.mint(address(this), 100e18);
        other.approve(address(facade), 100e18);
        uint256 beforeOther = other.balanceOf(address(this));

        vm.expectRevert(AerodromeSlipstreamAdapter.InvalidPair.selector);
        facade.exactInputSingle(_exactInput(address(other), address(tokenB), FEE));
        assertEq(other.balanceOf(address(this)), beforeOther);

        ISwapRouter.ExactInputSingleParams memory input = _exactInput(address(tokenA), address(tokenB), FEE);
        input.recipient = outsider;
        vm.expectRevert(AerodromeSlipstreamAdapter.InvalidRecipient.selector);
        facade.exactInputSingle(input);

        ISwapRouter.ExactOutputSingleParams memory output = _exactOutput(address(tokenB), address(tokenA), FEE);
        output.recipient = address(pool);
        vm.expectRevert(AerodromeSlipstreamAdapter.InvalidRecipient.selector);
        facade.exactOutputSingle(output);
    }

    function test_onlyFacadeCanCall() public {
        vm.expectRevert(AerodromeSlipstreamAdapter.OnlyFacade.selector);
        adapter.exactInputSingle(_exactInput(address(tokenA), address(tokenB), FEE));
        vm.expectRevert(AerodromeSlipstreamAdapter.OnlyFacade.selector);
        adapter.exactOutputSingle(_exactOutput(address(tokenB), address(tokenA), FEE));
    }

    function test_poolFeeChangeFailsBeforeCustody() public {
        pool.setFee(FEE + 1);
        uint256 beforeIn = tokenA.balanceOf(address(this));
        vm.expectRevert(AerodromeSlipstreamAdapter.PoolStateChanged.selector);
        facade.exactInputSingle(_exactInput(address(tokenA), address(tokenB), FEE));
        assertEq(tokenA.balanceOf(address(this)), beforeIn);
    }

    function test_factoryFeeChangeFailsBeforeCustody() public {
        factory.setFee(FEE + 1);
        vm.expectRevert(AerodromeSlipstreamAdapter.PoolStateChanged.selector);
        facade.exactInputSingle(_exactInput(address(tokenA), address(tokenB), FEE));
    }

    function test_consistentVenueFeeChangeRemainsLive() public {
        pool.setFee(FEE + 1);
        factory.setFee(FEE + 1);

        assertEq(facade.exactInputSingle(_exactInput(address(tokenA), address(tokenB), FEE)), 80e6 + 1);
        assertEq(adapter.effectiveFee(), FEE);
        _assertClean(tokenA, tokenB);
    }

    function test_zeroActiveLiquidityDefersToVenue() public {
        pool.setLiquidity(0);
        assertEq(facade.exactInputSingle(_exactInput(address(tokenA), address(tokenB), FEE)), 80e6 + 1);
        _assertClean(tokenA, tokenB);
    }

    function test_wrongConstructorBindingReverts() public {
        vm.expectRevert(AerodromeSlipstreamAdapter.InvalidBinding.selector);
        new AerodromeSlipstreamAdapter(
            address(facade),
            address(venueRouter),
            address(factory),
            address(pool),
            address(tokenA),
            address(tokenB),
            SPACING + 1
        );

        pool.setLiquidity(0);
        vm.expectRevert(AerodromeSlipstreamAdapter.InvalidBinding.selector);
        new AerodromeSlipstreamAdapter(
            address(facade),
            address(venueRouter),
            address(factory),
            address(pool),
            address(tokenA),
            address(tokenB),
            SPACING
        );
    }

    function test_onlyVenueRouterCanSendNative() public {
        vm.deal(address(this), 2);
        (bool outsiderOk,) = address(adapter).call{value: 1}("");
        assertFalse(outsiderOk);

        vm.deal(address(venueRouter), 1);
        vm.prank(address(venueRouter));
        (bool venueOk,) = address(adapter).call{value: 1}("");
        assertTrue(venueOk);
        assertEq(address(adapter).balance, 1);
    }

    function test_preexistingBalancesArePreserved() public {
        tokenA.mint(address(facade), 2e18);
        tokenB.mint(address(facade), 3e6);
        tokenA.mint(address(adapter), 4e18);
        tokenB.mint(address(adapter), 5e6);

        facade.exactInputSingle(_exactInput(address(tokenA), address(tokenB), FEE));

        assertEq(tokenA.balanceOf(address(facade)), 2e18);
        assertEq(tokenB.balanceOf(address(facade)), 3e6);
        assertEq(tokenA.balanceOf(address(adapter)), 4e18);
        assertEq(tokenB.balanceOf(address(adapter)), 5e6);
        assertEq(tokenA.allowance(address(facade), address(adapter)), 0);
        assertEq(tokenA.allowance(address(adapter), address(venueRouter)), 0);
    }

    function _activate(address tokenIn, address tokenOut, PairRoutingSwapRouter.SwapKind kind) internal {
        facade.proposeRoute(tokenIn, tokenOut, kind, address(adapter));
        vm.warp(block.timestamp + facade.ROUTE_DELAY());
        facade.activateRoute(tokenIn, tokenOut, kind);
    }

    function _exactInput(address tokenIn, address tokenOut, uint24 compatibilityFee)
        internal
        view
        returns (ISwapRouter.ExactInputSingleParams memory)
    {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: compatibilityFee,
            recipient: address(this),
            amountIn: 100e18,
            amountOutMinimum: 80e6,
            sqrtPriceLimitX96: 0
        });
    }

    function _exactOutput(address tokenIn, address tokenOut, uint24 compatibilityFee)
        internal
        view
        returns (ISwapRouter.ExactOutputSingleParams memory)
    {
        return ISwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: compatibilityFee,
            recipient: recipient,
            amountOut: 1e18,
            amountInMaximum: 100e6,
            sqrtPriceLimitX96: 0
        });
    }

    function _assertClean(MockERC20 tokenIn, MockERC20 tokenOut) internal view {
        assertEq(tokenIn.balanceOf(address(facade)), 0);
        assertEq(tokenOut.balanceOf(address(facade)), 0);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
        assertEq(tokenOut.balanceOf(address(adapter)), 0);
        assertEq(tokenIn.allowance(address(facade), address(adapter)), 0);
        assertEq(tokenIn.allowance(address(adapter), address(venueRouter)), 0);
    }
}
