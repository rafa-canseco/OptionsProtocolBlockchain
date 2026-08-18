// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AddressBook} from "../core/AddressBook.sol";
import {Oracle} from "../core/Oracle.sol";
import {OToken} from "../core/OToken.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {IPositionValuator} from "./interfaces/IPositionValuator.sol";
import {IManagedStrategyAdapter} from "./interfaces/IManagedStrategyAdapter.sol";
import {IAssetNeutralWheelV2 as IWheel} from "./interfaces/IAssetNeutralWheelV2.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "./interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "./interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";
import {WheelTypes} from "./WheelTypes.sol";
import {WheelManagedOperationDispatcher} from "./libraries/WheelManagedOperationDispatcher.sol";

interface IAssetNeutralOptionsValuatorReadbackV2 {
    function interfaceVersion() external view returns (uint64);
    function expectedAdapter() external view returns (address);
    function expectedFund() external view returns (address);
    function expectedAddressBook() external view returns (address);
    function expectedUnderlying() external view returns (address);
    function expectedSettlement() external view returns (address);
    function expectedPolicyHash() external view returns (bytes32);
    function expectedStrategyKind() external view returns (IAdapter.StrategyKind);
    function spotFeed() external view returns (address);
    function maxSpotStaleness() external view returns (uint64);
}

library AssetNeutralReadbackV2 {
    function readAddress(address target, bytes4 selector) internal view returns (bool ok, address value) {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length != 32) return (false, address(0));
        value = abi.decode(data, (address));
    }

    function readUint(address target, bytes4 selector) internal view returns (bool ok, uint256 value) {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length != 32) return (false, 0);
        value = abi.decode(data, (uint256));
    }

    function readBytes32(address target, bytes4 selector) internal view returns (bool ok, bytes32 value) {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok || data.length != 32) return (false, bytes32(0));
        value = abi.decode(data, (bytes32));
    }

    function readAssetConfig(address target) internal view returns (bool ok, IAdapter.AssetConfigV2 memory config) {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodeWithSelector(IAdapter.assetConfigV2.selector));
        if (!ok || data.length != 192) return (false, config);
        config = abi.decode(data, (IAdapter.AssetConfigV2));
    }
}

interface IAssetNeutralFundManagerBindingV2 {
    function fund() external view returns (address);
}

interface IAssetNeutralFundBindingV2 {
    function strategyManager() external view returns (address);
    function asset() external view returns (address);
}

interface IAssetNeutralWheelChildLaneV2 {
    enum LaneState {
        Idle,
        Open,
        Settling,
        ReadyForHandoff
    }

    struct Basket {
        IWheel.SettlementKind settlementKind;
        uint256 childSharesBurned;
        uint256 settlementAmount;
        uint256 underlyingAmount;
        uint256 positionId;
        uint256 literalAssignmentStrikeUsd8;
        uint256 callAwaySettlementAmount;
        bytes32 positionHash;
        bytes32 transitionHash;
    }
    function coordinator() external view returns (address);
    function adapter() external view returns (address);
    function fund() external view returns (address);
    function underlyingAsset() external view returns (address);
    function settlementAsset() external view returns (address);
    function policyHash() external view returns (bytes32);
    function adapterBound() external view returns (bool);
    function laneKind() external view returns (IWheel.LaneKind);
    function childShares() external view returns (uint256);
    function activePositionId() external view returns (uint256);
    function positionStateHash() external view returns (bytes32);
    function accountingState() external view returns (uint256 settlementAmount, uint256 underlyingAmount);
    function executionCostBufferUsd8() external view returns (uint256);
    function open(
        uint256 trancheId,
        bytes32 transitionHash,
        uint256 lotId,
        uint256 literalStrikeUsd8,
        uint256 amount,
        bytes calldata data
    ) external returns (uint256 shares, uint256 positionId, uint64 expiry, bytes32 positionHash);
    function settle(uint256 trancheId, bytes32 expectedHash) external returns (IWheel.SettlementKind, bytes32);
    function handoff(uint256 trancheId, bytes32 expectedHash, bytes32 transitionHash, address receiver)
        external
        returns (Basket memory);
}

