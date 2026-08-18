// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAssetEscrow} from "./interfaces/IStrategyAssetEscrow.sol";

/// @notice Fund-specific custody boundary for assets recovered from a strategy adapter.
/// @dev Assets can only return to the immutable fund. The AccessManager controls when that release is executable.
contract StrategyAssetEscrow is AccessManaged, IStrategyAssetEscrow {
    using SafeERC20 for IERC20;

    address public immutable FUND;
    bytes32 public immutable PURPOSE;

    constructor(address fund_, address authority_, bytes32 purpose_) AccessManaged(authority_) {
        if (
            fund_ == address(0) || authority_ == address(0) || purpose_ == bytes32(0) || fund_.code.length == 0
                || authority_.code.length == 0
        ) revert InvalidAddress();
        FUND = fund_;
        PURPOSE = purpose_;
    }

    /// @notice Returns an exact ERC-20 amount to this escrow's immutable fund.
    /// @dev Exact balance-delta validation rejects fee-on-transfer behavior that would break reconciliation.
    function releaseToFund(address asset, uint256 amount) external restricted {
        if (asset == address(0) || asset.code.length == 0) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        IERC20 token = IERC20(asset);
        uint256 fundBalanceBefore = token.balanceOf(FUND);
        token.safeTransfer(FUND, amount);
        uint256 fundBalanceAfter = token.balanceOf(FUND);
        uint256 received = fundBalanceAfter >= fundBalanceBefore ? fundBalanceAfter - fundBalanceBefore : 0;
        if (received != amount) revert BalanceDeltaMismatch(asset, amount, received);

        emit AssetReleasedToFund(asset, amount);
    }
}
