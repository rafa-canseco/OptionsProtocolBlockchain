// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./AddressBook.sol";
import "./MarginPool.sol";
import "./OToken.sol";
import "./OTokenFactory.sol";
import "./Oracle.sol";
import "./Whitelist.sol";
import "../interfaces/IMarginVault.sol";

interface IBatchSettlerClearance {
    function clearMMBalanceForVault(address owner, uint256 vaultId, address oToken, uint256 amount) external;
    function vaultMM(address owner, uint256 vaultId) external view returns (address);
    function mmOTokenBalance(address mm, address oToken) external view returns (uint256);
}

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

    /// @notice Whether new positions are blocked (settle/redeem still allowed)
    bool public systemPartiallyPaused;

    /// @notice Whether all operations are blocked
    bool public systemFullyPaused;

    /// @notice Address authorized to toggle partial pause
    address public partialPauser;

    event VaultOpened(address indexed owner, uint256 vaultId);
    event CollateralDeposited(address indexed owner, uint256 vaultId, address asset, uint256 amount);
    event OTokenMinted(address indexed owner, uint256 vaultId, address oToken, uint256 amount);
    event VaultSettled(address indexed owner, uint256 vaultId, uint256 collateralReturned);
    event Redeemed(address indexed oToken, address indexed redeemer, uint256 otokenAmount, uint256 payout);
    event SystemPartiallyPaused(address indexed caller);
    event SystemFullyPaused(address indexed caller);
    event SystemUnpaused(address indexed caller);
    event EmergencyWithdraw(address indexed user, uint256 vaultId, address asset, uint256 amount);
    event PartialPauserUpdated(address indexed oldPauser, address indexed newPauser);

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
    error SystemIsPartiallyPaused();
    error SystemIsFullyPaused();
    error OnlyPartialPauser();
    error NoCollateral();
    error SystemNotFullyPaused();
    error OTokensAlreadyRedeemed();
    error UnsupportedDecimals();

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

    modifier notPartiallyPaused() {
        if (systemPartiallyPaused) revert SystemIsPartiallyPaused();
        _;
    }

    modifier notFullyPaused() {
        if (systemFullyPaused) revert SystemIsFullyPaused();
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

    // --- Vault Operations ---

    function openVault(address _owner)
        external
        onlyAuthorized(_owner)
        notPartiallyPaused
        notFullyPaused
        returns (uint256)
    {
        uint256 vaultId = vaultCount[_owner] + 1;
        vaultCount[_owner] = vaultId;

        emit VaultOpened(_owner, vaultId);
        return vaultId;
    }

    function depositCollateral(address _owner, uint256 _vaultId, address _asset, uint256 _amount)
        external
        onlyAuthorized(_owner)
        notPartiallyPaused
        notFullyPaused
    {
        if (vaultSettled[_owner][_vaultId]) revert VaultAlreadySettledError();

        MarginVault.Vault storage vault = _getVault(_owner, _vaultId);

        if (vault.collateralAsset != address(0) && vault.collateralAsset != _asset) {
            revert CollateralMismatch();
        }

        vault.collateralAsset = _asset;
        vault.collateralAmount += _amount;

        MarginPool(addressBook.marginPool()).transferToPool(_asset, _owner, _amount);

        emit CollateralDeposited(_owner, _vaultId, _asset, _amount);
    }

    function mintOtoken(address _owner, uint256 _vaultId, address _oToken, uint256 _amount, address _to)
        external
        onlyAuthorized(_owner)
        notPartiallyPaused
        notFullyPaused
    {
        MarginVault.Vault storage vault = _getVault(_owner, _vaultId);
        if (vaultSettled[_owner][_vaultId]) revert VaultAlreadySettledError();

        if (vault.shortOtoken != address(0) && vault.shortOtoken != _oToken) {
            revert VaultAlreadyHasShort();
        }

        Whitelist wl = Whitelist(addressBook.whitelist());
        if (!wl.isWhitelistedOToken(_oToken)) revert OTokenNotWhitelisted();

        OToken oToken = OToken(_oToken);
        if (block.timestamp >= oToken.expiry()) revert OptionExpired();

        if (vault.collateralAsset != oToken.collateralAsset()) revert CollateralMismatch();

        uint256 requiredCollateral = _getRequiredCollateral(oToken, vault.shortAmount + _amount);
        if (vault.collateralAmount < requiredCollateral) revert InsufficientCollateral();

        vault.shortOtoken = _oToken;
        vault.shortAmount += _amount;

        oToken.mintOtoken(_to, _amount);

        emit OTokenMinted(_owner, _vaultId, _oToken, _amount);
    }

    function settleVault(address _owner, uint256 _vaultId) external onlyAuthorized(_owner) notFullyPaused {
        MarginVault.Vault storage vault = _getVault(_owner, _vaultId);
        if (vaultSettled[_owner][_vaultId]) revert VaultAlreadySettledError();

        OToken oToken = OToken(vault.shortOtoken);
        if (block.timestamp < oToken.expiry()) revert OptionNotExpired();

        Oracle oracle = Oracle(addressBook.oracle());
        (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 payout = _calculatePayout(oToken, vault.shortAmount, expiryPrice);
        uint256 collateralToReturn = payout >= vault.collateralAmount ? 0 : vault.collateralAmount - payout;

        vaultSettled[_owner][_vaultId] = true;

        if (collateralToReturn > 0) {
            MarginPool(addressBook.marginPool()).transferToUser(vault.collateralAsset, _owner, collateralToReturn);
        }

        emit VaultSettled(_owner, _vaultId, collateralToReturn);
    }

    function redeem(address _oToken, uint256 _amount) external notFullyPaused {
        if (_amount == 0) revert NoOtokensToRedeem();

        Whitelist wl = Whitelist(addressBook.whitelist());
        if (!wl.isWhitelistedOToken(_oToken)) revert OTokenNotWhitelisted();

        OToken oToken = OToken(_oToken);
        if (block.timestamp < oToken.expiry()) revert OptionNotExpired();

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

    function getVault(address _owner, uint256 _vaultId) external view returns (MarginVault.Vault memory) {
        return vaults[_owner][_vaultId];
    }

    // --- Internal ---

    function _getVault(address _owner, uint256 _vaultId) internal view returns (MarginVault.Vault storage) {
        if (_vaultId == 0 || _vaultId > vaultCount[_owner]) revert InvalidVault();
        return vaults[_owner][_vaultId];
    }

    function _getRequiredCollateral(OToken oToken, uint256 _amount) internal view returns (uint256) {
        uint256 cd = IERC20Metadata(oToken.collateralAsset()).decimals();
        if (oToken.isPut()) {
            if (cd < 6 || cd > 16) revert UnsupportedDecimals();
            uint256 required = (_amount * oToken.strikePrice()) / (10 ** (16 - cd));
            if (required == 0 && _amount > 0) revert InsufficientCollateral();
            return required;
        } else {
            if (cd < 8 || cd > 18) revert UnsupportedDecimals();
            return _amount * (10 ** (cd - 8));
        }
    }

    function _calculatePayout(OToken oToken, uint256 _amount, uint256 _expiryPrice) internal view returns (uint256) {
        uint256 strike = oToken.strikePrice();
        uint256 cd = IERC20Metadata(oToken.collateralAsset()).decimals();

        if (oToken.isPut()) {
            if (cd < 6 || cd > 16) revert UnsupportedDecimals();
            if (_expiryPrice >= strike) return 0;
            return (_amount * strike) / (10 ** (16 - cd));
        } else {
            if (cd < 8 || cd > 18) revert UnsupportedDecimals();
            if (_expiryPrice <= strike) return 0;
            return _amount * (10 ** (cd - 8));
        }
    }

    // --- Pause Management ---

    function setPartialPauser(address _pauser) external onlyOwner {
        emit PartialPauserUpdated(partialPauser, _pauser);
        partialPauser = _pauser;
    }

    function setSystemPartiallyPaused(bool _paused) external {
        if (msg.sender != partialPauser && msg.sender != owner) {
            revert OnlyPartialPauser();
        }

        systemPartiallyPaused = _paused;

        if (_paused) {
            emit SystemPartiallyPaused(msg.sender);
        } else {
            emit SystemUnpaused(msg.sender);
        }
    }

    function setSystemFullyPaused(bool _paused) external onlyOwner {
        systemFullyPaused = _paused;

        if (_paused) {
            emit SystemFullyPaused(msg.sender);
        } else {
            emit SystemUnpaused(msg.sender);
        }
    }

    /// @notice Allows a vault owner to rescue their collateral when the
    ///         system is fully paused (emergency circuit breaker).
    /// @dev    Marks the vault as settled to prevent double-claims.
    ///         Burns outstanding oTokens from BatchSettler and clears
    ///         the MM's custodied balance to prevent phantom redemption.
    function emergencyWithdrawVault(uint256 _vaultId) external {
        if (!systemFullyPaused) revert SystemNotFullyPaused();

        MarginVault.Vault storage vault = _getVault(msg.sender, _vaultId);
        if (vaultSettled[msg.sender][_vaultId]) {
            revert VaultAlreadySettledError();
        }
        if (vault.collateralAmount == 0) revert NoCollateral();

        uint256 amount = vault.collateralAmount;
        address asset = vault.collateralAsset;

        // Burn oTokens and clear MM ledger to prevent phantom redemption
        if (vault.shortOtoken != address(0) && vault.shortAmount > 0) {
            address settler = addressBook.batchSettler();
            if (settler != address(0)) {
                OToken ot = OToken(vault.shortOtoken);

                // Use per-MM balance check (not aggregate settlerBal) to
                // prevent cross-vault double-claim. Aggregate balanceOf
                // includes oTokens from OTHER vaults, masking redemptions.
                address mm = IBatchSettlerClearance(settler).vaultMM(msg.sender, _vaultId);
                if (mm != address(0)) {
                    uint256 mmBal = IBatchSettlerClearance(settler).mmOTokenBalance(mm, vault.shortOtoken);
                    if (mmBal < vault.shortAmount) revert OTokensAlreadyRedeemed();
                } else {
                    // Pre-migration vault (no MM attribution): aggregate check
                    uint256 settlerBal = ot.balanceOf(settler);
                    if (settlerBal < vault.shortAmount) revert OTokensAlreadyRedeemed();
                }

                ot.burnOtoken(settler, vault.shortAmount);

                IBatchSettlerClearance(settler)
                    .clearMMBalanceForVault(msg.sender, _vaultId, vault.shortOtoken, vault.shortAmount);
            }
        }

        vaultSettled[msg.sender][_vaultId] = true;

        MarginPool(addressBook.marginPool()).transferToUser(asset, msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, _vaultId, asset, amount);
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
