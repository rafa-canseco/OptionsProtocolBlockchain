// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

/// @notice Routes the existing BatchSettler swap ABI to explicit pair adapters.
contract PairRoutingSwapRouter is ISwapRouter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum SwapKind {
        ExactInput,
        ExactOutput
    }

    struct Route {
        address adapter;
        address pendingAdapter;
        uint48 activateAfter;
    }

    uint48 public constant ROUTE_DELAY = 1 days;

    address public immutable settler;
    mapping(bytes32 routeKey_ => Route route) public routes;

    error OnlySettler();
    error InvalidRoute();
    error RouteUnavailable();
    error RouteNotReady();
    error NoPendingRoute();
    error NativeValueUnsupported();
    error InvalidBalanceDelta();
    error AdapterRetainedFunds();
    error AllowanceNotCleared();
    error InsufficientOutput();

    event RouteProposed(
        bytes32 indexed routeKey,
        address indexed tokenIn,
        address indexed tokenOut,
        SwapKind kind,
        address adapter,
        uint48 activateAfter
    );
    event RouteActivated(bytes32 indexed routeKey, address indexed adapter);
    event RouteUpdateCancelled(bytes32 indexed routeKey);
    event RouteDisabled(bytes32 indexed routeKey, address indexed adapter);

    constructor(address settler_, address initialOwner) Ownable(initialOwner) {
        if (settler_.code.length == 0) revert InvalidRoute();
        settler = settler_;
    }

    modifier onlySettler() {
        if (msg.sender != settler) revert OnlySettler();
        _;
    }

    function routeKey(address tokenIn, address tokenOut, SwapKind kind) public pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut, kind));
    }

    function proposeRoute(address tokenIn, address tokenOut, SwapKind kind, address adapter) external onlyOwner {
        _validateRoute(tokenIn, tokenOut, adapter);

        bytes32 key = routeKey(tokenIn, tokenOut, kind);
        uint48 activateAfter = uint48(block.timestamp) + ROUTE_DELAY;
        Route storage route = routes[key];
        route.pendingAdapter = adapter;
        route.activateAfter = activateAfter;

        emit RouteProposed(key, tokenIn, tokenOut, kind, adapter, activateAfter);
    }

    function activateRoute(address tokenIn, address tokenOut, SwapKind kind) external onlyOwner {
        bytes32 key = routeKey(tokenIn, tokenOut, kind);
        Route storage route = routes[key];
        address adapter = route.pendingAdapter;
        if (adapter == address(0)) revert NoPendingRoute();
        if (block.timestamp < route.activateAfter) revert RouteNotReady();

        route.adapter = adapter;
        route.pendingAdapter = address(0);
        route.activateAfter = 0;

        emit RouteActivated(key, adapter);
    }

    function cancelRouteUpdate(address tokenIn, address tokenOut, SwapKind kind) external onlyOwner {
        bytes32 key = routeKey(tokenIn, tokenOut, kind);
        Route storage route = routes[key];
        if (route.pendingAdapter == address(0)) revert NoPendingRoute();

        route.pendingAdapter = address(0);
        route.activateAfter = 0;

        emit RouteUpdateCancelled(key);
    }

    function disableRoute(address tokenIn, address tokenOut, SwapKind kind) external onlyOwner {
        bytes32 key = routeKey(tokenIn, tokenOut, kind);
        address adapter = routes[key].adapter;
        if (adapter == address(0)) revert RouteUnavailable();

        delete routes[key];
        emit RouteDisabled(key, adapter);
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        onlySettler
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.value != 0) revert NativeValueUnsupported();
        if (params.amountIn == 0 || params.recipient == address(0) || params.recipient == address(this)) {
            revert InvalidRoute();
        }

        address adapter = _activeAdapter(params.tokenIn, params.tokenOut, SwapKind.ExactInput);
        IERC20 tokenIn = IERC20(params.tokenIn);
        IERC20 tokenOut = IERC20(params.tokenOut);

        uint256 callerInBefore = tokenIn.balanceOf(msg.sender);
        uint256 facadeInBefore = tokenIn.balanceOf(address(this));
        uint256 facadeOutBefore = tokenOut.balanceOf(address(this));
        uint256 adapterInBefore = tokenIn.balanceOf(adapter);
        uint256 adapterOutBefore = tokenOut.balanceOf(adapter);
        uint256 recipientOutBefore = tokenOut.balanceOf(params.recipient);

        tokenIn.safeTransferFrom(msg.sender, address(this), params.amountIn);
        if (tokenIn.balanceOf(address(this)) != facadeInBefore + params.amountIn) revert InvalidBalanceDelta();

        tokenIn.forceApprove(adapter, params.amountIn);
        ISwapRouter(adapter).exactInputSingle(params);
        tokenIn.forceApprove(adapter, 0);

        amountOut = tokenOut.balanceOf(params.recipient) - recipientOutBefore;
        if (amountOut < params.amountOutMinimum) revert InsufficientOutput();
        if (callerInBefore - tokenIn.balanceOf(msg.sender) != params.amountIn) revert InvalidBalanceDelta();

        _verifyCleanup(tokenIn, tokenOut, adapter, facadeInBefore, facadeOutBefore, adapterInBefore, adapterOutBefore);
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        onlySettler
        nonReentrant
        returns (uint256 amountIn)
    {
        if (msg.value != 0) revert NativeValueUnsupported();
        if (
            params.amountOut == 0 || params.amountInMaximum == 0 || params.recipient == address(0)
                || params.recipient == address(this)
        ) revert InvalidRoute();

        address adapter = _activeAdapter(params.tokenIn, params.tokenOut, SwapKind.ExactOutput);
        IERC20 tokenIn = IERC20(params.tokenIn);
        IERC20 tokenOut = IERC20(params.tokenOut);

        uint256 callerInBefore = tokenIn.balanceOf(msg.sender);
        uint256 facadeInBefore = tokenIn.balanceOf(address(this));
        uint256 facadeOutBefore = tokenOut.balanceOf(address(this));
        uint256 adapterInBefore = tokenIn.balanceOf(adapter);
        uint256 adapterOutBefore = tokenOut.balanceOf(adapter);
        uint256 recipientOutBefore = tokenOut.balanceOf(params.recipient);

        uint256 fundedMaximum = params.amountInMaximum;
        uint256 callerAllowance = tokenIn.allowance(msg.sender, address(this));
        if (callerAllowance < fundedMaximum) fundedMaximum = callerAllowance;
        if (callerInBefore < fundedMaximum) fundedMaximum = callerInBefore;
        if (fundedMaximum == 0) revert InvalidBalanceDelta();

        tokenIn.safeTransferFrom(msg.sender, address(this), fundedMaximum);
        if (tokenIn.balanceOf(address(this)) != facadeInBefore + fundedMaximum) revert InvalidBalanceDelta();

        ExactOutputSingleParams memory fundedParams = params;
        fundedParams.amountInMaximum = fundedMaximum;
        tokenIn.forceApprove(adapter, fundedMaximum);
        ISwapRouter(adapter).exactOutputSingle(fundedParams);
        tokenIn.forceApprove(adapter, 0);

        uint256 facadeInAfterSwap = tokenIn.balanceOf(address(this));
        if (facadeInAfterSwap < facadeInBefore || facadeInAfterSwap > facadeInBefore + fundedMaximum) {
            revert InvalidBalanceDelta();
        }

        uint256 refund = facadeInAfterSwap - facadeInBefore;
        amountIn = fundedMaximum - refund;
        if (amountIn == 0) revert InvalidBalanceDelta();
        if (refund != 0) tokenIn.safeTransfer(msg.sender, refund);

        uint256 delivered = tokenOut.balanceOf(params.recipient) - recipientOutBefore;
        if (delivered < params.amountOut) revert InsufficientOutput();
        if (callerInBefore - tokenIn.balanceOf(msg.sender) != amountIn) revert InvalidBalanceDelta();

        _verifyCleanup(tokenIn, tokenOut, adapter, facadeInBefore, facadeOutBefore, adapterInBefore, adapterOutBefore);
    }

    function _activeAdapter(address tokenIn, address tokenOut, SwapKind kind) private view returns (address adapter) {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert InvalidRoute();
        adapter = routes[routeKey(tokenIn, tokenOut, kind)].adapter;
        if (adapter == address(0)) revert RouteUnavailable();
    }

    function _validateRoute(address tokenIn, address tokenOut, address adapter) private view {
        if (
            tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut || tokenIn.code.length == 0
                || tokenOut.code.length == 0 || adapter.code.length == 0 || adapter == address(this)
                || adapter == settler || adapter == tokenIn || adapter == tokenOut
        ) revert InvalidRoute();
    }

    function _verifyCleanup(
        IERC20 tokenIn,
        IERC20 tokenOut,
        address adapter,
        uint256 facadeInBefore,
        uint256 facadeOutBefore,
        uint256 adapterInBefore,
        uint256 adapterOutBefore
    ) private view {
        if (tokenIn.allowance(address(this), adapter) != 0) revert AllowanceNotCleared();
        if (tokenIn.balanceOf(address(this)) != facadeInBefore || tokenOut.balanceOf(address(this)) != facadeOutBefore)
        {
            revert InvalidBalanceDelta();
        }
        if (tokenIn.balanceOf(adapter) != adapterInBefore || tokenOut.balanceOf(adapter) != adapterOutBefore) {
            revert AdapterRetainedFunds();
        }
    }
}
