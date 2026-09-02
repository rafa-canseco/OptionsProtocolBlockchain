// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {UniswapV3SettlementAdapter} from "../src/routers/UniswapV3SettlementAdapter.sol";

contract MockCanonicalSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    address internal constant SINK = address(0xdead);

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

contract UniswapV3SettlementAdapterTest is Test {
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    PairRoutingSwapRouter internal facade;
    UniswapV3SettlementAdapter internal adapter;
    address internal recipient = address(0xB0B);
    address internal outsider = address(0xBAD);

    function setUp() public {
        MockERC20 tokenImplementation = new MockERC20("Mock", "MOCK", 18);
        MockCanonicalSwapRouter venueImplementation = new MockCanonicalSwapRouter();
        vm.etch(WETH, address(tokenImplementation).code);
        vm.etch(USDC, address(tokenImplementation).code);
        vm.etch(CBBTC, address(tokenImplementation).code);
        vm.etch(VVV, address(tokenImplementation).code);
        vm.etch(SWAP_ROUTER, address(venueImplementation).code);

        facade = new PairRoutingSwapRouter(address(this), address(this));
        adapter = new UniswapV3SettlementAdapter(address(facade));

        _activate(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _activate(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _activate(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput);
        _activate(USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput);
        _activate(VVV, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _activate(USDC, VVV, PairRoutingSwapRouter.SwapKind.ExactOutput);

        MockERC20(WETH).mint(address(this), 1_000e18);
        MockERC20(CBBTC).mint(address(this), 1_000e8);
        MockERC20(VVV).mint(address(this), 1_000e18);
        MockERC20(USDC).mint(address(this), 1_000_000e6);
        IERC20(WETH).approve(address(facade), type(uint256).max);
        IERC20(CBBTC).approve(address(facade), type(uint256).max);
        IERC20(VVV).approve(address(facade), type(uint256).max);
        IERC20(USDC).approve(address(facade), type(uint256).max);
    }

    function test_exactInputWethUsesMeasuredOutputAndClearsCustody() public {
        uint256 beforeOut = IERC20(USDC).balanceOf(address(this));
        uint256 amountOut = facade.exactInputSingle(_exactInput(WETH, USDC, 500, 1e18, 100e6));

        assertEq(amountOut, 100e6 + 1);
        assertEq(IERC20(USDC).balanceOf(address(this)) - beforeOut, amountOut);
        _assertClean(WETH, USDC);
    }

    function test_exactInputCbBtcUsesMeasuredOutputAndClearsCustody() public {
        uint256 amountOut = facade.exactInputSingle(_exactInput(CBBTC, USDC, 500, 1e8, 100e6));

        assertEq(amountOut, 100e6 + 1);
        _assertClean(CBBTC, USDC);
    }

    function test_exactOutputWethReturnsMeasuredSpendAndRefunds() public {
        uint256 beforeIn = IERC20(USDC).balanceOf(address(this));
        uint256 amountIn = facade.exactOutputSingle(_exactOutput(USDC, WETH, 500, 1e18, 2_000e6));

        assertEq(amountIn, 1_000e6);
        assertEq(beforeIn - IERC20(USDC).balanceOf(address(this)), amountIn);
        assertEq(IERC20(WETH).balanceOf(recipient), 1e18);
        _assertClean(USDC, WETH);
    }

    function test_exactOutputCbBtcReturnsMeasuredSpendAndRefunds() public {
        uint256 amountIn = facade.exactOutputSingle(_exactOutput(USDC, CBBTC, 500, 1e8, 100_000e6));

        assertEq(amountIn, 50_000e6);
        assertEq(IERC20(CBBTC).balanceOf(recipient), 1e8);
        _assertClean(USDC, CBBTC);
    }

    function test_vvvExactInputAndExactOutputUseCanonicalFee() public {
        uint256 amountOut = facade.exactInputSingle(_exactInput(VVV, USDC, 3000, 1e18, 100e6));
        uint256 amountIn = facade.exactOutputSingle(_exactOutput(USDC, VVV, 3000, 1e18, 2_000e6));

        assertEq(amountOut, 100e6 + 1);
        assertEq(amountIn, 1_000e6);
        assertEq(IERC20(VVV).balanceOf(recipient), 1e18);
        _assertClean(VVV, USDC);
        _assertClean(USDC, VVV);
    }

    function test_wrongFeeRevertsWithoutMovingFunds() public {
        uint256 beforeIn = IERC20(WETH).balanceOf(address(this));
        vm.expectRevert(UniswapV3SettlementAdapter.InvalidPair.selector);
        facade.exactInputSingle(_exactInput(WETH, USDC, 3000, 1e18, 100e6));
        assertEq(IERC20(WETH).balanceOf(address(this)), beforeIn);
        _assertClean(WETH, USDC);
    }

    function test_wrongPairRevertsWithoutMovingFunds() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        other.mint(address(this), 1e18);
        other.approve(address(facade), type(uint256).max);
        _activate(address(other), USDC, PairRoutingSwapRouter.SwapKind.ExactInput);

        uint256 beforeIn = other.balanceOf(address(this));
        vm.expectRevert(UniswapV3SettlementAdapter.InvalidPair.selector);
        facade.exactInputSingle(_exactInput(address(other), USDC, 3000, 1e18, 100e6));
        assertEq(other.balanceOf(address(this)), beforeIn);
    }

    function test_wrongRecipientsRevertWithoutMovingFunds() public {
        ISwapRouter.ExactInputSingleParams memory input = _exactInput(WETH, USDC, 500, 1e18, 100e6);
        input.recipient = outsider;
        vm.expectRevert(UniswapV3SettlementAdapter.InvalidRecipient.selector);
        facade.exactInputSingle(input);

        ISwapRouter.ExactOutputSingleParams memory output = _exactOutput(USDC, WETH, 500, 1e18, 2_000e6);
        output.recipient = address(adapter);
        vm.expectRevert(UniswapV3SettlementAdapter.InvalidRecipient.selector);
        facade.exactOutputSingle(output);
    }

    function test_onlyFacadeCanCallAdapter() public {
        vm.expectRevert(UniswapV3SettlementAdapter.OnlyFacade.selector);
        adapter.exactInputSingle(_exactInput(WETH, USDC, 500, 1e18, 100e6));

        vm.expectRevert(UniswapV3SettlementAdapter.OnlyFacade.selector);
        adapter.exactOutputSingle(_exactOutput(USDC, WETH, 500, 1e18, 2_000e6));
    }

    function test_priceLimitFailsClosed() public {
        ISwapRouter.ExactInputSingleParams memory params = _exactInput(WETH, USDC, 500, 1e18, 100e6);
        params.sqrtPriceLimitX96 = 1;
        vm.expectRevert(UniswapV3SettlementAdapter.PriceLimitUnsupported.selector);
        facade.exactInputSingle(params);
    }

    function test_preexistingBalancesArePreserved() public {
        MockERC20(WETH).mint(address(facade), 2e18);
        MockERC20(USDC).mint(address(facade), 3e6);
        MockERC20(WETH).mint(address(adapter), 4e18);
        MockERC20(USDC).mint(address(adapter), 5e6);

        facade.exactInputSingle(_exactInput(WETH, USDC, 500, 1e18, 100e6));

        assertEq(IERC20(WETH).balanceOf(address(facade)), 2e18);
        assertEq(IERC20(USDC).balanceOf(address(facade)), 3e6);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 4e18);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 5e6);
        assertEq(IERC20(WETH).allowance(address(facade), address(adapter)), 0);
        assertEq(IERC20(WETH).allowance(address(adapter), SWAP_ROUTER), 0);
    }

    function _activate(address tokenIn, address tokenOut, PairRoutingSwapRouter.SwapKind kind) internal {
        facade.proposeRoute(tokenIn, tokenOut, kind, address(adapter));
        vm.warp(block.timestamp + facade.ROUTE_DELAY());
        facade.activateRoute(tokenIn, tokenOut, kind);
    }

    function _exactInput(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 minimumOut)
        internal
        view
        returns (ISwapRouter.ExactInputSingleParams memory)
    {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: minimumOut,
            sqrtPriceLimitX96: 0
        });
    }

    function _exactOutput(address tokenIn, address tokenOut, uint24 fee, uint256 amountOut, uint256 maximumIn)
        internal
        view
        returns (ISwapRouter.ExactOutputSingleParams memory)
    {
        return ISwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountOut: amountOut,
            amountInMaximum: maximumIn,
            sqrtPriceLimitX96: 0
        });
    }

    function _assertClean(address tokenIn, address tokenOut) internal view {
        assertEq(IERC20(tokenIn).balanceOf(address(facade)), 0);
        assertEq(IERC20(tokenOut).balanceOf(address(facade)), 0);
        assertEq(IERC20(tokenIn).balanceOf(address(adapter)), 0);
        assertEq(IERC20(tokenOut).balanceOf(address(adapter)), 0);
        assertEq(IERC20(tokenIn).allowance(address(facade), address(adapter)), 0);
        assertEq(IERC20(tokenIn).allowance(address(adapter), SWAP_ROUTER), 0);
    }
}