/// @notice Dedicated LBTC8/USDC6 single-position lane. Concrete CSP and call lanes use separate namespaces.
abstract contract AssetNeutralWheelChildLaneV2 is FundUpgradeable, IAssetNeutralWheelChildLaneV2 {
    using SafeERC20 for IERC20;
    bytes32 private constant INITIAL_HASH = keccak256("b1nary LBTC8 Wheel Child Lane V2");

    struct Layout {
        address coordinator;
        address adapter;
        address underlying;
        address settlement;
        bytes32 policyHash;
        uint64 stateNonce;
        bool allocationsPaused;
        LaneState state;
        IWheel.SettlementKind settlementKind;
        uint256 maxAssets;
        uint256 executionBufferUsd8;
        uint256 activeTrancheId;
        uint256 activePositionId;
        uint256 consumedLotId;
        uint256 shares;
        uint256 accountedSettlement;
        uint256 accountedUnderlying;
        uint256 literalStrikeUsd8;
        uint64 expiry;
        bytes32 positionsHash;
        mapping(bytes32 => bool) consumedTransitions;
    }

    struct InitializeParams {
        address coordinator;
        address adapter; // Deprecated bootstrap field; MUST be zero and bound after adapter initialization.
        address underlyingAsset;
        address settlementAsset;
        address authority;
        uint256 maxAssets;
        uint256 executionCostBufferUsd8;
        bytes32 policyHash;
    }

    error AccountingDeficit(address asset, uint256 accounted, uint256 actual);
    error CallStrikeBelowFloor(uint256 strikeUsd8, uint256 requiredFloorUsd8);
    error DuplicateTransition(bytes32 transitionHash);
    error InvalidAddress();
    error InvalidAmount();
    error InvalidLaneState();
    error InvalidPositionHash(bytes32 expected, bytes32 actual);
    error OnlyCoordinator();
    error TransferMismatch();
    error UnsupportedChain(uint256 chainId);

    event AssetNeutralLaneOpenedV2(
        uint256 indexed trancheId,
        uint256 indexed lotId,
        uint256 indexed positionId,
        uint256 amount,
        uint256 literalStrikeUsd8,
        uint64 expiry,
        bytes32 positionHash
    );
    event AssetNeutralLaneSettlementAdvancedV2(
        uint256 indexed trancheId,
        uint256 indexed positionId,
        IWheel.SettlementKind kind,
        LaneState state,
        bytes32 positionHash
    );
    event AssetNeutralLaneBasketHandedOffV2(
        uint256 indexed trancheId, bytes32 indexed transitionHash, uint256 settlementAmount, uint256 underlyingAmount
    );
    event AssetNeutralLaneAllocationPauseSetV2(bool paused);
    event AssetNeutralLaneAdapterBoundV2(address indexed adapter);

    constructor() {
        _disableInitializers();
    }
    function _storageLocation() internal pure virtual returns (bytes32);
    function laneKind() public pure virtual returns (IWheel.LaneKind);

    function _layout() internal pure returns (Layout storage $) {
        bytes32 slot = _storageLocation();
        assembly { $.slot := slot }
    }

    function _initialize(InitializeParams calldata p) internal onlyInitializing {
        if (block.chainid != 84532) revert UnsupportedChain(block.chainid);
        if (
            p.coordinator == address(0) || p.adapter != address(0) || p.underlyingAsset == address(0)
                || p.settlementAsset == address(0) || p.coordinator.code.length == 0
                || p.underlyingAsset.code.length == 0 || p.settlementAsset.code.length == 0 || p.maxAssets == 0
                || p.policyHash == bytes32(0)
                || (laneKind() == IWheel.LaneKind.CoveredCall && p.executionCostBufferUsd8 > type(uint256).max / 2)
        ) revert InvalidAddress();
        __FundUpgradeable_init(p.authority);
        Layout storage $ = _layout();
        $.coordinator = p.coordinator;
        $.adapter = address(0);
        $.underlying = p.underlyingAsset;
        $.settlement = p.settlementAsset;
        $.maxAssets = p.maxAssets;
        $.executionBufferUsd8 = p.executionCostBufferUsd8;
        $.policyHash = p.policyHash;
        $.positionsHash = INITIAL_HASH;
        $.allocationsPaused = true;
    }

    modifier onlyCoordinator() {
        if (msg.sender != _layout().coordinator) revert OnlyCoordinator();
        _;
    }

    function _checkNotDelegated() internal view override {
        if (block.chainid != 84532) revert UnsupportedChain(block.chainid);
        super._checkNotDelegated();
    }

    function _authorizeUpgrade(address) internal view override {
        if (block.chainid != 84532) revert UnsupportedChain(block.chainid);
    }

    function coordinator() external view returns (address) {
        return _layout().coordinator;
    }

    function adapter() external view returns (address) {
        return _layout().adapter;
    }

    function fund() external view returns (address) {
        return address(this);
    }

    function underlyingAsset() external view returns (address) {
        return _layout().underlying;
    }

    function settlementAsset() external view returns (address) {
        return _layout().settlement;
    }

    function policyHash() external view returns (bytes32) {
        return _layout().policyHash;
    }

    function adapterBound() external view returns (bool) {
        return _layout().adapter != address(0);
    }

    function bindAdapter(address adapter_) external restricted {
        Layout storage $ = _layout();
        if ($.adapter != address(0) || !_validAdapter(adapter_, $)) revert InvalidAddress();
        $.adapter = adapter_;
        _checkpoint($, keccak256(abi.encode("BIND_ADAPTER", adapter_)));
        emit AssetNeutralLaneAdapterBoundV2(adapter_);
    }

    function _validAdapter(address adapter_, Layout storage $) private view returns (bool) {
        if (adapter_ == address(0) || adapter_.code.length == 0) return false;
        IAdapter a = IAdapter(adapter_);
        IAdapter.StrategyKind expected =
            laneKind() == IWheel.LaneKind.Csp ? IAdapter.StrategyKind.Csp : IAdapter.StrategyKind.CoveredCall;
        IAdapter.AssetConfigV2 memory cfg = a.assetConfigV2();
        return a.interfaceVersion() == 2 && a.strategyKind() == expected && a.underlyingAsset() == $.underlying
            && a.settlementAsset() == $.settlement && a.policyHash() == $.policyHash
            && cfg.underlyingAsset == $.underlying && cfg.settlementAsset == $.settlement && cfg.oTokenDecimals == 8
            && cfg.underlyingDecimals == 8 && cfg.priceDecimals == 8 && cfg.settlementDecimals == 6
            && IOperations(adapter_).fund() == address(this) && IOperations(adapter_).strategyManager() == address(this);
    }

    function asset() external view returns (address) {
        return laneKind() == IWheel.LaneKind.Csp ? _layout().settlement : _layout().underlying;
    }

    function strategyManager() external view returns (address) {
        return address(this);
    }

    function totalAssets() external view returns (uint256) {
        return _layout().shares;
    }

    function childShares() external view returns (uint256) {
        return _layout().shares;
    }

    function activePositionId() external view returns (uint256) {
        return _layout().activePositionId;
    }

    function executionCostBufferUsd8() external view returns (uint256) {
        return _layout().executionBufferUsd8;
    }

    function accountingState() external view returns (uint256, uint256) {
        Layout storage $ = _layout();
        return ($.accountedSettlement, $.accountedUnderlying);
    }

    function allocationsPaused() external view returns (bool) {
        return _layout().allocationsPaused;
    }

    function executionStateHash() public view returns (bytes32) {
        Layout storage $ = _layout();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.stateNonce,
                $.state,
                $.settlementKind,
                $.activeTrancheId,
                $.activePositionId,
                $.consumedLotId,
                $.shares,
                $.accountedSettlement,
                $.accountedUnderlying,
                $.literalStrikeUsd8,
                $.positionsHash
            )
        );
    }

    function positionStateHash() public view returns (bytes32) {
        Layout storage $ = _layout();
        return keccak256(
            abi.encode(
                executionStateHash(),
                IOperations($.adapter).positionStateHash(),
                IERC20($.settlement).balanceOf(address(this)),
                IERC20($.underlying).balanceOf(address(this))
            )
        );
    }

    function open(
        uint256 trancheId,
        bytes32 transitionHash,
        uint256 lotId,
        uint256 literalStrikeUsd8,
        uint256 amount,
        bytes calldata data
    ) external onlyCoordinator returns (uint256 shares, uint256 positionId, uint64 expiry, bytes32 positionHash) {
        Layout storage $ = _layout();
        if (
            $.adapter == address(0) || $.allocationsPaused || $.state != LaneState.Idle || trancheId == 0 || amount == 0
                || amount > $.maxAssets
        ) {
            revert InvalidLaneState();
        }
        _consume($, transitionHash);
        IAdapter.OpenPositionDataV2 memory d = abi.decode(data, (IAdapter.OpenPositionDataV2));
        OToken o = OToken(d.quote.oToken);
        if (laneKind() == IWheel.LaneKind.Csp) {
            if (
                lotId != 0 || literalStrikeUsd8 != 0 || d.collateralAmount != amount
                    || Math.mulDiv(d.optionAmount8, o.strikePrice(), 1e10, Math.Rounding.Ceil) != amount
            ) revert InvalidAmount();
        } else {
            if (lotId == 0 || literalStrikeUsd8 == 0 || d.optionAmount8 != amount || d.collateralAmount != amount) {
                revert InvalidAmount();
            }
            uint256 floor = literalStrikeUsd8 + $.executionBufferUsd8;
            if (o.strikePrice() < floor) revert CallStrikeBelowFloor(o.strikePrice(), floor);
        }
        address collateral = laneKind() == IWheel.LaneKind.Csp ? $.settlement : $.underlying;
        IERC20 token = IERC20(collateral);
        uint256 before_ = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before_ != amount) revert TransferMismatch();
        token.safeTransfer($.adapter, amount);
        // The covered-call adapter evaluates utilization against lane totalAssets. Publish only the pending share
        // basis before the external allocation; the transaction remains atomic and committed lane state stays Idle.
        $.shares = amount;
        IOperations($.adapter).allocate(collateral, amount, data);
        IAdapter.AdapterStateV2 memory state = IAdapter($.adapter).adapterStateV2();
        positionId = state.positionCount;
        IAdapter.PositionV2 memory p = IAdapter($.adapter).positionV2(positionId);
        if (positionId == 0 || p.lifecycle != IAdapter.Lifecycle.Open || p.collateralAmount != amount) {
            revert InvalidAmount();
        }
        $.state = LaneState.Open;
        $.activeTrancheId = trancheId;
        $.activePositionId = positionId;
        $.consumedLotId = lotId;
        $.literalStrikeUsd8 = p.strikePriceUsd8;
        $.expiry = uint64(o.expiry());
        _checkpoint($, transitionHash);
        shares = amount;
        expiry = $.expiry;
        positionHash = executionStateHash();
        emit AssetNeutralLaneOpenedV2(trancheId, lotId, positionId, amount, $.literalStrikeUsd8, expiry, positionHash);
    }

    function settle(uint256 trancheId, bytes32 expectedHash)
        external
        onlyCoordinator
        returns (IWheel.SettlementKind kind, bytes32 positionHash)
    {
        Layout storage $ = _layout();
        if (trancheId != $.activeTrancheId || ($.state != LaneState.Open && $.state != LaneState.Settling)) {
            revert InvalidLaneState();
        }
        bytes32 current = executionStateHash();
        if (current != expectedHash) revert InvalidPositionHash(expectedHash, current);
        uint256 sb = IERC20($.settlement).balanceOf(address(this));
        uint256 ub = IERC20($.underlying).balanceOf(address(this));
        IOperations($.adapter)
            .deallocate(
                1,
                0,
                abi.encode(
                    IAdapter.DeallocateDataV2({
                        action: IAdapter.DeallocateAction.Settle,
                        positionId: $.activePositionId,
                        amount: 0,
                        minAmountOut: 0
                    })
                )
            );
        IAdapter.PositionV2 memory p = IAdapter($.adapter).positionV2($.activePositionId);
        if (p.lifecycle == IAdapter.Lifecycle.AwaitingPhysicalDelivery) {
            $.accountedSettlement += IERC20($.settlement).balanceOf(address(this)) - sb;
            $.accountedUnderlying += IERC20($.underlying).balanceOf(address(this)) - ub;
            $.state = LaneState.Settling;
            _checkpoint($, keccak256(abi.encode("SETTLING", p.lifecycleHash)));
            positionHash = executionStateHash();
            emit AssetNeutralLaneSettlementAdvancedV2(
                trancheId, $.activePositionId, IWheel.SettlementKind.None, $.state, positionHash
            );
            return (IWheel.SettlementKind.None, positionHash);
        }
        if (laneKind() == IWheel.LaneKind.Csp) {
            if (p.lifecycle == IAdapter.Lifecycle.SettledOtm) kind = IWheel.SettlementKind.CspOtm;
            else if (p.lifecycle == IAdapter.Lifecycle.AssignedUnderlying) kind = IWheel.SettlementKind.CspAssigned;
            else if (p.lifecycle == IAdapter.Lifecycle.CashFallback) kind = IWheel.SettlementKind.UnderlyingFallback;
            else revert InvalidLaneState();
        } else {
            if (p.lifecycle == IAdapter.Lifecycle.SettledOtm) kind = IWheel.SettlementKind.CallOtm;
            else if (p.lifecycle == IAdapter.Lifecycle.CalledAwaySettlement) kind = IWheel.SettlementKind.CallAway;
            else if (p.lifecycle == IAdapter.Lifecycle.CashFallback) kind = IWheel.SettlementKind.UnderlyingFallback;
            else revert InvalidLaneState();
        }
        IOperations($.adapter).deallocateInKind(FundConstants.WAD, address(this), "");
        $.accountedSettlement += IERC20($.settlement).balanceOf(address(this)) - sb;
        $.accountedUnderlying += IERC20($.underlying).balanceOf(address(this)) - ub;
        $.settlementKind = kind;
        $.state = LaneState.ReadyForHandoff;
        _checkpoint($, keccak256(abi.encode("SETTLED", p.lifecycleHash, kind)));
        _noDeficit($);
        positionHash = executionStateHash();
        emit AssetNeutralLaneSettlementAdvancedV2(trancheId, $.activePositionId, kind, $.state, positionHash);
    }

    function handoff(uint256 trancheId, bytes32 expectedHash, bytes32 transitionHash, address receiver)
        external
        onlyCoordinator
        returns (Basket memory b)
    {
        Layout storage $ = _layout();
        if ($.state != LaneState.ReadyForHandoff || trancheId != $.activeTrancheId || receiver == address(0)) {
            revert InvalidLaneState();
        }
        bytes32 current = executionStateHash();
        if (current != expectedHash) revert InvalidPositionHash(expectedHash, current);
        _consume($, transitionHash);
        _noDeficit($);
        IAdapter.PositionV2 memory p = IAdapter($.adapter).positionV2($.activePositionId);
        b = Basket(
            $.settlementKind,
            $.shares,
            $.accountedSettlement,
            $.accountedUnderlying,
            $.activePositionId,
            $.literalStrikeUsd8,
            p.calledAwaySettlementAmount,
            current,
            transitionHash
        );
        $.state = LaneState.Idle;
        $.settlementKind = IWheel.SettlementKind.None;
        $.activeTrancheId = 0;
        $.activePositionId = 0;
        $.consumedLotId = 0;
        $.shares = 0;
        $.accountedSettlement = 0;
        $.accountedUnderlying = 0;
        $.literalStrikeUsd8 = 0;
        $.expiry = 0;
        _checkpoint($, transitionHash);
        _transfer(IERC20($.settlement), receiver, b.settlementAmount);
        _transfer(IERC20($.underlying), receiver, b.underlyingAmount);
        emit AssetNeutralLaneBasketHandedOffV2(trancheId, transitionHash, b.settlementAmount, b.underlyingAmount);
    }

    function pauseAllocations() external restricted {
        _layout().allocationsPaused = true;
        emit AssetNeutralLaneAllocationPauseSetV2(true);
    }

    function resumeAllocations() external restricted {
        _layout().allocationsPaused = false;
        emit AssetNeutralLaneAllocationPauseSetV2(false);
    }

    function _consume(Layout storage $, bytes32 h) private {
        if (h == bytes32(0) || $.consumedTransitions[h]) revert DuplicateTransition(h);
        $.consumedTransitions[h] = true;
    }

    function _checkpoint(Layout storage $, bytes32 h) private {
        uint64 n = ++$.stateNonce;
        $.positionsHash = keccak256(
            abi.encode(
                $.positionsHash,
                n,
                h,
                $.state,
                $.activeTrancheId,
                $.activePositionId,
                $.shares,
                $.accountedSettlement,
                $.accountedUnderlying
            )
        );
    }

    function _noDeficit(Layout storage $) private view {
        uint256 s = IERC20($.settlement).balanceOf(address(this));
        uint256 u = IERC20($.underlying).balanceOf(address(this));
        if (s < $.accountedSettlement) revert AccountingDeficit($.settlement, $.accountedSettlement, s);
        if (u < $.accountedUnderlying) revert AccountingDeficit($.underlying, $.accountedUnderlying, u);
    }

    function _transfer(IERC20 t, address r, uint256 a) private {
        if (a == 0) return;
        uint256 b = t.balanceOf(r);
        t.safeTransfer(r, a);
        if (t.balanceOf(r) - b != a) revert TransferMismatch();
    }
}

