// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {UniswapV3SettlementAdapter} from "../src/routers/UniswapV3SettlementAdapter.sol";

interface IMainnetAddressBook {
    function batchSettler() external view returns (address);
}

interface IMainnetBatchSettler {
    struct Quote {
        address oToken;
        uint256 bidPrice;
        uint256 deadline;
        uint256 quoteId;
        uint256 maxAmount;
        uint256 makerNonce;
    }

    function owner() external view returns (address);
    function operator() external view returns (address);
    function swapRouter() external view returns (address);
    function protocolFeeBps() external view returns (uint256);
    function makerNonce(address maker) external view returns (uint256);
    function mmOTokenBalance(address maker, address oToken) external view returns (uint256);
    function hashQuote(Quote calldata quote) external view returns (bytes32);
    function setWhitelistedMM(address maker, bool allowed) external;
    function setSwapRouter(address router) external;
    function setAssetSwapFeeTier(address asset, uint24 feeTier) external;
    function executeOrder(Quote calldata quote, bytes calldata signature, uint256 amount, uint256 collateral)
        external
        returns (uint256 vaultId);
    function batchSettleVaults(address[] calldata owners, uint256[] calldata vaultIds) external;
    function physicalRedeem(address oToken, address user, uint256 amount, uint256 slippage, address maker) external;
}

interface IMainnetOracle {
    function getPrice(address asset) external view returns (uint256);
    function setExpiryPrice(address asset, uint256 expiry, uint256 price) external;
    function setPriceDeviationThreshold(uint256 thresholdBps) external;
    function setMaxOracleStaleness(uint256 maxStaleness) external;
}

interface IMainnetOTokenFactory {
    function getTargetOTokenAddress(
        address underlying,
        address strike,
        address collateral,
        uint256 strikePrice,
        uint256 expiry,
        bool isPut
    ) external view returns (address);
    function createOToken(
        address underlying,
        address strike,
        address collateral,
        uint256 strikePrice,
        uint256 expiry,
        bool isPut
    ) external returns (address);
}

interface IMainnetWhitelist {
    function isProductWhitelisted(address underlying, address strike, address collateral, bool isPut)
        external
        view
        returns (bool);
    function whitelistProduct(address underlying, address strike, address collateral, bool isPut) external;
}

