// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";

contract MockTypedSwapAdapter is ISwapRouter {
    using SafeERC20 for IERC20;

    address public constant SINK = address(0xdead);

    uint256 public nextAmountIn;
    uint256 public nextAmountOut;
    uint256 public reportedAmount;
    bool public retainInput;
    bool public pullPartialInput;
    bool public pullOnlySpentExactOutput;

    function configure(uint256 amountIn, uint256 amountOut, uint256 reported, bool retain, bool partialPull) external {
        nextAmountIn = amountIn;
        nextAmountOut = amountOut;
        reportedAmount = reported;
        retainInput = retain;
        pullPartialInput = partialPull;
    }

    function setPullOnlySpentExactOutput(bool enabled) external {
        pullOnlySpentExactOutput = enabled;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        uint256 pullAmount = pullPartialInput ? params.amountIn - 1 : params.amountIn;
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), pullAmount);
        if (!retainInput) IERC20(params.tokenIn).safeTransfer(SINK, pullAmount);
        MockERC20(params.tokenOut).mint(params.recipient, nextAmountOut);
        return reportedAmount;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn) {
        uint256 pullAmount = pullOnlySpentExactOutput ? nextAmountIn : params.amountInMaximum;
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), pullAmount);
        if (!retainInput) {
            IERC20(params.tokenIn).safeTransfer(SINK, nextAmountIn);
            if (pullAmount > nextAmountIn) IERC20(params.tokenIn).safeTransfer(msg.sender, pullAmount - nextAmountIn);
        }
        MockERC20(params.tokenOut).mint(params.recipient, nextAmountOut);
        return reportedAmount;
    }
}