contract AssetNeutralCspWheelChildLaneV2 is AssetNeutralWheelChildLaneV2 {
    bytes32 private constant SLOT = 0x4b0b8ea6a52df75cfa8ed49827d37929d1a4a1000d79a2ce66bcf9d217145400;

    function initialize(InitializeParams calldata p) external initializer {
        _initialize(p);
    }

    function _storageLocation() internal pure override returns (bytes32) {
        return SLOT;
    }

    function laneKind() public pure override returns (IWheel.LaneKind) {
        return IWheel.LaneKind.Csp;
    }
}

contract AssetNeutralCoveredCallWheelChildLaneV2 is AssetNeutralWheelChildLaneV2 {
    bytes32 private constant SLOT = 0xcdd7b84632977a6efabdb67715271088399ab37515012c5a3cc39afba75e3600;

    function initialize(InitializeParams calldata p) external initializer {
        _initialize(p);
    }

    function _storageLocation() internal pure override returns (bytes32) {
        return SLOT;
    }

    function laneKind() public pure override returns (IWheel.LaneKind) {
        return IWheel.LaneKind.CoveredCall;
    }
}

/// @notice Isolated LBTC8/USDC6 Meta Wheel coordinator. It never accepts v1/WETH lanes.
contract AssetNeutralMetaWheelCoordinatorV2 is FundUpgradeable, IWheel, IManagedStrategyAdapter {
    using SafeERC20 for IERC20;
    bytes32 public constant LBTC8_POLICY_HASH = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;
    bytes32 private constant SLOT = 0x25f3c781a3b4b2732130427eafb87fab390547f217493bc67910823b9bed6700;

    struct LaneConfig {
        LaneKind kind;
        bool active;
    }

    struct Layout {
        address fund;
        address manager;
        address underlying;
        address settlement;
        uint64 nonce;
        uint16 maxCsp;
        uint16 maxCall;
        uint256 bufferUsd8;
        bool paused;
        bool executing;
        uint256 trancheCount;
        uint256 lotCount;
        uint256 pending;
        uint256 reserved;
        uint256 reservedPrincipal;
        uint256 transitionUnderlying;
        uint256 accountedSettlement;
        uint256 accountedUnderlying;
        bytes32 positionsHash;
        address[] laneList;
        mapping(address => LaneConfig) lanes;
        mapping(address => uint256) activeLane;
        mapping(uint256 => TrancheV2) tranches;
        mapping(uint256 => AssignmentLotV2) lots;
        mapping(uint256 => uint256) openedCallStrikeUsd8;
        mapping(bytes32 => bool) consumed;
        mapping(address => address) laneValuators;
        address valuationReference;
    }

    struct InitializeParams {
        address fund;
        address strategyManager;
        address underlyingAsset;
        address settlementAsset;
        address authority;
        uint16 maxCspLanes;
        uint16 maxCoveredCallLanes;
        uint256 executionCostBufferUsd8;
        bytes32 policyHash;
    }
    error AccountingDeficit();
    error AllocationPaused();
    error CallStrikeBelowFloor(uint256 strikeUsd8, uint256 floorUsd8);
    error DuplicateTransition(bytes32);
    error InKindRedemptionDisabled();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidLane();
    error InvalidLeg();
    error InvalidSettlement();
    error LaneInUse();
    error OnlyStrategyManager();
    error ReentrantOperation();
    error TransferMismatch();
    error UnsupportedChain(uint256 chainId);
    event AssetNeutralWheelTrancheQueuedV2(
        uint256 indexed trancheId, bytes32 indexed allocationId, uint256 amount, bytes32 stateHash
    );
    event AssetNeutralWheelTrancheOpenedV2(
        uint256 indexed trancheId,
        address indexed lane,
        TrancheLeg leg,
        uint256 positionId,
        uint256 shares,
        uint64 expiry,
        bytes32 positionHash
    );
    event AssetNeutralWheelCallFloorEnforcedV2(
        uint256 indexed trancheId,
        uint256 indexed lotId,
        uint256 literalStrikeUsd8,
        uint256 bufferUsd8,
        uint256 callStrikeUsd8
    );
    event AssetNeutralWheelRedemptionReserveChangedV2(uint256 reserved, uint256 pending);
    event AssetNeutralWheelAllocationPauseSetV2(bool paused);
    event AssetNeutralWheelLaneRegisteredV2(address indexed lane, LaneKind kind);
    event AssetNeutralWheelLaneValuatorSetV2(address indexed lane, address indexed valuator);

    constructor() {
        _disableInitializers();
    }

    function _layout() private pure returns (Layout storage $) {
        bytes32 slot = SLOT;
        assembly { $.slot := slot }
    }

    function initialize(InitializeParams calldata p) external initializer {
        if (block.chainid != 84532) revert UnsupportedChain(block.chainid);
        if (!WheelManagedOperationDispatcher.validCoordinatorInitialize(
                p.fund,
                p.strategyManager,
                p.underlyingAsset,
                p.settlementAsset,
                p.maxCspLanes,
                p.maxCoveredCallLanes,
                p.executionCostBufferUsd8,
                p.policyHash,
                LBTC8_POLICY_HASH
            )) revert InvalidAddress();
        __FundUpgradeable_init(p.authority);
        Layout storage $ = _layout();
        $.fund = p.fund;
        $.manager = p.strategyManager;
        $.underlying = p.underlyingAsset;
        $.settlement = p.settlementAsset;
        $.maxCsp = p.maxCspLanes;
        $.maxCall = p.maxCoveredCallLanes;
        $.bufferUsd8 = p.executionCostBufferUsd8;
        $.positionsHash = keccak256("b1nary LBTC8 Meta Wheel V2");
        $.paused = true;
    }
    modifier onlyManager() {
        if (msg.sender != _layout().manager) revert OnlyStrategyManager();
        _;
    }
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlyStrategyManager();
        _;
    }
    modifier lock() {
        Layout storage $ = _layout();
        if ($.executing) revert ReentrantOperation();
        $.executing = true;
        _;
        $.executing = false;
    }

    function _checkNotDelegated() internal view override {
        if (block.chainid != 84532) revert UnsupportedChain(block.chainid);
        super._checkNotDelegated();
    }

    function _authorizeUpgrade(address) internal view override {
        if (block.chainid != 84532) revert UnsupportedChain(block.chainid);
    }

    function interfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function deallocationInterfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function fund() external view returns (address) {
        return _layout().fund;
    }

    function accountingAsset() external view returns (address) {
        return _layout().settlement;
    }

    function underlyingAsset() external view returns (address) {
        return _layout().underlying;
    }

    function settlementAsset() external view returns (address) {
        return _layout().settlement;
    }

    function policyHash() external pure returns (bytes32) {
        return LBTC8_POLICY_HASH;
    }

    function assetConfigV2() external view returns (AssetConfigV2 memory) {
        Layout storage $ = _layout();
        return AssetConfigV2($.underlying, $.settlement, 8, 8, 8, 6);
    }

    function allocationsPaused() external view returns (bool) {
        return _layout().paused;
    }

    function floorBufferUsd8() external view returns (uint256) {
        return _layout().bufferUsd8;
    }

    function summaryV2() public view returns (SummaryV2 memory) {
        Layout storage $ = _layout();
        return SummaryV2(
            $.nonce,
            $.trancheCount,
            $.lotCount,
            $.pending,
            $.reserved,
            $.reservedPrincipal,
            $.transitionUnderlying,
            $.accountedSettlement,
            $.accountedUnderlying
        );
    }

    function trancheV2(uint256 id) external view returns (TrancheV2 memory) {
        return _layout().tranches[id];
    }

    function assignmentLotV2(uint256 id) external view returns (AssignmentLotV2 memory) {
        return _layout().lots[id];
    }

    function registeredLaneCount() external view returns (uint256) {
        return _layout().laneList.length;
    }

    function registeredLaneAt(uint256 i) external view returns (address lane, LaneKind kind, bool active) {
        Layout storage $ = _layout();
        lane = $.laneList[i];
        LaneConfig storage c = $.lanes[lane];
        return (lane, c.kind, c.active);
    }

    function laneValuator(address lane) external view returns (address) {
        return _layout().laneValuators[lane];
    }

    function positionStateHash() public view returns (bytes32) {
        Layout storage $ = _layout();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.fund,
                $.nonce,
                $.positionsHash,
                $.trancheCount,
                $.lotCount,
                $.pending,
                $.reserved,
                $.reservedPrincipal,
                $.transitionUnderlying,
                $.accountedSettlement,
                $.accountedUnderlying,
                $.bufferUsd8,
                LBTC8_POLICY_HASH,
                IERC20($.settlement).balanceOf(address(this)),
                IERC20($.underlying).balanceOf(address(this))
            )
        );
    }

    function freeAssets(address a) external view returns (uint256) {
        Layout storage $ = _layout();
        if (a == $.settlement) {
            return Math.min($.reserved, Math.min($.accountedSettlement, IERC20(a).balanceOf(address(this))));
        }
        // The parent supports USDC-only redemptions. Transition LBTC is never free for in-kind withdrawal.
        return 0;
    }

    function executeManagedOperation(uint8 rawClass, bytes calldata data) external onlyManager returns (bytes memory) {
        return WheelManagedOperationDispatcher.dispatch(rawClass, data);
    }

    function registerLane(address lane, WheelTypes.LaneKind rawKind) external onlySelf {
        LaneKind kind = LaneKind(uint8(rawKind));
        Layout storage $ = _layout();
        if (
            lane == address(0) || lane.code.length == 0 || $.lanes[lane].kind != LaneKind.None
                || (kind != LaneKind.Csp && kind != LaneKind.CoveredCall)
        ) revert InvalidLane();
        if (!WheelManagedOperationDispatcher.validLane(
                lane, rawKind, address(this), $.underlying, $.settlement, $.bufferUsd8, LBTC8_POLICY_HASH
            )) revert InvalidLane();
        uint256 count;
        for (uint256 i; i < $.laneList.length; i++) {
            if ($.lanes[$.laneList[i]].kind == kind) count++;
        }
        if (count >= (kind == LaneKind.Csp ? $.maxCsp : $.maxCall)) revert InvalidLane();
        $.lanes[lane] = LaneConfig(kind, true);
        $.laneList.push(lane);
        _global($, keccak256(abi.encode("REGISTER", lane, kind)));
        emit AssetNeutralWheelLaneRegisteredV2(lane, kind);
    }

    function setLaneValuator(address lane, address valuator) external onlySelf {
        Layout storage $ = _layout();
        LaneKind kind = $.lanes[lane].kind;
        address domainRef = $.valuationReference == address(0) ? valuator : $.valuationReference;
        if (
            kind == LaneKind.None
                || !WheelManagedOperationDispatcher.validLaneValuator(
                    lane, valuator, WheelTypes.LaneKind(uint8(kind)), domainRef
                )
        ) revert InvalidLane();
        if ($.valuationReference == address(0)) $.valuationReference = valuator;
        $.laneValuators[lane] = valuator;
        _global($, keccak256(abi.encode("LANE_VALUATOR", lane, valuator)));
        emit AssetNeutralWheelLaneValuatorSetV2(lane, valuator);
    }

    function setLaneActive(address lane, bool active) external onlySelf {
        Layout storage $ = _layout();
        if ($.lanes[lane].kind == LaneKind.None || (!active && $.activeLane[lane] != 0)) revert InvalidLane();
        $.lanes[lane].active = active;
        _global($, keccak256(abi.encode("LANE_ACTIVE", lane, active)));
    }

    function removeLane(address) external pure {
        revert LaneInUse();
    }

    function setPolicyHash(bytes32 h) external onlySelf {
        if (h != LBTC8_POLICY_HASH) revert InvalidAmount();
    }

    function setFloorBufferUsd8(uint256 b) external onlySelf {
        Layout storage $ = _layout();
        for (uint256 i; i < $.laneList.length; i++) {
            if (
                $.lanes[$.laneList[i]].kind == LaneKind.CoveredCall
                    && IAssetNeutralWheelChildLaneV2($.laneList[i]).executionCostBufferUsd8() != b
            ) revert InvalidLane();
        }
        $.bufferUsd8 = b;
        _global($, keccak256(abi.encode("BUFFER", b)));
    }

    function allocate(address asset, uint256 amount, bytes calldata data) external onlyManager lock {
        Layout storage $ = _layout();
        if ($.paused) revert AllocationPaused();
        if (
            asset != $.settlement || amount == 0
                || IERC20(asset).balanceOf(address(this)) < $.accountedSettlement + amount
        ) {
            revert InvalidAmount();
        }
        bytes32 allocationId = data.length == 0
            ? keccak256(abi.encode(block.chainid, address(this), $.trancheCount + 1, amount, $.nonce))
            : abi.decode(data, (bytes32));
        bytes32 allocationKey = keccak256(abi.encode("ALLOCATION", allocationId));
        if ($.consumed[allocationKey]) revert DuplicateTransition(allocationId);
        $.consumed[allocationKey] = true;
        uint256 id = ++$.trancheCount;
        $.accountedSettlement += amount;
        $.pending += amount;
        TrancheV2 storage t = $.tranches[id];
        t.leg = TrancheLeg.PendingCsp;
        t.principalSettlementAmount = amount;
        t.pendingSettlementAmount = amount;
        _tranche($, id, keccak256(abi.encode("QUEUE", allocationId, amount)));
        emit AssetNeutralWheelTrancheQueuedV2(id, allocationId, amount, t.stateHash);
    }

    function openCspTranche(uint256 id, address lane, bytes calldata data) external onlySelf lock {
        Layout storage $ = _layout();
        if ($.paused) revert AllocationPaused();
        _lane($, lane, LaneKind.Csp);
        TrancheV2 storage t = $.tranches[id];
        if (t.leg != TrancheLeg.PendingCsp || $.activeLane[lane] != 0 || t.pendingSettlementAmount == 0) {
            revert InvalidLeg();
        }
        uint256 amount = t.pendingSettlementAmount;
        bytes32 h = _next($, id, "OPEN_CSP", lane);
        uint256 b = IERC20($.settlement).balanceOf(address(this));
        IERC20($.settlement).forceApprove(lane, amount);
        (uint256 shares, uint256 pos, uint64 expiry, bytes32 ph) =
            IAssetNeutralWheelChildLaneV2(lane).open(id, h, 0, 0, amount, data);
        IERC20($.settlement).forceApprove(lane, 0);
        if (b - IERC20($.settlement).balanceOf(address(this)) != amount || shares != amount) revert TransferMismatch();
        $.accountedSettlement -= amount;
        $.pending -= amount;
        $.activeLane[lane] = id;
        t.leg = TrancheLeg.CspOpen;
        t.childLane = lane;
        t.pendingSettlementAmount = 0;
        t.childShares = shares;
        t.childPositionId = pos;
        t.expiry = expiry;
        t.childPositionHash = ph;
        _tranche($, id, h);
        emit AssetNeutralWheelTrancheOpenedV2(id, lane, t.leg, pos, shares, expiry, ph);
    }

    function settleCspTranche(uint256 id) external onlySelf lock {
        _settle(id, LaneKind.Csp);
    }

    function settleCoveredCallTranche(uint256 id) external onlySelf lock {
        _settle(id, LaneKind.CoveredCall);
    }

    function _settle(uint256 id, LaneKind kind) private {
        Layout storage $ = _layout();
        TrancheV2 storage t = $.tranches[id];
        if (
            (kind == LaneKind.Csp && (t.leg != TrancheLeg.CspOpen && t.leg != TrancheLeg.CspSettling))
                || (kind == LaneKind.CoveredCall && (t.leg != TrancheLeg.CallOpen && t.leg != TrancheLeg.CallSettling))
        ) revert InvalidLeg();
        (, bytes32 ph) = IAssetNeutralWheelChildLaneV2(t.childLane).settle(id, t.childPositionHash);
        t.leg = kind == LaneKind.Csp ? TrancheLeg.CspSettling : TrancheLeg.CallSettling;
        t.childPositionHash = ph;
        _tranche($, id, keccak256(abi.encode("SETTLE", kind, ph)));
    }

    function handoffCspTranche(uint256 id) external onlySelf lock returns (uint256 lotId) {
        Layout storage $ = _layout();
        TrancheV2 storage t = $.tranches[id];
        if (t.leg != TrancheLeg.CspSettling) revert InvalidLeg();
        address lane = t.childLane;
        bytes32 h = _next($, id, "HANDOFF_CSP", lane);
        uint256 sb = IERC20($.settlement).balanceOf(address(this));
        uint256 ub = IERC20($.underlying).balanceOf(address(this));
        IAssetNeutralWheelChildLaneV2.Basket memory b =
            IAssetNeutralWheelChildLaneV2(lane).handoff(id, t.childPositionHash, h, address(this));
        _basket($, b, sb, ub, t.childShares, h);
        if (b.settlementKind == SettlementKind.None) revert InvalidSettlement();
        $.activeLane[lane] = 0;
        $.accountedSettlement += b.settlementAmount;
        $.accountedUnderlying += b.underlyingAmount;
        $.pending += b.settlementAmount;
        t.childLane = address(0);
        t.childShares = 0;
        t.childPositionHash = 0;
        if (b.underlyingAmount == 0) {
            t.pendingSettlementAmount = b.settlementAmount;
            t.leg = TrancheLeg.PendingCsp;
        } else {
            if (b.settlementKind != SettlementKind.CspAssigned || b.literalAssignmentStrikeUsd8 == 0) {
                revert InvalidSettlement();
            }
            if (b.settlementAmount != 0) {
                uint256 returnedPrincipal = _returnedPrincipal(
                    t.principalSettlementAmount, b.settlementAmount, b.underlyingAmount, b.literalAssignmentStrikeUsd8
                );
                t.principalSettlementAmount -= returnedPrincipal;
                _sibling($, id, b.settlementAmount, returnedPrincipal, h);
            }
            lotId = ++$.lotCount;
            $.lots[lotId] = AssignmentLotV2(
                lane,
                uint64(block.timestamp),
                LotStatus.Available,
                id,
                b.positionId,
                b.underlyingAmount,
                b.underlyingAmount,
                b.literalAssignmentStrikeUsd8
            );
            $.transitionUnderlying += b.underlyingAmount;
            t.assignmentLotId = lotId;
            t.leg = TrancheLeg.UnderlyingTransition;
            emit AssetNeutralWheelAssignmentLotCreatedV2(
                lotId, id, lane, b.positionId, b.underlyingAmount, b.literalAssignmentStrikeUsd8
            );
            emit AssetNeutralWheelLotStatusChangedV2(lotId, LotStatus.Available, b.underlyingAmount, id);
        }
        _tranche($, id, h);
        _noDeficit($);
        emit AssetNeutralWheelChildHandoffV2(
            id, lane, h, b.settlementKind, b.childSharesBurned, b.settlementAmount, b.underlyingAmount
        );
    }

    function openCoveredCallTranche(uint256 id, address lane, bytes calldata data) external onlySelf lock {
        Layout storage $ = _layout();
        if ($.paused) revert AllocationPaused();
        _lane($, lane, LaneKind.CoveredCall);
        TrancheV2 storage t = $.tranches[id];
        if (t.leg != TrancheLeg.UnderlyingTransition || $.activeLane[lane] != 0) revert InvalidLeg();
        AssignmentLotV2 storage lot = $.lots[t.assignmentLotId];
        if (lot.status != LotStatus.Available || lot.remainingUnderlyingAmount == 0) revert InvalidAmount();
        IAdapter.OpenPositionDataV2 memory d = abi.decode(data, (IAdapter.OpenPositionDataV2));
        uint256 floor = lot.literalAssignmentStrikeUsd8 + $.bufferUsd8;
        uint256 strike = OToken(d.quote.oToken).strikePrice();
        if (strike < floor) revert CallStrikeBelowFloor(strike, floor);
        uint256 amount = lot.remainingUnderlyingAmount;
        bytes32 h = _next($, id, "OPEN_CALL", lane);
        uint256 before_ = IERC20($.underlying).balanceOf(address(this));
        IERC20($.underlying).forceApprove(lane, amount);
        (uint256 shares, uint256 pos, uint64 expiry, bytes32 ph) = IAssetNeutralWheelChildLaneV2(lane)
            .open(id, h, t.assignmentLotId, lot.literalAssignmentStrikeUsd8, amount, data);
        IERC20($.underlying).forceApprove(lane, 0);
        if (before_ - IERC20($.underlying).balanceOf(address(this)) != amount || shares != amount) {
            revert TransferMismatch();
        }
        $.accountedUnderlying -= amount;
        $.transitionUnderlying -= amount;
        $.activeLane[lane] = id;
        lot.status = LotStatus.InCall;
        t.leg = TrancheLeg.CallOpen;
        t.childLane = lane;
        t.childShares = shares;
        t.childPositionId = pos;
        t.expiry = expiry;
        t.childPositionHash = ph;
        $.openedCallStrikeUsd8[id] = strike;
        _tranche($, id, h);
        emit AssetNeutralWheelCallFloorEnforcedV2(
            id, t.assignmentLotId, lot.literalAssignmentStrikeUsd8, $.bufferUsd8, strike
        );
        emit AssetNeutralWheelLotStatusChangedV2(t.assignmentLotId, lot.status, lot.remainingUnderlyingAmount, id);
        emit AssetNeutralWheelTrancheOpenedV2(id, lane, t.leg, pos, shares, expiry, ph);
    }

    function handoffCoveredCallTranche(uint256 id) external onlySelf lock {
        Layout storage $ = _layout();
        TrancheV2 storage t = $.tranches[id];
        if (t.leg != TrancheLeg.CallSettling) revert InvalidLeg();
        address lane = t.childLane;
        bytes32 h = _next($, id, "HANDOFF_CALL", lane);
        uint256 sb = IERC20($.settlement).balanceOf(address(this));
        uint256 ub = IERC20($.underlying).balanceOf(address(this));
        IAssetNeutralWheelChildLaneV2.Basket memory b =
            IAssetNeutralWheelChildLaneV2(lane).handoff(id, t.childPositionHash, h, address(this));
        _basket($, b, sb, ub, t.childShares, h);
        AssignmentLotV2 storage lot = $.lots[t.assignmentLotId];
        if (b.settlementKind == SettlementKind.CallAway) {
            uint256 openedStrike = $.openedCallStrikeUsd8[id];
            uint256 protectedPrincipal = Math.mulDiv(t.childShares, openedStrike, 1e10);
            if (
                openedStrike == 0 || b.underlyingAmount != 0 || b.callAwaySettlementAmount < protectedPrincipal
                    || b.settlementAmount < b.callAwaySettlementAmount
            ) revert InvalidSettlement();
            lot.status = LotStatus.CalledAway;
            lot.remainingUnderlyingAmount = 0;
            t.pendingSettlementAmount = b.settlementAmount;
            t.leg = TrancheLeg.PendingCsp;
        } else if (b.settlementKind == SettlementKind.CallOtm || b.settlementKind == SettlementKind.UnderlyingFallback)
        {
            if (
                b.underlyingAmount == 0 || b.underlyingAmount > t.childShares
                    || (b.settlementKind == SettlementKind.CallOtm && b.underlyingAmount != t.childShares)
            ) revert InvalidSettlement();
            lot.status = LotStatus.Available;
            lot.remainingUnderlyingAmount = b.underlyingAmount;
            $.transitionUnderlying += b.underlyingAmount;
            t.leg = TrancheLeg.UnderlyingTransition;
            uint256 returnedPrincipal;
            if (b.settlementKind == SettlementKind.UnderlyingFallback && b.underlyingAmount < t.childShares) {
                returnedPrincipal = _returnedPrincipal(
                    t.principalSettlementAmount, b.settlementAmount, b.underlyingAmount, lot.literalAssignmentStrikeUsd8
                );
                t.principalSettlementAmount -= returnedPrincipal;
            }
            if (b.settlementAmount != 0) _sibling($, id, b.settlementAmount, returnedPrincipal, h);
        } else {
            revert InvalidSettlement();
        }
        $.activeLane[lane] = 0;
        $.accountedSettlement += b.settlementAmount;
        $.accountedUnderlying += b.underlyingAmount;
        $.pending += b.settlementAmount;
        t.childLane = address(0);
        t.childShares = 0;
        t.childPositionHash = 0;
        delete $.openedCallStrikeUsd8[id];
        _tranche($, id, h);
        _noDeficit($);
        emit AssetNeutralWheelLotStatusChangedV2(t.assignmentLotId, lot.status, lot.remainingUnderlyingAmount, id);
        emit AssetNeutralWheelChildHandoffV2(
            id, lane, h, b.settlementKind, b.childSharesBurned, b.settlementAmount, b.underlyingAmount
        );
    }

    function reserveRedemptionUsdc(uint256 id, uint256 amount) external onlySelf {
        Layout storage $ = _layout();
        TrancheV2 storage t = $.tranches[id];
        if (t.leg != TrancheLeg.PendingCsp || amount == 0 || amount > t.pendingSettlementAmount) {
            revert InvalidAmount();
        }
        uint256 principal = _share(t.principalSettlementAmount, t.pendingSettlementAmount, amount);
        t.pendingSettlementAmount -= amount;
        t.principalSettlementAmount -= principal;
        if (t.pendingSettlementAmount == 0) t.leg = TrancheLeg.Closed;
        $.pending -= amount;
        $.reserved += amount;
        $.reservedPrincipal += principal;
        _tranche($, id, keccak256(abi.encode("RESERVE", amount, principal)));
        emit AssetNeutralWheelRedemptionReserveChangedV2($.reserved, $.pending);
    }

    function releaseRedemptionUsdc(uint256 amount) external onlySelf returns (uint256 id) {
        Layout storage $ = _layout();
        if (amount == 0 || amount > $.reserved) revert InvalidAmount();
        uint256 p = _share($.reservedPrincipal, $.reserved, amount);
        $.reserved -= amount;
        $.reservedPrincipal -= p;
        $.pending += amount;
        id = _pending($, amount, p, keccak256(abi.encode("RELEASE", amount, p)));
        emit AssetNeutralWheelRedemptionReserveChangedV2($.reserved, $.pending);
    }

    function splitPendingCspTranche(uint256 id, uint256 amount) external onlySelf returns (uint256 sibling) {
        Layout storage $ = _layout();
        TrancheV2 storage t = $.tranches[id];
        if (t.leg != TrancheLeg.PendingCsp || amount == 0 || amount >= t.pendingSettlementAmount) {
            revert InvalidAmount();
        }
        uint256 p = _share(t.principalSettlementAmount, t.pendingSettlementAmount, amount);
        t.pendingSettlementAmount -= amount;
        t.principalSettlementAmount -= p;
        bytes32 h = keccak256(abi.encode("SPLIT", id, amount, p));
        _tranche($, id, h);
        sibling = _pending($, amount, p, h);
    }

    function deallocate(uint256 target, uint256 minimum, bytes calldata)
        external
        onlyManager
        lock
        returns (uint256 out, uint256 principal)
    {
        Layout storage $ = _layout();
        if (target == 0 || target > $.reserved || target > $.accountedSettlement) revert InvalidAmount();
        out = target;
        if (out < minimum) revert InvalidAmount();
        principal = _share($.reservedPrincipal, $.reserved, out);
        $.reserved -= out;
        $.reservedPrincipal -= principal;
        $.accountedSettlement -= out;
        _global($, keccak256(abi.encode("RETURN", out, principal)));
        _transfer(IERC20($.settlement), $.fund, out);
    }

    function deallocateInKind(uint256, address, bytes calldata)
        external
        pure
        returns (address[] memory, uint256[] memory)
    {
        revert InKindRedemptionDisabled();
    }

    function emergencyExit(address, bytes calldata) external pure returns (address[] memory, uint256[] memory) {
        revert InKindRedemptionDisabled();
    }

    function pauseAllocations() external onlySelf {
        _layout().paused = true;
        emit AssetNeutralWheelAllocationPauseSetV2(true);
    }

    function resumeAllocations() external onlySelf {
        Layout storage $ = _layout();
        for (uint256 i; i < $.laneList.length; ++i) {
            address lane = $.laneList[i];
            if ($.lanes[lane].active && $.laneValuators[lane] == address(0)) revert InvalidLane();
        }
        $.paused = false;
        emit AssetNeutralWheelAllocationPauseSetV2(false);
    }

    function _lane(Layout storage $, address lane, LaneKind k) private view {
        if (
            !$.lanes[lane].active || $.lanes[lane].kind != k || $.laneValuators[lane] == address(0)
                || IAssetNeutralWheelChildLaneV2(lane).coordinator() != address(this)
        ) revert InvalidLane();
    }

    function _next(Layout storage $, uint256 id, bytes32 action, address lane) private returns (bytes32 h) {
        h = keccak256(abi.encode(block.chainid, address(this), id, $.nonce + 1, action, lane, $.positionsHash));
        if ($.consumed[h]) revert DuplicateTransition(h);
        $.consumed[h] = true;
    }

    function _basket(
        Layout storage $,
        IAssetNeutralWheelChildLaneV2.Basket memory b,
        uint256 sb,
        uint256 ub,
        uint256 shares,
        bytes32 h
    ) private view {
        if (
            b.transitionHash != h || b.childSharesBurned != shares
                || IERC20($.settlement).balanceOf(address(this)) - sb != b.settlementAmount
                || IERC20($.underlying).balanceOf(address(this)) - ub != b.underlyingAmount
        ) revert TransferMismatch();
    }

    function _sibling(Layout storage $, uint256 parent, uint256 amount, uint256 principal, bytes32 h) private {
        if (amount == 0) return;
        uint256 id = _pending($, amount, principal, keccak256(abi.encode("SIBLING", parent, h)));
        id;
    }

    function _pending(Layout storage $, uint256 amount, uint256 principal, bytes32 h) private returns (uint256 id) {
        id = ++$.trancheCount;
        TrancheV2 storage t = $.tranches[id];
        t.leg = TrancheLeg.PendingCsp;
        t.pendingSettlementAmount = amount;
        t.principalSettlementAmount = principal;
        _tranche($, id, h);
    }

    function _tranche(Layout storage $, uint256 id, bytes32 h) private {
        TrancheV2 storage t = $.tranches[id];
        uint64 n = ++$.nonce;
        t.stateNonce++;
        t.stateHash = keccak256(
            abi.encode(
                t.stateHash,
                t.stateNonce,
                id,
                t.leg,
                t.childLane,
                t.principalSettlementAmount,
                t.pendingSettlementAmount,
                t.childShares,
                t.childPositionId,
                t.assignmentLotId,
                t.childPositionHash,
                h
            )
        );
        $.positionsHash = keccak256(abi.encode($.positionsHash, n, id, t.stateHash));
    }

    function _global(Layout storage $, bytes32 h) private {
        uint64 n = ++$.nonce;
        $.positionsHash = keccak256(abi.encode($.positionsHash, n, h));
    }

    function _share(uint256 p, uint256 total, uint256 a) private pure returns (uint256) {
        if (a == total) return p;
        return Math.mulDiv(p, a, total);
    }

    function _returnedPrincipal(uint256 principal, uint256 cash, uint256 underlying, uint256 strikeUsd8)
        private
        pure
        returns (uint256)
    {
        uint256 retained = Math.min(principal, Math.mulDiv(underlying, strikeUsd8, 1e10, Math.Rounding.Ceil));
        return Math.min(cash, principal - retained);
    }

    function _noDeficit(Layout storage $) private view {
        if (
            IERC20($.settlement).balanceOf(address(this)) < $.accountedSettlement
                || IERC20($.underlying).balanceOf(address(this)) < $.accountedUnderlying
        ) revert AccountingDeficit();
    }

    function _transfer(IERC20 t, address r, uint256 a) private {
        if (a == 0) return;
        uint256 b = t.balanceOf(r);
        t.safeTransfer(r, a);
        if (t.balanceOf(r) - b != a) revert TransferMismatch();
    }
}

