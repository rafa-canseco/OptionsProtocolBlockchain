// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {MockChainlinkFeed} from "./MockChainlinkFeed.sol";
import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockFundedSwapRouter
 * @notice Testnet swap router for Circle USDC deployments.
 *         Mock asset outputs are minted; real USDC outputs are paid from router balance.
 */
contract MockFundedSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    address public immutable USDC;
    mapping(address asset => address feed) public priceFeeds;

    constructor(address usdc_) {
        require(usdc_ != address(0), "Zero address");
        USDC = usdc_;
    }

    function setPriceFeed(address asset, address feed) external {
        require(asset != address(0) && feed != address(0), "Zero address");
        priceFeeds[asset] = feed;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountIn)
    {
        (address asset, uint256 price) = _resolveSwap(params.tokenIn, params.tokenOut);
        uint256 scale = 10 ** (MockERC20(asset).decimals() + 2);

        if (params.tokenOut == USDC) {
            amountIn = (params.amountOut * scale) / price;
        } else {
            amountIn = (params.amountOut * price) / scale;
        }

        require(amountIn <= params.amountInMaximum, "Too much slippage");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        _payOutput(params.tokenOut, params.recipient, params.amountOut);
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        (address asset, uint256 price) = _resolveSwap(params.tokenIn, params.tokenOut);
        uint256 scale = 10 ** (MockERC20(asset).decimals() + 2);

        if (params.tokenIn == USDC) {
            amountOut = (params.amountIn * scale) / price;
        } else {
            amountOut = (params.amountIn * price) / scale;
        }

        require(amountOut >= params.amountOutMinimum, "Too much slippage");

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        _payOutput(params.tokenOut, params.recipient, amountOut);
    }

    function _payOutput(address tokenOut, address recipient, uint256 amount) internal {
        if (tokenOut == USDC) {
            IERC20(USDC).safeTransfer(recipient, amount);
        } else {
            MockERC20(tokenOut).mint(recipient, amount);
        }
    }

    function _resolveSwap(address tokenIn, address tokenOut) internal view returns (address asset, uint256 price) {
        require(tokenIn == USDC || tokenOut == USDC, "MockFundedSwapRouter: one token must be USDC");
        asset = tokenIn == USDC ? tokenOut : tokenIn;

        address feed = priceFeeds[asset];
        require(feed != address(0), "MockFundedSwapRouter: no price feed");
        (, int256 rawPrice,,,) = MockChainlinkFeed(feed).latestRoundData();
        require(rawPrice > 0, "MockFundedSwapRouter: invalid price");
        // casting to 'uint256' is safe because rawPrice is checked positive above.
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(rawPrice);
    }
}
