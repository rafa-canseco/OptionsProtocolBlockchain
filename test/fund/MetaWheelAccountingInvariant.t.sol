// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
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
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000e6);
        usdc.mint(address(this), amount);
        usdc.transfer(address(coordinator), amount);
        coordinator.allocate(address(usdc), amount, abi.encode(keccak256(abi.encode(rawAmount, amount))));
    }

    function returnUsdc(uint96 rawAmount) external {
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        uint256 available = state.pendingCspUsdc + state.reservedRedemptionUsdc;
        if (available == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, available);
        coordinator.deallocate(amount, amount, "");
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
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MetaWheelAccountingHandler.queue.selector;
        selectors[1] = MetaWheelAccountingHandler.returnUsdc.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_idleAccountingPartitionsAreExact() public view {
        IWheelCoordinatorAdapter.Summary memory state = coordinator.summary();
        assertEq(state.accountedUsdc, state.pendingCspUsdc + state.reservedRedemptionUsdc);
        assertEq(state.accountedWeth, state.transitionWeth);
        assertEq(usdc.balanceOf(address(coordinator)), state.accountedUsdc);
        assertEq(weth.balanceOf(address(coordinator)), state.accountedWeth);
    }
}
