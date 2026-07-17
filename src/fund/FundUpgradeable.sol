// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

/// @dev Shared UUPS/AccessManager integration for the fresh fund stack.
abstract contract FundUpgradeable is AccessManagedUpgradeable, UUPSUpgradeable {
    function __FundUpgradeable_init(address authority_) internal onlyInitializing {
        if (authority_ == address(0) || authority_.code.length == 0) {
            revert AccessManagedInvalidAuthority(authority_);
        }
        __AccessManaged_init(authority_);
    }

    /// @dev The restriction belongs on the external selector, not on the internal authorization hook.
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual override restricted {
        super.upgradeToAndCall(newImplementation, data);
    }

    function _authorizeUpgrade(address) internal virtual override {}
}
