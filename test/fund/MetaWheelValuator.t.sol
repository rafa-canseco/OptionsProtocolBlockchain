// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {MetaWheelValuator} from "../../src/fund/MetaWheelValuator.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {IPositionValuator} from "../../src/fund/interfaces/IPositionValuator.sol";
import {IWheelCoordinatorAdapter} from "../../src/fund/interfaces/IWheelCoordinatorAdapter.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MetaWheelMockCanonicalValuator is IPositionValuator {
    error InvalidCanonicalData();

    mapping(address adapter => bytes32 dataHash) public expectedDataHash;
    mapping(address adapter => FundTypes.PositionValue positionValue) private _values;

    function setValue(address adapter, bytes calldata valuationData, FundTypes.PositionValue calldata positionValue)
        external
    {
        expectedDataHash[adapter] = keccak256(valuationData);
        _values[adapter] = positionValue;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function value(address adapter, uint64 snapshotBlock, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory positionValue)
    {
        if (snapshotBlock != block.number || keccak256(data) != expectedDataHash[adapter]) {
            revert InvalidCanonicalData();
        }
        return _values[adapter];
    }
}

contract MetaWheelMockLane {
    address public immutable coordinator;
    address public immutable adapter;
    WheelTypes.LaneKind public immutable laneKind;
    uint256 public childShares;
    bytes32 public positionStateHash;
    uint256 public accountedUsdc;
    uint256 public accountedWeth;

    constructor(address coordinator_, address adapter_, WheelTypes.LaneKind kind_) {
        coordinator = coordinator_;
        adapter = adapter_;
        laneKind = kind_;
        childShares = 1;
        positionStateHash = keccak256(abi.encode(address(this), "lane-state"));
    }

    function setAccounting(uint256 usdcAmount, uint256 wethAmount) external {
        accountedUsdc = usdcAmount;
        accountedWeth = wethAmount;
    }

    function accountingState() external view returns (uint256, uint256, uint256, uint256) {
        return (accountedUsdc, accountedWeth, 0, 0);
    }

    function laneState() external pure returns (WheelTypes.LaneState) {
        return WheelTypes.LaneState.Open;
    }

    function stateNonce() external pure returns (uint64) {
        return 1;
    }

    function activeTrancheId() external pure returns (uint256) {
        return 1;
    }

    function activePositionId() external pure returns (uint256) {
        return 1;
    }
}

