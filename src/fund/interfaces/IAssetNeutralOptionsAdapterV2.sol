// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BatchSettler} from "../../core/BatchSettler.sol";
import {IFundStrategyAdapter} from "./IFundStrategyAdapter.sol";

/// @notice Version-2, asset-neutral read/event/DTO boundary for option fund adapters.
/// @dev Implementations MUST return 2 from interfaceVersion(). Amounts are in the native
///      decimals of their explicitly named asset unless a field name carries an 8 suffix.
interface IAssetNeutralOptionsAdapterV2 is IFundStrategyAdapter {
    enum StrategyKind {
        None,
        Csp,
        CoveredCall
    }

    enum Lifecycle {
        None,
        Open,
        AwaitingPhysicalDelivery,
        SettledOtm,
        AssignedUnderlying,
        CalledAwaySettlement,
        CashFallback
    }

    enum DeallocateAction {
        None,
        ReturnIdle,
        Settle,
        Normalize
    }

    struct AssetConfigV2 {
        address underlyingAsset;
        address settlementAsset;
        uint8 oTokenDecimals;
        uint8 underlyingDecimals;
        uint8 priceDecimals;
        uint8 settlementDecimals;
    }

    /// @dev `amount` and `minAmountOut` use the native decimals of the action's input and output assets.
    struct DeallocateDataV2 {
        DeallocateAction action;
        uint256 positionId;
        uint256 amount;
        uint256 minAmountOut;
    }

    /// @dev Encoded as allocate(..., abi.encode(OpenPositionDataV2)).
    struct OpenPositionDataV2 {
        BatchSettler.Quote quote;
        bytes signature;
        uint256 optionAmount8;
        uint256 collateralAmount;
    }

    struct AdapterStateV2 {
        uint64 stateNonce;
        bytes32 positionsHash;
        uint256 positionCount;
        uint256 activePositionCount;
        uint256 activeCollateralAmount;
        uint256 accountedSettlementAmount;
        uint256 accountedUnderlyingAmount;
    }

    struct PositionV2 {
        StrategyKind strategyKind;
        Lifecycle lifecycle;
        address oToken;
        address marketMaker;
        address collateralAsset;
        uint256 protocolVaultId;
        uint256 optionAmount8;
        uint256 collateralAmount;
        uint256 premiumSettlementAmount;
        uint256 collateralReturnedAmount;
        uint256 assignedUnderlyingAmount;
        uint256 calledAwaySettlementAmount;
        uint256 fallbackUnderlyingRecoveredAmount;
        uint256 marketMakerUnderlyingPayoutAmount;
        uint256 strikePriceUsd8;
        uint64 openedAt;
        uint64 fallbackEligibleAt;
        bytes32 lifecycleHash;
    }

    event AssetNeutralPositionOpenedV2(
        uint256 indexed positionId,
        uint256 indexed protocolVaultId,
        address indexed oToken,
        StrategyKind strategyKind,
        address underlyingAsset,
        address settlementAsset,
        address collateralAsset,
        address marketMaker,
        uint256 optionAmount8,
        uint256 collateralAmount,
        uint256 premiumSettlementAmount,
        uint256 strikePriceUsd8,
        bytes32 lifecycleHash
    );

    event AssetNeutralPositionTransitionedV2(
        uint256 indexed positionId,
        uint256 indexed protocolVaultId,
        Lifecycle lifecycle,
        uint256 collateralReturnedAmount,
        uint256 underlyingDelta,
        uint256 settlementDelta,
        uint256 marketMakerUnderlyingPayoutAmount,
        bytes32 lifecycleHash
    );

    event AssetNeutralDustIsolatedV2(address indexed asset, uint256 indexed positionId, uint256 amount, bytes32 reason);
    event AssetNeutralAssetsNormalizedV2(
        address indexed assetIn, address indexed assetOut, uint256 amountIn, uint256 amountOut
    );

    error AmbiguousInterfaceVersion(uint64 observed);
    error AssetConfigMismatch(address expected, address actual);
    error UnsupportedDecimals(address asset, uint8 actual);

    function strategyKind() external pure returns (StrategyKind);
    function underlyingAsset() external view returns (address);
    function settlementAsset() external view returns (address);
    function assetConfigV2() external view returns (AssetConfigV2 memory);
    function policyHash() external view returns (bytes32);
    function adapterStateV2() external view returns (AdapterStateV2 memory);
    function positionV2(uint256 positionId) external view returns (PositionV2 memory);
}
