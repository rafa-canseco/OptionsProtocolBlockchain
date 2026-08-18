// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Immutable custody for processed accounting-asset claims.
/// @dev The escrow has no admin, upgrade, arbitrary-call, or sweep surface.
contract ClaimEscrow {
    using SafeERC20 for IERC20;

    error OnlyFundVault(address caller);
    error InvalidAddress();

    IERC20 public immutable ASSET;
    address public immutable FUND_VAULT;

    constructor(IERC20 asset_, address fundVault_) {
        if (address(asset_) == address(0) || fundVault_ == address(0)) revert InvalidAddress();
        ASSET = asset_;
        FUND_VAULT = fundVault_;
    }

    function release(address receiver, uint256 assets) external {
        if (msg.sender != FUND_VAULT) revert OnlyFundVault(msg.sender);
        if (receiver == address(0)) revert InvalidAddress();
        ASSET.safeTransfer(receiver, assets);
    }
}
