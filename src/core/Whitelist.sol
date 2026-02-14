// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./AddressBook.sol";

/**
 * @title Whitelist
 * @notice Controls which assets and products are allowed in the protocol.
 *         For MVP: only ETH/USDC. Expandable later.
 *         A "product" is a valid combination of (underlying, strikeAsset, collateralAsset, isPut).
 */
contract Whitelist {
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
    error OnlyFactoryOrOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(address _addressBook) {
        addressBook = AddressBook(_addressBook);
        owner = msg.sender;
    }

    function whitelistCollateral(address _asset) external onlyOwner {
        isWhitelistedCollateral[_asset] = true;
        emit CollateralWhitelisted(_asset);
    }

    function whitelistUnderlying(address _asset) external onlyOwner {
        isWhitelistedUnderlying[_asset] = true;
        emit UnderlyingWhitelisted(_asset);
    }

    /**
     * @notice Whitelist a valid product combination.
     *         For a CSP: (WETH, USDC, USDC, true)  — put, collateral is USDC
     *         For a CC:  (WETH, USDC, WETH, false)  — call, collateral is WETH
     */
    function whitelistProduct(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        bool _isPut
    ) external onlyOwner {
        bytes32 productHash = keccak256(
            abi.encodePacked(_underlying, _strikeAsset, _collateralAsset, _isPut)
        );
        isWhitelistedProduct[productHash] = true;
        emit ProductWhitelisted(_underlying, _strikeAsset, _collateralAsset, _isPut);
    }

    /**
     * @notice Check if a product combination is whitelisted.
     */
    function isProductWhitelisted(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        bool _isPut
    ) external view returns (bool) {
        bytes32 productHash = keccak256(
            abi.encodePacked(_underlying, _strikeAsset, _collateralAsset, _isPut)
        );
        return isWhitelistedProduct[productHash];
    }

    /**
     * @notice Whitelist an oToken. Called by factory or owner after creation.
     */
    function whitelistOToken(address _oToken) external {
        if (msg.sender != owner && msg.sender != addressBook.oTokenFactory()) {
            revert OnlyFactoryOrOwner();
        }
        isWhitelistedOToken[_oToken] = true;
        emit OTokenWhitelisted(_oToken);
    }
}
