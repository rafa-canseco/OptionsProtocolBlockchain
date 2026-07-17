// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BatchSettler} from "../../core/BatchSettler.sol";
import {IFundStrategyAdapter} from "./IFundStrategyAdapter.sol";

interface ICspFundAdapter is IFundStrategyAdapter {
    enum Lifecycle {
        None,
        Open,
        AwaitingPhysicalDelivery,
        SettledOtm,
        Assigned,
        CashFallback
    }

    enum DeallocateAction {
        ReturnIdle,
        Settle,
        SwapAssignedWeth
    }

    struct RiskConfig {
        uint64 minExpiryDelay;
        uint64 maxExpiryDelay;
        uint64 settlementDefaultDelay;
        uint16 minPremiumBps;
        uint16 maxSwapSlippageBps;
        uint16 maxOpenPositions;
        uint256 minStrike;
        uint256 maxStrike;
        uint256 maxCollateralPerPosition;
        uint256 maxWethPerSwap;
    }

    struct OpenPositionData {
        BatchSettler.Quote quote;
        bytes signature;
        uint256 optionAmount;
        uint256 collateral;
    }

    struct DeallocateData {
        DeallocateAction action;
        uint256 positionId;
        uint256 amount;
        uint256 minAmountOut;
    }

    struct AdapterState {
        uint64 stateNonce;
        bytes32 positionsHash;
        uint256 positionCount;
        uint256 activePositionCount;
        uint256 accountedUsdc;
        uint256 accountedWeth;
    }

    struct AdapterConfig {
        RiskConfig riskConfig;
        address swapRouter;
        uint24 swapFeeTier;
    }

    struct Position {
        address oToken;
        address marketMaker;
        uint256 protocolVaultId;
        uint256 optionAmount;
        uint256 collateral;
        uint256 premiumEarned;
        uint256 collateralReturned;
        uint256 assignedWeth;
        uint256 wethBalanceBeforeDelivery;
        uint64 openedAt;
        uint64 fallbackEligibleAt;
        Lifecycle lifecycle;
        bytes32 lifecycleHash;
    }

    event PositionOpened(
        uint256 indexed positionId,
        uint256 indexed protocolVaultId,
        address indexed oToken,
        address marketMaker,
        uint256 optionAmount,
        uint256 collateral,
        uint256 premiumEarned,
        bytes32 lifecycleHash
    );
    event PositionTransitioned(
        uint256 indexed positionId,
        uint256 indexed protocolVaultId,
        Lifecycle lifecycle,
        uint256 collateralDelta,
        uint256 payment,
        uint256 wethDelta,
        bytes32 lifecycleHash
    );
    event AccountingAssetsReturned(uint256 amount);
    event AssignedWethSwapped(uint256 wethIn, uint256 usdcOut);
    event RawAssetsRecovered(address indexed escrow, address[] assets, uint256[] amounts, bool emergency);
    event AdapterConfigUpdated(RiskConfig riskConfig, address indexed swapRouter, uint24 swapFeeTier);

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

    function strategyManager() external view returns (address);
    function addressBook() external view returns (address);
    function weth() external view returns (address);
    function adapterState() external view returns (AdapterState memory);
    function adapterConfig() external view returns (AdapterConfig memory);
    function position(uint256 positionId) external view returns (Position memory);
    function isOnboarded() external view returns (bool);

    function setAdapterConfig(RiskConfig calldata riskConfig, address swapRouter, uint24 swapFeeTier) external;
}
