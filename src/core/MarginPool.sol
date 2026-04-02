// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AddressBook.sol";
import "../interfaces/IAaveV3Pool.sol";

/**
 * @title MarginPool
 * @notice Custodian of all collateral in the protocol.
 *         Only the Controller can move funds in/out.
 *         When Aave is enabled for an asset, deposits are routed
 *         through Aave V3 to earn yield on idle collateral.
 */
contract MarginPool is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    AddressBook public addressBook;

    // --- Aave integration (v2 storage, uses __gap slots) ---
    IAaveV3Pool public aavePool;
    mapping(address asset => uint256) public totalDeposited;
    address public yieldRecipient;
    mapping(address asset => bool) public isAaveEnabled;

    address public operator;
    mapping(address asset => address aToken) internal _aTokens;
    address[] internal _aaveAssets;

    error OnlyController();
    error Unauthorized();
    error InvalidAddress();
    error AaveNotConfigured();
    error AaveNotDrained(address asset, uint256 remaining);
    error AaveNotFullyDrained(address asset, uint256 aTokenBalance);

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    event ATokenFallback(
        address indexed asset,
        address indexed to,
        uint256 requested,
        uint256 transferred
    );

    event YieldHarvested(
        address indexed asset,
        address indexed recipient,
        uint256 amount
    );

    modifier onlyController() {
        if (msg.sender != addressBook.controller()) revert OnlyController();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != addressBook.owner()) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressBook) external initializer {
        if (_addressBook == address(0)) revert InvalidAddress();
        addressBook = AddressBook(_addressBook);
    }

    // --- Core Functions ---

    function transferToPool(address _asset, address _from, uint256 _amount) external onlyController {
        IERC20(_asset).safeTransferFrom(_from, address(this), _amount);

        if (isAaveEnabled[_asset]) {
            aavePool.supply(_asset, _amount, address(this), 0);
            totalDeposited[_asset] += _amount;
        }
    }

    function transferToUser(address _asset, address _to, uint256 _amount) external onlyController {
        uint256 deposited = totalDeposited[_asset];
        uint256 fromAave = deposited >= _amount ? _amount : deposited;
        uint256 fromDirect = _amount - fromAave;

        if (fromAave > 0) {
            totalDeposited[_asset] = deposited - fromAave;
            try aavePool.withdraw(_asset, fromAave, _to) {}
            catch {
                address aToken = _getAToken(_asset);
                uint256 aBalance = IERC20(aToken).balanceOf(address(this));
                uint256 transferAmt = fromAave < aBalance ? fromAave : aBalance;
                if (transferAmt < fromAave) {
                    totalDeposited[_asset] += (fromAave - transferAmt);
                    emit ATokenFallback(_asset, _to, fromAave, transferAmt);
                }
                IERC20(aToken).safeTransfer(_to, transferAmt);
            }
        }

        if (fromDirect > 0) {
            IERC20(_asset).safeTransfer(_to, fromDirect);
        }
    }

    // --- View Functions ---

    function getStoredBalance(address _asset) external view returns (uint256) {
        return totalDeposited[_asset] + IERC20(_asset).balanceOf(address(this));
    }

    function getATokenBalance(address _asset) external view returns (uint256) {
        address aToken = _getAToken(_asset);
        return IERC20(aToken).balanceOf(address(this));
    }

    function getAccruedYield(address _asset) public view returns (uint256) {
        address aToken = _getAToken(_asset);
        uint256 aBalance = IERC20(aToken).balanceOf(address(this));
        uint256 deposited = totalDeposited[_asset];
        return aBalance > deposited ? aBalance - deposited : 0;
    }

    // --- Yield Harvest ---

    function harvestYield(address _asset) external {
        if (msg.sender != addressBook.owner() && msg.sender != operator) {
            revert Unauthorized();
        }
        if (yieldRecipient == address(0)) revert InvalidAddress();
        uint256 yield_ = getAccruedYield(_asset);
        if (yield_ == 0) return;

        aavePool.withdraw(_asset, yield_, yieldRecipient);
        emit YieldHarvested(_asset, yieldRecipient, yield_);
    }

    // --- Admin Functions ---

    /// @notice Set the Aave V3 Pool address.
    ///         If an existing pool is configured, all tracked assets
    ///         must be fully drained first.
    function setAavePool(address _aavePool) external onlyOwner {
        if (_aavePool == address(0)) revert InvalidAddress();
        if (address(aavePool) != address(0)) {
            for (uint256 i; i < _aaveAssets.length; i++) {
                address asset = _aaveAssets[i];
                uint256 remaining = totalDeposited[asset];
                if (remaining > 0) {
                    revert AaveNotDrained(asset, remaining);
                }
                address aToken = _aTokens[asset];
                if (aToken != address(0)) {
                    uint256 aBal = IERC20(aToken).balanceOf(address(this));
                    if (aBal > 0) {
                        revert AaveNotFullyDrained(asset, aBal);
                    }
                }
            }
        }
        aavePool = IAaveV3Pool(_aavePool);
    }

    function setYieldRecipient(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert InvalidAddress();
        yieldRecipient = _recipient;
    }

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    function setAaveEnabled(address _asset, bool _enabled) external onlyOwner {
        if (_enabled && address(aavePool) == address(0)) {
            revert AaveNotConfigured();
        }
        if (_enabled && !isAaveEnabled[_asset]) {
            _aaveAssets.push(_asset);
        }
        isAaveEnabled[_asset] = _enabled;
    }

    /// @notice Withdraw all funds from Aave back to the pool for a
    ///         given asset. Use before disabling Aave or migrating pools.
    function drainAave(address _asset) external onlyOwner {
        uint256 deposited = totalDeposited[_asset];
        if (deposited == 0) return;
        aavePool.withdraw(_asset, deposited, address(this));
        totalDeposited[_asset] = 0;
    }

    function approveAave(address _asset) external onlyOwner {
        IERC20(_asset).forceApprove(address(aavePool), type(uint256).max);
    }

    function revokeAave(address _asset) external onlyOwner {
        IERC20(_asset).forceApprove(address(aavePool), 0);
    }

    // --- Internal ---

    function _getAToken(address _asset) internal view returns (address) {
        return _aTokens[_asset];
    }

    function setAToken(address _asset, address _aToken) external onlyOwner {
        if (_asset == address(0) || _aToken == address(0)) {
            revert InvalidAddress();
        }
        _aTokens[_asset] = _aToken;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[42] private __gap;
}
