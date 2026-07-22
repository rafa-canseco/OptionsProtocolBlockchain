// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {AddressBook} from "../../../src/core/AddressBook.sol";
import {MarginVault} from "../../../src/interfaces/IMarginVault.sol";

abstract contract ControllerStorageHarnessBase is Initializable, UUPSUpgradeable {
    AddressBook public addressBook;
    address public owner;
    mapping(address account => uint256 count) public vaultCount;
    mapping(address account => mapping(uint256 vaultId => MarginVault.Vault vault)) internal vaults;
    mapping(address account => mapping(uint256 vaultId => bool settled)) public vaultSettled;
    bool public systemPartiallyPaused;
    bool public systemFullyPaused;
    address public partialPauser;
    address public pendingOwner;

    function initialize(address owner_) external initializer {
        owner = owner_;
    }

    function setBaselineState(
        address addressBook_,
        address partialPauser_,
        address pendingOwner_,
        address vaultOwner,
        uint256 vaultCount_,
        bool partialPause,
        bool fullPause
    ) external {
        require(msg.sender == owner, "only owner");
        addressBook = AddressBook(addressBook_);
        partialPauser = partialPauser_;
        pendingOwner = pendingOwner_;
        vaultCount[vaultOwner] = vaultCount_;
        systemPartiallyPaused = partialPause;
        systemFullyPaused = fullPause;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == owner, "only owner");
    }
}

contract ControllerStorageHarnessV1 is ControllerStorageHarnessBase {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    uint256[43] private __gap;
}

/// @custom:oz-upgrades-from ControllerStorageHarnessV1
contract ControllerStorageHarnessV2 is ControllerStorageHarnessBase {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    bool public custodiedRedemptionOnly;

    function setCustodiedRedemptionOnly(bool enabled) external {
        require(msg.sender == owner, "only owner");
        custodiedRedemptionOnly = enabled;
    }

    uint256[43] private __gap;
}
