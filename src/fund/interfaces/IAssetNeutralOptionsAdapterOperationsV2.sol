// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IAssetNeutralOptionsAdapterV2} from "./IAssetNeutralOptionsAdapterV2.sol";

/// @notice Operational extension used by the standalone v2 implementations.
/// @dev The manifest ABI remains IAssetNeutralOptionsAdapterV2; this interface adds curator/read helpers only.
interface IAssetNeutralOptionsAdapterOperationsV2 is IAssetNeutralOptionsAdapterV2 {
    struct RiskConfigV2 {
        uint64 minExpiryDelay;
        uint64 maxExpiryDelay;
        uint64 settlementDefaultDelay;
        uint16 minPremiumBps;
        uint16 maxSwapSlippageBps;
        uint16 maxOpenPositions;
        uint16 maxUtilizationBps;
        uint256 minStrikeUsd8;
        uint256 maxStrikeUsd8;
        uint256 maxCollateralPerPosition;
        uint256 maxNormalizationInput;
        uint256 protectedBasisUsd8;
    }

    struct AdapterConfigV2 {
        RiskConfigV2 riskConfig;
        address swapRouter;
        uint24 swapFeeTier;
    }

    event AdapterConfigUpdatedV2(RiskConfigV2 riskConfig, address indexed swapRouter, uint24 swapFeeTier);
    event AccountingAssetsReturnedV2(address indexed asset, uint256 amount);
    event RawAssetsRecoveredV2(address indexed escrow, address[] assets, uint256[] amounts, bool emergency);

    error AdapterNotOnboarded();
    error AccountingDeficit(address asset, uint256 accounted, uint256 actual);
    error InvalidAddress();
    error InvalidAmount();
    error InvalidLifecycle(uint256 positionId, Lifecycle lifecycle);
    error InvalidPosition(uint256 positionId);
    error InvalidRiskConfig();
    error InvalidSeries(address oToken);
    error LedgerMismatch(uint256 positionId);
    error OnlyStrategyManager();
    error SettlementNotReady(uint256 positionId);
    error SlippageExceeded(uint256 minimum, uint256 actual);
    error UnresolvedSettlement(uint256 amount);

    function fund() external view returns (address);
    function strategyManager() external view returns (address);
    function addressBook() external view returns (address);
    function accountingAsset() external view returns (address);
    function adapterConfigV2() external view returns (AdapterConfigV2 memory);
    function positionStateHash() external view returns (bytes32);
    function isOnboarded() external view returns (bool);
    function setAdapterConfigV2(RiskConfigV2 calldata riskConfig, address swapRouter, uint24 swapFeeTier) external;
}
