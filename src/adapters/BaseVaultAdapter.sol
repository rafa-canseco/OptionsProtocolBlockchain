// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AddressBook} from "../core/AddressBook.sol";
import {BatchSettler} from "../core/BatchSettler.sol";
import {OToken} from "../core/OToken.sol";

/**
 * @title BaseVaultAdapter
 * @notice Base/EVM adapter for opening b1nary positions from an agent/vault flow.
 *         Solana execution is intentionally out of scope for this contract.
 */
contract BaseVaultAdapter is Initializable, UUPSUpgradeable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum PositionMode {
        CSP,
        CC
    }

    enum PositionStatus {
        None,
        Opened,
        NoAssignment,
        Assigned,
        Closed
    }

    struct Position {
        bool exists;
        PositionMode mode;
        PositionStatus status;
        address oToken;
        address underlying;
        address strikeAsset;
        address collateralAsset;
        uint256 expiry;
        uint256 amount;
        uint256 collateral;
        uint256 premium;
        uint256 vaultId;
        uint256 openedAt;
    }

    AddressBook public addressBook;
    BatchSettler public batchSettler;
    IERC20 public usdc;

    address public owner;
    address public pendingOwner;
    address public operator;
    address public agent;

    mapping(bytes32 => bool) public processedIntent;
    mapping(bytes32 => bool) public processedAssetReceipt;
    mapping(bytes32 => Position) public positions;

    event PositionOpened(
        bytes32 indexed intentId,
        uint256 indexed vaultId,
        address indexed oToken,
        PositionMode mode,
        uint256 amount,
        uint256 premium,
        uint256 collateral,
        uint256 expiry
    );
    event PositionStatusUpdated(bytes32 indexed intentId, PositionStatus oldStatus, PositionStatus newStatus);
    event AssetReceiptRecorded(bytes32 indexed receiptId, address indexed asset, uint256 amount);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidConfig();
    error IntentAlreadyProcessed();
    error ReceiptAlreadyProcessed();
    error InvalidMode();
    error PositionNotFound();
    error InvalidStatus();
    error OnlyAgentOrOperator();
    error OnlyOwner();

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyAgentOrOperator() {
        _checkAgentOrOperator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address addressBook_,
        address batchSettler_,
        address usdc_,
        address owner_,
        address operator_,
        address agent_
    ) external initializer {
        if (
            addressBook_ == address(0) || batchSettler_ == address(0) || usdc_ == address(0) || owner_ == address(0)
                || operator_ == address(0) || agent_ == address(0)
        ) {
            revert InvalidAddress();
        }

        addressBook = AddressBook(addressBook_);
        batchSettler = BatchSettler(batchSettler_);
        usdc = IERC20(usdc_);
        owner = owner_;
        operator = operator_;
        agent = agent_;

        emit OwnershipTransferred(address(0), owner_);
    }

    function executePosition(
        bytes32 intentId,
        BatchSettler.Quote calldata quote,
        bytes calldata signature,
        uint256 amount,
        uint256 collateral,
        PositionMode mode
    ) external onlyAgentOrOperator whenNotPaused nonReentrant returns (uint256 vaultId) {
        if (intentId == bytes32(0)) revert InvalidConfig();
        if (processedIntent[intentId]) revert IntentAlreadyProcessed();
        if (quote.oToken == address(0)) revert InvalidAddress();
        if (amount == 0 || collateral == 0) revert InvalidAmount();

        OToken oToken = OToken(quote.oToken);
        bool isPut = oToken.isPut();
        if ((mode == PositionMode.CSP && !isPut) || (mode == PositionMode.CC && isPut)) {
            revert InvalidMode();
        }

        address collateralAsset = oToken.collateralAsset();
        uint256 premium = (amount * quote.bidPrice) / 1e8;

        IERC20(collateralAsset).forceApprove(addressBook.marginPool(), collateral);
        vaultId = batchSettler.executeOrder(quote, signature, amount, collateral);

        processedIntent[intentId] = true;
        positions[intentId] = Position({
            exists: true,
            mode: mode,
            status: PositionStatus.Opened,
            oToken: quote.oToken,
            underlying: oToken.underlying(),
            strikeAsset: oToken.strikeAsset(),
            collateralAsset: collateralAsset,
            expiry: oToken.expiry(),
            amount: amount,
            collateral: collateral,
            premium: premium,
            vaultId: vaultId,
            openedAt: block.timestamp
        });

        emit PositionOpened(intentId, vaultId, quote.oToken, mode, amount, premium, collateral, oToken.expiry());
    }

    function recordAssetReceipt(bytes32 receiptId, address asset, uint256 amount)
        external
        onlyAgentOrOperator
        whenNotPaused
    {
        if (receiptId == bytes32(0)) revert InvalidConfig();
        if (processedAssetReceipt[receiptId]) revert ReceiptAlreadyProcessed();
        if (asset == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (IERC20(asset).balanceOf(address(this)) < amount) revert InvalidAmount();

        processedAssetReceipt[receiptId] = true;
        emit AssetReceiptRecorded(receiptId, asset, amount);
    }

    function updatePositionStatus(bytes32 intentId, PositionStatus newStatus)
        external
        onlyAgentOrOperator
        whenNotPaused
    {
        Position storage position = positions[intentId];
        if (!position.exists) revert PositionNotFound();
        if (newStatus == PositionStatus.None) revert InvalidStatus();

        PositionStatus oldStatus = position.status;
        if (oldStatus == newStatus) revert InvalidStatus();

        position.status = newStatus;
        emit PositionStatusUpdated(intentId, oldStatus, newStatus);
    }

    function setAgent(address newAgent) external onlyOwner {
        if (newAgent == address(0)) revert InvalidAddress();
        emit AgentUpdated(agent, newAgent);
        agent = newAgent;
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidAddress();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyOwner();
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _checkOwner() internal view {
        if (msg.sender != owner) revert OnlyOwner();
    }

    function _checkAgentOrOperator() internal view {
        if (msg.sender != agent && msg.sender != operator) revert OnlyAgentOrOperator();
    }

    uint256[40] private __gap;
}
