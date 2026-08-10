// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AddressBook} from "../core/AddressBook.sol";
import {BatchSettler} from "../core/BatchSettler.sol";
import {Controller} from "../core/Controller.sol";
import {MarginPool} from "../core/MarginPool.sol";
import {OToken} from "../core/OToken.sol";
import {Oracle} from "../core/Oracle.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "./interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "./interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";

interface IAssetNeutralFundTotalAssets {
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
    function strategyManager() external view returns (address);
}

interface IAssetNeutralStrategyManagerBinding {
    function fund() external view returns (address);
}

interface IAssetNeutralPriceFeedV2 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Shared hardened execution path for the standalone 8/8/8/6 option adapters.
/// @dev Concrete CSP and covered-call contracts use distinct ERC-7201 namespaces and proxy identities.
abstract contract AssetNeutralOptionsFundAdapterV2 is FundUpgradeable, IOperations {
    using SafeERC20 for IERC20;

    bytes32 internal constant LBTC8_POLICY_HASH = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;
    uint256 internal constant MAX_ORACLE_STALENESS = 1_200;
    bytes32 internal constant INITIAL_POSITIONS_HASH = keccak256("b1nary Asset Neutral Options V2 Positions");

    struct Layout {
        address fund;
        address strategyManager;
        address addressBook;
        address underlying;
        address settlement;
        address swapRouter;
        uint24 swapFeeTier;
        uint64 stateNonce;
        uint256 positionCount;
        uint256 activePositionCount;
        uint256 activeCollateral;
        uint256 accountedSettlement;
        uint256 accountedUnderlying;
        uint256 releasablePrincipal;
        bytes32 positionsHash;
        RiskConfigV2 riskConfig;
        mapping(uint256 => PositionV2) positions;
        mapping(uint256 => uint256) balanceBeforeDelivery;
    }

    struct InitializeParamsV2 {
        address fund;
        address strategyManager;
        address addressBook;
        address underlyingAsset;
        address settlementAsset;
        address swapRouter;
        uint24 swapFeeTier;
        address authority;
        RiskConfigV2 riskConfig;
    }

    constructor() {
        _disableInitializers();
    }

    function _storageLocation() internal pure virtual returns (bytes32);
    function strategyKind() public pure virtual returns (StrategyKind);

    function _layout() internal pure returns (Layout storage $) {
        bytes32 slot = _storageLocation();
        assembly { $.slot := slot }
    }

    function _initialize(InitializeParamsV2 calldata p) internal onlyInitializing {
        if (
            p.fund == address(0) || p.strategyManager == address(0) || p.addressBook == address(0)
                || p.underlyingAsset == address(0) || p.settlementAsset == address(0) || p.swapRouter == address(0)
                || p.fund.code.length == 0 || p.strategyManager.code.length == 0 || p.addressBook.code.length == 0
                || p.underlyingAsset.code.length == 0 || p.settlementAsset.code.length == 0
                || p.swapRouter.code.length == 0 || p.underlyingAsset == p.settlementAsset
        ) revert InvalidAddress();
        if (IERC20Metadata(p.underlyingAsset).decimals() != 8) {
            revert UnsupportedDecimals(p.underlyingAsset, IERC20Metadata(p.underlyingAsset).decimals());
        }
        if (IERC20Metadata(p.settlementAsset).decimals() != 6) {
            revert UnsupportedDecimals(p.settlementAsset, IERC20Metadata(p.settlementAsset).decimals());
        }
        address expectedAccountingAsset = strategyKind() == StrategyKind.Csp ? p.settlementAsset : p.underlyingAsset;
        if (
            IAssetNeutralStrategyManagerBinding(p.strategyManager).fund() != p.fund
                || IAssetNeutralFundTotalAssets(p.fund).strategyManager() != p.strategyManager
                || IAssetNeutralFundTotalAssets(p.fund).asset() != expectedAccountingAsset
        ) revert InvalidAddress();
        _validateRisk(p.riskConfig);
        if (!_feeTier(p.swapFeeTier)) revert InvalidRiskConfig();
        __FundUpgradeable_init(p.authority);
        Layout storage $ = _layout();
        $.fund = p.fund;
        $.strategyManager = p.strategyManager;
        $.addressBook = p.addressBook;
        $.underlying = p.underlyingAsset;
        $.settlement = p.settlementAsset;
        $.swapRouter = p.swapRouter;
        $.swapFeeTier = p.swapFeeTier;
        $.riskConfig = p.riskConfig;
        $.positionsHash = INITIAL_POSITIONS_HASH;
    }

    modifier onlyStrategyManager() {
        if (msg.sender != _layout().strategyManager) revert OnlyStrategyManager();
        _;
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

    function strategyManager() external view returns (address) {
        return _layout().strategyManager;
    }

    function addressBook() external view returns (address) {
        return _layout().addressBook;
    }

    function accountingAsset() external view returns (address) {
        return strategyKind() == StrategyKind.Csp ? _layout().settlement : _layout().underlying;
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

    function adapterConfigV2() external view returns (AdapterConfigV2 memory) {
        Layout storage $ = _layout();
        return AdapterConfigV2($.riskConfig, $.swapRouter, $.swapFeeTier);
    }

    function adapterStateV2() external view returns (AdapterStateV2 memory) {
        Layout storage $ = _layout();
        return AdapterStateV2(
            $.stateNonce,
            $.positionsHash,
            $.positionCount,
            $.activePositionCount,
            $.activeCollateral,
            $.accountedSettlement,
            $.accountedUnderlying
        );
    }

    function positionV2(uint256 id) external view returns (PositionV2 memory) {
        return _layout().positions[id];
    }

    function positionStateHash() public view returns (bytes32) {
        Layout storage $ = _layout();
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                $.fund,
                $.stateNonce,
                $.positionsHash,
                $.activePositionCount,
                $.activeCollateral,
                $.accountedSettlement,
                $.accountedUnderlying,
                IERC20($.settlement).balanceOf(address(this)),
                IERC20($.underlying).balanceOf(address(this))
            )
        );
    }

    function freeAssets(address asset) external view returns (uint256) {
        Layout storage $ = _layout();
        if (asset == $.settlement) return Math.min($.accountedSettlement, IERC20(asset).balanceOf(address(this)));
        if (asset == $.underlying) return Math.min($.accountedUnderlying, IERC20(asset).balanceOf(address(this)));
        return 0;
    }

    function setAdapterConfigV2(RiskConfigV2 calldata risk, address router, uint24 tier) external restricted {
        _validateRisk(risk);
        if (router == address(0) || router.code.length == 0 || !_feeTier(tier)) revert InvalidAddress();
        Layout storage $ = _layout();
        $.riskConfig = risk;
        $.swapRouter = router;
        $.swapFeeTier = tier;
        emit AdapterConfigUpdatedV2(risk, router, tier);
    }

    function isOnboarded() public view returns (bool) {
        Layout storage $ = _layout();
        AddressBook b = AddressBook($.addressBook);
        address c = b.controller();
        address s = b.batchSettler();
        address p = b.marginPool();
        address f = b.oTokenFactory();
        address o = b.oracle();
        address w = b.whitelist();
        if (
            c.code.length == 0 || s.code.length == 0 || p.code.length == 0 || f.code.length == 0 || o.code.length == 0
                || w.code.length == 0 || $.swapRouter.code.length == 0
        ) return false;
        if (
            !_addressEq(c, bytes4(keccak256("addressBook()")), "", $.addressBook)
                || !_addressEq(s, bytes4(keccak256("addressBook()")), "", $.addressBook)
                || !_addressEq(p, bytes4(keccak256("addressBook()")), "", $.addressBook)
                || !_addressEq(f, bytes4(keccak256("addressBook()")), "", $.addressBook)
                || !_addressEq(o, bytes4(keccak256("addressBook()")), "", $.addressBook)
        ) return false;
        if (!_bool(c, bytes4(keccak256("custodiedRedemptionOnly()")), "")) return false;
        if (!_bool(s, bytes4(keccak256("authorizedPhysicalDeliveryVault(address)")), abi.encode(address(this)))) {
            return false;
        }
        if (!_addressEq(s, bytes4(keccak256("swapRouter()")), "", $.swapRouter)) return false;
        uint24 settlerTier = BatchSettler(s).assetSwapFeeTier($.underlying);
        if (settlerTier == 0) settlerTier = BatchSettler(s).swapFeeTier();
        if (settlerTier != $.swapFeeTier) return false;
        if (!_freshSpotAvailable(o, $.underlying)) return false;
        if (!_bool(w, bytes4(keccak256("isWhitelistedUnderlying(address)")), abi.encode($.underlying))) return false;
        address collateral = strategyKind() == StrategyKind.Csp ? $.settlement : $.underlying;
        if (!_bool(w, bytes4(keccak256("isWhitelistedCollateral(address)")), abi.encode(collateral))) return false;
        return _bool(
            w,
            bytes4(keccak256("isProductWhitelisted(address,address,address,bool)")),
            abi.encode($.underlying, $.settlement, collateral, strategyKind() == StrategyKind.Csp)
        );
    }

    function allocate(address asset, uint256 amount, bytes calldata data) external virtual onlyStrategyManager {
        Layout storage $ = _layout();
        _noDeficit($);
        if (!isOnboarded()) revert AdapterNotOnboarded();
        address collateralAsset = strategyKind() == StrategyKind.Csp ? $.settlement : $.underlying;
        if (asset != collateralAsset || amount == 0) revert InvalidAmount();
        OpenPositionDataV2 memory d = abi.decode(data, (OpenPositionDataV2));
        if (
            d.optionAmount8 == 0 || d.collateralAmount != amount
                || $.activePositionCount >= $.riskConfig.maxOpenPositions
        ) revert InvalidAmount();
        OToken ot = OToken(d.quote.oToken);
        if (
            d.quote.oToken == address(0) || ot.decimals() != 8 || ot.underlying() != $.underlying
                || ot.strikeAsset() != $.settlement || ot.collateralAsset() != collateralAsset
                || ot.isPut() != (strategyKind() == StrategyKind.Csp)
        ) revert InvalidSeries(d.quote.oToken);
        uint256 delay = ot.expiry() > block.timestamp ? ot.expiry() - block.timestamp : 0;
        if (
            delay < $.riskConfig.minExpiryDelay || delay > $.riskConfig.maxExpiryDelay
                || ot.strikePrice() < $.riskConfig.minStrikeUsd8 || ot.strikePrice() > $.riskConfig.maxStrikeUsd8
                || amount > $.riskConfig.maxCollateralPerPosition
        ) revert InvalidRiskConfig();
        uint256 required = strategyKind() == StrategyKind.Csp
            ? Math.mulDiv(d.optionAmount8, ot.strikePrice(), 1e10, Math.Rounding.Ceil)
            : d.optionAmount8;
        if (amount != required) revert InvalidAmount();
        if (strategyKind() == StrategyKind.CoveredCall) {
            if ($.riskConfig.protectedBasisUsd8 != 0 && ot.strikePrice() < $.riskConfig.protectedBasisUsd8) {
                revert InvalidRiskConfig();
            }
            if (
                $.accountedSettlement != 0
                    || $.activeCollateral + amount
                        > Math.mulDiv(
                            IAssetNeutralFundTotalAssets($.fund).totalAssets(),
                            $.riskConfig.maxUtilizationBps,
                            FundConstants.BPS
                        )
            ) revert InvalidRiskConfig();
        }
        IERC20 collateral = IERC20(collateralAsset);
        IERC20 premium = IERC20($.settlement);
        AddressBook b = AddressBook($.addressBook);
        uint256 freshSpot = _freshSpot(b.oracle(), $.underlying);
        Controller controller = Controller(b.controller());
        BatchSettler settler = BatchSettler(b.batchSettler());
        MarginPool pool = MarginPool(b.marginPool());
        uint256 vaultExpected = controller.vaultCount(address(this)) + 1;
        uint256 cb = collateral.balanceOf(address(this));
        uint256 pb = premium.balanceOf(address(this));
        uint256 mb = pool.getStoredBalance(collateralAsset);
        if (strategyKind() == StrategyKind.Csp) $.accountedSettlement += amount;
        else $.accountedUnderlying += amount;
        collateral.forceApprove(address(pool), amount);
        uint256 vaultId = settler.executeOrder(d.quote, d.signature, d.optionAmount8, amount);
        collateral.forceApprove(address(pool), 0);
        uint256 ca = collateral.balanceOf(address(this));
        uint256 pa = premium.balanceOf(address(this));
        uint256 ma = pool.getStoredBalance(collateralAsset);
        if (vaultId != vaultExpected || ma < mb || ma - mb != amount) revert LedgerMismatch(0);
        uint256 earned;
        if (strategyKind() == StrategyKind.Csp) {
            if (cb != pb || ca != pa) revert LedgerMismatch(0);
            earned = _cspPremiumEarned(cb, ca, amount);
            $.accountedSettlement = $.accountedSettlement - amount + earned;
        } else {
            if (cb < ca || cb - ca != amount || pa < pb) revert LedgerMismatch(0);
            earned = pa - pb;
            $.accountedUnderlying -= amount;
            $.accountedSettlement += earned;
        }
        uint256 premiumBase = strategyKind() == StrategyKind.Csp ? amount : Math.mulDiv(amount, freshSpot, 1e10);
        if (earned == 0 || earned * FundConstants.BPS < premiumBase * $.riskConfig.minPremiumBps) {
            revert InvalidRiskConfig();
        }
        settler.reservePhysicalDelivery(vaultId);
        address mm = settler.vaultMM(address(this), vaultId);
        if (mm == address(0)) revert LedgerMismatch(0);
        uint256 id = ++$.positionCount;
        PositionV2 storage pos = $.positions[id];
        pos.strategyKind = strategyKind();
        pos.lifecycle = Lifecycle.Open;
        pos.oToken = d.quote.oToken;
        pos.marketMaker = mm;
        pos.collateralAsset = collateralAsset;
        pos.protocolVaultId = vaultId;
        pos.optionAmount8 = d.optionAmount8;
        pos.collateralAmount = amount;
        pos.premiumSettlementAmount = earned;
        pos.strikePriceUsd8 = ot.strikePrice();
        pos.openedAt = uint64(block.timestamp);
        ++$.activePositionCount;
        $.activeCollateral += amount;
        _checkpoint($, id, pos);
        emit AssetNeutralPositionOpenedV2(
            id,
            vaultId,
            pos.oToken,
            pos.strategyKind,
            $.underlying,
            $.settlement,
            collateralAsset,
            mm,
            d.optionAmount8,
            amount,
            earned,
            pos.strikePriceUsd8,
            pos.lifecycleHash
        );
    }

    function deallocate(uint256 targetValue, uint256 minimum, bytes calldata data)
        external
        onlyStrategyManager
        returns (uint256 out, uint256 principalReleased)
    {
        Layout storage $ = _layout();
        _noDeficit($);
        if (targetValue == 0) revert InvalidAmount();
        DeallocateDataV2 memory d = abi.decode(data, (DeallocateDataV2));
        if (d.action == DeallocateAction.ReturnIdle) {
            if (($.activePositionCount != 0 && $.releasablePrincipal == 0) || targetValue > _accountedPrimary($)) {
                revert InvalidAmount();
            }
            _global($, keccak256(abi.encode("RETURN_IDLE", targetValue)));
        } else if (d.action == DeallocateAction.Settle) {
            _settle($, d.positionId);
        } else if (d.action == DeallocateAction.Normalize) {
            if ($.activePositionCount != 0) revert InvalidRiskConfig();
            _normalize($, d.amount, d.minAmountOut);
        } else {
            revert InvalidAmount();
        }
        address primary = strategyKind() == StrategyKind.Csp ? $.settlement : $.underlying;
        bool principalReleaseReady =
            strategyKind() == StrategyKind.Csp ? $.accountedUnderlying == 0 : $.accountedSettlement == 0;
        uint256 available = Math.min(_accountedPrimary($), IERC20(primary).balanceOf(address(this)));
        if (principalReleaseReady) {
            // A terminal position releases the exact collateral principal recorded by _close. Returning only a
            // caller-selected target while consuming only that target would let StrategyManager compare a loss
            // against an understated principal amount. Return all currently liquid accounting assets and consume
            // every terminal principal lot; collateral for any still-open position remains locked and allocated.
            if ($.releasablePrincipal != 0) {
                out = available;
                principalReleased = $.releasablePrincipal;
                $.releasablePrincipal = 0;
            } else {
                out = Math.min(targetValue, available);
            }
        }
        if (out < minimum) revert SlippageExceeded(minimum, out);
        if (out != 0) {
            _debitPrimary($, out);
            IERC20(primary).safeTransfer($.fund, out);
            emit AccountingAssetsReturnedV2(primary, out);
        }
    }

    function _settle(Layout storage $, uint256 id) private {
        PositionV2 storage p = $.positions[id];
        if (p.protocolVaultId == 0) revert InvalidPosition(id);
        AddressBook b = AddressBook($.addressBook);
        BatchSettler s = BatchSettler(b.batchSettler());
        OToken ot = OToken(p.oToken);
        if (p.lifecycle == Lifecycle.Open) {
            if (block.timestamp < ot.expiry()) revert SettlementNotReady(id);
            Controller c = Controller(b.controller());
            address collateral = p.collateralAsset;
            uint256 before_ = IERC20(collateral).balanceOf(address(this));
            c.settleVault(address(this), p.protocolVaultId);
            uint256 after_ = IERC20(collateral).balanceOf(address(this));
            if (after_ < before_) revert LedgerMismatch(id);
            uint256 returned = after_ - before_;
            if (returned > p.collateralAmount) revert LedgerMismatch(id);
            p.collateralReturnedAmount = returned;
            (uint256 expiry, bool set) = Oracle(b.oracle()).getExpiryPrice($.underlying, ot.expiry());
            if (!set) revert SettlementNotReady(id);
            bool otm = strategyKind() == StrategyKind.Csp ? expiry >= p.strikePriceUsd8 : expiry <= p.strikePriceUsd8;
            if (otm) {
                if (returned != p.collateralAmount) revert LedgerMismatch(id);
                _creditCollateral($, returned);
                if (s.settleReservedPhysicalDelivery(p.protocolVaultId, p.marketMaker, 0) != 0) {
                    revert LedgerMismatch(id);
                }
                p.lifecycle = Lifecycle.SettledOtm;
                _close($, p);
                _terminal($, id, p);
                _checkpoint($, id, p);
                _emitTransition($, id, p, returned, 0, 0);
                return;
            }
            if (strategyKind() == StrategyKind.CoveredCall && returned != 0) revert LedgerMismatch(id);
            if (strategyKind() == StrategyKind.Csp) _creditCollateral($, returned);
            s.releasePhysicalDelivery(p.protocolVaultId);
            $.balanceBeforeDelivery[id] =
                IERC20(strategyKind() == StrategyKind.Csp ? $.underlying : $.settlement).balanceOf(address(this));
            p.fallbackEligibleAt = uint64(block.timestamp + $.riskConfig.settlementDefaultDelay);
            p.lifecycle = Lifecycle.AwaitingPhysicalDelivery;
            _checkpoint($, id, p);
            _emitTransition($, id, p, returned, 0, 0);
            return;
        }
        if (p.lifecycle != Lifecycle.AwaitingPhysicalDelivery) revert InvalidLifecycle(id, p.lifecycle);
        uint256 remaining = s.vaultOTokenBalance(address(this), p.protocolVaultId);
        if (remaining == 0) {
            if (s.physicalDeliveryReservedVault(address(this), p.protocolVaultId)) revert LedgerMismatch(id);
            address received = strategyKind() == StrategyKind.Csp ? $.underlying : $.settlement;
            uint256 bal = IERC20(received).balanceOf(address(this));
            uint256 old = $.balanceBeforeDelivery[id];
            if (bal < old) revert LedgerMismatch(id);
            uint256 observed = bal - old;
            uint256 expected = strategyKind() == StrategyKind.Csp
                ? p.optionAmount8
                : Math.mulDiv(p.optionAmount8, p.strikePriceUsd8, 1e10);
            if (observed < expected) revert LedgerMismatch(id);
            if (strategyKind() == StrategyKind.Csp) {
                $.accountedUnderlying += expected;
                p.assignedUnderlyingAmount = expected;
                p.lifecycle = Lifecycle.AssignedUnderlying;
            } else {
                $.accountedSettlement += expected;
                p.calledAwaySettlementAmount = expected;
                p.lifecycle = Lifecycle.CalledAwaySettlement;
            }
            _close($, p);
            _terminal($, id, p);
            _checkpoint($, id, p);
            if (observed > expected) {
                emit AssetNeutralDustIsolatedV2(
                    received, id, observed - expected, keccak256("EXCESS_PHYSICAL_DELIVERY")
                );
            }
            _emitTransition(
                $,
                id,
                p,
                0,
                strategyKind() == StrategyKind.Csp ? expected : 0,
                strategyKind() == StrategyKind.Csp ? 0 : expected
            );
            return;
        }
        if (block.timestamp < p.fallbackEligibleAt) revert SettlementNotReady(id);
        if (!s.physicalDeliveryReservedVault(address(this), p.protocolVaultId)) {
            s.reservePhysicalDelivery(p.protocolVaultId);
        }
        if (strategyKind() == StrategyKind.Csp) {
            uint256 gross = Math.mulDiv(p.optionAmount8, p.strikePriceUsd8, 1e10);
            (uint256 expiry, bool set) = Oracle(b.oracle()).getExpiryPrice($.underlying, ot.expiry());
            if (!set || expiry >= p.strikePriceUsd8) revert SettlementNotReady(id);
            uint256 mm = Math.mulDiv(p.optionAmount8, p.strikePriceUsd8 - expiry, 1e10);
            uint256 before_ = IERC20($.settlement).balanceOf(address(this));
            uint256 paid = s.settleReservedPhysicalDelivery(p.protocolVaultId, address(this), gross);
            uint256 observed = IERC20($.settlement).balanceOf(address(this)) - before_;
            if (paid != gross || observed != gross || mm > gross) revert LedgerMismatch(id);
            $.accountedSettlement += gross - mm;
            if (mm != 0) IERC20($.settlement).safeTransfer(p.marketMaker, mm);
            p.lifecycle = Lifecycle.CashFallback;
        } else {
            (uint256 expiry, bool set) = Oracle(b.oracle()).getExpiryPrice($.underlying, ot.expiry());
            if (!set || expiry <= p.strikePriceUsd8) revert SettlementNotReady(id);
            uint256 before_ = IERC20($.underlying).balanceOf(address(this));
            uint256 paid = s.settleReservedPhysicalDelivery(p.protocolVaultId, address(this), p.collateralAmount);
            uint256 observed = IERC20($.underlying).balanceOf(address(this)) - before_;
            uint256 mm = Math.mulDiv(p.collateralAmount, expiry - p.strikePriceUsd8, expiry, Math.Rounding.Ceil);
            if (paid != p.collateralAmount || observed != paid || mm > paid) revert LedgerMismatch(id);
            $.accountedUnderlying += paid - mm;
            if (mm != 0) IERC20($.underlying).safeTransfer(p.marketMaker, mm);
            p.fallbackUnderlyingRecoveredAmount = paid - mm;
            p.marketMakerUnderlyingPayoutAmount = mm;
            p.lifecycle = Lifecycle.CashFallback;
        }
        _close($, p);
        _terminal($, id, p);
        _checkpoint($, id, p);
        _emitTransition($, id, p, 0, 0, 0);
    }

    function _normalize(Layout storage $, uint256 amount, uint256 minOut) private {
        if (amount == 0 || amount > $.riskConfig.maxNormalizationInput) revert InvalidAmount();
        address input = strategyKind() == StrategyKind.Csp ? $.underlying : $.settlement;
        address output = strategyKind() == StrategyKind.Csp ? $.settlement : $.underlying;
        uint256 accounted = strategyKind() == StrategyKind.Csp ? $.accountedUnderlying : $.accountedSettlement;
        if (amount > accounted) revert InvalidAmount();
        uint256 spot = _freshSpot(AddressBook($.addressBook).oracle(), $.underlying);
        uint256 fair =
            strategyKind() == StrategyKind.Csp ? Math.mulDiv(amount, spot, 1e10) : Math.mulDiv(amount, 1e10, spot);
        uint256 floor = Math.mulDiv(fair, FundConstants.BPS - $.riskConfig.maxSwapSlippageBps, FundConstants.BPS);
        if (minOut < floor) revert SlippageExceeded(floor, minOut);
        IERC20 a = IERC20(input);
        IERC20 z = IERC20(output);
        uint256 ab = a.balanceOf(address(this));
        uint256 zb = z.balanceOf(address(this));
        a.forceApprove($.swapRouter, amount);
        uint256 quoted = ISwapRouter($.swapRouter)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams(input, output, $.swapFeeTier, address(this), amount, minOut, 0)
            );
        a.forceApprove($.swapRouter, 0);
        uint256 used = ab - a.balanceOf(address(this));
        uint256 got = z.balanceOf(address(this)) - zb;
        if (used != amount || got != quoted || got < minOut) revert SlippageExceeded(minOut, got);
        if (strategyKind() == StrategyKind.Csp) {
            $.accountedUnderlying -= used;
            $.accountedSettlement += got;
        } else {
            $.accountedSettlement -= used;
            $.accountedUnderlying += got;
        }
        _global($, keccak256(abi.encode("NORMALIZE", input, output, used, got)));
        emit AssetNeutralAssetsNormalizedV2(input, output, used, got);
    }

    function deallocateInKind(uint256 fraction, address escrow, bytes calldata)
        external
        onlyStrategyManager
        returns (address[] memory assets, uint256[] memory amounts)
    {
        if (fraction == 0 || fraction > FundConstants.WAD || escrow == address(0) || _layout().activePositionCount != 0)
        {
            revert InvalidAmount();
        }
        return _recover(fraction, escrow, false);
    }

    function emergencyExit(address escrow, bytes calldata)
        external
        onlyStrategyManager
        returns (address[] memory assets, uint256[] memory amounts)
    {
        if (escrow == address(0) || _layout().activePositionCount != 0) revert InvalidAmount();
        return _recover(FundConstants.WAD, escrow, true);
    }

    function _recover(uint256 fraction, address escrow, bool emergency)
        private
        returns (address[] memory assets, uint256[] memory amounts)
    {
        Layout storage $ = _layout();
        _noDeficit($);
        assets = new address[](2);
        amounts = new uint256[](2);
        assets[0] = $.settlement;
        assets[1] = $.underlying;
        amounts[0] = Math.mulDiv($.accountedSettlement, fraction, FundConstants.WAD);
        amounts[1] = Math.mulDiv($.accountedUnderlying, fraction, FundConstants.WAD);
        $.accountedSettlement -= amounts[0];
        $.accountedUnderlying -= amounts[1];
        _global($, keccak256(abi.encode("RECOVER", fraction, escrow, amounts)));
        if (amounts[0] != 0) IERC20(assets[0]).safeTransfer(escrow, amounts[0]);
        if (amounts[1] != 0) IERC20(assets[1]).safeTransfer(escrow, amounts[1]);
        emit RawAssetsRecoveredV2(escrow, assets, amounts, emergency);
    }

    function _close(Layout storage $, PositionV2 storage p) private {
        if ($.activePositionCount == 0 || $.activeCollateral < p.collateralAmount) {
            revert LedgerMismatch(p.protocolVaultId);
        }
        --$.activePositionCount;
        $.activeCollateral -= p.collateralAmount;
        $.releasablePrincipal += p.collateralAmount;
    }

    function _terminal(Layout storage $, uint256 id, PositionV2 storage p) private view {
        AddressBook b = AddressBook($.addressBook);
        BatchSettler s = BatchSettler(b.batchSettler());
        if (
            !Controller(b.controller()).vaultSettled(address(this), p.protocolVaultId)
                || s.vaultOTokenBalance(address(this), p.protocolVaultId) != 0
                || s.physicalDeliveryReservedVault(address(this), p.protocolVaultId)
        ) revert LedgerMismatch(id);
    }

    function _creditCollateral(Layout storage $, uint256 v) private {
        if (strategyKind() == StrategyKind.Csp) $.accountedSettlement += v;
        else $.accountedUnderlying += v;
    }

    function _accountedPrimary(Layout storage $) private view returns (uint256) {
        return strategyKind() == StrategyKind.Csp ? $.accountedSettlement : $.accountedUnderlying;
    }

    function _debitPrimary(Layout storage $, uint256 v) private {
        if (strategyKind() == StrategyKind.Csp) $.accountedSettlement -= v;
        else $.accountedUnderlying -= v;
    }

    function _noDeficit(Layout storage $) private view {
        uint256 s = IERC20($.settlement).balanceOf(address(this));
        uint256 u = IERC20($.underlying).balanceOf(address(this));
        if (s < $.accountedSettlement) revert AccountingDeficit($.settlement, $.accountedSettlement, s);
        if (u < $.accountedUnderlying) revert AccountingDeficit($.underlying, $.accountedUnderlying, u);
    }

    function _checkpoint(Layout storage $, uint256 id, PositionV2 storage p) private {
        uint64 n = ++$.stateNonce;
        p.lifecycleHash = keccak256(abi.encode(p.lifecycleHash, n, id, p));
        $.positionsHash = keccak256(abi.encode($.positionsHash, n, id, p.lifecycleHash));
    }

    function _global(Layout storage $, bytes32 h) private {
        uint64 n = ++$.stateNonce;
        $.positionsHash = keccak256(abi.encode($.positionsHash, n, h));
    }

    function _emitTransition(
        Layout storage $,
        uint256 id,
        PositionV2 storage p,
        uint256 collateral,
        uint256 underlying,
        uint256 settlement
    ) private {
        emit AssetNeutralPositionTransitionedV2(
            id,
            p.protocolVaultId,
            p.lifecycle,
            collateral,
            underlying,
            settlement,
            p.marketMakerUnderlyingPayoutAmount,
            p.lifecycleHash
        );
    }

    function _validateRisk(RiskConfigV2 memory r) private pure {
        if (
            r.minExpiryDelay == 0 || r.maxExpiryDelay < r.minExpiryDelay || r.settlementDefaultDelay == 0
                || r.minPremiumBps > FundConstants.BPS || r.maxSwapSlippageBps > FundConstants.BPS
                || r.maxOpenPositions == 0 || r.maxUtilizationBps == 0 || r.maxUtilizationBps > FundConstants.BPS
                || r.maxStrikeUsd8 < r.minStrikeUsd8 || r.maxCollateralPerPosition == 0 || r.maxNormalizationInput == 0
        ) revert InvalidRiskConfig();
    }

    function _cspPremiumEarned(uint256 balanceBefore, uint256 balanceAfter, uint256 collateral)
        internal
        pure
        returns (uint256 earned)
    {
        if (balanceAfter > type(uint256).max - collateral || balanceAfter + collateral < balanceBefore) {
            revert LedgerMismatch(0);
        }
        earned = balanceAfter + collateral - balanceBefore;
    }

    function _feeTier(uint24 x) private pure returns (bool) {
        return x == 100 || x == 500 || x == 3000 || x == 10000;
    }

    function _freshSpotAvailable(address oracleAddress, address asset) private view returns (bool) {
        (bool ok,) = address(this).staticcall(abi.encodeCall(this.validateFreshSpotV2, (oracleAddress, asset)));
        return ok;
    }

    function validateFreshSpotV2(address oracleAddress, address asset) external view returns (uint256) {
        return _freshSpot(oracleAddress, asset);
    }

    function _freshSpot(address oracleAddress, address asset) private view returns (uint256 price) {
        Oracle oracle = Oracle(oracleAddress);
        uint256 maxAge = oracle.maxOracleStaleness();
        if (maxAge == 0 || maxAge > MAX_ORACLE_STALENESS) revert InvalidRiskConfig();
        address feed = oracle.priceFeed(asset);
        if (feed == address(0) || feed.code.length == 0 || IAssetNeutralPriceFeedV2(feed).decimals() != 8) {
            revert InvalidRiskConfig();
        }
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) =
            IAssetNeutralPriceFeedV2(feed).latestRoundData();
        if (
            answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > maxAge
                || answered < round
        ) {
            revert InvalidRiskConfig();
        }
        price = uint256(answer);
    }

    function _bool(address t, bytes4 sel, bytes memory args) private view returns (bool) {
        (bool ok, bytes memory r) = t.staticcall(abi.encodePacked(sel, args));
        return ok && r.length >= 32 && abi.decode(r, (uint256)) == 1;
    }

    function _addressEq(address t, bytes4 sel, bytes memory args, address expected) private view returns (bool) {
        (bool ok, bytes memory r) = t.staticcall(abi.encodePacked(sel, args));
        return ok && r.length >= 32 && abi.decode(r, (address)) == expected;
    }
}

contract AssetNeutralCspFundAdapterV2 is AssetNeutralOptionsFundAdapterV2 {
    bytes32 private constant SLOT = 0x9591e324b6bef4f293bf5b406270137e316bf81c5dc4459c5dff3f5d92b0e500;

    function initialize(InitializeParamsV2 calldata p) external initializer {
        _initialize(p);
    }

    function _storageLocation() internal pure override returns (bytes32) {
        return SLOT;
    }

    function strategyKind() public pure override returns (StrategyKind) {
        return StrategyKind.Csp;
    }
}

contract AssetNeutralCoveredCallFundAdapterV2 is AssetNeutralOptionsFundAdapterV2 {
    bytes32 private constant SLOT = 0xb56377e01ba7390bcdce9ef7c884367de0dad4bbdc8649f6c3222c65bccb4300;

    function initialize(InitializeParamsV2 calldata p) external initializer {
        _initialize(p);
    }

    function _storageLocation() internal pure override returns (bytes32) {
        return SLOT;
    }

    function strategyKind() public pure override returns (StrategyKind) {
        return StrategyKind.CoveredCall;
    }
}