contract UniswapV3SettlementAdapterForkTest is Test {
    uint256 internal constant FORK_BLOCK = 50_400_001;

    address internal constant ADDRESS_BOOK = 0x48FE24a69417038a2D3d46B2B6B9De03b884eD72;
    address internal constant CONTROLLER = 0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624;
    address internal constant MARGIN_POOL = 0xa1e04873F6d112d84824C88c9D6937bE38811657;
    address internal constant FACTORY = 0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7;
    address internal constant ORACLE = 0x09daa0194A3AF59b46C5443aF9C20fAd98347671;
    address internal constant WHITELIST = 0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A;
    address internal constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;

    address internal constant OWNER = 0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7;
    address internal constant OPERATOR = 0x0bbD599cEB63b4603c2F007c5122e33f7b12364c;
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant PHYSICAL_DELIVERY_TOPIC = keccak256("PhysicalDelivery(address,address,uint256,uint256)");

    uint256 internal constant MM_KEY = 0xB1493;
    address internal mm;
    address internal user = address(0x4931);

    IMainnetBatchSettler internal settler = IMainnetBatchSettler(SETTLER);
    IMainnetOracle internal oracle = IMainnetOracle(ORACLE);
    IMainnetOTokenFactory internal factory = IMainnetOTokenFactory(FACTORY);
    IMainnetWhitelist internal whitelist = IMainnetWhitelist(WHITELIST);
    PairRoutingSwapRouter internal facade;
    UniswapV3SettlementAdapter internal adapter;

    struct Outcome {
        uint256 userOutput;
        uint256 mmUsdc;
        uint256 contraAmount;
        uint256 collateralUsed;
    }

    modifier onlyFork() {
        if (block.chainid != 8453) return;
        _;
    }

    function setUp() public {
        if (block.chainid != 8453) return;
        vm.rollFork(FORK_BLOCK);

        assertEq(IMainnetAddressBook(ADDRESS_BOOK).batchSettler(), SETTLER);
        assertEq(settler.swapRouter(), SWAP_ROUTER);
        mm = vm.addr(MM_KEY);

        facade = new PairRoutingSwapRouter(SETTLER, address(this));
        adapter = new UniswapV3SettlementAdapter(address(facade));
        _activate(WETH, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _activate(CBBTC, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _activate(USDC, WETH, PairRoutingSwapRouter.SwapKind.ExactOutput);
        _activate(USDC, CBBTC, PairRoutingSwapRouter.SwapKind.ExactOutput);
        _activate(VVV, USDC, PairRoutingSwapRouter.SwapKind.ExactInput);
        _activate(USDC, VVV, PairRoutingSwapRouter.SwapKind.ExactOutput);

        vm.startPrank(OWNER);
        settler.setWhitelistedMM(mm, true);
        settler.setAssetSwapFeeTier(VVV, 3000);
        oracle.setPriceDeviationThreshold(0);
        oracle.setMaxOracleStaleness(0);
        vm.stopPrank();

        deal(USDC, mm, 1_000_000e6);
        deal(USDC, user, 1_000_000e6);
        deal(WETH, user, 1_000e18);
        deal(CBBTC, user, 1_000e8);
        deal(VVV, user, 1_000e18);

        vm.prank(mm);
        IERC20(USDC).approve(SETTLER, type(uint256).max);
        vm.startPrank(user);
        IERC20(USDC).approve(MARGIN_POOL, type(uint256).max);
        IERC20(WETH).approve(MARGIN_POOL, type(uint256).max);
        IERC20(CBBTC).approve(MARGIN_POOL, type(uint256).max);
        IERC20(VVV).approve(MARGIN_POOL, type(uint256).max);
        vm.stopPrank();
    }

    function test_wethPutMatchesDirectProductionRouter() public onlyFork {
        uint256 spot = oracle.getPrice(WETH);
        _assertParity(WETH, true, spot + spot / 10, spot, 1e8);
    }

    function test_wethCallMatchesDirectProductionRouter() public onlyFork {
        uint256 spot = oracle.getPrice(WETH);
        _assertParity(WETH, false, spot - spot / 10, spot, 1e8);
    }

    function test_cbBtcPutMatchesDirectProductionRouter() public onlyFork {
        uint256 spot = oracle.getPrice(CBBTC);
        _assertParity(CBBTC, true, spot + spot / 10, spot, 1e8);
    }

    function test_cbBtcCallMatchesDirectProductionRouter() public onlyFork {
        uint256 spot = oracle.getPrice(CBBTC);
        _assertParity(CBBTC, false, spot - spot / 10, spot, 1e8);
    }

    function test_vvvPutMatchesDirectProductionRouter() public onlyFork {
        uint256 spot = _spotFromExactInput(VVV, 3000);
        _assertParity(VVV, true, spot + spot / 10, spot, 1e8);
    }

    function test_vvvCallMatchesDirectProductionRouter() public onlyFork {
        uint256 spot = _spotFromExactInput(VVV, 3000);
        _assertParity(VVV, false, spot - spot / 10, spot, 1e8);
    }

    function test_looseExactOutputMaximumMatchesDirectProductionRouter() public onlyFork {
        uint256 spot = oracle.getPrice(WETH);
        (address oToken,, uint256 collateral) = _openAndSettle(WETH, true, spot + spot / 10, spot, 1e8);
        uint256 looseMaximum = collateral + collateral / 2;
        uint256 snapshot = vm.snapshotState();

        Outcome memory direct = _redeem(oToken, WETH, 1e8, looseMaximum);
        assertTrue(vm.revertToState(snapshot));
        vm.prank(OWNER);
        settler.setSwapRouter(address(facade));
        Outcome memory routed = _redeem(oToken, WETH, 1e8, looseMaximum);

        assertEq(routed.userOutput, direct.userOutput);
        assertEq(routed.mmUsdc, direct.mmUsdc);
        assertEq(routed.collateralUsed, direct.collateralUsed);
        assertLt(routed.collateralUsed, collateral);
        assertEq(IERC20(USDC).balanceOf(address(facade)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
    }

    function test_facadeFailureMatchesDirectRouterAndRollbackPreservesState() public onlyFork {
        uint256 spot = oracle.getPrice(WETH);
        (address oToken, uint256 vaultId, uint256 collateral) = _openAndSettle(WETH, true, spot + spot / 10, spot, 1e8);
        uint256 snapshot = vm.snapshotState();

        (bool directOk, bytes memory directReason) = _callPhysical(oToken, 1e8, 1, mm);
        assertFalse(directOk);
        assertGt(directReason.length, 0);

        assertTrue(vm.revertToState(snapshot));
        bytes32 implementationBefore = vm.load(SETTLER, IMPLEMENTATION_SLOT);
        address ownerBefore = settler.owner();
        address operatorBefore = settler.operator();
        uint256 feeBefore = settler.protocolFeeBps();
        uint256 ledgerBefore = settler.mmOTokenBalance(mm, oToken);

        vm.prank(OWNER);
        settler.setSwapRouter(address(facade));
        (bool facadeOk, bytes memory facadeReason) = _callPhysical(oToken, 1e8, 1, mm);
        assertFalse(facadeOk);
        assertGt(facadeReason.length, 0);

        vm.prank(OWNER);
        settler.setSwapRouter(SWAP_ROUTER);
        assertEq(settler.swapRouter(), SWAP_ROUTER);
        assertEq(vm.load(SETTLER, IMPLEMENTATION_SLOT), implementationBefore);
        assertEq(settler.owner(), ownerBefore);
        assertEq(settler.operator(), operatorBefore);
        assertEq(settler.protocolFeeBps(), feeBefore);
        assertEq(settler.mmOTokenBalance(mm, oToken), ledgerBefore);
        assertEq(IERC20(USDC).balanceOf(address(facade)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertGt(collateral, 0);
        assertGt(vaultId, 0);
    }

    function _assertParity(address underlying, bool isPut, uint256 strike, uint256 expiryPrice, uint256 amount)
        internal
    {
        (address oToken,, uint256 collateral) = _openAndSettle(underlying, isPut, strike, expiryPrice, amount);
        uint256 slippage = isPut ? collateral : (amount * strike) / 1e10;
        uint256 snapshot = vm.snapshotState();

        Outcome memory direct = _redeem(oToken, underlying, amount, slippage);
        assertTrue(vm.revertToState(snapshot));

        vm.prank(OWNER);
        settler.setSwapRouter(address(facade));
        Outcome memory routed = _redeem(oToken, underlying, amount, slippage);

        assertEq(routed.userOutput, direct.userOutput);
        assertEq(routed.mmUsdc, direct.mmUsdc);
        assertEq(routed.contraAmount, direct.contraAmount);
        assertEq(routed.collateralUsed, direct.collateralUsed);
        assertEq(settler.mmOTokenBalance(mm, oToken), 0);
        assertEq(IERC20(underlying).balanceOf(address(facade)), 0);
        assertEq(IERC20(USDC).balanceOf(address(facade)), 0);
        assertEq(IERC20(underlying).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).allowance(address(facade), address(adapter)), 0);
        assertEq(IERC20(underlying).allowance(address(facade), address(adapter)), 0);
        assertEq(IERC20(USDC).allowance(address(adapter), SWAP_ROUTER), 0);
        assertEq(IERC20(underlying).allowance(address(adapter), SWAP_ROUTER), 0);
    }

    function _openAndSettle(address underlying, bool isPut, uint256 strike, uint256 expiryPrice, uint256 amount)
        internal
        returns (address oToken, uint256 vaultId, uint256 collateral)
    {
        address collateralAsset = isPut ? USDC : underlying;
        _ensureProduct(underlying, collateralAsset, isPut);
        uint256 expiry = _nextExpiry();
        oToken = _createOption(underlying, collateralAsset, strike, expiry, isPut);

        IMainnetBatchSettler.Quote memory quote = IMainnetBatchSettler.Quote({
            oToken: oToken,
            bidPrice: 1e6,
            deadline: block.timestamp + 1 hours,
            quoteId: uint256(keccak256(abi.encode(underlying, isPut, strike, expiry))),
            maxAmount: amount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        collateral = isPut ? (amount * strike) / 1e10 : _scaleUnderlying(amount, underlying);
        vm.prank(user);
        vaultId = settler.executeOrder(quote, signature, amount, collateral);

        vm.warp(expiry + 1);
        vm.prank(OPERATOR);
        oracle.setExpiryPrice(underlying, expiry, expiryPrice);

        address[] memory owners = new address[](1);
        owners[0] = user;
        uint256[] memory vaultIds = new uint256[](1);
        vaultIds[0] = vaultId;
        vm.prank(OPERATOR);
        settler.batchSettleVaults(owners, vaultIds);
    }

    function _redeem(address oToken, address underlying, uint256 amount, uint256 slippage)
        internal
        returns (Outcome memory outcome)
    {
        bool isPut = _isPut(oToken);
        address output = isPut ? underlying : USDC;
        uint256 userBefore = IERC20(output).balanceOf(user);
        uint256 mmBefore = IERC20(USDC).balanceOf(mm);
        vm.recordLogs();
        vm.prank(OPERATOR);
        settler.physicalRedeem(oToken, user, amount, slippage, mm);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        outcome.userOutput = IERC20(output).balanceOf(user) - userBefore;
        outcome.mmUsdc = IERC20(USDC).balanceOf(mm) - mmBefore;
        (outcome.contraAmount, outcome.collateralUsed) = _physicalEvent(logs, oToken);
    }

    function _callPhysical(address oToken, uint256 amount, uint256 slippage, address mm_)
        internal
        returns (bool ok, bytes memory reason)
    {
        vm.prank(OPERATOR);
        (ok, reason) =
            SETTLER.call(abi.encodeCall(IMainnetBatchSettler.physicalRedeem, (oToken, user, amount, slippage, mm_)));
    }

    function _physicalEvent(Vm.Log[] memory logs, address oToken)
        internal
        pure
        returns (uint256 contraAmount, uint256 collateralUsed)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == SETTLER && logs[i].topics.length == 3 && logs[i].topics[0] == PHYSICAL_DELIVERY_TOPIC
                    && address(uint160(uint256(logs[i].topics[1]))) == oToken
            ) return abi.decode(logs[i].data, (uint256, uint256));
        }
        revert("missing PhysicalDelivery");
    }

    function _ensureProduct(address underlying, address collateralAsset, bool isPut) internal {
        if (!whitelist.isProductWhitelisted(underlying, USDC, collateralAsset, isPut)) {
            vm.prank(OWNER);
            whitelist.whitelistProduct(underlying, USDC, collateralAsset, isPut);
        }
    }

    function _createOption(address underlying, address collateralAsset, uint256 strike, uint256 expiry, bool isPut)
        internal
        returns (address oToken)
    {
        oToken = factory.getTargetOTokenAddress(underlying, USDC, collateralAsset, strike, expiry, isPut);
        if (oToken.code.length == 0) {
            vm.prank(OPERATOR);
            oToken = factory.createOToken(underlying, USDC, collateralAsset, strike, expiry, isPut);
        }
    }

    function _nextExpiry() internal view returns (uint256 expiry) {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }

    function _scaleUnderlying(uint256 amount, address underlying) internal view returns (uint256) {
        return amount * (10 ** (IERC20Metadata(underlying).decimals() - 8));
    }

    function _spotFromExactInput(address underlying, uint24 fee) internal returns (uint256 spot) {
        uint256 snapshot = vm.snapshotState();
        uint256 amountIn = 10 ** IERC20Metadata(underlying).decimals();
        deal(underlying, address(this), amountIn);
        IERC20(underlying).approve(SWAP_ROUTER, amountIn);
        uint256 amountOut = ISwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: underlying,
                    tokenOut: USDC,
                    fee: fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        spot = amountOut * 100;
        assertGt(spot, 0);
        assertTrue(vm.revertToState(snapshot));
    }

    function _isPut(address oToken) internal view returns (bool) {
        (bool ok, bytes memory data) = oToken.staticcall(abi.encodeWithSignature("isPut()"));
        require(ok);
        return abi.decode(data, (bool));
    }

    function _activate(address tokenIn, address tokenOut, PairRoutingSwapRouter.SwapKind kind) internal {
        facade.proposeRoute(tokenIn, tokenOut, kind, address(adapter));
        vm.warp(block.timestamp + facade.ROUTE_DELAY());
        facade.activateRoute(tokenIn, tokenOut, kind);
    }
}
