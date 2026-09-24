// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {B1N495RoutePreflight} from "./B1N495RoutePreflight.sol";
import {B1N495RouteToolsBase} from "./B1N495RouteTools.s.sol";

interface IB1N500GateWhitelist {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function isWhitelistedUnderlying(address asset) external view returns (bool);
    function isWhitelistedCollateral(address asset) external view returns (bool);
    function isProductWhitelisted(address underlying, address strikeAsset, address collateralAsset, bool isPut)
        external
        view
        returns (bool);
}

interface IB1N500GateSettler {
    function owner() external view returns (address);
    function swapRouter() external view returns (address);
}

interface IB1N500GateController {
    function systemFullyPaused() external view returns (bool);
    function systemPartiallyPaused() external view returns (bool);
}

/// @notice Read-only, fail-closed gate that must pass immediately before Ledger Bundle 2 is signed.
contract B1N500LedgerBundle2Gate is B1N495RouteToolsBase {
    address private constant CONTROLLER = 0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624;
    address private constant WHITELIST = 0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A;
    address private constant PRODUCTION_UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address private constant WHITELIST_IMPLEMENTATION = 0x5F3b652b2b258e36bc88C3Bdf3c4e1EcF04BCF00;
    address private constant SETTLER_IMPLEMENTATION = 0x645a8A66B812A13D5042939b88C144467B825648;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant WHITELIST_IMPLEMENTATION_HASH =
        0x346c0ac9e338e6a8080629689a5ba300c66f5de2ecc19591f0a910fb2e99e649;
    bytes32 private constant SETTLER_IMPLEMENTATION_HASH =
        0x961901664cba1e17fe5dfaeef550b91ecdbe08834ef16065dfb6e462a095209a;
    bytes32 private constant FACADE_HASH = 0x8520cccdac2846a4817c26368f2b3ab04f1e0d3cc872ce11418ade10d496f678;
    bytes32 private constant NVDAC_ADAPTER_HASH = 0xa4b70749fc39ee3ab532fef6ff604710b2cdbc0de0f071e6d434f8ac76d36a2a;
    bytes32 private constant CBZEC_ADAPTER_HASH = 0x59e49007bee0ff9dddf105c8c6cd7f7830bc283025f610e3e4e6f68c35035a4b;
    bytes32 private constant CBHYPE_ADAPTER_HASH = 0x11e20e91e531b78036f02fd5e7fd683402ec14692fd24faffbc6ba3b1388b1de;
    bytes32 private constant UNISWAP_ADAPTER_HASH = 0x458568b4f0efd1dbf5ee64adc7228eb6fd27073c6d29eb1ce047a4d7dc0586ee;

    error Bundle2GateFailed(bytes32 checkName);

    function run() external returns (B1N495RoutePreflight.Result memory result) {
        address routeOwner = vm.envAddress("B1N495_ROUTE_OWNER");
        FinalizedPins memory pins = _loadFinalizedPins();
        uint256 baseFork = _selectPinnedFork(
            "B1N495_BASE_RPC_URL", 8453, pins.baseNumber, pins.baseHash, pins.baseParentHash, true, true
        );
        _assertFreshCapture(pins.capturedAt);
        Addresses memory addresses = computeAddresses(routeOwner);
        _assertBindings(addresses, routeOwner);
        result = _latestFinalizedPreflight(addresses, routeOwner, baseFork, pins);
        requireEligibility(result);
        assertBundle2State(routeOwner, addresses);
    }

    function requireEligibility(B1N495RoutePreflight.Result memory result) public pure {
        if (!result.nvdacEligible) revert Bundle2GateFailed("NVDAC_ELIGIBILITY");
        if (!result.cbzecEvidencePass) revert Bundle2GateFailed("CBZEC_ELIGIBILITY");
        if (!result.cbhypeEligible) revert Bundle2GateFailed("CBHYPE_ELIGIBILITY");
        if (!result.vvvEvidencePass) revert Bundle2GateFailed("VVV_ELIGIBILITY");
    }

    function assertBundle2State(address routeOwner, Addresses memory addresses) public view {
        if (block.chainid != 8453) revert Bundle2GateFailed("CHAIN");
        if (
            _implementation(WHITELIST) != WHITELIST_IMPLEMENTATION || _implementation(SETTLER) != SETTLER_IMPLEMENTATION
        ) revert Bundle2GateFailed("IMPLEMENTATION_SLOT");
        if (
            WHITELIST_IMPLEMENTATION.codehash != WHITELIST_IMPLEMENTATION_HASH
                || SETTLER_IMPLEMENTATION.codehash != SETTLER_IMPLEMENTATION_HASH
        ) revert Bundle2GateFailed("IMPLEMENTATION_HASH");
        if (
            addresses.facade.codehash != FACADE_HASH || addresses.nvdacAdapter.codehash != NVDAC_ADAPTER_HASH
                || addresses.cbzecAdapter.codehash != CBZEC_ADAPTER_HASH
                || addresses.cbhypeAdapter.codehash != CBHYPE_ADAPTER_HASH
                || addresses.uniswapAdapter.codehash != UNISWAP_ADAPTER_HASH
        ) revert Bundle2GateFailed("ROUTER_CODEHASH");

        IB1N500GateWhitelist whitelist = IB1N500GateWhitelist(WHITELIST);
        if (whitelist.owner() != routeOwner || whitelist.pendingOwner() != address(0)) {
            revert Bundle2GateFailed("WHITELIST_OWNER");
        }
        _assertProduct(whitelist, NVDAC);
        _assertProduct(whitelist, CBHYPE);

        IB1N500GateController controller = IB1N500GateController(CONTROLLER);
        if (controller.systemFullyPaused() || controller.systemPartiallyPaused()) {
            revert Bundle2GateFailed("CONTROLLER_PAUSE");
        }

        IB1N500GateSettler settler = IB1N500GateSettler(SETTLER);
        if (settler.owner() != routeOwner || settler.swapRouter() != PRODUCTION_UNISWAP_ROUTER) {
            revert Bundle2GateFailed("SETTLER_BASELINE");
        }

        PairRoutingSwapRouter facade = PairRoutingSwapRouter(payable(addresses.facade));
        _assertActivePair(facade, WETH, addresses.uniswapAdapter);
        _assertActivePair(facade, CBBTC, addresses.uniswapAdapter);
        _assertActivePair(facade, CBZEC, addresses.cbzecAdapter);
        _assertActivePair(facade, VVV, addresses.uniswapAdapter);
        _assertMaturePendingPair(facade, NVDAC, addresses.nvdacAdapter);
        _assertMaturePendingPair(facade, CBHYPE, addresses.cbhypeAdapter);
    }

    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _assertProduct(IB1N500GateWhitelist whitelist, address asset) private view {
        if (
            !whitelist.isWhitelistedUnderlying(asset) || !whitelist.isWhitelistedCollateral(asset)
                || !whitelist.isProductWhitelisted(asset, USDC, USDC, true)
                || !whitelist.isProductWhitelisted(asset, USDC, asset, false)
        ) revert Bundle2GateFailed("PRODUCT");
    }

    function _assertActivePair(PairRoutingSwapRouter facade, address asset, address adapter) private view {
        _assertRoute(facade, asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, adapter, address(0), true);
        _assertRoute(facade, USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput, adapter, address(0), true);
    }

    function _assertMaturePendingPair(PairRoutingSwapRouter facade, address asset, address adapter) private view {
        _assertRoute(facade, asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(0), adapter, false);
        _assertRoute(facade, USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput, address(0), adapter, false);
    }

    function _assertRoute(
        PairRoutingSwapRouter facade,
        address tokenIn,
        address tokenOut,
        PairRoutingSwapRouter.SwapKind kind,
        address expectedActive,
        address expectedPending,
        bool activeRoute
    ) private view {
        (address active, address pending, uint48 activateAfter) =
            facade.routes(facade.routeKey(tokenIn, tokenOut, kind));
        if (active != expectedActive || pending != expectedPending) revert Bundle2GateFailed("ROUTE");
        if (activeRoute) {
            if (activateAfter != 0) revert Bundle2GateFailed("ACTIVE_ROUTE_ETA");
        } else if (activateAfter == 0 || block.timestamp < activateAfter) {
            revert Bundle2GateFailed("ROUTE_DELAY");
        }
    }
}
