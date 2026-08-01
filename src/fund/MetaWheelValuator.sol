// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {WheelTypes} from "./WheelTypes.sol";
import {IPositionValuator} from "./interfaces/IPositionValuator.sol";
import {IWheelChildLane} from "./interfaces/IWheelChildLane.sol";
import {IWheelCoordinatorAdapter} from "./interfaces/IWheelCoordinatorAdapter.sol";

interface IMetaWheelSpotFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IWheelCspLaneAccounting {
    function accountingState() external view returns (uint256 accountedUsdc, uint256 accountedWeth);
}

interface IWheelCoveredCallLaneAccounting {
    function accountingState()
        external
        view
        returns (uint256 accountedUsdc, uint256 accountedWeth, uint256 literalFloor8, uint256 requiredFloor8);
}

/// @notice Independent USDC valuator for the parent Meta Wheel coordinator.
/// @dev Child reports are bound to exact child shares and position hashes; parent NAV reporters sign the component.
contract MetaWheelValuator is IPositionValuator {
    address public immutable usdc;
    address public immutable weth;
    address public immutable spotFeed;
    address public immutable cspValuator;
    address public immutable coveredCallValuator;
    uint8 public immutable usdcDecimals;
    uint8 public immutable spotFeedDecimals;
    uint64 public immutable maxSpotStaleness;
    uint16 public immutable transitionExitCostBps;

    error AccountingDeficit(address asset, uint256 accounted, uint256 actual);
    error DuplicateOrUnexpectedLane(address lane);
    error IncompleteLaneSet(uint256 expected, uint256 actual);
    error InvalidAdapter(address adapter);
    error InvalidLaneReport(address lane);
    error InvalidSnapshotBlock(uint64 expected, uint64 actual);
    error InvalidSpotObservation();
    error LiabilityExceedsGrossAssets(uint256 liabilities, uint256 grossAssets);

    constructor(
        address usdc_,
        address weth_,
        address spotFeed_,
        address cspValuator_,
        address coveredCallValuator_,
        uint8 spotFeedDecimals_,
        uint64 maxSpotStaleness_,
        uint16 transitionExitCostBps_
    ) {
        if (
            usdc_ == address(0) || weth_ == address(0) || spotFeed_ == address(0) || cspValuator_ == address(0)
                || coveredCallValuator_ == address(0) || usdc_.code.length == 0 || weth_.code.length == 0
                || spotFeed_.code.length == 0 || cspValuator_.code.length == 0 || coveredCallValuator_.code.length == 0
                || spotFeedDecimals_ > 18 || maxSpotStaleness_ == 0 || transitionExitCostBps_ > FundConstants.BPS
        ) revert InvalidSpotObservation();
        uint8 usdcDecimals_ = IERC20Metadata(usdc_).decimals();
        if (usdcDecimals_ > 18 || IMetaWheelSpotFeed(spotFeed_).decimals() != spotFeedDecimals_) {
            revert InvalidSpotObservation();
        }
        usdc = usdc_;
        weth = weth_;
        spotFeed = spotFeed_;
        cspValuator = cspValuator_;
        coveredCallValuator = coveredCallValuator_;
        usdcDecimals = usdcDecimals_;
        spotFeedDecimals = spotFeedDecimals_;
        maxSpotStaleness = maxSpotStaleness_;
        transitionExitCostBps = transitionExitCostBps_;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function value(address adapter, uint64 snapshotBlock, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory positionValue)
    {
        if (adapter == address(0) || adapter.code.length == 0) revert InvalidAdapter(adapter);
        if (snapshotBlock != block.number) revert InvalidSnapshotBlock(uint64(block.number), snapshotBlock);
        IWheelCoordinatorAdapter coordinator = IWheelCoordinatorAdapter(adapter);
        if (coordinator.interfaceVersion() != 1 || coordinator.accountingAsset() != usdc || coordinator.weth() != weth) revert InvalidAdapter(adapter);

        WheelTypes.LaneValuation[] memory laneReports = abi.decode(data, (WheelTypes.LaneValuation[]));
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        if (state.accountedWeth != state.transitionWeth) {
            revert AccountingDeficit(weth, state.transitionWeth, state.accountedWeth);
        }
        uint256 rawUsdc = IERC20(usdc).balanceOf(adapter);
        uint256 rawWeth = IERC20(weth).balanceOf(adapter);
        if (rawUsdc < state.accountedUsdc) revert AccountingDeficit(usdc, state.accountedUsdc, rawUsdc);
        if (rawWeth < state.accountedWeth) revert AccountingDeficit(weth, state.accountedWeth, rawWeth);

        (uint80 spotRoundId, uint256 spotPrice, uint256 spotUpdatedAt) = _readSpot();
        uint256 transitionWethValue = _wethValue(state.transitionWeth, spotPrice);
        positionValue.grossAssets = state.accountedUsdc + transitionWethValue;
        positionValue.liquidAccountingAssets = state.accountedUsdc;
        positionValue.baseExitCost =
            Math.mulDiv(transitionWethValue, transitionExitCostBps, FundConstants.BPS, Math.Rounding.Ceil);

        uint256 reportCursor;
        uint256 laneCount = coordinator.registeredLaneCount();
        for (uint256 i; i < laneCount; ++i) {
            (address lane, WheelTypes.LaneKind kind, bool active) = coordinator.registeredLaneAt(i);
            if (!active) continue;
            uint256 shares = IWheelChildLane(lane).childShares();
            if (shares == 0) continue;
            if (reportCursor >= laneReports.length) {
                revert IncompleteLaneSet(reportCursor + 1, laneReports.length);
            }
            WheelTypes.LaneValuation memory report = laneReports[reportCursor];
            if (report.lane != lane) revert DuplicateOrUnexpectedLane(report.lane);
            if (
                report.snapshotBlock != snapshotBlock || report.childShares != shares
                    || report.positionHash != IWheelChildLane(lane).positionStateHash()
            ) revert InvalidLaneReport(lane);
            bytes32 componentHash = _addCanonicalLaneValue(positionValue, lane, kind, snapshotBlock, report, spotPrice);
            positionValue.dataHash = keccak256(abi.encode(positionValue.dataHash, componentHash));
            ++reportCursor;
        }
        if (reportCursor != laneReports.length) revert IncompleteLaneSet(reportCursor, laneReports.length);
        if (positionValue.liabilities > positionValue.grossAssets) {
            revert LiabilityExceedsGrossAssets(positionValue.liabilities, positionValue.grossAssets);
        }
        positionValue.dataHash = keccak256(
            abi.encode(
                adapter,
                coordinator.positionStateHash(),
                snapshotBlock,
                spotRoundId,
                spotPrice,
                spotUpdatedAt,
                keccak256(data),
                positionValue.dataHash,
                positionValue.grossAssets,
                positionValue.liabilities,
                positionValue.liquidAccountingAssets,
                positionValue.baseExitCost
            )
        );
    }

    function _addCanonicalLaneValue(
        FundTypes.PositionValue memory parentValue,
        address lane,
        WheelTypes.LaneKind kind,
        uint64 snapshotBlock,
        WheelTypes.LaneValuation memory report,
        uint256 spotPrice
    ) private view returns (bytes32 componentHash) {
        address childAdapter = IWheelChildLane(lane).adapter();
        FundTypes.PositionValue memory childValue;
        uint256 idleUsdc;
        uint256 idleWeth;
        if (kind == WheelTypes.LaneKind.Csp) {
            childValue = IPositionValuator(cspValuator).value(childAdapter, snapshotBlock, report.valuationData);
            (idleUsdc, idleWeth) = IWheelCspLaneAccounting(lane).accountingState();
            parentValue.grossAssets += childValue.grossAssets;
            parentValue.liabilities += childValue.liabilities;
            parentValue.baseExitCost += childValue.baseExitCost;
        } else if (kind == WheelTypes.LaneKind.CoveredCall) {
            childValue = IPositionValuator(coveredCallValuator).value(childAdapter, snapshotBlock, report.valuationData);
            (idleUsdc, idleWeth,,) = IWheelCoveredCallLaneAccounting(lane).accountingState();
            parentValue.grossAssets += _wethValue(childValue.grossAssets, spotPrice);
            parentValue.liabilities += _wethValue(childValue.liabilities, spotPrice);
            parentValue.baseExitCost += _wethValue(childValue.baseExitCost, spotPrice);
        } else {
            revert InvalidLaneReport(lane);
        }

        uint256 rawIdleUsdc = IERC20(usdc).balanceOf(lane);
        uint256 rawIdleWeth = IERC20(weth).balanceOf(lane);
        if (rawIdleUsdc < idleUsdc) revert AccountingDeficit(usdc, idleUsdc, rawIdleUsdc);
        if (rawIdleWeth < idleWeth) revert AccountingDeficit(weth, idleWeth, rawIdleWeth);
        uint256 idleWethValue = _wethValue(idleWeth, spotPrice);
        parentValue.grossAssets += idleUsdc + idleWethValue;
        parentValue.baseExitCost += Math.mulDiv(
            idleWethValue, transitionExitCostBps, FundConstants.BPS, Math.Rounding.Ceil
        );
        componentHash = keccak256(
            abi.encode(
                lane,
                childAdapter,
                kind,
                report.positionHash,
                childValue.dataHash,
                idleUsdc,
                idleWeth,
                parentValue.grossAssets,
                parentValue.liabilities,
                parentValue.baseExitCost
            )
        );
    }

    function _readSpot() private view returns (uint80 roundId, uint256 price, uint256 updatedAt) {
        int256 answer;
        uint80 answeredInRound;
        (roundId, answer,, updatedAt, answeredInRound) = IMetaWheelSpotFeed(spotFeed).latestRoundData();
        if (
            answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp
                || block.timestamp - updatedAt > maxSpotStaleness || answeredInRound < roundId
        ) revert InvalidSpotObservation();
        price = uint256(answer);
    }

    function _wethValue(uint256 wethAmount, uint256 spotPrice) private view returns (uint256) {
        uint256 valueAtWad = Math.mulDiv(wethAmount, spotPrice, 10 ** spotFeedDecimals);
        return valueAtWad / (10 ** (18 - usdcDecimals));
    }
}
