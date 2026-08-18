// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {OToken} from "../../src/core/OToken.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ProtectedFloorMockAdapter {
    address public fund;
    address public strategyManager;
    address public accountingAsset;
    address public usdc;

    ICoveredCallFundAdapter.AdapterState private _adapterState;
    ICoveredCallFundAdapter.Position private _position;

    function configure(address lane, address weth_, address usdc_) external {
        require(fund == address(0), "CONFIGURED");
        fund = lane;
        strategyManager = lane;
        accountingAsset = weth_;
        usdc = usdc_;
    }

    function allocate(address asset, uint256 amount, bytes calldata data) external {
        require(msg.sender == fund && asset == accountingAsset && amount != 0, "ALLOCATE");
        ICoveredCallFundAdapter.OpenPositionData memory decoded =
            abi.decode(data, (ICoveredCallFundAdapter.OpenPositionData));
        _adapterState.positionCount = 1;
        _adapterState.activePositionCount = 1;
        _adapterState.activeCollateral = decoded.collateral;
        _adapterState.accountedWeth = decoded.collateral;
        _adapterState.positionsHash = keccak256(abi.encode(decoded.quote.oToken, decoded.collateral));
        _position = ICoveredCallFundAdapter.Position({
            oToken: decoded.quote.oToken,
            marketMaker: address(0xBEEF),
            protocolVaultId: 1,
            optionAmount: decoded.optionAmount,
            collateral: decoded.collateral,
            premiumEarned: 0,
            collateralReturned: 0,
            calledAwayUsdc: 0,
            fallbackWethRecovered: 0,
            mmWethPayout: 0,
            usdcBalanceBeforeDelivery: 0,
            openedAt: uint64(block.timestamp),
            fallbackEligibleAt: 0,
            lifecycle: ICoveredCallFundAdapter.Lifecycle.Open,
            lifecycleHash: keccak256("OPEN")
        });
    }

    function adapterState() external view returns (ICoveredCallFundAdapter.AdapterState memory) {
        return _adapterState;
    }

    function position(uint256 positionId) external view returns (ICoveredCallFundAdapter.Position memory) {
        require(positionId == 1, "POSITION");
        return _position;
    }

    function positionStateHash() external view returns (bytes32) {
        return _adapterState.positionsHash;
    }
}

