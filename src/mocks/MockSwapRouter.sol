// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../interfaces/ISwapRouter.sol";
import "./MockERC20.sol";
import "./MockChainlinkFeed.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockSwapRouter
 * @notice Mock Uniswap V3 SwapRouter that implements ISwapRouter.exactOutputSingle().
 *         Uses MockChainlinkFeed for realistic ETH/USD conversion rates.
 *         Mints output tokens via MockERC20.mint() — no pre-funded liquidity needed.
 */
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    MockChainlinkFeed public priceFeed;
    address public weth;
    address public usdc;

    constructor(address _priceFeed, address _weth, address _usdc) {
        priceFeed = MockChainlinkFeed(_priceFeed);
        weth = _weth;
        usdc = _usdc;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountIn)
    {
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 ethPrice = uint256(price); // 8 decimals (e.g., 2500e8)

        if (params.tokenOut == weth) {
            // Buying WETH (18 dec) with USDC (6 dec)
            // amountIn (USDC 6 dec) = amountOut (WETH 18 dec) * price (8 dec) / 1e20
            amountIn = (params.amountOut * ethPrice) / 1e20;
        } else {
            // Buying USDC (6 dec) with WETH (18 dec)
            // amountIn (WETH 18 dec) = amountOut (USDC 6 dec) * 1e20 / price (8 dec)
            amountIn = (params.amountOut * 1e20) / ethPrice;
        }

        require(amountIn <= params.amountInMaximum, "Too much slippage");

        // Pull input tokens from caller
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Mint output tokens to recipient (no real liquidity needed)
        MockERC20(params.tokenOut).mint(params.recipient, params.amountOut);

        return amountIn;
    }
}
