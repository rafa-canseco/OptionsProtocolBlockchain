// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {AerodromeSlipstreamAdapter} from "../src/routers/AerodromeSlipstreamAdapter.sol";
import {UniswapV3SettlementAdapter} from "../src/routers/UniswapV3SettlementAdapter.sol";
import {B1N495RoutePreflight, IB1N495PreflightFeed} from "./B1N495RoutePreflight.sol";

abstract contract B1N495RouteToolsBase is Script {
    address internal constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant DETERMINISTIC_DEPLOYER_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    address internal constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant CBZEC = 0xB2000000000000000000008501b13360000cb2EC;
    address internal constant CBHYPE = 0xB200000000000000000000451d033a5000cb479e;
    address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address internal constant AERO_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address internal constant AERO_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address internal constant NVDAC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    address internal constant CBZEC_POOL = 0x0Fc47C17AF86078d809358db1b4db2DeBC988566;
    address internal constant CBHYPE_POOL = 0xD5Eaea9da564217EA101D1E369fDA168A3025686;
    address internal constant HYPE_FEED = 0xa5a72eF19F82A579431186402425593a559ed352;
    address internal constant ZEC_FEED = 0x21082CA28570f0ccfb089465bFaEfDc77b00D367;

    bytes32 internal constant FACADE_SALT = keccak256("B1N-495:facade:v1");
    bytes32 internal constant NVDAC_SALT = keccak256("B1N-495:NVDAc:v1");
    bytes32 internal constant CBZEC_SALT = keccak256("B1N-495:cbZEC:v1");
    bytes32 internal constant CBHYPE_SALT = keccak256("B1N-495:cbHYPE:v1");
    bytes32 internal constant UNISWAP_SALT = keccak256("B1N-495:uniswap:v1");

    struct Addresses {
        address facade;
        address nvdacAdapter;
        address cbzecAdapter;
        address cbhypeAdapter;
        address uniswapAdapter;
    }

    struct FinalizedPins {
        uint256 baseNumber;
        bytes32 baseHash;
        bytes32 baseParentHash;
        uint256 hypeNumber;
        bytes32 hypeHash;
        bytes32 hypeParentHash;
        uint256 arbNumber;
        bytes32 arbHash;
        bytes32 arbParentHash;
        uint256 capturedAt;
    }

    error InvalidDeployment(bytes32 component);
    error UnexpectedRoute(bytes32 routeKey);
    error ActivationNotEligible(address asset);

    function computeAddresses(address routeOwner) public pure returns (Addresses memory a) {
        bytes memory facadeInit =
            abi.encodePacked(type(PairRoutingSwapRouter).creationCode, abi.encode(SETTLER, routeOwner));
        a.facade = _create2Address(FACADE_SALT, keccak256(facadeInit));
        a.nvdacAdapter = _aeroAddress(a.facade, NVDAC_POOL, NVDAC, 10, NVDAC_SALT);
        a.cbzecAdapter = _aeroAddress(a.facade, CBZEC_POOL, CBZEC, 200, CBZEC_SALT);
        a.cbhypeAdapter = _aeroAddress(a.facade, CBHYPE_POOL, CBHYPE, 200, CBHYPE_SALT);
        bytes memory uniInit = abi.encodePacked(type(UniswapV3SettlementAdapter).creationCode, abi.encode(a.facade));
        a.uniswapAdapter = _create2Address(UNISWAP_SALT, keccak256(uniInit));
    }

    function _deploy(address routeOwner) internal returns (Addresses memory a) {
        if (block.chainid != 8453 || DETERMINISTIC_DEPLOYER.codehash != DETERMINISTIC_DEPLOYER_CODEHASH) {
            revert InvalidDeployment("CHAIN_OR_DEPLOYER");
        }
        a = computeAddresses(routeOwner);
        _deployIfMissing(
            a.facade,
            FACADE_SALT,
            abi.encodePacked(type(PairRoutingSwapRouter).creationCode, abi.encode(SETTLER, routeOwner)),
            "FACADE"
        );
        _deployIfMissing(a.nvdacAdapter, NVDAC_SALT, _aeroInit(a.facade, NVDAC_POOL, NVDAC, 10), "NVDAC_ADAPTER");
        _deployIfMissing(a.cbzecAdapter, CBZEC_SALT, _aeroInit(a.facade, CBZEC_POOL, CBZEC, 200), "CBZEC_ADAPTER");
        _deployIfMissing(a.cbhypeAdapter, CBHYPE_SALT, _aeroInit(a.facade, CBHYPE_POOL, CBHYPE, 200), "CBHYPE_ADAPTER");
        _deployIfMissing(
            a.uniswapAdapter,
            UNISWAP_SALT,
            abi.encodePacked(type(UniswapV3SettlementAdapter).creationCode, abi.encode(a.facade)),
            "UNISWAP_ADAPTER"
        );
        _assertBindings(a, routeOwner);
    }

    function _proposeApproved(Addresses memory a) internal {
        PairRoutingSwapRouter facade = PairRoutingSwapRouter(payable(a.facade));
        _propose(facade, WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, a.uniswapAdapter);
        _propose(facade, USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput, a.uniswapAdapter);
        _propose(facade, CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, a.uniswapAdapter);
        _propose(facade, USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput, a.uniswapAdapter);
        _assertDisabled(facade, NVDAC);
        _assertDisabled(facade, CBZEC);
        _assertDisabled(facade, CBHYPE);
        _assertDisabled(facade, VVV);
    }

    function _activatePreserved(Addresses memory a) internal {
        PairRoutingSwapRouter facade = PairRoutingSwapRouter(payable(a.facade));
        _activate(facade, WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, a.uniswapAdapter);
        _activate(facade, USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput, a.uniswapAdapter);
        _activate(facade, CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, a.uniswapAdapter);
        _activate(facade, USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput, a.uniswapAdapter);
        _assertDisabled(facade, NVDAC);
        _assertDisabled(facade, CBZEC);
        _assertDisabled(facade, CBHYPE);
        _assertDisabled(facade, VVV);
    }

    function _assertBindings(Addresses memory a, address routeOwner) internal view {
        PairRoutingSwapRouter facade = PairRoutingSwapRouter(payable(a.facade));
        if (
            a.facade.code.length == 0 || facade.settler() != SETTLER || facade.owner() != routeOwner
                || facade.ROUTE_DELAY() != 1 days
        ) revert InvalidDeployment("FACADE_BINDING");
        _assertAero(a.nvdacAdapter, a.facade, NVDAC_POOL, NVDAC, 10, 500);
        _assertAero(a.cbzecAdapter, a.facade, CBZEC_POOL, CBZEC, 200, 2000);
        _assertAero(a.cbhypeAdapter, a.facade, CBHYPE_POOL, CBHYPE, 200, 2000);
        UniswapV3SettlementAdapter uni = UniswapV3SettlementAdapter(a.uniswapAdapter);
        if (a.uniswapAdapter.code.length == 0 || uni.facade() != a.facade || uni.settler() != SETTLER) {
            revert InvalidDeployment("UNISWAP_BINDING");
        }
    }

    function _assertAero(address target, address facade, address pool, address asset, int24 spacing, uint24 fee)
        private
        view
    {
        AerodromeSlipstreamAdapter adapter = AerodromeSlipstreamAdapter(payable(target));
        if (
            target.code.length == 0 || adapter.facade() != facade || adapter.settler() != SETTLER
                || adapter.venueRouter() != AERO_ROUTER || adapter.factory() != AERO_FACTORY || adapter.pool() != pool
                || adapter.tokenA() != asset || adapter.tokenB() != USDC || adapter.tickSpacing() != spacing
                || adapter.effectiveFee() != fee
        ) revert InvalidDeployment("AERODROME_BINDING");
    }

    function _propose(
        PairRoutingSwapRouter facade,
        address tokenIn,
        address tokenOut,
        PairRoutingSwapRouter.SwapKind kind,
        address adapter
    ) private {
        bytes32 key = facade.routeKey(tokenIn, tokenOut, kind);
        (address active, address pending, uint48 activateAfter) = facade.routes(key);
        if (active == adapter && pending == address(0) && activateAfter == 0) return;
        if (active == address(0) && pending == adapter && activateAfter != 0) return;
        if (active != address(0) || pending != address(0) || activateAfter != 0) revert UnexpectedRoute(key);
        facade.proposeRoute(tokenIn, tokenOut, kind, adapter);
        (active, pending,) = facade.routes(key);
        if (active != address(0) || pending != adapter) revert UnexpectedRoute(key);
    }

    function _activate(
        PairRoutingSwapRouter facade,
        address tokenIn,
        address tokenOut,
        PairRoutingSwapRouter.SwapKind kind,
        address adapter
    ) private {
        bytes32 key = facade.routeKey(tokenIn, tokenOut, kind);
        (address active, address pending, uint48 activateAfter) = facade.routes(key);
        if (active == adapter && pending == address(0)) return;
        if (active != address(0) || pending != adapter || block.timestamp < activateAfter) revert UnexpectedRoute(key);
        facade.activateRoute(tokenIn, tokenOut, kind);
        (active, pending, activateAfter) = facade.routes(key);
        if (active != adapter || pending != address(0) || activateAfter != 0) revert UnexpectedRoute(key);
    }

    function _assertDisabled(PairRoutingSwapRouter facade, address asset) private view {
        bytes32 callKey = facade.routeKey(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        bytes32 putKey = facade.routeKey(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput);
        (address callActive, address callPending, uint48 callActivateAfter) = facade.routes(callKey);
        (address putActive, address putPending, uint48 putActivateAfter) = facade.routes(putKey);
        if (callActive != address(0) || callPending != address(0) || callActivateAfter != 0) {
            revert ActivationNotEligible(asset);
        }
        if (putActive != address(0) || putPending != address(0) || putActivateAfter != 0) {
            revert ActivationNotEligible(asset);
        }
    }

    function _latestFinalizedPreflight(
        Addresses memory a,
        address routeOwner,
        uint256 baseFork,
        FinalizedPins memory pins
    ) internal returns (B1N495RoutePreflight.Result memory result) {
        _selectPinnedFork(
            "B1N495_HYPEREVM_RPC_URL", 999, pins.hypeNumber, pins.hypeHash, pins.hypeParentHash, true, false
        );
        (uint256 hypePrice8, uint256 hypeUpdatedAt) = _readFeed(HYPE_FEED, 8);

        _selectPinnedFork(
            "B1N495_ARBITRUM_RPC_URL", 42161, pins.arbNumber, pins.arbHash, pins.arbParentHash, false, false
        );
        (uint256 zecPrice18, uint256 zecUpdatedAt) = _readFeed(ZEC_FEED, 18);
        vm.selectFork(baseFork);

        B1N495RoutePreflight preflight = new B1N495RoutePreflight();
        result = preflight.check(
            B1N495RoutePreflight.Deployment({
                routeOwner: routeOwner,
                settlementRecipient: vm.envAddress("B1N495_SETTLEMENT_RECIPIENT"),
                facade: a.facade,
                nvdacAdapter: a.nvdacAdapter,
                cbzecAdapter: a.cbzecAdapter,
                cbhypeAdapter: a.cbhypeAdapter,
                uniswapAdapter: a.uniswapAdapter
            }),
            B1N495RoutePreflight.OracleEvidence({
                observedAt: pins.capturedAt,
                cbzecPrice8: zecPrice18 / 1e10,
                cbzecUpdatedAt: zecUpdatedAt,
                cbhypePrice8: hypePrice8,
                cbhypeUpdatedAt: hypeUpdatedAt
            })
        );
        console2.log("NVDAc eligible/deviation", result.nvdacEligible, result.nvdacDeviationBps);
        console2.log("cbZEC evidence-pass/deviation", result.cbzecEvidencePass, result.cbzecDeviationBps);
        console2.log("cbHYPE eligible/deviation", result.cbhypeEligible, result.cbhypeDeviationBps);
        console2.log("VVV evidence-pass/deviation", result.vvvEvidencePass, result.vvvDeviationBps);
    }

    function _loadFinalizedPins() internal returns (FinalizedPins memory pins) {
        string[] memory command = new string[](2);
        command[0] = "python3";
        command[1] = "scripts/b1n495-finalized-pins.py";
        bytes memory encoded = vm.ffi(command);
        pins = abi.decode(encoded, (FinalizedPins));
    }

    function _selectPinnedFork(
        string memory rpcEnvName,
        uint256 chainId,
        uint256 finalizedBlock,
        bytes32 finalizedHash,
        bytes32 parentHash,
        bool verifyEvmBlock,
        bool verifyParent
    ) internal returns (uint256 forkId) {
        _verifyPinnedHeader(rpcEnvName, finalizedBlock, finalizedHash);
        forkId = vm.createSelectFork(vm.envString(rpcEnvName), finalizedBlock);
        // Arbitrum NUMBER/BLOCKHASH expose L1 values; createSelectFork still pins the captured finalized L2 RPC block.
        if (block.chainid != chainId || (verifyEvmBlock && block.number != finalizedBlock)) {
            revert InvalidDeployment("FINALIZED_PIN");
        }
        if (verifyParent && blockhash(block.number - 1) != parentHash) revert InvalidDeployment("FINALIZED_PIN");
    }

    function _verifyPinnedHeader(string memory rpcEnvName, uint256 number, bytes32 expectedHash) private {
        string[] memory command = new string[](6);
        command[0] = "python3";
        command[1] = "scripts/b1n495-finalized-pins.py";
        command[2] = "--verify";
        command[3] = rpcEnvName;
        command[4] = vm.toString(number);
        command[5] = vm.toString(expectedHash);
        vm.ffi(command);
    }

    function _assertFreshCapture(uint256 capturedAt) internal view {
        if (capturedAt < block.timestamp || capturedAt - block.timestamp > 1 hours) {
            revert InvalidDeployment("FINALIZED_CAPTURE");
        }
    }

    function _readFeed(address feed, uint8 expectedDecimals) private view returns (uint256 answer, uint256 updatedAt) {
        if (feed.code.length == 0 || IB1N495PreflightFeed(feed).decimals() != expectedDecimals) {
            revert InvalidDeployment("FOREIGN_FEED");
        }
        (uint80 roundId, int256 signedAnswer, uint256 startedAt, uint256 feedUpdatedAt, uint80 answeredInRound) =
            IB1N495PreflightFeed(feed).latestRoundData();
        startedAt;
        updatedAt = feedUpdatedAt;
        if (signedAnswer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < roundId) {
            revert InvalidDeployment("FOREIGN_ROUND");
        }
        answer = uint256(signedAnswer);
    }

    function _deployIfMissing(address expected, bytes32 salt, bytes memory initCode, bytes32 component) private {
        if (expected.code.length != 0) return;
        (bool ok,) = DETERMINISTIC_DEPLOYER.call(bytes.concat(salt, initCode));
        if (!ok || expected.code.length == 0) revert InvalidDeployment(component);
    }

    function _aeroAddress(address facade, address pool, address asset, int24 spacing, bytes32 salt)
        private
        pure
        returns (address)
    {
        return _create2Address(salt, keccak256(_aeroInit(facade, pool, asset, spacing)));
    }

    function _aeroInit(address facade, address pool, address asset, int24 spacing) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(AerodromeSlipstreamAdapter).creationCode,
            abi.encode(facade, AERO_ROUTER, AERO_FACTORY, pool, asset, USDC, spacing)
        );
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", DETERMINISTIC_DEPLOYER, salt, initCodeHash)))));
    }
}

