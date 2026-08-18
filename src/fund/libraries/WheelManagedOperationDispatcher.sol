// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";
import {IWheelCoordinatorManagedActions} from "../interfaces/IWheelCoordinatorManagedActions.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "../interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "../interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";
import {FundConstants} from "../FundConstants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "../../interfaces/ISwapRouter.sol";
import {OToken} from "../../core/OToken.sol";

interface IWheelAdapterFundAssets {
    function totalAssets() external view returns (uint256);
}

interface IWheelAdapterPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Closed dispatcher and registration validator kept outside coordinator and adapter runtimes for EIP-170 headroom.
library WheelManagedOperationDispatcher {
    using SafeERC20 for IERC20;

    error InvalidManagedOperation(uint8 operationClass, WheelTypes.ManagedOperation operation);

    bytes4 private constant COORDINATOR = bytes4(keccak256("coordinator()"));
    bytes4 private constant LANE_KIND = bytes4(keccak256("laneKind()"));
    bytes4 private constant ADAPTER = bytes4(keccak256("adapter()"));
    bytes4 private constant ADAPTER_BOUND = bytes4(keccak256("adapterBound()"));
    bytes4 private constant UNDERLYING = bytes4(keccak256("underlyingAsset()"));
    bytes4 private constant SETTLEMENT = bytes4(keccak256("settlementAsset()"));
    bytes4 private constant POLICY = bytes4(keccak256("policyHash()"));
    bytes4 private constant EXECUTION_BUFFER = bytes4(keccak256("executionCostBufferUsd8()"));
    bytes4 private constant STRATEGY_KIND = bytes4(keccak256("strategyKind()"));
    bytes4 private constant FUND = bytes4(keccak256("fund()"));
    bytes4 private constant STRATEGY_MANAGER = bytes4(keccak256("strategyManager()"));
    bytes4 private constant INTERFACE_VERSION = bytes4(keccak256("interfaceVersion()"));
    bytes4 private constant ASSET = bytes4(keccak256("asset()"));
    bytes4 private constant DECIMALS = bytes4(keccak256("decimals()"));
    bytes4 private constant EXPECTED_ADAPTER = bytes4(keccak256("expectedAdapter()"));
    bytes4 private constant EXPECTED_FUND = bytes4(keccak256("expectedFund()"));
    bytes4 private constant EXPECTED_ADDRESS_BOOK = bytes4(keccak256("expectedAddressBook()"));
    bytes4 private constant EXPECTED_UNDERLYING = bytes4(keccak256("expectedUnderlying()"));
    bytes4 private constant EXPECTED_SETTLEMENT = bytes4(keccak256("expectedSettlement()"));
    bytes4 private constant EXPECTED_POLICY = bytes4(keccak256("expectedPolicyHash()"));
    bytes4 private constant EXPECTED_STRATEGY_KIND = bytes4(keccak256("expectedStrategyKind()"));
    bytes4 private constant ADDRESS_BOOK = bytes4(keccak256("addressBook()"));
    bytes4 private constant SPOT_FEED = bytes4(keccak256("spotFeed()"));
    bytes4 private constant MAX_SPOT_STALENESS = bytes4(keccak256("maxSpotStaleness()"));
    bytes4 private constant CONTROLLER = bytes4(keccak256("controller()"));
    bytes4 private constant BATCH_SETTLER = bytes4(keccak256("batchSettler()"));
    bytes4 private constant MARGIN_POOL = bytes4(keccak256("marginPool()"));
    bytes4 private constant OTOKEN_FACTORY = bytes4(keccak256("oTokenFactory()"));
    bytes4 private constant ORACLE = bytes4(keccak256("oracle()"));
    bytes4 private constant WHITELIST = bytes4(keccak256("whitelist()"));
    bytes4 private constant CUSTODIED_REDEMPTION = bytes4(keccak256("custodiedRedemptionOnly()"));
    bytes4 private constant AUTHORIZED_DELIVERY = bytes4(keccak256("authorizedPhysicalDeliveryVault(address)"));
    bytes4 private constant SWAP_ROUTER = bytes4(keccak256("swapRouter()"));
    bytes4 private constant ASSET_SWAP_FEE = bytes4(keccak256("assetSwapFeeTier(address)"));
    bytes4 private constant SWAP_FEE = bytes4(keccak256("swapFeeTier()"));
    bytes4 private constant WHITELISTED_UNDERLYING = bytes4(keccak256("isWhitelistedUnderlying(address)"));
    bytes4 private constant WHITELISTED_COLLATERAL = bytes4(keccak256("isWhitelistedCollateral(address)"));
    bytes4 private constant WHITELISTED_PRODUCT =
        bytes4(keccak256("isProductWhitelisted(address,address,address,bool)"));
    bytes4 private constant MAX_ORACLE_AGE = bytes4(keccak256("maxOracleStaleness()"));
    bytes4 private constant PRICE_FEED = bytes4(keccak256("priceFeed(address)"));
    bytes4 private constant VAULT_SETTLED = bytes4(keccak256("vaultSettled(address,uint256)"));
    bytes4 private constant VAULT_OTOKEN_BALANCE = bytes4(keccak256("vaultOTokenBalance(address,uint256)"));
    bytes4 private constant DELIVERY_RESERVED = bytes4(keccak256("physicalDeliveryReservedVault(address,uint256)"));
    uint256 private constant MAX_ORACLE_STALENESS = 1_200;
    uint256 private constant MAX_SETTLEMENT_DEFAULT_DELAY = 30 days;
    uint16 private constant MAX_OPEN_POSITIONS = 16;

    function validCoordinatorInitialize(
        address fund,
        address manager,
        address underlying,
        address settlement,
        uint16 maxCsp,
        uint16 maxCall,
        uint256 executionBuffer,
        bytes32 policy,
        bytes32 expectedPolicy
    ) external view returns (bool) {
        if (
            fund.code.length == 0 || manager.code.length == 0 || underlying.code.length == 0
                || settlement.code.length == 0 || maxCsp == 0 || maxCall == 0 || maxCsp > 32 || maxCall > 32
                || policy != expectedPolicy || executionBuffer > type(uint256).max / 2
        ) return false;
        (bool okUnderlyingDecimals, uint256 underlyingDecimals) = _read(underlying, DECIMALS);
        (bool okSettlementDecimals, uint256 settlementDecimals) = _read(settlement, DECIMALS);
        (bool okManagerFund, uint256 managerFund) = _read(manager, FUND);
        (bool okFundManager, uint256 fundManager) = _read(fund, STRATEGY_MANAGER);
        (bool okAsset, uint256 asset_) = _read(fund, ASSET);
        return okUnderlyingDecimals && underlyingDecimals == 8 && okSettlementDecimals && settlementDecimals == 6
            && okManagerFund && address(uint160(managerFund)) == fund && okFundManager
            && address(uint160(fundManager)) == manager && okAsset && address(uint160(asset_)) == settlement;
    }

    function validAdapterInitialize(
        address fund,
        address manager,
        address addressBook_,
        address underlying,
        address settlement,
        address router,
        uint8 strategy
    ) external view returns (bool) {
        if (
            fund.code.length == 0 || manager.code.length == 0 || addressBook_.code.length == 0
                || underlying.code.length == 0 || settlement.code.length == 0 || router.code.length == 0
                || underlying == settlement
        ) return false;
        (bool okManagerFund, uint256 managerFund) = _read(manager, FUND);
        (bool okFundManager, uint256 fundManager) = _read(fund, STRATEGY_MANAGER);
        (bool okAsset, uint256 asset_) = _read(fund, ASSET);
        address expectedAsset = strategy == uint8(IAdapter.StrategyKind.Csp) ? settlement : underlying;
        return okManagerFund && address(uint160(managerFund)) == fund && okFundManager
            && address(uint160(fundManager)) == manager && okAsset && address(uint160(asset_)) == expectedAsset;
    }

    function validAdapterRisk(IOperations.RiskConfigV2 calldata r) external pure returns (bool) {
        return r.minExpiryDelay != 0 && r.maxExpiryDelay >= r.minExpiryDelay && r.settlementDefaultDelay != 0
            && r.settlementDefaultDelay <= MAX_SETTLEMENT_DEFAULT_DELAY && r.minPremiumBps <= FundConstants.BPS
            && r.maxSwapSlippageBps <= FundConstants.BPS && r.maxOpenPositions != 0
            && r.maxOpenPositions <= MAX_OPEN_POSITIONS && r.maxUtilizationBps != 0
            && r.maxUtilizationBps <= FundConstants.BPS && r.maxStrikeUsd8 >= r.minStrikeUsd8
            && r.maxCollateralPerPosition != 0 && r.maxNormalizationInput != 0;
    }

    function validFeeTier(uint24 tier) external pure returns (bool) {
        return tier == 100 || tier == 500 || tier == 3000 || tier == 10000;
    }

    function isAdapterOnboarded(
        address addressBook_,
        address adapter,
        address router,
        address underlying,
        address settlement,
        uint24 feeTier,
        uint8 strategy
    ) external view returns (bool) {
        (bool okController, uint256 controller_) = _read(addressBook_, CONTROLLER);
        (bool okSettler, uint256 settler_) = _read(addressBook_, BATCH_SETTLER);
        (bool okPool, uint256 pool_) = _read(addressBook_, MARGIN_POOL);
        (bool okFactory, uint256 factory_) = _read(addressBook_, OTOKEN_FACTORY);
        (bool okOracle, uint256 oracle_) = _read(addressBook_, ORACLE);
        (bool okWhitelist, uint256 whitelist_) = _read(addressBook_, WHITELIST);
        if (!okController || !okSettler || !okPool || !okFactory || !okOracle || !okWhitelist) return false;
        address controller = address(uint160(controller_));
        address settler = address(uint160(settler_));
        address pool = address(uint160(pool_));
        address factory = address(uint160(factory_));
        address oracle = address(uint160(oracle_));
        address whitelist = address(uint160(whitelist_));
        if (
            controller.code.length == 0 || settler.code.length == 0 || pool.code.length == 0 || factory.code.length == 0
                || oracle.code.length == 0 || whitelist.code.length == 0 || router.code.length == 0
        ) return false;
        if (
            !_matches(controller, ADDRESS_BOOK, uint256(uint160(addressBook_)))
                || !_matches(settler, ADDRESS_BOOK, uint256(uint160(addressBook_)))
                || !_matches(pool, ADDRESS_BOOK, uint256(uint160(addressBook_)))
                || !_matches(factory, ADDRESS_BOOK, uint256(uint160(addressBook_)))
                || !_matches(oracle, ADDRESS_BOOK, uint256(uint160(addressBook_)))
                || !_matches(controller, CUSTODIED_REDEMPTION, 1)
                || !_matchesWithArgs(settler, AUTHORIZED_DELIVERY, abi.encode(adapter), 1)
                || !_matches(settler, SWAP_ROUTER, uint256(uint160(router)))
        ) return false;
        (bool okTier, uint256 tier) = _readWithArgs(settler, ASSET_SWAP_FEE, abi.encode(underlying));
        if (!okTier) return false;
        if (tier == 0) {
            (okTier, tier) = _read(settler, SWAP_FEE);
        }
        if (!okTier || tier != feeTier || !_freshSpotAvailable(oracle, underlying)) return false;
        if (!_matchesWithArgs(whitelist, WHITELISTED_UNDERLYING, abi.encode(underlying), 1)) return false;
        address collateral = strategy == uint8(IAdapter.StrategyKind.Csp) ? settlement : underlying;
        return _matchesWithArgs(whitelist, WHITELISTED_COLLATERAL, abi.encode(collateral), 1)
            && _matchesWithArgs(
            whitelist,
            WHITELISTED_PRODUCT,
            abi.encode(underlying, settlement, collateral, strategy == uint8(IAdapter.StrategyKind.Csp)),
            1
        );
    }

    function freshSpot(address oracle, address asset) external view returns (uint256 price) {
        (bool ok, uint256 value) = _freshSpotData(oracle, asset);
        if (!ok) revert IOperations.InvalidRiskConfig();
        return value;
    }

    function adapterFreeAssets(
        address asset,
        address settlement,
        address underlying,
        uint256 accountedSettlement,
        uint256 accountedUnderlying
    ) external view returns (uint256) {
        if (asset == settlement) {
            return Math.min(accountedSettlement, IERC20(asset).balanceOf(address(this)));
        }
        if (asset == underlying) return Math.min(accountedUnderlying, IERC20(asset).balanceOf(address(this)));
        return 0;
    }

    function recoveryAmounts(
        uint256 accountedSettlement,
        uint256 accountedUnderlying,
        uint256 releasablePrincipal,
        uint256 fraction
    ) external pure returns (uint256 settlementAmount, uint256 underlyingAmount, uint256 principalRecovered) {
        settlementAmount = Math.mulDiv(accountedSettlement, fraction, FundConstants.WAD);
        underlyingAmount = Math.mulDiv(accountedUnderlying, fraction, FundConstants.WAD);
        principalRecovered = Math.mulDiv(releasablePrincipal, fraction, FundConstants.WAD);
    }

    function adapterPositionStateHash(
        address fund,
        uint64 stateNonce,
        bytes32 positionsHash,
        uint256 activePositionCount,
        uint256 activeCollateral,
        uint256 accountedSettlement,
        uint256 accountedUnderlying,
        address settlement,
        address underlying
    ) external view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                fund,
                stateNonce,
                positionsHash,
                activePositionCount,
                activeCollateral,
                accountedSettlement,
                accountedUnderlying,
                IERC20(settlement).balanceOf(address(this)),
                IERC20(underlying).balanceOf(address(this))
            )
        );
    }

    function validateAdapterNoDeficit(
        address settlement,
        address underlying,
        uint256 accountedSettlement,
        uint256 accountedUnderlying
    ) external view {
        uint256 settlementBalance = IERC20(settlement).balanceOf(address(this));
        uint256 underlyingBalance = IERC20(underlying).balanceOf(address(this));
        if (settlementBalance < accountedSettlement) {
            revert IOperations.AccountingDeficit(settlement, accountedSettlement, settlementBalance);
        }
        if (underlyingBalance < accountedUnderlying) {
            revert IOperations.AccountingDeficit(underlying, accountedUnderlying, underlyingBalance);
        }
    }

    function validateAdapterTerminal(address addressBook_, address adapter, uint256 vaultId, uint256 positionId)
        external
        view
    {
        (, uint256 controller_) = _read(addressBook_, CONTROLLER);
        (, uint256 settler_) = _read(addressBook_, BATCH_SETTLER);
        address controller = address(uint160(controller_));
        address settler = address(uint160(settler_));
        if (
            !_matchesWithArgs(controller, VAULT_SETTLED, abi.encode(adapter, vaultId), 1)
                || !_matchesWithArgs(settler, VAULT_OTOKEN_BALANCE, abi.encode(adapter, vaultId), 0)
                || !_matchesWithArgs(settler, DELIVERY_RESERVED, abi.encode(adapter, vaultId), 0)
        ) revert IOperations.LedgerMismatch(positionId);
    }

    function cspPremiumEarned(uint256 balanceBefore, uint256 balanceAfter, uint256 collateral)
        external
        pure
        returns (uint256 earned)
    {
        if (balanceAfter > type(uint256).max - collateral || balanceAfter + collateral < balanceBefore) {
            revert IOperations.LedgerMismatch(0);
        }
        return balanceAfter + collateral - balanceBefore;
    }

    function validateAdapterAllocation(
        address addressBook_,
        address fund,
        address underlying,
        address settlement,
        IOperations.RiskConfigV2 calldata risk,
        uint8 strategy,
        address oToken,
        uint256 optionAmount8,
        uint256 amount,
        uint256 activePositionCount,
        uint256 activeCollateral,
        uint256 accountedSettlement
    ) external view returns (address collateralAsset, uint256 freshSpot) {
        if (optionAmount8 == 0 || activePositionCount >= risk.maxOpenPositions) {
            revert IOperations.InvalidAmount();
        }
        bool csp = strategy == uint8(IAdapter.StrategyKind.Csp);
        collateralAsset = csp ? settlement : underlying;
        OToken ot = OToken(oToken);
        if (
            oToken == address(0) || ot.decimals() != 8 || ot.underlying() != underlying
                || ot.strikeAsset() != settlement || ot.collateralAsset() != collateralAsset || ot.isPut() != csp
        ) revert IOperations.InvalidSeries(oToken);
        uint256 delay = ot.expiry() > block.timestamp ? ot.expiry() - block.timestamp : 0;
        uint256 strike = ot.strikePrice();
        if (
            delay < risk.minExpiryDelay || delay > risk.maxExpiryDelay || strike < risk.minStrikeUsd8
                || strike > risk.maxStrikeUsd8 || amount > risk.maxCollateralPerPosition
        ) revert IOperations.InvalidRiskConfig();
        uint256 required = csp ? Math.mulDiv(optionAmount8, strike, 1e10, Math.Rounding.Ceil) : optionAmount8;
        if (amount != required) revert IOperations.InvalidAmount();
        if (!csp) {
            if (risk.protectedBasisUsd8 != 0 && strike < risk.protectedBasisUsd8) {
                revert IOperations.InvalidRiskConfig();
            }
            if (
                accountedSettlement != 0
                    || activeCollateral + amount
                        > Math.mulDiv(
                            IWheelAdapterFundAssets(fund).totalAssets(), risk.maxUtilizationBps, FundConstants.BPS
                        )
            ) revert IOperations.InvalidRiskConfig();
        }
        (, uint256 oracle_) = _read(addressBook_, ORACLE);
        (bool fresh, uint256 spot) = _freshSpotData(address(uint160(oracle_)), underlying);
        if (!fresh) revert IOperations.InvalidRiskConfig();
        return (collateralAsset, spot);
    }

    function normalizeAdapterAssets(
        address router,
        address input,
        address output,
        uint24 feeTier,
        uint8 strategy,
        uint256 amount,
        uint256 minOut,
        uint256 spot,
        uint16 maxSlippageBps
    ) external returns (uint256 used, uint256 got) {
        uint256 fair = strategy == uint8(IAdapter.StrategyKind.Csp)
            ? Math.mulDiv(amount, spot, 1e10)
            : Math.mulDiv(amount, 1e10, spot);
        uint256 floor = Math.mulDiv(fair, FundConstants.BPS - maxSlippageBps, FundConstants.BPS);
        if (minOut < floor) revert IOperations.SlippageExceeded(floor, minOut);
        IERC20 source = IERC20(input);
        IERC20 target = IERC20(output);
        uint256 sourceBefore = source.balanceOf(address(this));
        uint256 targetBefore = target.balanceOf(address(this));
        source.forceApprove(router, amount);
        uint256 quoted = ISwapRouter(router)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams(input, output, feeTier, address(this), amount, minOut, 0)
            );
        source.forceApprove(router, 0);
        used = sourceBefore - source.balanceOf(address(this));
        got = target.balanceOf(address(this)) - targetBefore;
        if (used != amount || got != quoted || got < minOut) revert IOperations.SlippageExceeded(minOut, got);
    }

    function validLane(
        address lane,
        WheelTypes.LaneKind kind,
        address coordinator,
        address underlying,
        address settlement,
        uint256 executionBuffer,
        bytes32 policy
    ) external view returns (bool) {
        (bool okCoordinator, uint256 coordinator_) = _read(lane, COORDINATOR);
        (bool okKind, uint256 kind_) = _read(lane, LANE_KIND);
        (bool okBound, uint256 bound_) = _read(lane, ADAPTER_BOUND);
        (bool okUnderlying, uint256 underlying_) = _read(lane, UNDERLYING);
        (bool okSettlement, uint256 settlement_) = _read(lane, SETTLEMENT);
        (bool okPolicy, uint256 policy_) = _read(lane, POLICY);
        (bool okAdapter, uint256 adapterWord) = _read(lane, ADAPTER);
        address adapter = address(uint160(adapterWord));
        if (
            !okCoordinator || address(uint160(coordinator_)) != coordinator || !okKind || kind_ != uint256(kind)
                || !okBound || bound_ != 1 || !okUnderlying || address(uint160(underlying_)) != underlying
                || !okSettlement || address(uint160(settlement_)) != settlement || !okPolicy
                || bytes32(policy_) != policy || !okAdapter || adapter.code.length == 0
        ) return false;

        (bool okStrategy, uint256 strategy) = _read(adapter, STRATEGY_KIND);
        (bool okFund, uint256 fund_) = _read(adapter, FUND);
        (bool okManager, uint256 manager_) = _read(adapter, STRATEGY_MANAGER);
        uint256 expected = kind == WheelTypes.LaneKind.Csp
            ? uint256(IAdapter.StrategyKind.Csp)
            : uint256(IAdapter.StrategyKind.CoveredCall);
        if (
            !okStrategy || strategy != expected || !okFund || address(uint160(fund_)) != lane || !okManager
                || address(uint160(manager_)) != lane
        ) return false;
        if (kind != WheelTypes.LaneKind.CoveredCall) return true;
        (bool okBuffer, uint256 buffer) = _read(lane, EXECUTION_BUFFER);
        return okBuffer && buffer == executionBuffer;
    }

    function validLaneValuator(address lane, address valuator, WheelTypes.LaneKind kind, address domainRef)
        external
        view
        returns (bool)
    {
        if (valuator.code.length == 0 || domainRef.code.length == 0) return false;
        (bool okAdapter, uint256 adapter_) = _read(lane, ADAPTER);
        uint256 book = _value(valuator, EXPECTED_ADDRESS_BOOK);
        if (!okAdapter || !_matches(valuator, INTERFACE_VERSION, 2) || !_matches(valuator, EXPECTED_ADAPTER, adapter_))
        {
            return false;
        }
        uint256 expected = kind == WheelTypes.LaneKind.Csp
            ? uint256(IAdapter.StrategyKind.Csp)
            : uint256(IAdapter.StrategyKind.CoveredCall);
        return _matches(valuator, EXPECTED_FUND, uint256(uint160(lane)))
            && _matches(valuator, EXPECTED_STRATEGY_KIND, expected)
            && _matches(valuator, EXPECTED_UNDERLYING, _value(lane, UNDERLYING))
            && _matches(valuator, EXPECTED_SETTLEMENT, _value(lane, SETTLEMENT))
            && _matches(valuator, EXPECTED_POLICY, _value(lane, POLICY))
            && _matches(valuator, EXPECTED_ADDRESS_BOOK, _value(domainRef, EXPECTED_ADDRESS_BOOK))
            && _matches(valuator, SPOT_FEED, _value(domainRef, SPOT_FEED))
            && _matches(valuator, MAX_SPOT_STALENESS, _value(domainRef, MAX_SPOT_STALENESS))
            && _matches(address(uint160(adapter_)), ADDRESS_BOOK, book);
    }

    function _matches(address target, bytes4 selector, uint256 expected) private view returns (bool) {
        (bool ok, uint256 value) = _read(target, selector);
        return ok && value == expected;
    }

    function _matchesWithArgs(address target, bytes4 selector, bytes memory args, uint256 expected)
        private
        view
        returns (bool)
    {
        (bool ok, uint256 value) = _readWithArgs(target, selector, args);
        return ok && value == expected;
    }

    function _freshSpotAvailable(address oracle, address asset) private view returns (bool) {
        (bool ok,) = _freshSpotData(oracle, asset);
        return ok;
    }

    function _freshSpotData(address oracle, address asset) private view returns (bool ok, uint256 price) {
        (bool okAge, uint256 maxAge) = _read(oracle, MAX_ORACLE_AGE);
        (bool okFeed, uint256 feed_) = _readWithArgs(oracle, PRICE_FEED, abi.encode(asset));
        address feed = address(uint160(feed_));
        if (!okAge || maxAge == 0 || maxAge > MAX_ORACLE_STALENESS || !okFeed || feed.code.length == 0) {
            return (false, 0);
        }
        (bool okDecimals, uint256 decimals_) = _read(feed, DECIMALS);
        if (!okDecimals || decimals_ != 8) return (false, 0);
        try IWheelAdapterPriceFeed(feed).latestRoundData() returns (
            uint80 round, int256 answer, uint256, uint256 updated, uint80 answered
        ) {
            if (
                answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > maxAge
                    || answered < round
            ) return (false, 0);
            return (true, uint256(answer));
        } catch {
            return (false, 0);
        }
    }

    function _value(address target, bytes4 selector) private view returns (uint256 value) {
        (bool ok, uint256 readValue) = _read(target, selector);
        if (!ok) return type(uint256).max;
        return readValue;
    }

    function _read(address target, bytes4 selector) private view returns (bool ok, uint256 value) {
        return _readWithArgs(target, selector, "");
    }

    function _readWithArgs(address target, bytes4 selector, bytes memory args)
        private
        view
        returns (bool ok, uint256 value)
    {
        bytes memory data;
        (ok, data) = target.staticcall(abi.encodePacked(selector, args));
        if (!ok || data.length != 32) return (false, 0);
        value = abi.decode(data, (uint256));
    }

    function dispatch(uint8 rawClass, bytes calldata data) external returns (bytes memory result) {
        WheelTypes.ManagedOperationClass operationClass = WheelTypes.ManagedOperationClass(rawClass);
        (WheelTypes.ManagedOperation operation, bytes memory arguments) =
            abi.decode(data, (WheelTypes.ManagedOperation, bytes));
        IWheelCoordinatorManagedActions coordinator = IWheelCoordinatorManagedActions(address(this));

        if (operationClass == WheelTypes.ManagedOperationClass.Allocation) {
            if (operation == WheelTypes.ManagedOperation.OpenCsp) {
                (uint256 trancheId, address lane, bytes memory openData) =
                    abi.decode(arguments, (uint256, address, bytes));
                coordinator.openCspTranche(trancheId, lane, openData);
            } else if (operation == WheelTypes.ManagedOperation.OpenCoveredCall) {
                (uint256 trancheId, address lane, bytes memory openData) =
                    abi.decode(arguments, (uint256, address, bytes));
                coordinator.openCoveredCallTranche(trancheId, lane, openData);
            } else if (operation == WheelTypes.ManagedOperation.SplitPendingCsp) {
                (uint256 trancheId, uint256 amount) = abi.decode(arguments, (uint256, uint256));
                result = abi.encode(coordinator.splitPendingCspTranche(trancheId, amount));
            } else {
                revert InvalidManagedOperation(rawClass, operation);
            }
        } else if (operationClass == WheelTypes.ManagedOperationClass.Processing) {
            if (operation == WheelTypes.ManagedOperation.SettleCsp) {
                coordinator.settleCspTranche(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.HandoffCsp) {
                result = abi.encode(coordinator.handoffCspTranche(abi.decode(arguments, (uint256))));
            } else if (operation == WheelTypes.ManagedOperation.SettleCoveredCall) {
                coordinator.settleCoveredCallTranche(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.HandoffCoveredCall) {
                coordinator.handoffCoveredCallTranche(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.ReserveRedemption) {
                (uint256 trancheId, uint256 amount) = abi.decode(arguments, (uint256, uint256));
                coordinator.reserveRedemptionUsdc(trancheId, amount);
            } else if (operation == WheelTypes.ManagedOperation.ReleaseRedemption) {
                result = abi.encode(coordinator.releaseRedemptionUsdc(abi.decode(arguments, (uint256))));
            } else {
                revert InvalidManagedOperation(rawClass, operation);
            }
        } else if (operationClass == WheelTypes.ManagedOperationClass.Guardian) {
            if (operation != WheelTypes.ManagedOperation.PauseAllocations) {
                revert InvalidManagedOperation(rawClass, operation);
            }
            coordinator.pauseAllocations();
        } else if (operationClass == WheelTypes.ManagedOperationClass.Configuration) {
            if (operation == WheelTypes.ManagedOperation.RegisterLane) {
                (address lane, WheelTypes.LaneKind kind) = abi.decode(arguments, (address, WheelTypes.LaneKind));
                coordinator.registerLane(lane, kind);
            } else if (operation == WheelTypes.ManagedOperation.RemoveLane) {
                coordinator.removeLane(abi.decode(arguments, (address)));
            } else if (operation == WheelTypes.ManagedOperation.SetLaneActive) {
                (address lane, bool active) = abi.decode(arguments, (address, bool));
                coordinator.setLaneActive(lane, active);
            } else if (operation == WheelTypes.ManagedOperation.SetPolicyHash) {
                coordinator.setPolicyHash(abi.decode(arguments, (bytes32)));
            } else if (operation == WheelTypes.ManagedOperation.SetFloorBuffer) {
                coordinator.setFloorBufferUsd8(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.ResumeAllocations) {
                coordinator.resumeAllocations();
            } else if (operation == WheelTypes.ManagedOperation.SetLaneValuator) {
                (address lane, address valuator) = abi.decode(arguments, (address, address));
                coordinator.setLaneValuator(lane, valuator);
            } else {
                revert InvalidManagedOperation(rawClass, operation);
            }
        } else {
            revert InvalidManagedOperation(rawClass, operation);
        }
    }
}
