// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AddressBook} from "../core/AddressBook.sol";
import {OToken} from "../core/OToken.sol";
import {Oracle} from "../core/Oracle.sol";
import {FundTypes} from "./FundTypes.sol";
import {IPositionValuator} from "./interfaces/IPositionValuator.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "./interfaces/IAssetNeutralOptionsAdapterV2.sol";

interface IAssetNeutralSpotFeedV2 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IAssetNeutralAdapterStateHashV2 {
    function positionStateHash() external view returns (bytes32);
    function addressBook() external view returns (address);
    function fund() external view returns (address);
}

/// @notice Conservative 8/8/8/6 NAV policy for standalone asset-neutral option adapters.
/// @dev Pre-expiry liabilities require unique, current, state-bound observer marks and fail closed without quorum.
abstract contract AssetNeutralOptionsFundValuatorV2 is IPositionValuator {
    using ECDSA for bytes32;
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant OBSERVATION_TYPEHASH = keccak256(
        "Observation(address adapter,bytes32 stateHash,uint256 positionId,uint256 liability,uint256 baseExitCost,uint64 snapshotBlock,uint64 validUntilBlock,uint256 nonce)"
    );
    bytes32 private constant NAME_HASH = keccak256("b1nary Asset Neutral Options Valuator V2");
    bytes32 private constant VERSION_HASH = keccak256("2");

    struct Observation {
        uint256 positionId;
        uint256 liability;
        uint256 baseExitCost;
        uint64 snapshotBlock;
        uint64 validUntilBlock;
        uint256 nonce;
        bytes signature;
    }

    struct ValuationData {
        Observation[] observations;
    }

    address public immutable spotFeed;
    address public immutable expectedAdapter;
    address public immutable expectedFund;
    address public immutable expectedAddressBook;
    address public immutable expectedUnderlying;
    address public immutable expectedSettlement;
    bytes32 public immutable expectedPolicyHash;
    uint8 public immutable spotFeedDecimals;
    uint64 public immutable maxSpotStaleness;
    uint64 public immutable maxObservationWindow;
    uint8 public immutable observationQuorum;
    mapping(address => bool) public isApprovedObserver;

    error InvalidAdapter(address adapter);
    error InvalidSnapshotBlock(uint64 expected, uint64 actual);
    error InvalidSpotObservation();
    error InvalidObservation(uint256 positionId);
    error DuplicateObserver(address observer);
    error InsufficientObservationQuorum(uint256 positionId, uint256 required, uint256 actual);
    error AccountingDeficit(address asset, uint256 accounted, uint256 actual);
    error ExpiryPriceUnavailable(uint256 positionId, uint256 expiry);

    constructor(
        address feed,
        uint64 stale,
        uint64 window,
        uint8 quorum,
        address[] memory observers,
        address adapter,
        address fund_,
        address addressBook_,
        address underlying,
        address settlement,
        bytes32 policyHash_
    ) {
        if (
            feed == address(0) || feed.code.length == 0 || stale == 0 || stale > 1_200 || window == 0 || quorum < 2
                || quorum > observers.length || adapter == address(0) || fund_ == address(0)
                || addressBook_ == address(0) || underlying == address(0) || settlement == address(0)
                || policyHash_ == bytes32(0)
        ) revert InvalidSpotObservation();
        uint8 decimals = IAssetNeutralSpotFeedV2(feed).decimals();
        if (decimals != 8) revert InvalidSpotObservation();
        spotFeed = feed;
        expectedAdapter = adapter;
        expectedFund = fund_;
        expectedAddressBook = addressBook_;
        expectedUnderlying = underlying;
        expectedSettlement = settlement;
        expectedPolicyHash = policyHash_;
        spotFeedDecimals = decimals;
        maxSpotStaleness = stale;
        maxObservationWindow = window;
        observationQuorum = quorum;
        for (uint256 i; i < observers.length; ++i) {
            if (observers[i] == address(0) || isApprovedObserver[observers[i]]) revert DuplicateObserver(observers[i]);
            isApprovedObserver[observers[i]] = true;
        }
    }

    function expectedStrategyKind() public pure virtual returns (IAdapter.StrategyKind);

    function interfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function observationDigest(
        address adapter,
        uint256 id,
        uint256 liability,
        uint256 cost,
        uint64 snapshot,
        uint64 valid,
        uint256 nonce
    ) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        OBSERVATION_TYPEHASH,
                        adapter,
                        IAssetNeutralAdapterStateHashV2(adapter).positionStateHash(),
                        id,
                        liability,
                        cost,
                        snapshot,
                        valid,
                        nonce
                    )
                )
            )
        );
    }

    function value(address adapter, uint64 snapshotBlock, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory v)
    {
        if (adapter != expectedAdapter || adapter.code.length == 0) revert InvalidAdapter(adapter);
        if (snapshotBlock != block.number) revert InvalidSnapshotBlock(uint64(block.number), snapshotBlock);
        IAdapter a = IAdapter(adapter);
        if (
            a.interfaceVersion() != 2 || a.strategyKind() != expectedStrategyKind()
                || IAssetNeutralAdapterStateHashV2(adapter).fund() != expectedFund
                || a.underlyingAsset() != expectedUnderlying || a.settlementAsset() != expectedSettlement
                || a.policyHash() != expectedPolicyHash
                || IAssetNeutralAdapterStateHashV2(adapter).addressBook() != expectedAddressBook
        ) revert InvalidAdapter(adapter);
        IAdapter.AssetConfigV2 memory cfg = a.assetConfigV2();
        if (
            cfg.underlyingAsset != expectedUnderlying || cfg.settlementAsset != expectedSettlement
                || cfg.oTokenDecimals != 8 || cfg.underlyingDecimals != 8 || cfg.priceDecimals != 8
                || cfg.settlementDecimals != 6
        ) revert InvalidAdapter(adapter);
        Oracle boundOracle = Oracle(AddressBook(expectedAddressBook).oracle());
        uint256 oracleAge = boundOracle.maxOracleStaleness();
        if (boundOracle.priceFeed(expectedUnderlying) != spotFeed || oracleAge == 0) {
            revert InvalidSpotObservation();
        }
        uint256 effectiveMaxAge = Math.min(oracleAge, uint256(maxSpotStaleness));
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) =
            IAssetNeutralSpotFeedV2(spotFeed).latestRoundData();
        if (
            answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > effectiveMaxAge
                || answered < round
        ) {
            revert InvalidSpotObservation();
        }
        uint256 spot = uint256(answer);
        IAdapter.AdapterStateV2 memory state = a.adapterStateV2();
        uint256 rawS = IERC20(cfg.settlementAsset).balanceOf(adapter);
        uint256 rawU = IERC20(cfg.underlyingAsset).balanceOf(adapter);
        if (rawS < state.accountedSettlementAmount) {
            revert AccountingDeficit(cfg.settlementAsset, state.accountedSettlementAmount, rawS);
        }
        if (rawU < state.accountedUnderlyingAmount) {
            revert AccountingDeficit(cfg.underlyingAsset, state.accountedUnderlyingAmount, rawU);
        }
        bool csp = expectedStrategyKind() == IAdapter.StrategyKind.Csp;
        v.grossAssets = csp
            ? state.accountedSettlementAmount + Math.mulDiv(state.accountedUnderlyingAmount, spot, 1e10)
            : state.accountedUnderlyingAmount + Math.mulDiv(state.accountedSettlementAmount, 1e10, spot);
        if (state.activePositionCount == 0) {
            v.liquidAccountingAssets = csp ? state.accountedSettlementAmount : state.accountedUnderlyingAmount;
        }
        ValuationData memory marks = abi.decode(data, (ValuationData));
        uint256 used;
        uint256 activeCollateral;
        for (uint256 index; index < state.activePositionCount; ++index) {
            uint256 id = a.activePositionIdAt(index);
            if (id == 0 || id > state.positionCount) revert InvalidObservation(id);
            IAdapter.PositionV2 memory p = a.positionV2(id);
            activeCollateral += p.collateralAmount;
            if (p.lifecycle == IAdapter.Lifecycle.Open) {
                v.grossAssets += p.collateralAmount;
                if (block.timestamp >= OToken(p.oToken).expiry()) {
                    (uint256 expiry, bool set) = Oracle(
                            AddressBook(IAssetNeutralAdapterStateHashV2(adapter).addressBook()).oracle()
                        ).getExpiryPrice(cfg.underlyingAsset, OToken(p.oToken).expiry());
                    if (!set) revert ExpiryPriceUnavailable(id, OToken(p.oToken).expiry());
                    if (csp && expiry < p.strikePriceUsd8) {
                        v.liabilities += Math.mulDiv(
                            p.optionAmount8, p.strikePriceUsd8 - expiry, 1e10, Math.Rounding.Ceil
                        );
                    }
                    if (!csp && expiry > p.strikePriceUsd8) {
                        v.liabilities += Math.mulDiv(
                            p.optionAmount8, expiry - p.strikePriceUsd8, expiry, Math.Rounding.Ceil
                        );
                    }
                } else {
                    (uint256 liability, uint256 cost, uint256 count) =
                        _mark(adapter, id, p.collateralAmount, snapshotBlock, marks.observations);
                    v.liabilities += liability;
                    v.baseExitCost += cost;
                    used += count;
                }
            } else if (p.lifecycle == IAdapter.Lifecycle.AwaitingPhysicalDelivery) {
                v.liabilities += p.collateralAmount;
            } else {
                revert InvalidObservation(id);
            }
        }
        if (used != marks.observations.length || activeCollateral != state.activeCollateralAmount) {
            revert InvalidObservation(0);
        }
        v.dataHash = keccak256(
            abi.encode(
                adapter,
                IAssetNeutralAdapterStateHashV2(adapter).positionStateHash(),
                snapshotBlock,
                round,
                spot,
                updated,
                keccak256(data),
                v
            )
        );
    }

    function _mark(address adapter, uint256 id, uint256 cap, uint64 snapshot, Observation[] memory marks)
        private
        view
        returns (uint256 liability, uint256 cost, uint256 used)
    {
        address[] memory seen = new address[](observationQuorum);
        uint256 maxLiability;
        uint256 maxCost;
        for (uint256 i; i < marks.length; ++i) {
            Observation memory o = marks[i];
            if (o.positionId != id) continue;
            if (
                o.snapshotBlock != snapshot || o.validUntilBlock < block.number
                    || o.validUntilBlock > snapshot + maxObservationWindow || o.liability > cap || o.baseExitCost > cap
                    || o.nonce == 0 || used >= observationQuorum
            ) revert InvalidObservation(id);
            address signer = observationDigest(
                    adapter, id, o.liability, o.baseExitCost, o.snapshotBlock, o.validUntilBlock, o.nonce
                ).recover(o.signature);
            if (!isApprovedObserver[signer]) revert InvalidObservation(id);
            for (uint256 j; j < used; ++j) {
                if (seen[j] == signer) revert DuplicateObserver(signer);
            }
            seen[used++] = signer;
            maxLiability = Math.max(maxLiability, o.liability);
            maxCost = Math.max(maxCost, o.baseExitCost);
        }
        if (used != observationQuorum) revert InsufficientObservationQuorum(id, observationQuorum, used);
        return (maxLiability, maxCost, used);
    }
}

contract AssetNeutralCspFundValuatorV2 is AssetNeutralOptionsFundValuatorV2 {
    constructor(
        address f,
        uint64 s,
        uint64 w,
        uint8 q,
        address[] memory o,
        address a,
        address fund_,
        address b,
        address u,
        address settlement,
        bytes32 p
    ) AssetNeutralOptionsFundValuatorV2(f, s, w, q, o, a, fund_, b, u, settlement, p) {}

    function expectedStrategyKind() public pure override returns (IAdapter.StrategyKind) {
        return IAdapter.StrategyKind.Csp;
    }
}

contract AssetNeutralCoveredCallFundValuatorV2 is AssetNeutralOptionsFundValuatorV2 {
    constructor(
        address f,
        uint64 s,
        uint64 w,
        uint8 q,
        address[] memory o,
        address a,
        address fund_,
        address b,
        address u,
        address settlement,
        bytes32 p
    ) AssetNeutralOptionsFundValuatorV2(f, s, w, q, o, a, fund_, b, u, settlement, p) {}

    function expectedStrategyKind() public pure override returns (IAdapter.StrategyKind) {
        return IAdapter.StrategyKind.CoveredCall;
    }
}