contract WheelCoveredCallProtectedFloorTest is Test {
    uint256 private constant BUFFER_8 = 10e8;
    uint256 private constant LITERAL_STRIKE_8 = 2_000e8;
    uint256 private constant PROTECTED_BASE_FLOOR_8 = 2_250e8;
    bytes32 private constant OPENED_EVENT_SIGNATURE = keccak256(
        "CoveredCallOpened(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint64,uint256,bytes32)"
    );

    MockERC20 private usdc;
    MockERC20 private weth;
    ProtectedFloorMockAdapter private adapter;
    WheelCoveredCallChildLane private lane;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        FundAccessManager accessManager = new FundAccessManager(address(this));
        WheelCoveredCallChildLane implementation = new WheelCoveredCallChildLane();
        lane = WheelCoveredCallChildLane(address(new ERC1967Proxy(address(implementation), "")));
        adapter = new ProtectedFloorMockAdapter();
        adapter.configure(address(lane), address(weth), address(usdc));
        lane.initialize(
            WheelCoveredCallChildLane.InitializeParams({
                coordinator: address(this),
                adapter: address(adapter),
                usdc: address(usdc),
                weth: address(weth),
                authority: address(accessManager),
                maxAssets: 10e18,
                executionCostBuffer8: BUFFER_8
            })
        );
    }

    function test_childRejectsProtectedFloorBelowLiteral() public {
        bytes memory openData = _openData(PROTECTED_BASE_FLOOR_8 + BUFFER_8);
        vm.expectRevert(WheelCoveredCallChildLane.InvalidAmount.selector);
        lane.openCoveredCall(
            1, keccak256("INVALID_PROTECTED_FLOOR"), 1, LITERAL_STRIKE_8, LITERAL_STRIKE_8 - 1, 2e18, openData
        );
    }

    function test_childRejectsStrikeBelowProtectedFloorPlusBuffer() public {
        uint256 requiredFloor8 = PROTECTED_BASE_FLOOR_8 + BUFFER_8;
        bytes memory openData = _openData(requiredFloor8 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                WheelCoveredCallChildLane.CallStrikeBelowFloor.selector, requiredFloor8 - 1, requiredFloor8
            )
        );
        lane.openCoveredCall(
            1, keccak256("BELOW_PROTECTED_FLOOR"), 1, LITERAL_STRIKE_8, PROTECTED_BASE_FLOOR_8, 2e18, openData
        );
    }

    function test_childRequiredFloorAdditionOverflowRevertsClosed() public {
        bytes memory openData = _openData(type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        lane.openCoveredCall(
            1, keccak256("REQUIRED_FLOOR_OVERFLOW"), 1, LITERAL_STRIKE_8, type(uint256).max, 2e18, openData
        );
        assertEq(uint256(lane.laneState()), 0);
        assertEq(lane.requiredFloor8(), 0);
    }

    function test_childStoresAndEmitsLiteralStrikeWithEffectiveRequiredFloor() public {
        uint256 wethAmount = 2e18;
        uint256 collateral = 1e18;
        uint256 requiredFloor8 = PROTECTED_BASE_FLOOR_8 + BUFFER_8;
        weth.mint(address(this), wethAmount);
        weth.approve(address(lane), wethAmount);
        vm.recordLogs();

        lane.openCoveredCall(
            7,
            keccak256("EXACT_PROTECTED_FLOOR"),
            11,
            LITERAL_STRIKE_8,
            PROTECTED_BASE_FLOOR_8,
            wethAmount,
            _openData(requiredFloor8)
        );

        (,, uint256 storedLiteralStrike8, uint256 storedRequiredFloor8) = lane.accountingState();
        assertEq(storedLiteralStrike8, LITERAL_STRIKE_8);
        assertEq(storedRequiredFloor8, requiredFloor8);
        assertEq(lane.requiredFloor8(), requiredFloor8);
        assertEq(lane.childShares(), wethAmount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(lane) || logs[i].topics[0] != OPENED_EVENT_SIGNATURE) continue;
            assertEq(uint256(logs[i].topics[1]), 7);
            assertEq(uint256(logs[i].topics[2]), 11);
            assertEq(uint256(logs[i].topics[3]), 1);
            (
                uint256 emittedWethAmount,
                uint256 emittedCollateral,
                uint256 emittedLiteralStrike8,
                uint256 emittedRequiredFloor8,
                uint256 emittedCallStrike8,
                uint64 expiry,
                uint256 emittedChildShares,
                bytes32 positionHash
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint64, uint256, bytes32));
            assertEq(emittedWethAmount, wethAmount);
            assertEq(emittedCollateral, collateral);
            assertEq(emittedLiteralStrike8, LITERAL_STRIKE_8);
            assertEq(emittedRequiredFloor8, requiredFloor8);
            assertEq(emittedCallStrike8, requiredFloor8);
            assertGt(expiry, block.timestamp);
            assertEq(emittedChildShares, wethAmount);
            assertEq(positionHash, lane.executionStateHash());
            found = true;
            break;
        }
        assertTrue(found);
    }

    function _openData(uint256 strike8) private returns (bytes memory) {
        OToken oToken = new OToken();
        oToken.init(
            address(weth), address(usdc), address(weth), strike8, block.timestamp + 2 days, false, address(this)
        );
        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: address(oToken),
            bidPrice: 10e8,
            deadline: type(uint256).max,
            quoteId: 1,
            maxAmount: 1e8,
            makerNonce: 0
        });
        return abi.encode(
            ICoveredCallFundAdapter.OpenPositionData({quote: quote, signature: "", optionAmount: 1e8, collateral: 1e18})
        );
    }
}
