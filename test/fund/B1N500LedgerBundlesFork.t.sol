// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PairRoutingSwapRouter} from "../../src/routers/PairRoutingSwapRouter.sol";
import {B1N495RoutePreflight} from "../../script/B1N495RoutePreflight.sol";
import {B1N495RouteToolsBase} from "../../script/B1N495RouteTools.s.sol";
import {B1N500LedgerBundles} from "../../script/B1N500LedgerBundles.s.sol";
import {B1N500LedgerBundle2Gate} from "../../script/B1N500LedgerBundle2Gate.s.sol";

interface IB1N500WhitelistState {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function isWhitelistedUnderlying(address asset) external view returns (bool);
    function isWhitelistedCollateral(address asset) external view returns (bool);
    function isProductWhitelisted(address underlying, address strikeAsset, address collateralAsset, bool isPut)
        external
        view
        returns (bool);
}

interface IB1N500SettlerState {
    function owner() external view returns (address);
    function operator() external view returns (address);
    function addressBook() external view returns (address);
    function aavePool() external view returns (address);
    function swapRouter() external view returns (address);
    function swapFeeTier() external view returns (uint24);
    function batchNonce() external view returns (uint256);
}

interface IB1N500ControllerState {
    function systemFullyPaused() external view returns (bool);
    function systemPartiallyPaused() external view returns (bool);
}