contract PairRoutingSwapRouterTest is Test {
    PairRoutingSwapRouter internal router;
    MockTypedSwapAdapter internal adapter;
    MockTypedSwapAdapter internal replacement;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal recipient = address(0xB0B);
    address internal outsider = address(0xBAD);

    function setUp() public {
        tokenA = new MockERC20("Token A", "A", 18);
        tokenB = new MockERC20("Token B", "B", 6);
        adapter = new MockTypedSwapAdapter();
        replacement = new MockTypedSwapAdapter();
        router = new PairRoutingSwapRouter(address(this), address(this));

        tokenA.mint(address(this), 1_000e18);
        tokenA.approve(address(router), type(uint256).max);
    }

    function test_routeKeysSeparateDirectionAndSwapKind() public view {
        bytes32 exactInput =
            router.routeKey(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        bytes32 exactOutput =
            router.routeKey(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactOutput);
        bytes32 reverse = router.routeKey(address(tokenB), address(tokenA), PairRoutingSwapRouter.SwapKind.ExactInput);

        assertNotEq(exactInput, exactOutput);
        assertNotEq(exactInput, reverse);
        assertNotEq(exactOutput, reverse);
    }

    function test_pendingRouteCannotMoveFunds() public {
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter)
        );

        uint256 beforeBalance = tokenA.balanceOf(address(this));
        vm.expectRevert(PairRoutingSwapRouter.RouteUnavailable.selector);
        router.exactInputSingle(_exactInputParams(100e18, 80e6));

        assertEq(tokenA.balanceOf(address(this)), beforeBalance);
        assertEq(tokenA.balanceOf(address(router)), 0);
    }

    function test_routeActivationRequiresDelay() public {
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter)
        );

        vm.expectRevert(PairRoutingSwapRouter.RouteNotReady.selector);
        router.activateRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);

        vm.warp(block.timestamp + router.ROUTE_DELAY());
        router.activateRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);

        bytes32 key = router.routeKey(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        (address active, address pending, uint48 activateAfter) = router.routes(key);
        assertEq(active, address(adapter));
        assertEq(pending, address(0));
        assertEq(activateAfter, 0);
    }

    function test_pendingReplacementDoesNotChangeActiveRoute() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(replacement)
        );

        adapter.configure(100e18, 90e6, 1, false, false);
        assertEq(router.exactInputSingle(_exactInputParams(100e18, 80e6)), 90e6);
    }

    function test_replacementProposalRestartsDelay() public {
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter)
        );
        vm.warp(block.timestamp + router.ROUTE_DELAY() - 1);
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(replacement)
        );

        vm.warp(block.timestamp + 1);
        vm.expectRevert(PairRoutingSwapRouter.RouteNotReady.selector);
        router.activateRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);

        vm.warp(block.timestamp + router.ROUTE_DELAY() - 1);
        router.activateRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        bytes32 key = router.routeKey(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        (address active,,) = router.routes(key);
        assertEq(active, address(replacement));
    }

    function test_cancelRouteUpdateKeepsActiveRoute() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(replacement)
        );
        router.cancelRouteUpdate(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);

        bytes32 key = router.routeKey(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        (address active, address pending, uint48 activateAfter) = router.routes(key);
        assertEq(active, address(adapter));
        assertEq(pending, address(0));
        assertEq(activateAfter, 0);
    }

    function test_disableRouteIsImmediateAndClearsPendingUpdate() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(replacement)
        );
        router.disableRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);

        bytes32 key = router.routeKey(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        (address active, address pending, uint48 activateAfter) = router.routes(key);
        assertEq(active, address(0));
        assertEq(pending, address(0));
        assertEq(activateAfter, 0);

        vm.expectRevert(PairRoutingSwapRouter.RouteUnavailable.selector);
        router.exactInputSingle(_exactInputParams(100e18, 80e6));
    }

    function test_onlyOwnerCanManageRoutes() public {
        bytes memory unauthorized = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider);
        vm.prank(outsider);
        vm.expectRevert(unauthorized);
        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter)
        );

        router.proposeRoute(
            address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter)
        );
        vm.startPrank(outsider);
        vm.expectRevert(unauthorized);
        router.activateRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        vm.expectRevert(unauthorized);
        router.cancelRouteUpdate(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        vm.stopPrank();

        vm.warp(block.timestamp + router.ROUTE_DELAY());
        router.activateRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
        vm.prank(outsider);
        vm.expectRevert(unauthorized);
        router.disableRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput);
    }

    function test_onlyBoundSettlerCanSwap() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        _activate(PairRoutingSwapRouter.SwapKind.ExactOutput, address(adapter));

        vm.startPrank(outsider);
        vm.expectRevert(PairRoutingSwapRouter.OnlySettler.selector);
        router.exactInputSingle(_exactInputParams(100e18, 80e6));
        vm.expectRevert(PairRoutingSwapRouter.OnlySettler.selector);
        router.exactOutputSingle(_exactOutputParams(50e6, 100e18));
        vm.stopPrank();
    }

    function test_activeRouteDoesNotEnableReverseOrOtherSwapKind() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));

        vm.expectRevert(PairRoutingSwapRouter.RouteUnavailable.selector);
        router.exactOutputSingle(_exactOutputParams(50e6, 100e18));

        ISwapRouter.ExactInputSingleParams memory reverse = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenB),
            tokenOut: address(tokenA),
            fee: 3000,
            recipient: recipient,
            amountIn: 50e6,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: 0
        });
        vm.expectRevert(PairRoutingSwapRouter.RouteUnavailable.selector);
        router.exactInputSingle(reverse);
    }

    function test_exactInputUsesMeasuredOutputAndLeavesNoCustody() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        adapter.configure(100e18, 90e6, 1, false, false);

        uint256 callerBefore = tokenA.balanceOf(address(this));
        uint256 recipientBefore = tokenB.balanceOf(recipient);
        uint256 amountOut = router.exactInputSingle(_exactInputParams(100e18, 80e6));

        assertEq(amountOut, 90e6);
        assertEq(callerBefore - tokenA.balanceOf(address(this)), 100e18);
        assertEq(tokenB.balanceOf(recipient) - recipientBefore, 90e6);
        _assertClean(address(adapter));
    }

    function test_exactOutputReturnsMeasuredSpendAndRefundsSurplus() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactOutput, address(adapter));
        adapter.configure(70e18, 50e6, 999e18, false, false);
        adapter.setPullOnlySpentExactOutput(true);

        uint256 callerBefore = tokenA.balanceOf(address(this));
        uint256 recipientBefore = tokenB.balanceOf(recipient);
        uint256 amountIn = router.exactOutputSingle(_exactOutputParams(50e6, 100e18));

        assertEq(amountIn, 70e18);
        assertEq(callerBefore - tokenA.balanceOf(address(this)), 70e18);
        assertEq(tokenB.balanceOf(recipient) - recipientBefore, 50e6);
        _assertClean(address(adapter));
    }

    function test_exactOutputCapsPrefundingToAvailableAllowance() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactOutput, address(adapter));
        adapter.configure(70e18, 50e6, 999e18, false, false);
        adapter.setPullOnlySpentExactOutput(true);
        tokenA.approve(address(router), 80e18);

        uint256 callerBefore = tokenA.balanceOf(address(this));
        uint256 amountIn = router.exactOutputSingle(_exactOutputParams(50e6, 100e18));

        assertEq(amountIn, 70e18);
        assertEq(callerBefore - tokenA.balanceOf(address(this)), 70e18);
        assertEq(tokenA.allowance(address(this), address(router)), 0);
        _assertClean(address(adapter));
    }

    function test_swapsPreservePreexistingFacadeAndAdapterBalances() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        _activate(PairRoutingSwapRouter.SwapKind.ExactOutput, address(adapter));
        tokenA.mint(address(router), 3e18);
        tokenB.mint(address(router), 4e6);
        tokenA.mint(address(adapter), 5e18);
        tokenB.mint(address(adapter), 6e6);

        adapter.configure(100e18, 90e6, 1, false, false);
        router.exactInputSingle(_exactInputParams(100e18, 80e6));
        adapter.configure(70e18, 50e6, 999e18, false, false);
        router.exactOutputSingle(_exactOutputParams(50e6, 100e18));

        assertEq(tokenA.balanceOf(address(router)), 3e18);
        assertEq(tokenB.balanceOf(address(router)), 4e6);
        assertEq(tokenA.balanceOf(address(adapter)), 5e18);
        assertEq(tokenB.balanceOf(address(adapter)), 6e6);
        assertEq(tokenA.allowance(address(router), address(adapter)), 0);
    }

    function test_exactInputRejectsShortMeasuredOutput() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        adapter.configure(100e18, 79e6, type(uint256).max, false, false);

        vm.expectRevert(PairRoutingSwapRouter.InsufficientOutput.selector);
        router.exactInputSingle(_exactInputParams(100e18, 80e6));
    }

    function test_exactOutputRejectsShortMeasuredOutput() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactOutput, address(adapter));
        adapter.configure(70e18, 49e6, 70e18, false, false);

        vm.expectRevert(PairRoutingSwapRouter.InsufficientOutput.selector);
        router.exactOutputSingle(_exactOutputParams(50e6, 100e18));
    }

    function test_exactOutputRejectsAdapterCustody() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactOutput, address(adapter));
        adapter.configure(70e18, 50e6, 70e18, true, false);

        vm.expectRevert(PairRoutingSwapRouter.AdapterRetainedFunds.selector);
        router.exactOutputSingle(_exactOutputParams(50e6, 100e18));
    }

    function test_exactInputRejectsPartialAdapterPull() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        adapter.configure(100e18, 90e6, 90e6, false, true);

        vm.expectRevert(PairRoutingSwapRouter.InvalidBalanceDelta.selector);
        router.exactInputSingle(_exactInputParams(100e18, 80e6));
    }

    function test_invalidAndUnknownRoutesFailClosed() public {
        vm.expectRevert(PairRoutingSwapRouter.InvalidRoute.selector);
        router.proposeRoute(
            address(tokenA), address(tokenA), PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter)
        );

        vm.expectRevert(PairRoutingSwapRouter.InvalidRoute.selector);
        router.proposeRoute(address(tokenA), address(tokenB), PairRoutingSwapRouter.SwapKind.ExactInput, outsider);

        vm.expectRevert(PairRoutingSwapRouter.RouteUnavailable.selector);
        router.exactOutputSingle(_exactOutputParams(50e6, 100e18));
    }

    function test_nativeValueFailsBeforeTokenMovement() public {
        _activate(PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        vm.deal(address(this), 1 ether);

        vm.expectRevert(PairRoutingSwapRouter.NativeValueUnsupported.selector);
        router.exactInputSingle{value: 1}(_exactInputParams(100e18, 80e6));
        assertEq(tokenA.balanceOf(address(router)), 0);
    }

    function _activate(PairRoutingSwapRouter.SwapKind kind, address adapter_) internal {
        router.proposeRoute(address(tokenA), address(tokenB), kind, adapter_);
        vm.warp(block.timestamp + router.ROUTE_DELAY());
        router.activateRoute(address(tokenA), address(tokenB), kind);
    }

    function _exactInputParams(uint256 amountIn, uint256 minimumOut)
        internal
        view
        returns (ISwapRouter.ExactInputSingleParams memory)
    {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            fee: 3000,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minimumOut,
            sqrtPriceLimitX96: 0
        });
    }

    function _exactOutputParams(uint256 amountOut, uint256 maximumIn)
        internal
        view
        returns (ISwapRouter.ExactOutputSingleParams memory)
    {
        return ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            fee: 3000,
            recipient: recipient,
            amountOut: amountOut,
            amountInMaximum: maximumIn,
            sqrtPriceLimitX96: 0
        });
    }

    function _assertClean(address adapter_) internal view {
        assertEq(tokenA.balanceOf(address(router)), 0);
        assertEq(tokenB.balanceOf(address(router)), 0);
        assertEq(tokenA.balanceOf(adapter_), 0);
        assertEq(tokenB.balanceOf(adapter_), 0);
        assertEq(tokenA.allowance(address(router), adapter_), 0);
    }

    receive() external payable {}
}
