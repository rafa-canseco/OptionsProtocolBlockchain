// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {IWheelCoordinatorAdapter} from "../../src/fund/interfaces/IWheelCoordinatorAdapter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MetaWheelInvariantFund {}

contract MetaWheelAccountingHandler is Test {
    MockERC20 public immutable usdc;
    WheelCoordinatorAdapter public coordinator;

    constructor(MockERC20 usdc_) {
        usdc = usdc_;
    }

    function bind(WheelCoordinatorAdapter coordinator_) external {
        require(address(coordinator) == address(0), "BOUND");
        coordinator = coordinator_;
    }

    function queue(uint96 rawAmount) external {
        if (coordinator.summary().trancheCount >= 64) return;
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000e6);
        usdc.mint(address(this), amount);
        usdc.transfer(address(coordinator), amount);
        coordinator.allocate(address(usdc), amount, abi.encode(keccak256(abi.encode(rawAmount, amount))));
    }

    function returnUsdc(uint96 rawAmount) external {
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        uint256 available = state.reservedRedemptionUsdc;
        if (available == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, available);
        coordinator.deallocate(amount, amount, "");
    }

    function reserve(uint256 rawTrancheId, uint96 rawAmount) external {
        uint256 count = coordinator.summary().trancheCount;
        if (count == 0) return;
        uint256 trancheId = bound(rawTrancheId, 1, count);
        WheelTypes.Tranche memory current = coordinator.tranche(trancheId);
        if (current.leg != WheelTypes.TrancheLeg.PendingCsp || current.pendingUsdc == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, current.pendingUsdc);
        coordinator.executeManagedOperation(
            uint8(WheelTypes.ManagedOperationClass.Processing),
            abi.encode(WheelTypes.ManagedOperation.ReserveRedemption, abi.encode(trancheId, amount))
        );
    }

    function release(uint96 rawAmount) external {
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        uint256 reserved = state.reservedRedemptionUsdc;
        if (reserved == 0 || state.trancheCount >= 64) return;
        coordinator.executeManagedOperation(
            uint8(WheelTypes.ManagedOperationClass.Processing),
            abi.encode(
                WheelTypes.ManagedOperation.ReleaseRedemption, abi.encode(bound(uint256(rawAmount), 1, reserved))
            )
        );
    }
}

contract MetaWheelAccountingInvariantTest is StdInvariant, Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    WheelCoordinatorAdapter internal coordinator;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        MetaWheelInvariantFund fund = new MetaWheelInvariantFund();
        MetaWheelAccountingHandler handler = new MetaWheelAccountingHandler(usdc);
        FundAccessManager accessManager = new FundAccessManager(address(this));
        WheelCoordinatorAdapter implementation = new WheelCoordinatorAdapter();
        coordinator = WheelCoordinatorAdapter(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        WheelCoordinatorAdapter.initialize,
                        (WheelCoordinatorAdapter.InitializeParams({
                                fund: address(fund),
                                strategyManager: address(handler),
                                usdc: address(usdc),
                                weth: address(weth),
                                authority: address(accessManager),
                                maxCspLanes: 4,
                                maxCoveredCallLanes: 4,
                                floorBufferUsd8: 10e8,
                                policyHash: keccak256("wheel-policy-v1")
                            }))
                    )
                )
            )
        );
        handler.bind(coordinator);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MetaWheelAccountingHandler.queue.selector;
        selectors[1] = MetaWheelAccountingHandler.returnUsdc.selector;
        selectors[2] = MetaWheelAccountingHandler.reserve.selector;
        selectors[3] = MetaWheelAccountingHandler.release.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_idleAccountingPartitionsAreExact() public view {
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.accountedUsdc, state.pendingCspUsdc + state.reservedRedemptionUsdc);
        assertEq(state.accountedWeth, state.transitionWeth);
        assertEq(usdc.balanceOf(address(coordinator)), state.accountedUsdc);
        assertEq(weth.balanceOf(address(coordinator)), state.accountedWeth);

        uint256 observedPending;
        uint256 observedPrincipal;
        for (uint256 trancheId = 1; trancheId <= state.trancheCount; ++trancheId) {
            WheelTypes.Tranche memory current = coordinator.tranche(trancheId);
            if (current.leg == WheelTypes.TrancheLeg.PendingCsp) {
                observedPending += current.pendingUsdc;
                observedPrincipal += current.principalUsdc;
            } else {
                assertEq(current.pendingUsdc, 0);
                assertEq(current.principalUsdc, 0);
            }
        }
        assertEq(observedPending, state.pendingCspUsdc);
        assertEq(observedPrincipal + state.reservedPrincipalUsdc, state.accountedUsdc);
    }
}
