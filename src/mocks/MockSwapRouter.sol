// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../interfaces/ISwapRouter.sol";
import "./MockERC20.sol";
import "./MockChainlinkFeed.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockSwapRouter
 * @notice Mock Uniswap V3 SwapRouter for testing.
 *         Supports any asset/USDC pair via per-asset Chainlink price feeds.
 *         Mints output tokens via MockERC20.mint() — no pre-funded liquidity.
 * @dev Fee tier parameter is ignored — swaps use registered price feeds.
 *      All swaps must have USDC on one side.
 */
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    address public immutable usdc;

    /// @notice asset → Chainlink feed (USD price, 8 decimals)
    mapping(address => address) public priceFeeds;

    constructor(address _usdc) {
        require(_usdc != address(0), "Zero address");
        usdc = _usdc;
    }

    function setPriceFeed(address _asset, address _feed) external {
        require(_asset != address(0) && _feed != address(0), "Zero address");
        priceFeeds[_asset] = _feed;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountIn)
    {
        (address asset, uint256 price) = _resolveSwap(params.tokenIn, params.tokenOut);
        uint256 scale = 10 ** (MockERC20(asset).decimals() + 2);

        if (params.tokenOut == usdc) {
            // Selling asset for exact USDC output
            amountIn = (params.amountOut * scale) / price;
        } else {
            // Buying asset with USDC
            amountIn = (params.amountOut * price) / scale;
        }

        require(amountIn <= params.amountInMaximum, "Too much slippage");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        MockERC20(params.tokenOut).mint(params.recipient, params.amountOut);

        return amountIn;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        (address asset, uint256 price) = _resolveSwap(params.tokenIn, params.tokenOut);
        uint256 scale = 10 ** (MockERC20(asset).decimals() + 2);

        if (params.tokenIn == usdc) {
            // Buying asset with USDC
            amountOut = (params.amountIn * scale) / price;
        } else {
            // Selling asset for USDC
            amountOut = (params.amountIn * price) / scale;
        }

        require(amountOut >= params.amountOutMinimum, "Too much slippage");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        MockERC20(params.tokenOut).mint(params.recipient, amountOut);

        return amountOut;
    }

    function _resolveSwap(address tokenIn, address tokenOut) internal view returns (address asset, uint256 price) {
        require(tokenIn == usdc || tokenOut == usdc, "MockSwapRouter: one token must be USDC");
        asset = tokenIn == usdc ? tokenOut : tokenIn;

        address feed = priceFeeds[asset];
        require(feed != address(0), "MockSwapRouter: no price feed");
        (, int256 rawPrice,,,) = MockChainlinkFeed(feed).latestRoundData();
        require(rawPrice > 0, "MockSwapRouter: invalid price");
        price = uint256(rawPrice);
    }
}
