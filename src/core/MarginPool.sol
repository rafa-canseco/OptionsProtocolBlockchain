// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AddressBook.sol";

/**
 * @title MarginPool
 * @notice Custodian of all collateral in the protocol.
 *         Only the Controller can move funds in/out.
 *         Users deposit collateral here when opening positions,
 *         and receive it back at settlement.
 */
contract MarginPool {
    using SafeERC20 for IERC20;

    AddressBook public addressBook;

    error OnlyController();

    modifier onlyController() {
        if (msg.sender != addressBook.controller()) revert OnlyController();
        _;
    }

    constructor(address _addressBook) {
        addressBook = AddressBook(_addressBook);
    }

    /**
     * @notice Transfer asset from a user into the pool. Called by Controller during vault deposit.
     */
    function transferToPool(address _asset, address _from, uint256 _amount) external onlyController {
        IERC20(_asset).safeTransferFrom(_from, address(this), _amount);
    }

    /**
     * @notice Transfer asset from the pool to a user. Called by Controller during withdrawal/settlement.
     */
    function transferToUser(address _asset, address _to, uint256 _amount) external onlyController {
        IERC20(_asset).safeTransfer(_to, _amount);
    }

    /**
     * @notice Get the pool's balance of a specific asset.
     */
    function getStoredBalance(address _asset) external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }
}
