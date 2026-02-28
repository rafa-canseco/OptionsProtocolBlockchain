// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title OToken
 * @notice ERC20 token representing an option contract.
 *         Each unique (underlying, strikeAsset, collateral, strikePrice, expiry, isPut)
 *         gets its own OToken deployment. Only the Controller can mint/burn.
 */
contract OToken is ERC20 {
    address public underlying;
    address public strikeAsset;
    address public collateralAsset;
    uint256 public strikePrice; // scaled to 8 decimals (e.g., $2000 = 200000000000)
    uint256 public expiry; // unix timestamp, must be 08:00 UTC
    bool public isPut;

    address public controller;
    address private _creator;
    bool private _initialized;

    string private _tokenName;
    string private _tokenSymbol;

    error AlreadyInitialized();
    error OnlyController();
    error OnlyCreator();

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    constructor() ERC20("", "") {
        _creator = msg.sender;
    }

    /**
     * @notice Initialize the oToken. Called once by the factory after deployment.
     */
    function init(
        address _underlying,
        address _strikeAsset,
        address _collateralAsset,
        uint256 _strikePrice,
        uint256 _expiry,
        bool _isPut,
        address _controller
    ) external {
        if (msg.sender != _creator) revert OnlyCreator();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        underlying = _underlying;
        strikeAsset = _strikeAsset;
        collateralAsset = _collateralAsset;
        strikePrice = _strikePrice;
        expiry = _expiry;
        isPut = _isPut;
        controller = _controller;

        string memory optType = _isPut ? "P" : "C";
        string memory strikeStr = _uint2str(_strikePrice / 1e8);
        _tokenName = string.concat("oToken ", strikeStr, " ", _isPut ? "Put" : "Call");
        _tokenSymbol = string.concat("o", strikeStr, optType);
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mintOtoken(address _to, uint256 _amount) external onlyController {
        _mint(_to, _amount);
    }

    function burnOtoken(address _from, uint256 _amount) external onlyController {
        _burn(_from, _amount);
    }

    function _uint2str(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
