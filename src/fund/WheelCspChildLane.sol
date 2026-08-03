// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OToken} from "../core/OToken.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {WheelTypes} from "./WheelTypes.sol";
import {ICspFundAdapter} from "./interfaces/ICspFundAdapter.sol";
import {IWheelCspChildLane} from "./interfaces/IWheelCspChildLane.sol";
import {WheelCspChildLaneStorage} from "./storage/WheelCspChildLaneStorage.sol";

/// @notice Dedicated single-position CSP lane controlled only by one Meta Wheel coordinator.
contract WheelCspChildLane is FundUpgradeable, WheelCspChildLaneStorage, IWheelCspChildLane {
    using SafeERC20 for IERC20;

    bytes32 private constant INITIAL_POSITIONS_HASH = keccak256("b1nary Wheel CSP Child Lane");

    struct InitializeParams {
        address coordinator;
        address adapter;
        address usdc;
        address weth;
        address authority;
        uint256 maxAssets;
    }

    error AccountingDeficit(address asset, uint256 accounted, uint256 actual);
    error DuplicateTransition(bytes32 transitionHash);
    error InvalidAddress();
    error InvalidAmount();
    error InvalidLaneState(WheelTypes.LaneState expected, WheelTypes.LaneState actual);
    error InvalidPositionHash(bytes32 expected, bytes32 actual);
    error OnlyCoordinator();
    error TransferMismatch(address asset, uint256 expected, uint256 actual);

    event CspOpened(
        uint256 indexed trancheId,
        uint256 indexed positionId,
        uint256 usdcAmount,
        uint256 literalAssignmentStrike8,
        uint64 expiry,
        uint256 childShares,
        bytes32 positionHash
    );
    event CspSettlementAdvanced(
        uint256 indexed trancheId,
        uint256 indexed positionId,
        WheelTypes.SettlementKind settlementKind,
        WheelTypes.LaneState laneState,
        uint256 observedUsdc,
        uint256 observedWeth,
        bytes32 positionHash
    );
    event CspBasketHandedOff(
        uint256 indexed trancheId,
        bytes32 indexed transitionHash,
        address indexed receiver,
        uint256 childSharesBurned,
        uint256 usdcAmount,
        uint256 wethAmount
    );
    event LaneAllocationPauseSet(bool paused);
    event LaneMaxAssetsSet(uint256 maxAssets);
    event WheelPremiumAccrued(
        uint256 indexed trancheId,
        address indexed lane,
        uint256 indexed childPositionId,
        uint256 grossPremiumAssets,
        uint256 protocolFeeAssets,
        uint256 netPremiumAssets
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitializeParams calldata params) external initializer {
        if (
            params.coordinator == address(0) || params.adapter == address(0) || params.usdc == address(0)
                || params.weth == address(0) || params.coordinator.code.length == 0 || params.adapter.code.length == 0
                || params.usdc.code.length == 0 || params.weth.code.length == 0 || params.maxAssets == 0
        ) revert InvalidAddress();
        ICspFundAdapter adapter_ = ICspFundAdapter(params.adapter);
        if (
            adapter_.fund() != address(this) || adapter_.strategyManager() != address(this)
                || adapter_.accountingAsset() != params.usdc || adapter_.weth() != params.weth
        ) revert InvalidAddress();
        __FundUpgradeable_init(params.authority);
        WheelCspChildLaneStorageLayout storage $ = _getWheelCspChildLaneStorage();
        $.coordinator = params.coordinator;
        $.adapter = params.adapter;
        $.usdc = params.usdc;
        $.weth = params.weth;
        $.maxAssets = params.maxAssets;
        $.positionsHash = INITIAL_POSITIONS_HASH;
    }

    modifier onlyCoordinator() {
        _checkCoordinator();
        _;
    }

    function _checkCoordinator() private view {
        if (msg.sender != _getWheelCspChildLaneStorage().coordinator) revert OnlyCoordinator();
    }

    function coordinator() external view returns (address) {
        return _getWheelCspChildLaneStorage().coordinator;
    }

    function adapter() external view returns (address) {
        return _getWheelCspChildLaneStorage().adapter;
    }

    function laneKind() external pure returns (WheelTypes.LaneKind) {
        return WheelTypes.LaneKind.Csp;
    }

    function laneState() external view returns (WheelTypes.LaneState) {
        return _getWheelCspChildLaneStorage().state;
    }

    function allocationsPaused() external view returns (bool) {
        return _getWheelCspChildLaneStorage().allocationsPaused;
    }

    function stateNonce() external view returns (uint64) {
        return _getWheelCspChildLaneStorage().stateNonce;
    }

    function childShares() external view returns (uint256) {
        return _getWheelCspChildLaneStorage().childShares;
    }

    function activeTrancheId() external view returns (uint256) {
        return _getWheelCspChildLaneStorage().activeTrancheId;
    }

    function activePositionId() external view returns (uint256) {
        return _getWheelCspChildLaneStorage().activePositionId;
    }

    function maxAssets() external view returns (uint256) {
        return _getWheelCspChildLaneStorage().maxAssets;
    }

    function accountingState() external view returns (uint256 accountedUsdc, uint256 accountedWeth) {
        WheelCspChildLaneStorageLayout storage $ = _getWheelCspChildLaneStorage();
        return ($.accountedUsdc, $.accountedWeth);
    }

    /// @notice Stable operational commitment; permissionless token transfers cannot invalidate it.
    function executionStateHash() public view returns (bytes32) {
        WheelCspChildLaneStorageLayout storage $ = _getWheelCspChildLaneStorage();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.stateNonce,
                $.state,
                $.settlementKind,
                $.activeTrancheId,
                $.activePositionId,
                $.childShares,
                $.accountedUsdc,
                $.accountedWeth,
                $.literalAssignmentStrike8,
                $.expiry,
                $.positionsHash
            )
        );
    }

    /// @notice Balance-sensitive reconciliation commitment used by NAV reporters.
    function positionStateHash() public view returns (bytes32) {
        WheelCspChildLaneStorageLayout storage $ = _getWheelCspChildLaneStorage();
        return keccak256(
            abi.encode(
                executionStateHash(),
                ICspFundAdapter($.adapter).positionStateHash(),
                IERC20($.usdc).balanceOf(address(this)),
                IERC20($.weth).balanceOf(address(this))
            )
        );
    }

    function openCsp(uint256 trancheId, bytes32 transitionHash, uint256 usdcAmount, bytes calldata openData)
        external
        onlyCoordinator
        returns (uint256 mintedChildShares, uint256 positionId, uint64 expiry, bytes32 positionHash)
    {
        WheelCspChildLaneStorageLayout storage $ = _getWheelCspChildLaneStorage();
        if ($.allocationsPaused) revert InvalidLaneState(WheelTypes.LaneState.Idle, $.state);
        if ($.state != WheelTypes.LaneState.Idle) {
            revert InvalidLaneState(WheelTypes.LaneState.Idle, $.state);
        }
        if (trancheId == 0 || transitionHash == bytes32(0) || usdcAmount == 0 || usdcAmount > $.maxAssets) {
            revert InvalidAmount();
        }
        _consumeTransition($, transitionHash);

        IERC20 usdcToken = IERC20($.usdc);
        uint256 laneBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);
        uint256 received = usdcToken.balanceOf(address(this)) - laneBefore;
        if (received != usdcAmount) revert TransferMismatch($.usdc, usdcAmount, received);
        uint256 adapterBefore = usdcToken.balanceOf($.adapter);
        usdcToken.safeTransfer($.adapter, received);
        uint256 adapterReceived = usdcToken.balanceOf($.adapter) - adapterBefore;
        if (adapterReceived != received) revert TransferMismatch($.usdc, received, adapterReceived);

        ICspFundAdapter csp = ICspFundAdapter($.adapter);
        csp.allocate($.usdc, received, openData);
        ICspFundAdapter.AdapterState memory adapterState_ = csp.adapterState();
        positionId = adapterState_.positionCount;
        ICspFundAdapter.Position memory opened = csp.position(positionId);
        if (positionId == 0 || opened.lifecycle != ICspFundAdapter.Lifecycle.Open) revert InvalidAmount();
        OToken oToken = OToken(opened.oToken);
        expiry = uint64(oToken.expiry());

        $.state = WheelTypes.LaneState.Open;
        $.settlementKind = WheelTypes.SettlementKind.None;
        $.activeTrancheId = trancheId;
        $.activePositionId = positionId;
        $.childShares = received;
        $.literalAssignmentStrike8 = oToken.strikePrice();
        $.expiry = expiry;
        _checkpoint($, transitionHash);
        mintedChildShares = received;
        positionHash = executionStateHash();
        emit CspOpened(
            trancheId, positionId, received, $.literalAssignmentStrike8, expiry, mintedChildShares, positionHash
        );
        ICspFundAdapter.OpenPositionData memory decoded = abi.decode(openData, (ICspFundAdapter.OpenPositionData));
        uint256 grossPremium = decoded.optionAmount * decoded.quote.bidPrice / 1e8;
        if (opened.premiumEarned > grossPremium) revert InvalidAmount();
        emit WheelPremiumAccrued(
            trancheId,
            address(this),
            positionId,
            grossPremium,
            grossPremium - opened.premiumEarned,
            opened.premiumEarned
        );
    }

    function settleCsp(uint256 trancheId, bytes32 expectedPositionHash)
        external
        onlyCoordinator
        returns (WheelTypes.SettlementKind settlementKind, bytes32 positionHash)
    {
        WheelCspChildLaneStorageLayout storage $ = _getWheelCspChildLaneStorage();
        if (
            trancheId != $.activeTrancheId
                || ($.state != WheelTypes.LaneState.Open && $.state != WheelTypes.LaneState.Settling)
        ) revert InvalidLaneState(WheelTypes.LaneState.Open, $.state);
        bytes32 currentHash = executionStateHash();
        if (currentHash != expectedPositionHash) revert InvalidPositionHash(expectedPositionHash, currentHash);

        IERC20 usdcToken = IERC20($.usdc);
        IERC20 wethToken = IERC20($.weth);
        uint256 usdcBefore = usdcToken.balanceOf(address(this));
        uint256 wethBefore = wethToken.balanceOf(address(this));
        ICspFundAdapter csp = ICspFundAdapter($.adapter);
        csp.deallocate(
            type(uint256).max,
            0,
            abi.encode(
                ICspFundAdapter.DeallocateData({
                    action: ICspFundAdapter.DeallocateAction.Settle,
                    positionId: $.activePositionId,
                    amount: 0,
                    minAmountOut: 0
                })
            )
        );

        ICspFundAdapter.Position memory settled = csp.position($.activePositionId);
        if (settled.lifecycle == ICspFundAdapter.Lifecycle.Assigned) {
            csp.deallocateInKind(FundConstants.WAD, address(this), "");
            settlementKind = WheelTypes.SettlementKind.CspAssigned;
            $.state = WheelTypes.LaneState.ReadyForHandoff;
        } else if (settled.lifecycle == ICspFundAdapter.Lifecycle.SettledOtm) {
            settlementKind = WheelTypes.SettlementKind.CspOtm;
            $.state = WheelTypes.LaneState.ReadyForHandoff;
        } else if (settled.lifecycle == ICspFundAdapter.Lifecycle.CashFallback) {
            settlementKind = WheelTypes.SettlementKind.WethFallback;
            $.state = WheelTypes.LaneState.ReadyForHandoff;
        } else if (settled.lifecycle == ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery) {
            settlementKind = WheelTypes.SettlementKind.None;
            $.state = WheelTypes.LaneState.Settling;
        } else {
            revert InvalidAmount();
        }

        uint256 observedUsdc = usdcToken.balanceOf(address(this)) - usdcBefore;
        uint256 observedWeth = wethToken.balanceOf(address(this)) - wethBefore;
        $.accountedUsdc += observedUsdc;
        $.accountedWeth += observedWeth;
        $.settlementKind = settlementKind;
        _checkpoint($, keccak256(abi.encode("SETTLE_CSP", trancheId, settled.lifecycleHash)));
        _requireNoDeficit($);
        positionHash = executionStateHash();
        emit CspSettlementAdvanced(
            trancheId, $.activePositionId, settlementKind, $.state, observedUsdc, observedWeth, positionHash
        );
    }

    function handoffCsp(uint256 trancheId, bytes32 expectedPositionHash, bytes32 transitionHash, address receiver)
        external
        onlyCoordinator
        returns (WheelTypes.LaneBasket memory basket)
    {
        WheelCspChildLaneStorageLayout storage $ = _getWheelCspChildLaneStorage();
        if ($.state != WheelTypes.LaneState.ReadyForHandoff || trancheId != $.activeTrancheId) {
            revert InvalidLaneState(WheelTypes.LaneState.ReadyForHandoff, $.state);
        }
        bytes32 currentHash = executionStateHash();
        if (currentHash != expectedPositionHash) revert InvalidPositionHash(expectedPositionHash, currentHash);
        if (receiver == address(0)) revert InvalidAddress();
        _consumeTransition($, transitionHash);
        _requireNoDeficit($);

        basket = WheelTypes.LaneBasket({
            settlementKind: $.settlementKind,
            childSharesBurned: $.childShares,
            usdcAmount: $.accountedUsdc,
            wethAmount: $.accountedWeth,
            positionId: $.activePositionId,
            literalAssignmentStrike8: $.literalAssignmentStrike8,
            positionHash: currentHash,
            transitionHash: transitionHash
        });

        $.state = WheelTypes.LaneState.Idle;
        $.settlementKind = WheelTypes.SettlementKind.None;
        $.activeTrancheId = 0;
        $.activePositionId = 0;
        $.childShares = 0;
        $.accountedUsdc = 0;
        $.accountedWeth = 0;
        $.literalAssignmentStrike8 = 0;
        $.expiry = 0;
        _checkpoint($, transitionHash);

        _transferExact(IERC20($.usdc), receiver, basket.usdcAmount);
        _transferExact(IERC20($.weth), receiver, basket.wethAmount);
        emit CspBasketHandedOff(
            trancheId, transitionHash, receiver, basket.childSharesBurned, basket.usdcAmount, basket.wethAmount
        );
    }

    function pauseAllocations() external restricted {
        _getWheelCspChildLaneStorage().allocationsPaused = true;
        emit LaneAllocationPauseSet(true);
    }

    function resumeAllocations() external restricted {
        _getWheelCspChildLaneStorage().allocationsPaused = false;
        emit LaneAllocationPauseSet(false);
    }

    function setMaxAssets(uint256 newMaxAssets) external restricted {
        if (newMaxAssets == 0) revert InvalidAmount();
        _getWheelCspChildLaneStorage().maxAssets = newMaxAssets;
        emit LaneMaxAssetsSet(newMaxAssets);
    }

    function storageLocation() external pure returns (bytes32) {
        return WHEEL_CSP_CHILD_LANE_STORAGE_LOCATION;
    }

    function _consumeTransition(WheelCspChildLaneStorageLayout storage $, bytes32 transitionHash) private {
        if (transitionHash == bytes32(0) || $.consumedTransitions[transitionHash]) {
            revert DuplicateTransition(transitionHash);
        }
        $.consumedTransitions[transitionHash] = true;
        $.lastTransitionHash = transitionHash;
    }

    function _checkpoint(WheelCspChildLaneStorageLayout storage $, bytes32 operationHash) private {
        uint64 nonce = ++$.stateNonce;
        $.positionsHash = keccak256(
            abi.encode(
                $.positionsHash,
                nonce,
                operationHash,
                $.state,
                $.activeTrancheId,
                $.activePositionId,
                $.childShares,
                $.accountedUsdc,
                $.accountedWeth
            )
        );
    }

    function _requireNoDeficit(WheelCspChildLaneStorageLayout storage $) private view {
        uint256 rawUsdc = IERC20($.usdc).balanceOf(address(this));
        uint256 rawWeth = IERC20($.weth).balanceOf(address(this));
        if (rawUsdc < $.accountedUsdc) revert AccountingDeficit($.usdc, $.accountedUsdc, rawUsdc);
        if (rawWeth < $.accountedWeth) revert AccountingDeficit($.weth, $.accountedWeth, rawWeth);
    }

    function _transferExact(IERC20 token, address receiver, uint256 amount) private {
        if (amount == 0) return;
        uint256 receiverBefore = token.balanceOf(receiver);
        token.safeTransfer(receiver, amount);
        uint256 received = token.balanceOf(receiver) - receiverBefore;
        if (received != amount) revert TransferMismatch(address(token), amount, received);
    }
}
