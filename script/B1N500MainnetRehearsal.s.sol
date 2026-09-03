// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {B1N495RoutePreflight} from "./B1N495RoutePreflight.sol";
import {B1N495RouteToolsBase} from "./B1N495RouteTools.s.sol";

interface IB1N500BatchSettler {
    function owner() external view returns (address);
    function operator() external view returns (address);
    function addressBook() external view returns (address);
    function aavePool() external view returns (address);
    function swapRouter() external view returns (address);
    function swapFeeTier() external view returns (uint24);
    function batchNonce() external view returns (uint256);
    function setSwapRouter(address router) external;
}

/// @notice Fork-only rehearsal. It deliberately uses prank, never broadcast, so it cannot submit a transaction.
contract B1N500MainnetRehearsal is B1N495RouteToolsBase {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private constant PRODUCTION_UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    struct RehearsalResult {
        Addresses deployed;
        B1N495RoutePreflight.Result eligibility;
        uint256 activatedNewAssets;
    }

    error RehearsalFailed(bytes32 checkName);

    function run() external returns (RehearsalResult memory out) {
        if (keccak256(bytes(vm.envString("B1N500_CONFIRM"))) != keccak256("SIMULATE_MAINNET_NO_BROADCAST")) {
            revert RehearsalFailed("CONFIRMATION");
        }

        address routeOwner = vm.envAddress("B1N495_ROUTE_OWNER");
        FinalizedPins memory pins = _loadFinalizedPins();
        uint256 baseFork = _selectPinnedFork(
            "B1N495_BASE_RPC_URL", 8453, pins.baseNumber, pins.baseHash, pins.baseParentHash, true, true
        );
        _assertFreshCapture(pins.capturedAt);

        IB1N500BatchSettler settler = IB1N500BatchSettler(SETTLER);
        if (settler.owner() != routeOwner || settler.swapRouter() != PRODUCTION_UNISWAP_ROUTER) {
            revert RehearsalFailed("SETTLER_BASELINE");
        }

        bytes32 implementationBefore = vm.load(SETTLER, IMPLEMENTATION_SLOT);
        bytes32 stateBefore = _unchangedState(settler);

        vm.startPrank(routeOwner);
        out.deployed = _deploy(routeOwner);
        vm.stopPrank();
        out.eligibility = _latestFinalizedPreflight(out.deployed, routeOwner, baseFork, pins);

        PairRoutingSwapRouter facade = PairRoutingSwapRouter(payable(out.deployed.facade));
        vm.startPrank(routeOwner);
        _proposePair(facade, WETH, out.deployed.uniswapAdapter);
        _proposePair(facade, CBBTC, out.deployed.uniswapAdapter);
        if (out.eligibility.nvdacEligible) {
            _proposePair(facade, NVDAC, out.deployed.nvdacAdapter);
            ++out.activatedNewAssets;
        }
        if (out.eligibility.cbzecEvidencePass) {
            _proposePair(facade, CBZEC, out.deployed.cbzecAdapter);
            ++out.activatedNewAssets;
        }
        if (out.eligibility.cbhypeEligible) {
            _proposePair(facade, CBHYPE, out.deployed.cbhypeAdapter);
            ++out.activatedNewAssets;
        }
        if (out.eligibility.vvvEvidencePass) {
            _proposePair(facade, VVV, out.deployed.uniswapAdapter);
            ++out.activatedNewAssets;
        }
        vm.stopPrank();

        vm.warp(block.timestamp + facade.ROUTE_DELAY());
        vm.startPrank(routeOwner);
        _activatePair(facade, WETH);
        _activatePair(facade, CBBTC);
        if (out.eligibility.nvdacEligible) _activatePair(facade, NVDAC);
        if (out.eligibility.cbzecEvidencePass) _activatePair(facade, CBZEC);
        if (out.eligibility.cbhypeEligible) _activatePair(facade, CBHYPE);
        if (out.eligibility.vvvEvidencePass) _activatePair(facade, VVV);
        vm.stopPrank();

        _assertPair(facade, WETH, out.deployed.uniswapAdapter);
        _assertPair(facade, CBBTC, out.deployed.uniswapAdapter);
        _assertEligibilityRoute(facade, NVDAC, out.deployed.nvdacAdapter, out.eligibility.nvdacEligible);
        _assertEligibilityRoute(facade, CBZEC, out.deployed.cbzecAdapter, out.eligibility.cbzecEvidencePass);
        _assertEligibilityRoute(facade, CBHYPE, out.deployed.cbhypeAdapter, out.eligibility.cbhypeEligible);
        _assertEligibilityRoute(facade, VVV, out.deployed.uniswapAdapter, out.eligibility.vvvEvidencePass);

        vm.record();
        vm.prank(routeOwner);
        settler.setSwapRouter(address(facade));
        (, bytes32[] memory writes) = vm.accesses(SETTLER);
        if (writes.length != 1 || settler.swapRouter() != address(facade)) revert RehearsalFailed("CUTOVER");
        if (vm.load(SETTLER, IMPLEMENTATION_SLOT) != implementationBefore || _unchangedState(settler) != stateBefore) {
            revert RehearsalFailed("PROXY_CHANGED");
        }

        _rehearseObservedRouteChange(facade, routeOwner, out.deployed.uniswapAdapter);
        _rehearseIsolatedPause(facade, routeOwner, out);

        vm.prank(routeOwner);
        settler.setSwapRouter(PRODUCTION_UNISWAP_ROUTER);
        if (
            settler.swapRouter() != PRODUCTION_UNISWAP_ROUTER
                || vm.load(SETTLER, IMPLEMENTATION_SLOT) != implementationBefore
                || _unchangedState(settler) != stateBefore
        ) revert RehearsalFailed("ROLLBACK");

        console2.log("eligible new assets activated in fork", out.activatedNewAssets);
        console2.log("facade", out.deployed.facade);
        console2.log("proxy implementation unchanged", uint256(implementationBefore));
    }

    function _proposePair(PairRoutingSwapRouter facade, address asset, address adapter) private {
        facade.proposeRoute(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, adapter);
        facade.proposeRoute(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput, adapter);
    }

    function _activatePair(PairRoutingSwapRouter facade, address asset) private {
        facade.activateRoute(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        facade.activateRoute(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput);
    }

    function _assertPair(PairRoutingSwapRouter facade, address asset, address adapter) private view {
        _assertRoute(facade, asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, adapter);
        _assertRoute(facade, USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput, adapter);
    }

    function _assertEligibilityRoute(PairRoutingSwapRouter facade, address asset, address adapter, bool eligible)
        private
        view
    {
        _assertPair(facade, asset, eligible ? adapter : address(0));
    }

    function _assertRoute(
        PairRoutingSwapRouter facade,
        address tokenIn,
        address tokenOut,
        PairRoutingSwapRouter.SwapKind kind,
        address expected
    ) private view {
        (address active, address pending, uint48 activateAfter) =
            facade.routes(facade.routeKey(tokenIn, tokenOut, kind));
        if (active != expected || pending != address(0) || activateAfter != 0) revert RehearsalFailed("ROUTE");
    }

    function _rehearseObservedRouteChange(PairRoutingSwapRouter facade, address routeOwner, address adapter) private {
        vm.prank(routeOwner);
        facade.proposeRoute(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, adapter);
        (address active, address pending,) =
            facade.routes(facade.routeKey(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput));
        if (active != adapter || pending != adapter) revert RehearsalFailed("ROUTE_CHANGE");
        vm.prank(routeOwner);
        facade.cancelRouteUpdate(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _assertRoute(facade, WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, adapter);
    }

    function _rehearseIsolatedPause(PairRoutingSwapRouter facade, address routeOwner, RehearsalResult memory out)
        private
    {
        address asset;
        if (out.eligibility.nvdacEligible) asset = NVDAC;
        else if (out.eligibility.cbzecEvidencePass) asset = CBZEC;
        else if (out.eligibility.cbhypeEligible) asset = CBHYPE;
        else if (out.eligibility.vvvEvidencePass) asset = VVV;
        else return;

        vm.prank(routeOwner);
        facade.disableRoute(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _assertRoute(facade, asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0));
        (address paired,,) = facade.routes(facade.routeKey(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput));
        if (paired == address(0)) revert RehearsalFailed("PAUSE_ISOLATION");
        _assertPair(facade, CBBTC, out.deployed.uniswapAdapter);
    }

    function _unchangedState(IB1N500BatchSettler settler) private view returns (bytes32) {
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
