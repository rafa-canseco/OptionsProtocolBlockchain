// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

interface IBoundSettlementFacade {
    function settler() external view returns (address);
}

/// @notice Immutable Uniswap V3 adapter for current Base settlement pairs.
contract UniswapV3SettlementAdapter is ISwapRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address public constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    uint24 public constant WETH_FEE = 500;
    uint24 public constant CBBTC_FEE = 500;
    uint24 public constant VVV_FEE = 3000;

    address public immutable facade;
    address public immutable settler;

    error OnlyFacade();
    error InvalidBinding();
    error InvalidPair();
    error InvalidRecipient();
    error InvalidAmount();
    error NativeValueUnsupported();
    error PriceLimitUnsupported();
    error InvalidBalanceDelta();
    error InsufficientOutput();
    error AllowanceNotCleared();

    constructor(address facade_) {
        if (facade_.code.length == 0 || SWAP_ROUTER.code.length == 0) revert InvalidBinding();
        address settler_ = IBoundSettlementFacade(facade_).settler();
        if (settler_.code.length == 0) revert InvalidBinding();
        facade = facade_;
        settler = settler_;
    }

    modifier onlyFacade() {
        if (msg.sender != facade) revert OnlyFacade();
        _;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        onlyFacade
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.value != 0) revert NativeValueUnsupported();
        if (params.amountIn == 0) revert InvalidAmount();
        if (params.recipient != settler) revert InvalidRecipient();
        _validatePair(params.tokenIn, params.tokenOut, params.fee);
        if (params.sqrtPriceLimitX96 != 0) revert PriceLimitUnsupported();

        IERC20 tokenIn = IERC20(params.tokenIn);
        IERC20 tokenOut = IERC20(params.tokenOut);
        uint256 callerInBefore = tokenIn.balanceOf(msg.sender);
        uint256 adapterInBefore = tokenIn.balanceOf(address(this));
        uint256 adapterOutBefore = tokenOut.balanceOf(address(this));
        uint256 recipientOutBefore = tokenOut.balanceOf(params.recipient);

        tokenIn.safeTransferFrom(msg.sender, address(this), params.amountIn);
        if (tokenIn.balanceOf(address(this)) != adapterInBefore + params.amountIn) revert InvalidBalanceDelta();

        tokenIn.forceApprove(SWAP_ROUTER, params.amountIn);
        ISwapRouter(SWAP_ROUTER).exactInputSingle(params);
        tokenIn.forceApprove(SWAP_ROUTER, 0);

        amountOut = tokenOut.balanceOf(params.recipient) - recipientOutBefore;
        if (amountOut < params.amountOutMinimum) revert InsufficientOutput();
        if (callerInBefore - tokenIn.balanceOf(msg.sender) != params.amountIn) revert InvalidBalanceDelta();
        _verifyCleanup(tokenIn, tokenOut, adapterInBefore, adapterOutBefore);
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        onlyFacade
        nonReentrant
        returns (uint256 amountIn)
    {
        if (msg.value != 0) revert NativeValueUnsupported();
        if (params.amountOut == 0 || params.amountInMaximum == 0) revert InvalidAmount();
        if (
            params.recipient == address(0) || params.recipient == address(this) || params.recipient == facade
                || params.recipient == SWAP_ROUTER
        ) revert InvalidRecipient();
        _validatePair(params.tokenIn, params.tokenOut, params.fee);
        if (params.sqrtPriceLimitX96 != 0) revert PriceLimitUnsupported();

        IERC20 tokenIn = IERC20(params.tokenIn);
        IERC20 tokenOut = IERC20(params.tokenOut);
        uint256 callerInBefore = tokenIn.balanceOf(msg.sender);
        uint256 adapterInBefore = tokenIn.balanceOf(address(this));
        uint256 adapterOutBefore = tokenOut.balanceOf(address(this));
        uint256 recipientOutBefore = tokenOut.balanceOf(params.recipient);

        tokenIn.safeTransferFrom(msg.sender, address(this), params.amountInMaximum);
        if (tokenIn.balanceOf(address(this)) != adapterInBefore + params.amountInMaximum) {
            revert InvalidBalanceDelta();
        }

        tokenIn.forceApprove(SWAP_ROUTER, params.amountInMaximum);
        ISwapRouter(SWAP_ROUTER).exactOutputSingle(params);
        tokenIn.forceApprove(SWAP_ROUTER, 0);

        uint256 adapterInAfterSwap = tokenIn.balanceOf(address(this));
        if (adapterInAfterSwap < adapterInBefore || adapterInAfterSwap > adapterInBefore + params.amountInMaximum) {
            revert InvalidBalanceDelta();
        }

        uint256 refund = adapterInAfterSwap - adapterInBefore;
        amountIn = params.amountInMaximum - refund;
        if (amountIn == 0) revert InvalidBalanceDelta();
        if (refund != 0) tokenIn.safeTransfer(msg.sender, refund);

        uint256 delivered = tokenOut.balanceOf(params.recipient) - recipientOutBefore;
        if (delivered < params.amountOut) revert InsufficientOutput();
        if (callerInBefore - tokenIn.balanceOf(msg.sender) != amountIn) revert InvalidBalanceDelta();
        _verifyCleanup(tokenIn, tokenOut, adapterInBefore, adapterOutBefore);
    }

    function _validatePair(address tokenIn, address tokenOut, uint24 fee) private pure {
        bool wethPair =
            ((tokenIn == WETH && tokenOut == USDC) || (tokenIn == USDC && tokenOut == WETH)) && fee == WETH_FEE;
        bool cbBtcPair =
            ((tokenIn == CBBTC && tokenOut == USDC) || (tokenIn == USDC && tokenOut == CBBTC)) && fee == CBBTC_FEE;
        bool vvvPair = ((tokenIn == VVV && tokenOut == USDC) || (tokenIn == USDC && tokenOut == VVV)) && fee == VVV_FEE;
        if (!wethPair && !cbBtcPair && !vvvPair) revert InvalidPair();
    }

    function _verifyCleanup(IERC20 tokenIn, IERC20 tokenOut, uint256 adapterInBefore, uint256 adapterOutBefore)
        private
        view
    {
        if (tokenIn.allowance(address(this), SWAP_ROUTER) != 0) revert AllowanceNotCleared();
        if (
            tokenIn.balanceOf(address(this)) != adapterInBefore || tokenOut.balanceOf(address(this)) != adapterOutBefore
        ) {
            revert InvalidBalanceDelta();
        }
    }
}
