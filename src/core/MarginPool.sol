// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
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
contract MarginPool is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    AddressBook public addressBook;

    error OnlyController();
    error Unauthorized();
    error InvalidAddress();

    modifier onlyController() {
        if (msg.sender != addressBook.controller()) revert OnlyController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressBook) external initializer {
        if (_addressBook == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
    }

    function transferToPool(address _asset, address _from, uint256 _amount) external onlyController {
        IERC20(_asset).safeTransferFrom(_from, address(this), _amount);
    }

    function transferToUser(address _asset, address _to, uint256 _amount) external onlyController {
        IERC20(_asset).safeTransfer(_to, _amount);
    }

    function getStoredBalance(address _asset) external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != addressBook.owner()) revert Unauthorized();
    }
}
