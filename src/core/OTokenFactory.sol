// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./OToken.sol";
import "./AddressBook.sol";

/**
 * @title OTokenFactory
 * @notice Creates new OToken instances for each option series.
 *         Uses CREATE2 for deterministic addresses — given the same parameters,
 *         the oToken address is always the same.
 */
contract OTokenFactory {
    AddressBook public addressBook;

    /// @notice All oTokens ever created
    address[] public oTokens;

    /// @notice Quick lookup: is this address an oToken we created?
    mapping(address => bool) public isOToken;

    /// @notice Lookup: parameters hash → oToken address (prevents duplicates)
    mapping(bytes32 => address) public getOToken;

    event OTokenCreated(
        address indexed oToken,
        address indexed underlying,
        address strikeAsset,
        address collateralAsset,
        uint256 strikePrice,
        uint256 expiry,
        bool isPut
    );

    error OTokenAlreadyExists();
    error InvalidExpiry();
    error AssetNotWhitelisted();
    error InvalidAddress();
    error InvalidStrikePrice();

    constructor(address _addressBook) {
        addressBook = AddressBook(_addressBook);
    }

    /**
     * @notice Create a new oToken for an option series.
     * @return The address of the newly created oToken.
     */
    function createOToken(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        uint256 _strikePrice,
        uint256 _expiry,
        bool _isPut
    ) external returns (address) {
        if (_underlying == address(0) || _strikeAsset == address(0) || _collateralAsset == address(0)) {
            revert InvalidAddress();
        }
        if (_strikePrice == 0) revert InvalidStrikePrice();

        // Expiry must be in the future and at 08:00 UTC
        if (_expiry <= block.timestamp) revert InvalidExpiry();
        if (_expiry % (24 hours) != 8 hours) revert InvalidExpiry();

        bytes32 paramsHash = _getParamsHash(
            _underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut
        );

        if (getOToken[paramsHash] != address(0)) revert OTokenAlreadyExists();

        // Deploy oToken with CREATE2 using paramsHash as salt
        OToken oToken = new OToken{salt: paramsHash}();

        oToken.init(
            _underlying,
            _strikeAsset,
            _collateralAsset,
            _strikePrice,
            _expiry,
            _isPut,
            addressBook.controller()
        );

        address oTokenAddress = address(oToken);
        oTokens.push(oTokenAddress);
        isOToken[oTokenAddress] = true;
        getOToken[paramsHash] = oTokenAddress;

        emit OTokenCreated(
            oTokenAddress, _underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut
        );

        return oTokenAddress;
    }

    /**
     * @notice Get the total number of oTokens created.
     */
    function getOTokensLength() external view returns (uint256) {
        return oTokens.length;
    }

    /**
     * @notice Compute the address of an oToken before it's created.
     *         Useful for the backend to know the address in advance.
     */
    function getTargetOTokenAddress(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        uint256 _strikePrice,
        uint256 _expiry,
        bool _isPut
    ) external view returns (address) {
        bytes32 paramsHash = _getParamsHash(
            _underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                paramsHash,
                keccak256(type(OToken).creationCode)
            )
        );

        return address(uint160(uint256(hash)));
    }

    function _getParamsHash(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        uint256 _strikePrice,
        uint256 _expiry,
        bool _isPut
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(_underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut)
        );
    }
}