/// @notice USDC6 parent NAV from exact coordinator and active lane ledgers, with LBTC8 spot conversion.
contract AssetNeutralMetaWheelValuatorV2 is IPositionValuator {
    bytes32 private constant LBTC8_POLICY_HASH = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;

    address public immutable coordinator;
    address public immutable underlying;
    address public immutable settlement;
    address public immutable spotFeed;
    address public immutable expectedAddressBook;
    uint64 public immutable maxSpotStaleness;
    error InvalidAdapter();
    error InvalidSnapshot();
    error InvalidSpot();
    error InvalidLaneSet();
    error AccountingDeficit();

    constructor(address c, address u, address s, address feed, address cv, address av, uint64 stale) {
        if (
            c == address(0) || u == address(0) || s == address(0) || feed == address(0) || cv == address(0)
                || av == address(0) || c.code.length == 0 || u.code.length == 0 || s.code.length == 0
                || feed.code.length == 0 || cv.code.length == 0 || av.code.length == 0 || stale == 0 || stale > 1_200
                || IERC20Metadata(u).decimals() != 8 || IERC20Metadata(s).decimals() != 6
                || IERC20Metadata(feed).decimals() != 8
        ) revert InvalidSpot();
        if (!_validCoordinator(c, u, s)) revert InvalidAdapter();
        (bool okCspBook, address cspBook) =
            AssetNeutralReadbackV2.readAddress(cv, IAssetNeutralOptionsValuatorReadbackV2.expectedAddressBook.selector);
        (bool okCallBook, address callBook) =
            AssetNeutralReadbackV2.readAddress(av, IAssetNeutralOptionsValuatorReadbackV2.expectedAddressBook.selector);
        if (
            !okCspBook || !okCallBook || cspBook == address(0) || cspBook != callBook
                || !_validChildDomain(cv, feed, stale) || !_validChildDomain(av, feed, stale)
        ) revert InvalidAdapter();
        coordinator = c;
        underlying = u;
        settlement = s;
        spotFeed = feed;
        expectedAddressBook = cspBook;
        maxSpotStaleness = stale;
    }

    function _validCoordinator(address c, address u, address s) private view returns (bool) {
        (bool okVersion, uint256 version) =
            AssetNeutralReadbackV2.readUint(c, IAssetNeutralOptionsValuatorReadbackV2.interfaceVersion.selector);
        if (!okVersion || version != 2) return false;
        (bool okUnderlying, address underlying_) =
            AssetNeutralReadbackV2.readAddress(c, IWheel.underlyingAsset.selector);
        if (!okUnderlying || underlying_ != u) return false;
        (bool okSettlement, address settlement_) =
            AssetNeutralReadbackV2.readAddress(c, IWheel.settlementAsset.selector);
        if (!okSettlement || settlement_ != s) return false;
        (bool okPolicy, bytes32 policy_) = AssetNeutralReadbackV2.readBytes32(c, IWheel.policyHash.selector);
        return okPolicy && policy_ == LBTC8_POLICY_HASH;
    }

    function _validChildDomain(address valuator, address feed, uint64 stale) private view returns (bool) {
        (bool okFeed, address childFeed) =
            AssetNeutralReadbackV2.readAddress(valuator, IAssetNeutralOptionsValuatorReadbackV2.spotFeed.selector);
        (bool okStale, uint256 childStale) =
            AssetNeutralReadbackV2.readUint(valuator, IAssetNeutralOptionsValuatorReadbackV2.maxSpotStaleness.selector);
        return okFeed && childFeed == feed && okStale && childStale != 0 && stale <= childStale;
    }

    function _validChildValuator(address c, address valuator, address u, address s, IAdapter.StrategyKind kind)
        private
        view
        returns (bool)
    {
        (bool okVersion, uint256 version) = AssetNeutralReadbackV2.readUint(
            valuator, IAssetNeutralOptionsValuatorReadbackV2.interfaceVersion.selector
        );
        if (!okVersion || version != 2) return false;
        (bool okKind, uint256 strategyKind_) = AssetNeutralReadbackV2.readUint(
            valuator, IAssetNeutralOptionsValuatorReadbackV2.expectedStrategyKind.selector
        );
        if (!okKind || strategyKind_ != uint256(kind)) return false;
        (bool okUnderlying, address underlying_) = AssetNeutralReadbackV2.readAddress(
            valuator, IAssetNeutralOptionsValuatorReadbackV2.expectedUnderlying.selector
        );
        if (!okUnderlying || underlying_ != u) return false;
        (bool okSettlement, address settlement_) = AssetNeutralReadbackV2.readAddress(
            valuator, IAssetNeutralOptionsValuatorReadbackV2.expectedSettlement.selector
        );
        if (!okSettlement || settlement_ != s) return false;
        (bool okPolicy, bytes32 policy_) = AssetNeutralReadbackV2.readBytes32(
            valuator, IAssetNeutralOptionsValuatorReadbackV2.expectedPolicyHash.selector
        );
        if (!okPolicy || policy_ != LBTC8_POLICY_HASH) return false;
        (bool okBook, address book_) = AssetNeutralReadbackV2.readAddress(
            valuator, IAssetNeutralOptionsValuatorReadbackV2.expectedAddressBook.selector
        );
        if (!okBook || book_ != expectedAddressBook) return false;
        if (!_validChildDomain(valuator, spotFeed, maxSpotStaleness)) return false;
        (bool okAdapter, address adapter_) = AssetNeutralReadbackV2.readAddress(
            valuator, IAssetNeutralOptionsValuatorReadbackV2.expectedAdapter.selector
        );
        if (!okAdapter || adapter_.code.length == 0) return false;
        (bool okFund, address fund_) =
            AssetNeutralReadbackV2.readAddress(valuator, IAssetNeutralOptionsValuatorReadbackV2.expectedFund.selector);
        if (!okFund || fund_.code.length == 0 || !_validValuatorAdapter(adapter_, fund_, u, s, kind)) return false;
        return _isRegisteredLane(c, fund_, adapter_, kind);
    }

    function _validValuatorAdapter(address adapter_, address fund_, address u, address s, IAdapter.StrategyKind kind)
        private
        view
        returns (bool)
    {
        (bool okVersion, uint256 version) =
            AssetNeutralReadbackV2.readUint(adapter_, IAssetNeutralOptionsValuatorReadbackV2.interfaceVersion.selector);
        if (!okVersion || version != 2) return false;
        (bool okKind, uint256 strategyKind_) = AssetNeutralReadbackV2.readUint(adapter_, IAdapter.strategyKind.selector);
        if (!okKind || strategyKind_ != uint256(kind)) return false;
        (bool okUnderlying, address underlying_) =
            AssetNeutralReadbackV2.readAddress(adapter_, IAdapter.underlyingAsset.selector);
        if (!okUnderlying || underlying_ != u) return false;
        (bool okSettlement, address settlement_) =
            AssetNeutralReadbackV2.readAddress(adapter_, IAdapter.settlementAsset.selector);
        if (!okSettlement || settlement_ != s) return false;
        (bool okPolicy, bytes32 policy_) = AssetNeutralReadbackV2.readBytes32(adapter_, IAdapter.policyHash.selector);
        if (!okPolicy || policy_ != LBTC8_POLICY_HASH) return false;
        (bool okFund, address adapterFund_) = AssetNeutralReadbackV2.readAddress(adapter_, IOperations.fund.selector);
        if (!okFund || adapterFund_ != fund_) return false;
        (bool okManager, address manager_) =
            AssetNeutralReadbackV2.readAddress(adapter_, IOperations.strategyManager.selector);
        if (!okManager || manager_ != fund_) return false;
        (bool okConfig, IAdapter.AssetConfigV2 memory config) = AssetNeutralReadbackV2.readAssetConfig(adapter_);
        return okConfig && config.underlyingAsset == u && config.settlementAsset == s && config.oTokenDecimals == 8
            && config.underlyingDecimals == 8 && config.priceDecimals == 8 && config.settlementDecimals == 6;
    }

    function _isRegisteredLane(address c, address fund_, address adapter_, IAdapter.StrategyKind kind)
        private
        view
        returns (bool)
    {
        uint256 count = IWheel(c).registeredLaneCount();
        IWheel.LaneKind expected = kind == IAdapter.StrategyKind.Csp ? IWheel.LaneKind.Csp : IWheel.LaneKind.CoveredCall;
        for (uint256 i; i < count; ++i) {
            (address lane, IWheel.LaneKind laneKind_,) = IWheel(c).registeredLaneAt(i);
            if (lane != fund_ || laneKind_ != expected) continue;
            (bool ok, address linkedAdapter) =
                AssetNeutralReadbackV2.readAddress(lane, IAssetNeutralWheelChildLaneV2.adapter.selector);
            return ok && linkedAdapter == adapter_;
        }
        return false;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function value(address adapter, uint64 snapshot, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory v)
    {
        if (
            adapter != coordinator || IWheel(adapter).interfaceVersion() != 2
                || IWheel(adapter).underlyingAsset() != underlying || IWheel(adapter).settlementAsset() != settlement
        ) revert InvalidAdapter();
        if (snapshot != block.number) revert InvalidSnapshot();
        Oracle boundOracle = Oracle(AddressBook(expectedAddressBook).oracle());
        uint256 oracleAge = boundOracle.maxOracleStaleness();
        if (boundOracle.priceFeed(underlying) != spotFeed || oracleAge == 0) revert InvalidSpot();
        uint256 effectiveMaxAge = Math.min(oracleAge, uint256(maxSpotStaleness));
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) = IAssetNeutralFeed(spotFeed).latestRoundData();
        if (
            answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > effectiveMaxAge
                || answered < round
        ) {
            revert InvalidSpot();
        }
        uint256 spot = uint256(answer);
        IWheel.SummaryV2 memory s = IWheel(adapter).summaryV2();
        if (
            s.accountedUnderlyingAmount != s.transitionUnderlyingAmount
                || IERC20(settlement).balanceOf(adapter) < s.accountedSettlementAmount
                || IERC20(underlying).balanceOf(adapter) < s.accountedUnderlyingAmount
        ) revert AccountingDeficit();
        v.grossAssets = s.accountedSettlementAmount + Math.mulDiv(s.transitionUnderlyingAmount, spot, 1e10);
        v.liquidAccountingAssets = s.accountedSettlementAmount;
        IWheel.LaneValuationV2[] memory reports = abi.decode(data, (IWheel.LaneValuationV2[]));
        uint256 cursor;
        uint256 count = IWheel(adapter).registeredLaneCount();
        for (uint256 i; i < count; i++) {
            (address lane, IWheel.LaneKind kind, bool active) = IWheel(adapter).registeredLaneAt(i);
            if (!active || IAssetNeutralWheelChildLaneV2(lane).childShares() == 0) continue;
            if (
                cursor >= reports.length || reports[cursor].lane != lane || reports[cursor].snapshotBlock != snapshot
                    || reports[cursor].childShares != IAssetNeutralWheelChildLaneV2(lane).childShares()
                    || reports[cursor].positionHash != IAssetNeutralWheelChildLaneV2(lane).positionStateHash()
            ) revert InvalidLaneSet();
            address childValuator = IWheel(adapter).laneValuator(lane);
            IAdapter.StrategyKind expectedKind =
                kind == IWheel.LaneKind.Csp ? IAdapter.StrategyKind.Csp : IAdapter.StrategyKind.CoveredCall;
            if (!_validChildValuator(adapter, childValuator, underlying, settlement, expectedKind)) {
                revert InvalidLaneSet();
            }
            FundTypes.PositionValue memory child = IPositionValuator(childValuator)
                .value(IAssetNeutralWheelChildLaneV2(lane).adapter(), snapshot, reports[cursor].valuationData);
            (uint256 idleS, uint256 idleU) = IAssetNeutralWheelChildLaneV2(lane).accountingState();
            if (IERC20(settlement).balanceOf(lane) < idleS || IERC20(underlying).balanceOf(lane) < idleU) {
                revert AccountingDeficit();
            }
            if (kind == IWheel.LaneKind.Csp) {
                v.grossAssets += child.grossAssets;
                v.liabilities += child.liabilities;
                v.baseExitCost += child.baseExitCost;
            } else {
                v.grossAssets += Math.mulDiv(child.grossAssets, spot, 1e10);
                v.liabilities += Math.mulDiv(child.liabilities, spot, 1e10, Math.Rounding.Ceil);
                v.baseExitCost += Math.mulDiv(child.baseExitCost, spot, 1e10, Math.Rounding.Ceil);
            }
            v.grossAssets += idleS + Math.mulDiv(idleU, spot, 1e10);
            v.dataHash = keccak256(abi.encode(v.dataHash, lane, child.dataHash, reports[cursor].positionHash));
            cursor++;
        }
        if (cursor != reports.length || v.liabilities > v.grossAssets) revert InvalidLaneSet();
        v.dataHash = keccak256(
            abi.encode(adapter, IWheel(adapter).positionStateHash(), snapshot, round, spot, updated, keccak256(data), v)
        );
    }
}

interface IAssetNeutralFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
