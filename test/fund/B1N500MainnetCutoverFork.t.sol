// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PairRoutingSwapRouter} from "../../src/routers/PairRoutingSwapRouter.sol";
import {UniswapV3SettlementAdapter} from "../../src/routers/UniswapV3SettlementAdapter.sol";

interface IB500BatchSettler {
    function owner() external view returns (address);
    function operator() external view returns (address);
    function addressBook() external view returns (address);
    function aavePool() external view returns (address);
    function swapRouter() external view returns (address);
    function swapFeeTier() external view returns (uint24);
    function batchNonce() external view returns (uint256);
    function setSwapRouter(address router) external;
}

/// @notice Pinned fork proof that the existing BatchSettler owner can cut the swapRouter over to the
///         routing facade with a single storage write, leaving the UUPS implementation slot and all
///         ABI-facing settlement state unchanged, and can roll the cutover back.
contract B1N500MainnetCutoverForkTest is Test {
    uint256 private constant FORK_BLOCK = 50_780_000;
    uint256 private constant FORK_TIMESTAMP = 1_788_349_347;
    bytes32 private constant FORK_PARENT = 0x25fe310773dc0da61c61050b004c8fad9279b093ac804f45cc99857788e79db2;

    address private constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address private constant OWNER = 0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7;
    address private constant UNI_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant WETH = 0x4200000000000000000000000000000000000006;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    modifier onlyFork() {
        if (block.chainid != 8453) return;
        _;
    }

    function setUp() public {
        if (block.chainid != 8453) return;
        vm.rollFork(FORK_BLOCK);
        assertEq(block.timestamp, FORK_TIMESTAMP);
        assertEq(blockhash(FORK_BLOCK - 1), FORK_PARENT);
    }

    function test_cutoverWritesSingleSlotAndPreservesProxyState() public onlyFork {
        IB500BatchSettler settler = IB500BatchSettler(SETTLER);
        assertEq(settler.owner(), OWNER);
        assertEq(settler.swapRouter(), UNI_ROUTER);

        PairRoutingSwapRouter facade = new PairRoutingSwapRouter(SETTLER, OWNER);
        UniswapV3SettlementAdapter uni = new UniswapV3SettlementAdapter(address(facade));
        vm.startPrank(OWNER);
        facade.proposeRoute(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(uni));
        facade.proposeRoute(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput, address(uni));
        facade.proposeRoute(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(uni));
        facade.proposeRoute(USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput, address(uni));
        vm.stopPrank();
        vm.warp(block.timestamp + facade.ROUTE_DELAY());
        vm.startPrank(OWNER);
        facade.activateRoute(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        facade.activateRoute(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput);
        facade.activateRoute(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        facade.activateRoute(USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput);
        vm.stopPrank();

        bytes32 implementationBefore = vm.load(SETTLER, IMPLEMENTATION_SLOT);
        bytes32 stateBefore = _state(settler);

        vm.record();
        vm.prank(OWNER);
        settler.setSwapRouter(address(facade));
        (, bytes32[] memory writes) = vm.accesses(SETTLER);
        assertEq(writes.length, 1, "cutover must touch exactly one storage slot");
        assertEq(settler.swapRouter(), address(facade));
        assertEq(vm.load(SETTLER, IMPLEMENTATION_SLOT), implementationBefore);
        assertEq(_state(settler), stateBefore);

        vm.record();
        vm.prank(OWNER);
        settler.setSwapRouter(UNI_ROUTER);
        (, writes) = vm.accesses(SETTLER);
        assertEq(writes.length, 1, "rollback must touch exactly one storage slot");
        assertEq(settler.swapRouter(), UNI_ROUTER);
        assertEq(vm.load(SETTLER, IMPLEMENTATION_SLOT), implementationBefore);
        assertEq(_state(settler), stateBefore);
    }

    function test_isolatedRouteDisablePreservesPairedDirectionAndOtherAssets() public onlyFork {
        PairRoutingSwapRouter facade = new PairRoutingSwapRouter(SETTLER, OWNER);
        UniswapV3SettlementAdapter uni = new UniswapV3SettlementAdapter(address(facade));
        vm.startPrank(OWNER);
        facade.proposeRoute(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(uni));
        facade.proposeRoute(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput, address(uni));
        facade.proposeRoute(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(uni));
        facade.proposeRoute(USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput, address(uni));
        vm.stopPrank();
        vm.warp(block.timestamp + facade.ROUTE_DELAY());
        vm.startPrank(OWNER);
        facade.activateRoute(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        facade.activateRoute(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput);
        facade.activateRoute(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        facade.activateRoute(USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput);
        facade.disableRoute(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        vm.stopPrank();

        (address callActive,,) = facade.routes(facade.routeKey(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput));
        (address putActive,,) = facade.routes(facade.routeKey(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput));
        (address btcCall,,) = facade.routes(facade.routeKey(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput));
        assertEq(callActive, address(0), "disabled direction must be empty");
        assertEq(putActive, address(uni), "paired direction must stay active");
        assertEq(btcCall, address(uni), "unrelated asset must stay active");
    }

    function _state(IB500BatchSettler settler) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                settler.owner(),
                settler.operator(),
                settler.addressBook(),
                settler.aavePool(),
                settler.swapFeeTier(),
                settler.batchNonce()
            )
        );
    }
}
