// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IFundShare is IERC20, IERC20Metadata, IERC20Permit, IERC165 {
    function asset() external view returns (address);
    function vault(address asset) external view returns (address);
    function compatibilityVersion() external view returns (uint64);
    function mint(address receiver, uint256 shares) external;
    function burn(address owner, uint256 shares) external;
    function escrowShares(address owner, address spender, uint256 shares) external;
    function returnEscrowedShares(address receiver, uint256 shares) external;
}
