// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

interface IBoundAerodromeFacade {
    function settler() external view returns (address);
}

interface IAerodromeSlipstreamFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
    function getSwapFee(address pool) external view returns (uint24);
}

interface IAerodromeSlipstreamPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

interface IAerodromeSlipstreamRouter {
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
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// @notice Immutable adapter for one Aerodrome Slipstream pool.
contract AerodromeSlipstreamAdapter is ISwapRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable facade;
    address public immutable settler;
    address public immutable venueRouter;
    address public immutable factory;
    address public immutable pool;
    address public immutable tokenA;
    address public immutable tokenB;
    int24 public immutable tickSpacing;
    uint24 public immutable effectiveFee;

    error OnlyFacade();
    error OnlyVenueRouter();
    error InvalidBinding();
    error InvalidPair();
    error InvalidRecipient();
    error InvalidAmount();
    error NativeValueUnsupported();
    error PriceLimitUnsupported();
    error PoolStateChanged();
    error InvalidBalanceDelta();
    error InsufficientOutput();
    error AllowanceNotCleared();

    constructor(
        address facade_,
        address venueRouter_,
        address factory_,
        address pool_,
        address tokenA_,
        address tokenB_,
        int24 tickSpacing_
    ) {
        if (
            facade_.code.length == 0 || venueRouter_.code.length == 0 || factory_.code.length == 0
                || pool_.code.length == 0 || tokenA_.code.length == 0 || tokenB_.code.length == 0 || tokenA_ == tokenB_
                || tickSpacing_ <= 0
        ) revert InvalidBinding();

        address settler_ = IBoundAerodromeFacade(facade_).settler();
        IAerodromeSlipstreamPool boundPool = IAerodromeSlipstreamPool(pool_);
        IAerodromeSlipstreamFactory boundFactory = IAerodromeSlipstreamFactory(factory_);
        address poolToken0 = boundPool.token0();
        address poolToken1 = boundPool.token1();
        bool pairMatches =
            (poolToken0 == tokenA_ && poolToken1 == tokenB_) || (poolToken0 == tokenB_ && poolToken1 == tokenA_);
        uint24 fee_ = boundPool.fee();

        if (
            settler_.code.length == 0 || IAerodromeSlipstreamRouter(venueRouter_).factory() != factory_
                || boundPool.factory() != factory_ || boundPool.tickSpacing() != tickSpacing_ || !pairMatches
                || boundFactory.getPool(tokenA_, tokenB_, tickSpacing_) != pool_ || fee_ == 0
                || boundFactory.getSwapFee(pool_) != fee_ || boundPool.liquidity() == 0
        ) revert InvalidBinding();

        facade = facade_;
        settler = settler_;
        venueRouter = venueRouter_;
        factory = factory_;
        pool = pool_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        tickSpacing = tickSpacing_;
        effectiveFee = fee_;
    }

    modifier onlyFacade() {
        if (msg.sender != facade) revert OnlyFacade();
        _;
    }

    receive() external payable {
        if (msg.sender != venueRouter) revert OnlyVenueRouter();
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        payable
        onlyFacade
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.value != 0) revert NativeValueUnsupported();
        if (params.amountIn == 0) revert InvalidAmount();
        if (params.recipient != settler) revert InvalidRecipient();
        if (params.sqrtPriceLimitX96 != 0) revert PriceLimitUnsupported();
        _validatePool(params.tokenIn, params.tokenOut);

        IERC20 tokenIn = IERC20(params.tokenIn);
        IERC20 tokenOut = IERC20(params.tokenOut);
        uint256 callerInBefore = tokenIn.balanceOf(msg.sender);
        uint256 adapterInBefore = tokenIn.balanceOf(address(this));
        uint256 adapterOutBefore = tokenOut.balanceOf(address(this));
        uint256 recipientOutBefore = tokenOut.balanceOf(params.recipient);

        tokenIn.safeTransferFrom(msg.sender, address(this), params.amountIn);
        if (tokenIn.balanceOf(address(this)) != adapterInBefore + params.amountIn) revert InvalidBalanceDelta();

        tokenIn.forceApprove(venueRouter, params.amountIn);
        IAerodromeSlipstreamRouter(venueRouter)
            .exactInputSingle(
                IAerodromeSlipstreamRouter.ExactInputSingleParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    tickSpacing: tickSpacing,
                    recipient: params.recipient,
                    deadline: block.timestamp,
                    amountIn: params.amountIn,
                    amountOutMinimum: params.amountOutMinimum,
                    sqrtPriceLimitX96: 0
                })
            );
        tokenIn.forceApprove(venueRouter, 0);

        amountOut = tokenOut.balanceOf(params.recipient) - recipientOutBefore;
        if (amountOut < params.amountOutMinimum) revert InsufficientOutput();
        if (callerInBefore - tokenIn.balanceOf(msg.sender) != params.amountIn) revert InvalidBalanceDelta();
        _verifyCleanup(tokenIn, tokenOut, adapterInBefore, adapterOutBefore);
    }

    function exactOutputSingle(ISwapRouter.ExactOutputSingleParams calldata params)
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
                || params.recipient == venueRouter || params.recipient == factory || params.recipient == pool
        ) revert InvalidRecipient();
        if (params.sqrtPriceLimitX96 != 0) revert PriceLimitUnsupported();
        _validatePool(params.tokenIn, params.tokenOut);

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

        tokenIn.forceApprove(venueRouter, params.amountInMaximum);
        IAerodromeSlipstreamRouter(venueRouter)
            .exactOutputSingle(
                IAerodromeSlipstreamRouter.ExactOutputSingleParams({
                    tokenIn: params.tokenIn,
                    tokenOut: params.tokenOut,
                    tickSpacing: tickSpacing,
                    recipient: params.recipient,
                    deadline: block.timestamp,
                    amountOut: params.amountOut,
                    amountInMaximum: params.amountInMaximum,
                    sqrtPriceLimitX96: 0
                })
            );
        tokenIn.forceApprove(venueRouter, 0);

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

    function _validatePool(address tokenIn, address tokenOut) private view {
        bool pairMatches = (tokenIn == tokenA && tokenOut == tokenB) || (tokenIn == tokenB && tokenOut == tokenA);
        if (!pairMatches) revert InvalidPair();
        IAerodromeSlipstreamPool boundPool = IAerodromeSlipstreamPool(pool);
        uint24 liveFee = boundPool.fee();
        if (
            boundPool.factory() != factory || boundPool.tickSpacing() != tickSpacing || liveFee == 0
                || IAerodromeSlipstreamFactory(factory).getSwapFee(pool) != liveFee
        ) revert PoolStateChanged();
    }

    function _verifyCleanup(IERC20 tokenIn, IERC20 tokenOut, uint256 adapterInBefore, uint256 adapterOutBefore)
        private
        view
    {
        if (tokenIn.allowance(address(this), venueRouter) != 0) revert AllowanceNotCleared();
        if (
            tokenIn.balanceOf(address(this)) != adapterInBefore || tokenOut.balanceOf(address(this)) != adapterOutBefore
        ) revert InvalidBalanceDelta();
    }
}
