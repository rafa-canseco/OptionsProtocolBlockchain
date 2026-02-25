// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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
contract Controller {
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

    error OnlyOwnerOrBatchSettler();
    error InvalidVault();
    error VaultAlreadyHasShort();
    error VaultAlreadySettledError();
    error OptionNotExpired();
    error ExpiryPriceNotSet();
    error CollateralMismatch();
    error InsufficientCollateral();
    error NoOtokensToRedeem();
    error OTokenNotWhitelisted();
    error Unauthorized();

    modifier onlyAuthorized(address _owner) {
        if (msg.sender != _owner && msg.sender != addressBook.batchSettler()) {
            revert Unauthorized();
        }
        _;
    }

    constructor(address _addressBook) {
        addressBook = AddressBook(_addressBook);
        owner = msg.sender;
    }

    /// @notice Enable or disable beta mode (bypasses expiry time checks). Owner only.
    function setBetaMode(bool _enabled) external {
        if (msg.sender != owner) revert Unauthorized();
        betaMode = _enabled;
        emit BetaModeSet(_enabled);
    }

    // --- Vault Operations ---

    /**
     * @notice Open a new empty vault. Returns the vault ID.
     */
    function openVault(address _owner) external onlyAuthorized(_owner) returns (uint256) {
        uint256 vaultId = vaultCount[_owner] + 1;
        vaultCount[_owner] = vaultId;

        emit VaultOpened(_owner, vaultId);
        return vaultId;
    }

    /**
     * @notice Deposit collateral into a vault.
     *         The user must have approved the MarginPool to spend their tokens.
     */
    function depositCollateral(
        address _owner,
        uint256 _vaultId,
        address _asset,
        uint256 _amount
    ) external onlyAuthorized(_owner) {
        MarginVault.Vault storage vault = _getVault(_owner, _vaultId);

        // If vault already has collateral, must be same asset
        if (vault.collateralAsset != address(0) && vault.collateralAsset != _asset) {
            revert CollateralMismatch();
        }

        vault.collateralAsset = _asset;
        vault.collateralAmount += _amount;

        MarginPool(addressBook.marginPool()).transferToPool(_asset, _owner, _amount);

        emit CollateralDeposited(_owner, _vaultId, _asset, _amount);
    }

    /**
     * @notice Mint oTokens from a vault (write options).
     *         Vault must have enough collateral to be fully collateralized.
     *
     *         For a PUT: collateral is USDC. Need (shortAmount * strikePrice / 1e8) USDC.
     *           e.g., 1 PUT at $2000 strike = 2000e6 USDC (2000 * 1e6) collateral
     *         For a CALL: collateral is the underlying. Need shortAmount of underlying.
     *           e.g., 1 CALL = 1e18 WETH collateral
     *
     * @param _owner   Vault owner whose collateral backs the position
     * @param _vaultId Vault to mint from
     * @param _oToken  The oToken to mint
     * @param _amount  Amount of oTokens to mint (8 decimals)
     * @param _to      Recipient of the minted oTokens (e.g. operator/MM)
     */
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

        // Verify oToken is whitelisted
        Whitelist wl = Whitelist(addressBook.whitelist());
        if (!wl.isWhitelistedOToken(_oToken)) revert OTokenNotWhitelisted();

        OToken oToken = OToken(_oToken);

        // Check collateral is sufficient for fully collateralized position
        uint256 requiredCollateral = _getRequiredCollateral(oToken, _amount);
        if (vault.collateralAmount < requiredCollateral) revert InsufficientCollateral();

        vault.shortOtoken = _oToken;
        vault.shortAmount += _amount;

        oToken.mintOtoken(_to, _amount);

        emit OTokenMinted(_owner, _vaultId, _oToken, _amount);
    }

    /**
     * @notice Settle a vault after expiry — or immediately if betaMode is active (physical settlement).
     *         Calculates payout based on expiry price and returns remaining collateral.
     *
     *         Physical settlement behavior:
     *         - ITM: full collateral stays in MarginPool for redemption via physical delivery.
     *           Vault owner receives 0 collateral back. They get the contra-asset via
     *           BatchSettler.physicalRedeem() (flash loan + DEX swap).
     *         - OTM: full collateral returned to vault owner (no delivery needed).
     */
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

        // Return remaining collateral to vault owner
        if (collateralToReturn > 0) {
            MarginPool(addressBook.marginPool()).transferToUser(
                vault.collateralAsset, _owner, collateralToReturn
            );
        }

        emit VaultSettled(_owner, _vaultId, collateralToReturn);
    }

    /**
     * @notice Redeem oTokens for payout after expiry — or immediately if betaMode is active
     *         (for option holders/buyers). Burns the oTokens and pays out if ITM.
     */
    function redeem(address _oToken, uint256 _amount) external {
        if (_amount == 0) revert NoOtokensToRedeem();

        OToken oToken = OToken(_oToken);
        if (!betaMode && block.timestamp < oToken.expiry()) revert OptionNotExpired();

        Oracle oracle = Oracle(addressBook.oracle());
        (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(oToken.underlying(), oToken.expiry());
        if (!isSet) revert ExpiryPriceNotSet();

        uint256 payout = _calculatePayout(oToken, _amount, expiryPrice);

        // Burn the oTokens
        oToken.burnOtoken(msg.sender, _amount);

        // Pay out if ITM
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

    /**
     * @notice Calculate required collateral for fully collateralized position.
     *         PUT:  (amount * strikePrice) / 1e8, converted to collateral decimals (USDC = 6)
     *         CALL: amount converted to underlying decimals (WETH = 18)
     */
    function _getRequiredCollateral(OToken oToken, uint256 _amount) internal view returns (uint256) {
        if (oToken.isPut()) {
            // PUT: need (amount * strikePrice / 1e8) in USDC
            // amount is 8 decimals, strikePrice is 8 decimals
            // result needs to be in USDC decimals (6)
            // amount * strikePrice / 1e8 / 1e2 = amount * strikePrice / 1e10
            return (_amount * oToken.strikePrice()) / 1e10;
        } else {
            // CALL: need `amount` of underlying
            // amount is 8 decimals, underlying is 18 decimals
            // convert: amount * 1e18 / 1e8 = amount * 1e10
            return _amount * 1e10;
        }
    }

    /**
     * @notice Calculate payout for physical settlement.
     *         Physical settlement: ITM options pay out the FULL collateral to the oToken holder.
     *         The vault owner receives the contra-asset via physical delivery (flash loan).
     *
     *         PUT ITM (expiryPrice < strike):
     *           payout = full collateral = amount * strike / 1e10, in USDC
     *         CALL ITM (expiryPrice > strike):
     *           payout = full collateral = amount * 1e10, in WETH
     *         OTM (including ATM): payout = 0
     */
    function _calculatePayout(OToken oToken, uint256 _amount, uint256 _expiryPrice)
        internal
        view
        returns (uint256)
    {
        uint256 strike = oToken.strikePrice();

        if (oToken.isPut()) {
            if (_expiryPrice >= strike) return 0; // OTM or ATM
            // ITM: full collateral in USDC
            return (_amount * strike) / 1e10;
        } else {
            if (_expiryPrice <= strike) return 0; // OTM or ATM
            // ITM: full collateral in underlying
            return _amount * 1e10;
        }
    }
}
