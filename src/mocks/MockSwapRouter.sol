// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
 *         Only supports swaps between the configured WETH and USDC pair.
 * @dev The fee tier parameter is ignored — all swaps use the single Chainlink price feed.
 */
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    MockChainlinkFeed public immutable priceFeed;
    address public immutable weth;
    address public immutable usdc;

    constructor(address _priceFeed, address _weth, address _usdc) {
        require(_priceFeed != address(0) && _weth != address(0) && _usdc != address(0), "Zero address");
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
        require(params.tokenOut == weth || params.tokenOut == usdc, "MockSwapRouter: unsupported tokenOut");
        require(params.tokenIn == weth || params.tokenIn == usdc, "MockSwapRouter: unsupported tokenIn");

        (, int256 rawPrice,,,) = priceFeed.latestRoundData();
        require(rawPrice > 0, "MockSwapRouter: invalid price");
        uint256 ethPrice = uint256(rawPrice); // 8 decimals (e.g., 2500e8)

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
