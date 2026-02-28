// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../interfaces/IFlashLoanSimple.sol";
import "./MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockAavePool
 * @notice Mock Aave V3 Pool that implements IPool.flashLoanSimple().
 *         Mints tokens from nothing via MockERC20.mint() — no pre-funded liquidity needed.
 *         Charges a realistic 0.05% flash loan fee.
 */
contract MockAavePool is IPool {
    using SafeERC20 for IERC20;

    uint256 public constant FLASH_LOAN_FEE_BPS = 5; // 0.05%

    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    )
        external
        override
    {
        // Mint tokens from nothing (MockERC20 has public mint)
        MockERC20(asset).mint(address(this), amount);

        // Transfer to receiver
        IERC20(asset).safeTransfer(receiverAddress, amount);

        // Calculate fee
        uint256 premium = (amount * FLASH_LOAN_FEE_BPS) / 10_000;

        // Call receiver's callback (initiator = msg.sender, matching real Aave V3)
        bool success =
            IFlashLoanSimpleReceiver(receiverAddress).executeOperation(asset, amount, premium, msg.sender, params);
        require(success, "Flash loan callback failed");

        // Pull back amount + premium
        IERC20(asset).safeTransferFrom(receiverAddress, address(this), amount + premium);
    }
}
