// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./OToken.sol";
import "./AddressBook.sol";
import "./Whitelist.sol";

/**
 * @title OTokenFactory
 * @notice Creates new OToken instances for each option series.
 *         Uses CREATE2 for deterministic addresses — given the same parameters,
 *         the oToken address is always the same.
 */
contract OTokenFactory is Initializable, UUPSUpgradeable {
    AddressBook public addressBook;

    /// @notice All oTokens ever created
    address[] public oTokens;

    /// @notice Quick lookup: is this address an oToken we created?
    mapping(address => bool) public isOToken;

    /// @notice Lookup: parameters hash → oToken address (prevents duplicates)
    mapping(bytes32 => address) public getOToken;

    /// @notice Authorized operator that can create oTokens
    address public operator;

    event OTokenCreated(
        address indexed oToken,
        address indexed underlying,
        address strikeAsset,
        address collateralAsset,
        uint256 strikePrice,
        uint256 expiry,
        bool isPut
    );

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    error OTokenAlreadyExists();
    error InvalidExpiry();
    error InvalidAddress();
    error InvalidStrikePrice();
    error Unauthorized();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressBook) external initializer {
        if (_addressBook == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
    }

    function setOperator(address _operator) external {
        if (msg.sender != addressBook.owner()) revert Unauthorized();
        if (_operator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    function createOToken(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        uint256 _strikePrice,
        uint256 _expiry,
        bool _isPut
    ) external returns (address) {
        if (msg.sender != operator) revert Unauthorized();
        if (_underlying == address(0) || _strikeAsset == address(0) || _collateralAsset == address(0)) {
            revert InvalidAddress();
        }
        if (_strikePrice == 0) revert InvalidStrikePrice();

        if (_expiry <= block.timestamp) revert InvalidExpiry();
        if (_expiry % (24 hours) != 8 hours) revert InvalidExpiry();

        bytes32 paramsHash = _getParamsHash(_underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut);

        if (getOToken[paramsHash] != address(0)) revert OTokenAlreadyExists();

        OToken oToken = new OToken{salt: paramsHash}();

        oToken.init(
            _underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut, addressBook.controller()
        );

        address oTokenAddress = address(oToken);
        oTokens.push(oTokenAddress);
        isOToken[oTokenAddress] = true;
        getOToken[paramsHash] = oTokenAddress;

        Whitelist(addressBook.whitelist()).whitelistOToken(oTokenAddress);

        emit OTokenCreated(oTokenAddress, _underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut);

        return oTokenAddress;
    }

    function getOTokensLength() external view returns (uint256) {
        return oTokens.length;
    }

    function getTargetOTokenAddress(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        uint256 _strikePrice,
        uint256 _expiry,
        bool _isPut
    ) external view returns (address) {
        bytes32 paramsHash = _getParamsHash(_underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut);

        bytes32 hash =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), paramsHash, keccak256(type(OToken).creationCode)));

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
        return keccak256(abi.encodePacked(_underlying, _strikeAsset, _collateralAsset, _strikePrice, _expiry, _isPut));
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != addressBook.owner()) revert Unauthorized();
    }

    uint256[45] private __gap;
}