contract MetaWheelMockCoordinator {
    struct RegisteredLane {
        address lane;
        WheelTypes.LaneKind kind;
        bool active;
    }

    address public immutable accountingAsset;
    address public immutable weth;
    IWheelCoordinatorAdapter.Summary private _summary;
    RegisteredLane[] private _lanes;
    bytes32 public positionStateHash = keccak256("wheel-state");

    constructor(address usdc_, address weth_) {
        accountingAsset = usdc_;
        weth = weth_;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function setSummary(IWheelCoordinatorAdapter.Summary calldata state) external {
        _summary = state;
    }

    function addLane(address lane, WheelTypes.LaneKind kind) external {
        _lanes.push(RegisteredLane({lane: lane, kind: kind, active: true}));
    }

    function summary() external view returns (IWheelCoordinatorAdapter.Summary memory) {
        return _summary;
    }

    function registeredLaneCount() external view returns (uint256) {
        return _lanes.length;
    }

    function registeredLaneAt(uint256 index) external view returns (address, WheelTypes.LaneKind, bool) {
        RegisteredLane memory lane = _lanes[index];
        return (lane.lane, lane.kind, lane.active);
    }
}

contract MetaWheelValuatorTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockChainlinkFeed internal feed;
    MetaWheelMockCanonicalValuator internal cspValuator;
    MetaWheelMockCanonicalValuator internal callValuator;
    MetaWheelMockCoordinator internal coordinator;
    MetaWheelMockLane internal cspLane;
    MetaWheelMockLane internal callLane;
    MetaWheelValuator internal valuator;
    address internal cspAdapter = address(0xC5F);
    address internal callAdapter = address(0xCA11);
    bytes internal cspData = abi.encode("signed-csp-observations");
    bytes internal callData = abi.encode("signed-call-observations");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        feed = new MockChainlinkFeed(2_000e8);
        cspValuator = new MetaWheelMockCanonicalValuator();
        callValuator = new MetaWheelMockCanonicalValuator();
        coordinator = new MetaWheelMockCoordinator(address(usdc), address(weth));
        cspLane = new MetaWheelMockLane(address(coordinator), cspAdapter, WheelTypes.LaneKind.Csp);
        callLane = new MetaWheelMockLane(address(coordinator), callAdapter, WheelTypes.LaneKind.CoveredCall);
        coordinator.addLane(address(cspLane), WheelTypes.LaneKind.Csp);
        coordinator.addLane(address(callLane), WheelTypes.LaneKind.CoveredCall);
        coordinator.setSummary(
            IWheelCoordinatorAdapter.Summary({
                stateNonce: 1,
                trancheCount: 2,
                assignmentLotCount: 1,
                pendingCspUsdc: 100e6,
                reservedRedemptionUsdc: 0,
                transitionWeth: 1e18,
                accountedUsdc: 100e6,
                accountedWeth: 1e18
            })
        );
        usdc.mint(address(coordinator), 100e6);
        weth.mint(address(coordinator), 1e18);

        cspLane.setAccounting(50e6, 1e18);
        usdc.mint(address(cspLane), 50e6);
        weth.mint(address(cspLane), 1e18);
        callLane.setAccounting(40e6, 0.5e18);
        usdc.mint(address(callLane), 40e6);
        weth.mint(address(callLane), 0.5e18);

        cspValuator.setValue(
            cspAdapter,
            cspData,
            FundTypes.PositionValue({
                grossAssets: 1_000e6,
                liabilities: 100e6,
                liquidAccountingAssets: 1_000e6,
                baseExitCost: 10e6,
                dataHash: keccak256("canonical-csp")
            })
        );
        callValuator.setValue(
            callAdapter,
            callData,
            FundTypes.PositionValue({
                grossAssets: 2e18,
                liabilities: 0.25e18,
                liquidAccountingAssets: 1e18,
                baseExitCost: 0.02e18,
                dataHash: keccak256("canonical-call")
            })
        );
        valuator = new MetaWheelValuator(
            address(usdc), address(weth), address(feed), address(cspValuator), address(callValuator), 8, 1 hours, 100
        );
    }

    function test_composesCanonicalChildValuesAndExcludesDonations() public {
        WheelTypes.LaneValuation[] memory reports = _reports();
        FundTypes.PositionValue memory positionValue =
            valuator.value(address(coordinator), uint64(block.number), abi.encode(reports));
        assertEq(positionValue.grossAssets, 10_190e6);
        assertEq(positionValue.liabilities, 600e6);
        assertEq(positionValue.liquidAccountingAssets, 100e6);
        assertEq(positionValue.baseExitCost, 100e6);

        usdc.mint(address(coordinator), 9_000e6);
        weth.mint(address(callLane), 5e18);
        FundTypes.PositionValue memory afterDonation =
            valuator.value(address(coordinator), uint64(block.number), abi.encode(reports));
        assertEq(afterDonation.grossAssets, positionValue.grossAssets);
        assertEq(afterDonation.dataHash, positionValue.dataHash);
    }

    function test_changingEconomicDataWithSameLanePositionHashReverts() public {
        WheelTypes.LaneValuation[] memory reports = _reports();
        reports[0].valuationData = abi.encode("changed-economic-amounts");
        vm.expectRevert(MetaWheelMockCanonicalValuator.InvalidCanonicalData.selector);
        valuator.value(address(coordinator), uint64(block.number), abi.encode(reports));
    }

    function test_incompleteOrMismatchedLaneSetReverts() public {
        WheelTypes.LaneValuation[] memory reports = new WheelTypes.LaneValuation[](1);
        reports[0] = _reports()[0];
        vm.expectRevert(abi.encodeWithSelector(MetaWheelValuator.IncompleteLaneSet.selector, 2, 1));
        valuator.value(address(coordinator), uint64(block.number), abi.encode(reports));

        reports = _reports();
        reports[0].positionHash = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(MetaWheelValuator.InvalidLaneReport.selector, address(cspLane)));
        valuator.value(address(coordinator), uint64(block.number), abi.encode(reports));
    }

    function _reports() private view returns (WheelTypes.LaneValuation[] memory reports) {
        reports = new WheelTypes.LaneValuation[](2);
        reports[0] = WheelTypes.LaneValuation({
            lane: address(cspLane),
            snapshotBlock: uint64(block.number),
            childShares: 1,
            positionHash: cspLane.positionStateHash(),
            valuationData: cspData
        });
        reports[1] = WheelTypes.LaneValuation({
            lane: address(callLane),
            snapshotBlock: uint64(block.number),
            childShares: 1,
            positionHash: callLane.positionStateHash(),
            valuationData: callData
        });
    }
}
