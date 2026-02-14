// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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
    uint256 public expiry;      // unix timestamp, must be 08:00 UTC
    bool public isPut;

    address public controller;
    bool private _initialized;

    error AlreadyInitialized();
    error OnlyController();

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    constructor() ERC20("", "") {}

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
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        underlying = _underlying;
        strikeAsset = _strikeAsset;
        collateralAsset = _collateralAsset;
        strikePrice = _strikePrice;
        expiry = _expiry;
        isPut = _isPut;
        controller = _controller;
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
}
