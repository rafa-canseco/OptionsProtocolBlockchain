// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./AddressBook.sol";

/**
 * @title Whitelist
 * @notice Controls which assets and products are allowed in the protocol.
 *         For MVP: only ETH/USDC. Expandable later.
 *         A "product" is a valid combination of (underlying, strikeAsset, collateralAsset, isPut).
 */
contract Whitelist is Initializable, UUPSUpgradeable {
    AddressBook public addressBook;
    address public owner;

    /// @notice Whitelisted collateral assets (e.g., USDC, WETH)
    mapping(address => bool) public isWhitelistedCollateral;

    /// @notice Whitelisted underlying assets (e.g., WETH)
    mapping(address => bool) public isWhitelistedUnderlying;

    /// @notice Whitelisted products: hash(underlying, strike, collateral, isPut) → bool
    mapping(bytes32 => bool) public isWhitelistedProduct;

    /// @notice Whitelisted oTokens (set by factory after creation)
    mapping(address => bool) public isWhitelistedOToken;

    event CollateralWhitelisted(address indexed asset);
    event UnderlyingWhitelisted(address indexed asset);
    event ProductWhitelisted(address indexed underlying, address strikeAsset, address collateralAsset, bool isPut);
    event OTokenWhitelisted(address indexed oToken);

    error OnlyOwner();
    error OnlyOwnerOrFactory();
    error InvalidAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressBook, address _owner) external initializer {
        if (_addressBook == address(0) || _owner == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
        owner = _owner;
    }

    function whitelistCollateral(address _asset) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();
        isWhitelistedCollateral[_asset] = true;
        emit CollateralWhitelisted(_asset);
    }

    function whitelistUnderlying(address _asset) external onlyOwner {
        if (_asset == address(0)) revert InvalidAddress();
        isWhitelistedUnderlying[_asset] = true;
        emit UnderlyingWhitelisted(_asset);
    }

    function whitelistProduct(address _underlying, address _strikeAsset, address _collateralAsset, bool _isPut)
        external
        onlyOwner
    {
        if (_underlying == address(0) || _strikeAsset == address(0) || _collateralAsset == address(0)) {
            revert InvalidAddress();
        }
        bytes32 productHash = keccak256(abi.encodePacked(_underlying, _strikeAsset, _collateralAsset, _isPut));
        isWhitelistedProduct[productHash] = true;
        emit ProductWhitelisted(_underlying, _strikeAsset, _collateralAsset, _isPut);
    }

    function isProductWhitelisted(address _underlying, address _strikeAsset, address _collateralAsset, bool _isPut)
        external
        view
        returns (bool)
    {
        bytes32 productHash = keccak256(abi.encodePacked(_underlying, _strikeAsset, _collateralAsset, _isPut));
        return isWhitelistedProduct[productHash];
    }

    function whitelistOToken(address _oToken) external {
        if (msg.sender != owner && msg.sender != addressBook.oTokenFactory()) {
            revert OnlyOwnerOrFactory();
        }
        if (_oToken == address(0)) revert InvalidAddress();
        isWhitelistedOToken[_oToken] = true;
        emit OTokenWhitelisted(_oToken);
    }

    // --- Ownership ---

    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OnlyPendingOwner();

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[43] private __gap;
}
