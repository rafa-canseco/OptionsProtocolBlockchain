// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title AddressBook
 * @notice Central registry for all protocol contract addresses.
 */
contract AddressBook is Initializable, UUPSUpgradeable {
    address public owner;
    address public controller;
    address public marginPool;
    address public oTokenFactory;
    address public oracle;
    address public whitelist;
    address public batchSettler;

    address public pendingOwner;

    error InvalidAddress();
    error OnlyOwner();
    error OnlyPendingOwner();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event ControllerUpdated(address indexed oldAddress, address indexed newAddress);
    event MarginPoolUpdated(address indexed oldAddress, address indexed newAddress);
    event OTokenFactoryUpdated(address indexed oldAddress, address indexed newAddress);
    event OracleUpdated(address indexed oldAddress, address indexed newAddress);
    event WhitelistUpdated(address indexed oldAddress, address indexed newAddress);
    event BatchSettlerUpdated(address indexed oldAddress, address indexed newAddress);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert InvalidAddress();
        owner = _owner;
    }

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

    function setController(address _controller) external onlyOwner {
        if (_controller == address(0)) revert InvalidAddress();
        emit ControllerUpdated(controller, _controller);
        controller = _controller;
    }

    function setMarginPool(address _marginPool) external onlyOwner {
        if (_marginPool == address(0)) revert InvalidAddress();
        emit MarginPoolUpdated(marginPool, _marginPool);
        marginPool = _marginPool;
    }

    function setOTokenFactory(address _oTokenFactory) external onlyOwner {
        if (_oTokenFactory == address(0)) revert InvalidAddress();
        emit OTokenFactoryUpdated(oTokenFactory, _oTokenFactory);
        oTokenFactory = _oTokenFactory;
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress();
        emit OracleUpdated(oracle, _oracle);
        oracle = _oracle;
    }

    function setWhitelist(address _whitelist) external onlyOwner {
        if (_whitelist == address(0)) revert InvalidAddress();
        emit WhitelistUpdated(whitelist, _whitelist);
        whitelist = _whitelist;
    }

    function setBatchSettler(address _batchSettler) external onlyOwner {
        if (_batchSettler == address(0)) revert InvalidAddress();
        emit BatchSettlerUpdated(batchSettler, _batchSettler);
        batchSettler = _batchSettler;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[42] private __gap;
}
