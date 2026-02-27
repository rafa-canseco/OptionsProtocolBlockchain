// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "./AddressBook.sol";
import "./MarginPool.sol";
import "./OToken.sol";
import "./OTokenFactory.sol";
import "./Oracle.sol";
import "./Whitelist.sol";
import "../interfaces/IMarginVault.sol";

/**
 * @title Controller
 * @notice Main entry point for the options protocol.
 *         Manages vaults, coordinates minting/burning of oTokens, and handles settlement.
 *         Simplified: only fully collateralized vaults, no naked margin, no liquidation.
 *
 *         Vault lifecycle:
 *         1. openVault()          → creates empty vault for user
 *         2. depositCollateral()  → locks collateral in MarginPool
 *         3. mintOtoken()         → mints oTokens (writes the option)
 *         4. ... time passes, option expires ...
 *         5. settleVault()        → settles at expiry, returns remaining collateral
 *
 *         Option holders (buyers) call:
 *         6. redeem()             → burns oTokens for payout if ITM
 */
contract Controller is Initializable, UUPSUpgradeable {
    AddressBook public addressBook;
    address public owner;

    /// @notice user address → vault count
    mapping(address => uint256) public vaultCount;

    /// @notice user address → vault id → Vault
    mapping(address => mapping(uint256 => MarginVault.Vault)) public vaults;

    /// @notice Whether a vault has been settled
    mapping(address => mapping(uint256 => bool)) public vaultSettled;

    /// @notice When true, expiry time checks are bypassed (for testnet demos)
    bool public betaMode;

    event VaultOpened(address indexed owner, uint256 vaultId);
    event CollateralDeposited(address indexed owner, uint256 vaultId, address asset, uint256 amount);
    event OTokenMinted(address indexed owner, uint256 vaultId, address oToken, uint256 amount);
    event VaultSettled(address indexed owner, uint256 vaultId, uint256 collateralReturned);
    event Redeemed(address indexed oToken, address indexed redeemer, uint256 otokenAmount, uint256 payout);
    event BetaModeSet(bool enabled);

    error OnlyOwner();
    error InvalidVault();
    error VaultAlreadyHasShort();
    error VaultAlreadySettledError();
    error OptionNotExpired();
    error ExpiryPriceNotSet();
    error CollateralMismatch();
    error InsufficientCollateral();
    error NoOtokensToRedeem();
    error OTokenNotWhitelisted();
    error OptionExpired();
    error Unauthorized();
    error InvalidAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyAuthorized(address _owner) {
        if (msg.sender != _owner && msg.sender != addressBook.batchSettler()) {
            revert Unauthorized();
        }
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

    /// @notice Enable or disable beta mode (bypasses expiry time checks). Owner only.
    function setBetaMode(bool _enabled) external onlyOwner {
        betaMode = _enabled;
        emit BetaModeSet(_enabled);
    }

    // --- Vault Operations ---

    function openVault(address _owner) external onlyAuthorized(_owner) returns (uint256) {
        uint256 vaultId = vaultCount[_owner] + 1;
        vaultCount[_owner] = vaultId;

        emit VaultOpened(_owner, vaultId);
        return vaultId;
    }

    function depositCollateral(
        address _owner,
        uint256 _vaultId,
        address _asset,
        uint256 _amount
    ) external onlyAuthorized(_owner) {
        MarginVault.Vault storage vault = _getVault(_owner, _vaultId);

        if (vault.collateralAsset != address(0) && vault.collateralAsset != _asset) {
            revert CollateralMismatch();
        }

        vault.collateralAsset = _asset;
        vault.collateralAmount += _amount;

        MarginPool(addressBook.marginPool()).transferToPool(_asset, _owner, _amount);

        emit CollateralDeposited(_owner, _vaultId, _asset, _amount);
    }

    function mintOtoken(
        address _owner,
        uint256 _vaultId,
        address _oToken,
        uint256 _amount,
        address _to
    ) external onlyAuthorized(_owner) {
        MarginVault.Vault storage vault = _getVault(_owner, _vaultId);

        if (vault.shortOtoken != address(0) && vault.shortOtoken != _oToken) {
            revert VaultAlreadyHasShort();
        }

        Whitelist wl = Whitelist(addressBook.whitelist());
        if (!wl.isWhitelistedOToken(_oToken)) revert OTokenNotWhitelisted();

        OToken oToken = OToken(_oToken);

        if (!betaMode && block.timestamp >= oToken.expiry()) revert OptionExpired();

        uint256 requiredCollateral = _getRequiredCollateral(oToken, _amount);
        if (vault.collateralAmount < requiredCollateral) revert InsufficientCollateral();

        vault.shortOtoken = _oToken;
        vault.shortAmount += _amount;

        oToken.mintOtoken(_to, _amount);

        emit OTokenMinted(_owner, _vaultId, _oToken, _amount);
    }

    function settleVault(address _owner, uint256 _vaultId) external onlyAuthorized(_owner) {
        MarginVault.Vault storage vault = _getVault(_owner, _vaultId);
        if (vaultSettled[_owner][_vaultId]) revert VaultAlreadySettledError();

        OToken oToken = OToken(vault.shortOtoken);
        if (!betaMode && block.timestamp < oToken.expiry()) revert OptionNotExpired();

        Oracle oracle = Oracle(addressBook.oracle());
        (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 payout = _calculatePayout(oToken, vault.shortAmount, expiryPrice);
        uint256 collateralToReturn = vault.collateralAmount - payout;

        vaultSettled[_owner][_vaultId] = true;

        if (collateralToReturn > 0) {
            MarginPool(addressBook.marginPool()).transferToUser(
                vault.collateralAsset, _owner, collateralToReturn
            );
        }

        emit VaultSettled(_owner, _vaultId, collateralToReturn);
    }

    function redeem(address _oToken, uint256 _amount) external {
        if (_amount == 0) revert NoOtokensToRedeem();

        OToken oToken = OToken(_oToken);
        if (!betaMode && block.timestamp < oToken.expiry()) revert OptionNotExpired();

        Oracle oracle = Oracle(addressBook.oracle());
        (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 payout = _calculatePayout(oToken, _amount, expiryPrice);

        oToken.burnOtoken(msg.sender, _amount);

        if (payout > 0) {
            address payoutAsset = oToken.collateralAsset();
            MarginPool(addressBook.marginPool()).transferToUser(payoutAsset, msg.sender, payout);
        }

        emit Redeemed(_oToken, msg.sender, _amount, payout);
    }

    // --- View Functions ---

    function getVault(address _owner, uint256 _vaultId)
        external
        view
        returns (MarginVault.Vault memory)
    {
        return vaults[_owner][_vaultId];
    }

    // --- Internal ---

    function _getVault(address _owner, uint256 _vaultId)
        internal
        view
        returns (MarginVault.Vault storage)
    {
        if (_vaultId == 0 || _vaultId > vaultCount[_owner]) revert InvalidVault();
        return vaults[_owner][_vaultId];
    }

    function _getRequiredCollateral(OToken oToken, uint256 _amount) internal view returns (uint256) {
        if (oToken.isPut()) {
            return (_amount * oToken.strikePrice()) / 1e10;
        } else {
            return _amount * 1e10;
        }
    }

    function _calculatePayout(OToken oToken, uint256 _amount, uint256 _expiryPrice)
        internal
        view
        returns (uint256)
    {
        uint256 strike = oToken.strikePrice();

        if (oToken.isPut()) {
            if (_expiryPrice >= strike) return 0;
            return (_amount * strike) / 1e10;
        } else {
            if (_expiryPrice <= strike) return 0;
            return _amount * 1e10;
        }
    }

    // --- Ownership ---

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[44] private __gap;
}
