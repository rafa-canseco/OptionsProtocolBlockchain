// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundShareStorage} from "./storage/FundShareStorage.sol";

/// @notice ERC-20/Permit share token authorized by exactly one fund vault.
contract FundShare is FundUpgradeable, ERC20Upgradeable, ERC20PermitUpgradeable, FundShareStorage {
    error InvalidAddress();
    error InvalidVaultAsset(address asset);
    error UnauthorizedVault(address caller);

    event VaultUpdate(address indexed asset, address vault);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        address asset_,
        address vault_,
        address authority_,
        uint64 compatibilityVersion_
    ) external initializer {
        if (asset_ == address(0) || vault_ == address(0) || compatibilityVersion_ == 0) {
            revert InvalidAddress();
        }
        __FundUpgradeable_init(authority_);
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        FundShareStorageLayout storage $ = _getFundShareStorage();
        $.asset = asset_;
        $.vault = vault_;
        $.compatibilityVersion = compatibilityVersion_;
        emit VaultUpdate(asset_, vault_);
    }

    function asset() external view returns (address) {
        return _getFundShareStorage().asset;
    }

    function vault(address asset_) external view returns (address) {
        FundShareStorageLayout storage $ = _getFundShareStorage();
        return asset_ == $.asset ? $.vault : address(0);
    }

    function compatibilityVersion() external view returns (uint64) {
        return _getFundShareStorage().compatibilityVersion;
    }

    function mint(address receiver, uint256 shares) external onlyVault {
        if (receiver == address(0) || shares == 0) revert InvalidAddress();
        _mint(receiver, shares);
    }

    function burn(address owner, uint256 shares) external onlyVault {
        if (owner == address(0) || shares == 0) revert InvalidAddress();
        _burn(owner, shares);
    }

    function escrowShares(address owner, address spender, uint256 shares) external onlyVault {
        if (owner == address(0) || spender == address(0) || shares == 0) revert InvalidAddress();
        if (spender != owner) _spendAllowance(owner, spender, shares);
        _transfer(owner, _getFundShareStorage().vault, shares);
    }

    function returnEscrowedShares(address receiver, uint256 shares) external onlyVault {
        if (receiver == address(0) || shares == 0) revert InvalidAddress();
        _transfer(_getFundShareStorage().vault, receiver, shares);
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return
            interfaceId == FundConstants.ERC7575_SHARE_INTERFACE_ID || interfaceId == FundConstants.ERC165_INTERFACE_ID;
    }

    modifier onlyVault() {
        address vault_ = _getFundShareStorage().vault;
        if (msg.sender != vault_) revert UnauthorizedVault(msg.sender);
        _;
    }
}