contract B1N500LedgerBundlesForkTest is Test {
    uint256 private constant FORK_BLOCK = 51_712_872;
    uint256 private constant FORK_TIMESTAMP = 1_790_215_091;
    bytes32 private constant FORK_PARENT = 0x8dbbd85f89bf8088a21654454fcaf820a3a03fda2922bc5277b9bbedfb2937eb;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private constant OWNER = 0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7;
    address private constant WHITELIST = 0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A;
    address private constant CONTROLLER = 0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624;
    address private constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address private constant FACADE = 0xFcecd17d0f5e15ed881974a2602c1833C418e28e;
    address private constant UNI_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address private constant WHITELIST_IMPLEMENTATION = 0x5F3b652b2b258e36bc88C3Bdf3c4e1EcF04BCF00;
    address private constant SETTLER_IMPLEMENTATION = 0x645a8A66B812A13D5042939b88C144467B825648;
    address private constant UNI_ADAPTER = 0x9baED665316cCA02BeA40f059F8b84874787210B;
    address private constant NVDAC_ADAPTER = 0xE2562017C63C5B7EcD6F91F4C1510367bcF6284D;
    address private constant CBZEC_ADAPTER = 0xF8c97C9CaefB9799eC55a0a3095c40E1c580Caf1;
    address private constant CBHYPE_ADAPTER = 0xc76287aB15C8ced24f4164CF88B4094B6DC1c039;

    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant WETH = 0x4200000000000000000000000000000000000006;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address private constant CBZEC = 0xB2000000000000000000008501b13360000cb2EC;
    address private constant CBHYPE = 0xB200000000000000000000451d033a5000cb479e;
    address private constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    B1N500LedgerBundles private bundles;
    B1N500LedgerBundle2Gate private gate;
    PairRoutingSwapRouter private facade;
    IB1N500WhitelistState private whitelist;
    IB1N500SettlerState private settler;

    modifier onlyFork() {
        if (block.chainid != 8453) return;
        _;
    }

    function setUp() public {
        if (block.chainid != 8453) return;
        vm.rollFork(FORK_BLOCK);
        assertEq(block.timestamp, FORK_TIMESTAMP);
        assertEq(blockhash(FORK_BLOCK - 1), FORK_PARENT);
        bundles = new B1N500LedgerBundles();
        gate = new B1N500LedgerBundle2Gate();
        facade = PairRoutingSwapRouter(payable(FACADE));
        whitelist = IB1N500WhitelistState(WHITELIST);
        settler = IB1N500SettlerState(SETTLER);
    }

    function test_twoLedgerBundlesMatchLiveStateAndPreserveRollback() public onlyFork {
        _assertBaseline();
        bytes32 implementationBefore = vm.load(SETTLER, IMPLEMENTATION_SLOT);
        bytes32 settlerStateBefore = _settlerState();
        B1N495RouteToolsBase.Addresses memory addresses = gate.computeAddresses(OWNER);

        vm.expectRevert();
        gate.assertBundle2State(OWNER, addresses);
        B1N495RoutePreflight.Result memory eligibility;
        eligibility.cbzecEvidencePass = true;
        eligibility.cbhypeEligible = true;
        eligibility.vvvEvidencePass = true;
        vm.expectRevert();
        gate.requireEligibility(eligibility);

        B1N500LedgerBundles.Transaction[] memory bundle1 = bundles.bundle1();
        assertEq(bundle1.length, 20);
        _execute(bundle1);

        _assertProduct(NVDAC, true);
        _assertProduct(CBHYPE, true);
        _assertPair(WETH, UNI_ADAPTER, address(0));
        _assertPair(CBBTC, UNI_ADAPTER, address(0));
        _assertPair(CBZEC, CBZEC_ADAPTER, address(0));
        _assertPair(VVV, UNI_ADAPTER, address(0));
        _assertPair(NVDAC, address(0), NVDAC_ADAPTER);
        _assertPair(CBHYPE, address(0), CBHYPE_ADAPTER);
        assertEq(settler.swapRouter(), UNI_ROUTER);

        uint48 nvdaEta = _eta(NVDAC);
        uint48 hypeEta = _eta(CBHYPE);
        assertEq(nvdaEta, block.timestamp + facade.ROUTE_DELAY());
        assertEq(hypeEta, nvdaEta);
        vm.expectRevert();
        gate.assertBundle2State(OWNER, addresses);
        vm.warp(nvdaEta);

        eligibility.nvdacEligible = true;
        gate.requireEligibility(eligibility);
        gate.assertBundle2State(OWNER, addresses);

        bytes32 whitelistImplementation = vm.load(WHITELIST, IMPLEMENTATION_SLOT);
        bytes32 settlerImplementation = vm.load(SETTLER, IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(whitelistImplementation))), WHITELIST_IMPLEMENTATION);
        assertEq(address(uint160(uint256(settlerImplementation))), SETTLER_IMPLEMENTATION);
        vm.store(WHITELIST, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0xBEEF)))));
        vm.expectRevert();
        gate.assertBundle2State(OWNER, addresses);
        vm.store(WHITELIST, IMPLEMENTATION_SLOT, whitelistImplementation);
        vm.store(SETTLER, IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0xBEEF)))));
        vm.expectRevert();
        gate.assertBundle2State(OWNER, addresses);
        vm.store(SETTLER, IMPLEMENTATION_SLOT, settlerImplementation);
        gate.assertBundle2State(OWNER, addresses);

        B1N500LedgerBundles.Transaction[] memory bundle2 = bundles.bundle2();
        assertEq(bundle2.length, 5);
        _executeFirst(bundle2, 4);

        vm.record();
        _executeOne(bundle2[4]);
        (, bytes32[] memory settlerWrites) = vm.accesses(SETTLER);
        assertEq(settlerWrites.length, 1, "cutover must change one settler slot");

        _assertPair(WETH, UNI_ADAPTER, address(0));
        _assertPair(CBBTC, UNI_ADAPTER, address(0));
        _assertPair(NVDAC, NVDAC_ADAPTER, address(0));
        _assertPair(CBZEC, CBZEC_ADAPTER, address(0));
        _assertPair(CBHYPE, CBHYPE_ADAPTER, address(0));
        _assertPair(VVV, UNI_ADAPTER, address(0));
        assertEq(settler.swapRouter(), FACADE);
        assertEq(vm.load(SETTLER, IMPLEMENTATION_SLOT), implementationBefore);
        assertEq(_settlerState(), settlerStateBefore);

        B1N500LedgerBundles.Transaction memory rollbackTx = bundles.rollback();
        vm.record();
        _executeOne(rollbackTx);
        (, settlerWrites) = vm.accesses(SETTLER);
        assertEq(settlerWrites.length, 1, "rollback must change one settler slot");
        assertEq(settler.swapRouter(), UNI_ROUTER);
        assertEq(vm.load(SETTLER, IMPLEMENTATION_SLOT), implementationBefore);
        assertEq(_settlerState(), settlerStateBefore);
    }

    function _assertBaseline() private view {
        assertEq(block.chainid, 8453);
        assertEq(whitelist.owner(), OWNER);
        assertEq(whitelist.pendingOwner(), address(0));
        assertEq(facade.owner(), OWNER);
        assertEq(facade.pendingOwner(), address(0));
        assertEq(facade.settler(), SETTLER);
        assertEq(facade.ROUTE_DELAY(), 1 days);
        assertEq(settler.owner(), OWNER);
        assertEq(settler.swapRouter(), UNI_ROUTER);
        assertFalse(IB1N500ControllerState(CONTROLLER).systemFullyPaused());
        assertFalse(IB1N500ControllerState(CONTROLLER).systemPartiallyPaused());

        _assertProduct(NVDAC, false);
        _assertProduct(CBHYPE, false);
        _assertProduct(CBZEC, true);
        _assertProduct(VVV, true);
        _assertPendingMaturedPair(WETH, UNI_ADAPTER);
        _assertPendingMaturedPair(CBBTC, UNI_ADAPTER);
        _assertPendingMaturedPair(CBZEC, CBZEC_ADAPTER);
        _assertPendingMaturedPair(VVV, UNI_ADAPTER);
        _assertPair(NVDAC, address(0), address(0));
        _assertPair(CBHYPE, address(0), address(0));
    }

    function _assertProduct(address asset, bool expected) private view {
        assertEq(whitelist.isWhitelistedUnderlying(asset), expected);
        assertEq(whitelist.isWhitelistedCollateral(asset), expected);
        assertEq(whitelist.isProductWhitelisted(asset, USDC, USDC, true), expected);
        assertEq(whitelist.isProductWhitelisted(asset, USDC, asset, false), expected);
    }

    function _assertPendingMaturedPair(address asset, address adapter) private view {
        _assertPair(asset, address(0), adapter);
        (,, uint48 callEta) = facade.routes(facade.routeKey(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput));
        (,, uint48 putEta) = facade.routes(facade.routeKey(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput));
        assertGt(callEta, 0);
        assertGt(putEta, 0);
        assertLe(callEta, block.timestamp);
        assertLe(putEta, block.timestamp);
    }

    function _assertPair(address asset, address active, address pending) private view {
        _assertRoute(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, active, pending);
        _assertRoute(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput, active, pending);
    }

    function _assertRoute(
        address tokenIn,
        address tokenOut,
        PairRoutingSwapRouter.SwapKind kind,
        address active,
        address pending
    ) private view {
        (address actualActive, address actualPending, uint48 eta) =
            facade.routes(facade.routeKey(tokenIn, tokenOut, kind));
        assertEq(actualActive, active);
        assertEq(actualPending, pending);
        if (pending == address(0)) assertEq(eta, 0);
    }

    function _eta(address asset) private view returns (uint48) {
        (, address callPending, uint48 callEta) =
            facade.routes(facade.routeKey(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput));
        (, address putPending, uint48 putEta) =
            facade.routes(facade.routeKey(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput));
        assertTrue(callPending != address(0) && putPending != address(0));
        assertEq(callEta, putEta);
        return callEta;
    }

    function _execute(B1N500LedgerBundles.Transaction[] memory txs) private {
        _executeFirst(txs, txs.length);
    }

    function _executeFirst(B1N500LedgerBundles.Transaction[] memory txs, uint256 count) private {
        for (uint256 i; i < count; ++i) {
            _executeOne(txs[i]);
        }
    }

    function _executeOne(B1N500LedgerBundles.Transaction memory txn) private {
        assertEq(txn.value, 0);
        vm.prank(OWNER);
        (bool ok, bytes memory reason) = txn.to.call(txn.data);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _settlerState() private view returns (bytes32) {
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
