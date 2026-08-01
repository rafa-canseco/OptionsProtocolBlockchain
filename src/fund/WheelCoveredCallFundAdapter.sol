// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoveredCallFundAdapter} from "./CoveredCallFundAdapter.sol";
import {WheelCoveredCallFundAdapterStorage} from "./storage/WheelCoveredCallFundAdapterStorage.sol";

/// @notice Covered-call adapter variant used only by dedicated Wheel child lanes.
/// @dev Adds a terminal basket handoff; it does not alter the standalone adapter implementation or proxies.
contract WheelCoveredCallFundAdapter is CoveredCallFundAdapter, WheelCoveredCallFundAdapterStorage {
    using SafeERC20 for IERC20;

    error DuplicateWheelHandoff(bytes32 transitionHash);
    error InvalidWheelHandoff();
    error WheelHandoffDeficit(address asset, uint256 accounted, uint256 actual);
    error WheelHandoffTransferMismatch(address asset, uint256 expected, uint256 actual);

    event WheelAssetsHandedOff(
        bytes32 indexed transitionHash, address indexed receiver, uint256 wethAmount, uint256 usdcAmount
    );

    function wheelHandoff(bytes32 transitionHash, address receiver)
        external
        returns (uint256 wethAmount, uint256 usdcAmount)
    {
        CoveredCallFundAdapterStorageLayout storage base = _getCoveredCallFundAdapterStorage();
        if (msg.sender != base.strategyManager) revert OnlyStrategyManager();
        if (transitionHash == bytes32(0) || receiver == address(0) || base.activePositionCount != 0) {
            revert InvalidWheelHandoff();
        }
        WheelCoveredCallFundAdapterStorageLayout storage wheel = _getWheelCoveredCallFundAdapterStorage();
        if (wheel.consumedHandoffs[transitionHash]) revert DuplicateWheelHandoff(transitionHash);

        IERC20 wethToken = IERC20(base.accountingAsset);
        IERC20 usdcToken = IERC20(base.usdc);
        uint256 rawWeth = wethToken.balanceOf(address(this));
        uint256 rawUsdc = usdcToken.balanceOf(address(this));
        wethAmount = base.accountedWeth;
        usdcAmount = base.accountedUsdc;
        if (rawWeth < wethAmount) revert WheelHandoffDeficit(base.accountingAsset, wethAmount, rawWeth);
        if (rawUsdc < usdcAmount) revert WheelHandoffDeficit(base.usdc, usdcAmount, rawUsdc);

        wheel.consumedHandoffs[transitionHash] = true;
        base.accountedWeth = 0;
        base.accountedUsdc = 0;
        base.releasablePrincipal = 0;
        uint64 nonce = ++base.stateNonce;
        base.positionsHash = keccak256(
            abi.encode(base.positionsHash, nonce, "WHEEL_HANDOFF", transitionHash, receiver, wethAmount, usdcAmount)
        );

        uint256 receiverWethBefore = wethToken.balanceOf(receiver);
        uint256 receiverUsdcBefore = usdcToken.balanceOf(receiver);
        if (wethAmount != 0) wethToken.safeTransfer(receiver, wethAmount);
        if (usdcAmount != 0) usdcToken.safeTransfer(receiver, usdcAmount);
        uint256 receivedWeth = wethToken.balanceOf(receiver) - receiverWethBefore;
        uint256 receivedUsdc = usdcToken.balanceOf(receiver) - receiverUsdcBefore;
        if (receivedWeth != wethAmount) {
            revert WheelHandoffTransferMismatch(base.accountingAsset, wethAmount, receivedWeth);
        }
        if (receivedUsdc != usdcAmount) {
            revert WheelHandoffTransferMismatch(base.usdc, usdcAmount, receivedUsdc);
        }
        emit WheelAssetsHandedOff(transitionHash, receiver, wethAmount, usdcAmount);
    }

    function wheelHandoffConsumed(bytes32 transitionHash) external view returns (bool) {
        return _getWheelCoveredCallFundAdapterStorage().consumedHandoffs[transitionHash];
    }

    function wheelStorageLocation() external pure returns (bytes32) {
        return WHEEL_COVERED_CALL_FUND_ADAPTER_STORAGE_LOCATION;
    }
}