/// @notice Idempotently deploys immutable routing contracts and proposes only release-approved routes.
contract PrepareB1N495Routes is B1N495RouteToolsBase {
    function run() external returns (Addresses memory a) {
        address routeOwner = vm.envAddress("B1N495_ROUTE_OWNER");
        if (keccak256(bytes(vm.envString("B1N495_CONFIRM"))) != keccak256("PREPARE_DISABLED_ROUTES")) {
            revert InvalidDeployment("CONFIRMATION");
        }
        FinalizedPins memory pins = _loadFinalizedPins();
        uint256 baseFork = _selectPinnedFork(
            "B1N495_BASE_RPC_URL", 8453, pins.baseNumber, pins.baseHash, pins.baseParentHash, true, true
        );
        _assertFreshCapture(pins.capturedAt);
        vm.startBroadcast(routeOwner);
        a = _deploy(routeOwner);
        vm.stopBroadcast();
        _latestFinalizedPreflight(a, routeOwner, baseFork, pins);
        vm.startBroadcast(routeOwner);
        _proposeApproved(a);
        vm.stopBroadcast();
        _assertBindings(a, routeOwner);
    }
}

/// @notice Latest-finalized, multi-chain, read-only deployment gate. It never starts a broadcast.
contract PreflightB1N495Routes is B1N495RouteToolsBase {
    function run() external returns (B1N495RoutePreflight.Result memory result) {
        address routeOwner = vm.envAddress("B1N495_ROUTE_OWNER");
        FinalizedPins memory pins = _loadFinalizedPins();
        uint256 baseFork = _selectPinnedFork(
            "B1N495_BASE_RPC_URL", 8453, pins.baseNumber, pins.baseHash, pins.baseParentHash, true, true
        );
        _assertFreshCapture(pins.capturedAt);
        Addresses memory a = computeAddresses(routeOwner);
        _assertBindings(a, routeOwner);
        result = _latestFinalizedPreflight(a, routeOwner, baseFork, pins);
    }
}

/// @notice Explicit delayed activation. cbZEC, cbHYPE, and VVV remain disabled in this release.
contract ActivateB1N495Routes is B1N495RouteToolsBase {
    function run() external {
        address routeOwner = vm.envAddress("B1N495_ROUTE_OWNER");
        FinalizedPins memory pins = _loadFinalizedPins();
        uint256 baseFork = _selectPinnedFork(
            "B1N495_BASE_RPC_URL", 8453, pins.baseNumber, pins.baseHash, pins.baseParentHash, true, true
        );
        _assertFreshCapture(pins.capturedAt);
        Addresses memory a = computeAddresses(routeOwner);
        _assertBindings(a, routeOwner);

        if (keccak256(bytes(vm.envString("B1N495_CONFIRM"))) != keccak256("ACTIVATE_DELAYED_ROUTES")) {
            revert InvalidDeployment("CONFIRMATION");
        }
        _latestFinalizedPreflight(a, routeOwner, baseFork, pins);

        vm.startBroadcast(routeOwner);
        _activatePreserved(a);
        vm.stopBroadcast();
    }
}
