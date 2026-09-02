// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {
    AerodromeSlipstreamAdapter,
    IAerodromeSlipstreamFactory,
    IAerodromeSlipstreamPool,
    IAerodromeSlipstreamRouter
} from "../src/routers/AerodromeSlipstreamAdapter.sol";

interface IB494AddressBook {
    function batchSettler() external view returns (address);
}

interface IB494BatchSettler {
    struct Quote {
        address oToken;
        uint256 bidPrice;
        uint256 deadline;
        uint256 quoteId;
        uint256 maxAmount;
        uint256 makerNonce;
    }

    function owner() external view returns (address);
    function swapRouter() external view returns (address);
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

interface IB494Oracle {
    function setExpiryPrice(address asset, uint256 expiry, uint256 price) external;
    function setPriceDeviationThreshold(uint256 thresholdBps) external;
    function setMaxOracleStaleness(uint256 maxStaleness) external;
}

interface IB494OTokenFactory {
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

interface IB494Whitelist {
    function isProductWhitelisted(address underlying, address strike, address collateral, bool isPut)
        external
        view
        returns (bool);
    function whitelistProduct(address underlying, address strike, address collateral, bool isPut) external;
}

contract ForceNativeToVenue {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract AerodromeSlipstreamAdapterForkTest is Test {
    uint256 internal constant FORK_BLOCK = 50_780_000;
    uint256 internal constant FORK_TIMESTAMP = 1_788_349_347;
    bytes32 internal constant FORK_PARENT = 0x25fe310773dc0da61c61050b004c8fad9279b093ac804f45cc99857788e79db2;
    uint256 internal constant OPTION_AMOUNT = 1e6; // 0.01 oToken / underlying

    address internal constant ADDRESS_BOOK = 0x48FE24a69417038a2D3d46B2B6B9De03b884eD72;
    address internal constant MARGIN_POOL = 0xa1e04873F6d112d84824C88c9D6937bE38811657;
    address internal constant FACTORY = 0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7;
    address internal constant ORACLE = 0x09daa0194A3AF59b46C5443aF9C20fAd98347671;
    address internal constant WHITELIST = 0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A;
    address internal constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address internal constant OWNER = 0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7;
    address internal constant OPERATOR = 0x0bbD599cEB63b4603c2F007c5122e33f7b12364c;
    address internal constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant NEW_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address internal constant NEW_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address internal constant OLD_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address internal constant OLD_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    address internal constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address internal constant CBZEC = 0xB2000000000000000000008501b13360000cb2EC;
    address internal constant CBHYPE = 0xB200000000000000000000451d033a5000cb479e;
    address internal constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address internal constant DIEM = 0xF4d97F2da56e8c3098f3a8D538DB630A2606a024;
    address internal constant NVDAC_HOLDER = 0xA561f0A080e6de58AAF9d174E06e842693978412;

    address internal constant NVDAC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    address internal constant CBZEC_POOL = 0x0Fc47C17AF86078d809358db1b4db2DeBC988566;
    address internal constant CBHYPE_POOL = 0xD5Eaea9da564217EA101D1E369fDA168A3025686;
    address internal constant VIRTUAL_POOL = 0xaE08F8e7F810BaB3e12875AdC9715ecD626Cf23c;
    address internal constant DIEM_POOL = 0xBc3231036Ee1ECa03E5F67FEceDC640D21610823;

    bytes32 internal constant PHYSICAL_DELIVERY_TOPIC = keccak256("PhysicalDelivery(address,address,uint256,uint256)");
    uint256 internal constant MM_KEY = 0xB1494;
    address internal mm;
    address internal user = address(0x4941);

    IB494BatchSettler internal settler = IB494BatchSettler(SETTLER);
    IB494Oracle internal oracle = IB494Oracle(ORACLE);
    IB494OTokenFactory internal oTokenFactory = IB494OTokenFactory(FACTORY);
    IB494Whitelist internal whitelist = IB494Whitelist(WHITELIST);
    PairRoutingSwapRouter internal facade;
    mapping(address asset => AerodromeSlipstreamAdapter) internal adapters;

    struct Outcome {
        uint256 userOutput;
        uint256 makerSurplus;
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
        assertEq(block.timestamp, FORK_TIMESTAMP);
        assertEq(blockhash(FORK_BLOCK - 1), FORK_PARENT);
        assertEq(IB494AddressBook(ADDRESS_BOOK).batchSettler(), SETTLER);
        assertEq(settler.swapRouter(), UNISWAP_ROUTER);

        mm = vm.addr(MM_KEY);
        facade = new PairRoutingSwapRouter(SETTLER, address(this));
        _deployRoute(NVDAC, NVDAC_POOL, NEW_ROUTER, NEW_FACTORY, 10, 500);
        _deployRoute(CBZEC, CBZEC_POOL, NEW_ROUTER, NEW_FACTORY, 200, 2000);
        _deployRoute(CBHYPE, CBHYPE_POOL, NEW_ROUTER, NEW_FACTORY, 200, 2000);
        _deployRoute(VIRTUAL, VIRTUAL_POOL, OLD_ROUTER, OLD_FACTORY, 200, 3000);
        _deployRoute(DIEM, DIEM_POOL, OLD_ROUTER, OLD_FACTORY, 100, 2700);

        vm.startPrank(OWNER);
        settler.setWhitelistedMM(mm, true);
        oracle.setPriceDeviationThreshold(0);
        oracle.setMaxOracleStaleness(0);
        settler.setAssetSwapFeeTier(NVDAC, 500);
        settler.setAssetSwapFeeTier(CBZEC, 3000);
        settler.setAssetSwapFeeTier(CBHYPE, 3000);
        settler.setAssetSwapFeeTier(VIRTUAL, 3000);
        settler.setAssetSwapFeeTier(DIEM, 3000);
        vm.stopPrank();

        deal(USDC, mm, 10_000_000e6);
        deal(USDC, user, 10_000_000e6);
        vm.prank(mm);
        IERC20(USDC).approve(SETTLER, type(uint256).max);

        address[5] memory assets = [NVDAC, CBZEC, CBHYPE, VIRTUAL, DIEM];
        for (uint256 i; i < assets.length; ++i) {
            _fundAsset(assets[i], user, 10 ** IERC20Metadata(assets[i]).decimals());
        }
        vm.startPrank(user);
        IERC20(USDC).approve(MARGIN_POOL, type(uint256).max);
        for (uint256 i; i < assets.length; ++i) {
            IERC20(assets[i]).approve(MARGIN_POOL, type(uint256).max);
        }
        vm.stopPrank();
    }

    function test_pinnedPoolAndRouterIdentities() public view onlyFork {
        _assertIdentity(NVDAC, NVDAC_POOL, NEW_ROUTER, NEW_FACTORY, 10, 500, 8);
        _assertIdentity(CBZEC, CBZEC_POOL, NEW_ROUTER, NEW_FACTORY, 200, 2000, 8);
        _assertIdentity(CBHYPE, CBHYPE_POOL, NEW_ROUTER, NEW_FACTORY, 200, 2000, 18);
        _assertIdentity(VIRTUAL, VIRTUAL_POOL, OLD_ROUTER, OLD_FACTORY, 200, 3000, 18);
        _assertIdentity(DIEM, DIEM_POOL, OLD_ROUTER, OLD_FACTORY, 100, 2700, 18);
    }

    function test_nvdaCPutOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(NVDAC, true);
    }

    function test_nvdaCCallOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(NVDAC, false);
    }

    function test_forcedNativeAtNewVenueCannotBlockDelivery() public onlyFork {
        uint256 spot = _spotFromExactInput(NVDAC);
        vm.deal(address(this), 1);
        new ForceNativeToVenue{value: 1}(payable(NEW_ROUTER));
        _assertDeliveryAtSpot(NVDAC, false, spot);
        assertEq(NEW_ROUTER.balance, 0);
        assertEq(address(adapters[NVDAC]).balance, 1);
    }

    function test_forcedNativeAtOldVenueCannotBlockDelivery() public onlyFork {
        uint256 spot = _spotFromExactInput(VIRTUAL);
        vm.deal(address(this), 1);
        new ForceNativeToVenue{value: 1}(payable(OLD_ROUTER));
        _assertDeliveryAtSpot(VIRTUAL, false, spot);
        assertEq(OLD_ROUTER.balance, 0);
        assertEq(address(adapters[VIRTUAL]).balance, 1);
    }

    function test_cbZecPutOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(CBZEC, true);
    }

    function test_cbZecCallOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(CBZEC, false);
    }

    function test_cbHypePutOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(CBHYPE, true);
    }

    function test_cbHypeCallOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(CBHYPE, false);
    }

    function test_virtualPutOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(VIRTUAL, true);
    }

    function test_virtualCallOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(VIRTUAL, false);
    }

    function test_diemPutOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(DIEM, true);
    }

    function test_diemCallOpensSettlesAndDelivers() public onlyFork {
        _assertDelivery(DIEM, false);
    }

    function _assertDelivery(address underlying, bool isPut) internal {
        _assertDeliveryAtSpot(underlying, isPut, _spotFromExactInput(underlying));
    }

    function _assertDeliveryAtSpot(address underlying, bool isPut, uint256 spot) internal {
        uint256 strike = isPut ? spot + spot / 5 : spot - spot / 5;
        (address oToken, uint256 collateral) = _openAndSettle(underlying, isPut, strike, spot);
        uint256 slippage = isPut ? collateral : (OPTION_AMOUNT * strike) / 1e10;

        vm.prank(OWNER);
        settler.setSwapRouter(address(facade));
        Outcome memory outcome = _redeem(oToken, underlying, isPut, slippage);

        uint256 expectedUnderlying = _scaleUnderlying(OPTION_AMOUNT, underlying);
        uint256 expectedUsdc = (OPTION_AMOUNT * strike) / 1e10;
        assertEq(outcome.userOutput, isPut ? expectedUnderlying : expectedUsdc);
        assertEq(outcome.contraAmount, isPut ? expectedUnderlying : expectedUsdc);
        assertGt(outcome.makerSurplus, 0);
        assertGt(outcome.collateralUsed, 0);
        if (isPut) assertLt(outcome.collateralUsed, collateral);
        else assertEq(outcome.collateralUsed, collateral);
        assertEq(settler.mmOTokenBalance(mm, oToken), 0);
        _assertNoResidue(underlying);
    }

    function _openAndSettle(address underlying, bool isPut, uint256 strike, uint256 expiryPrice)
        internal
        returns (address oToken, uint256 collateral)
    {
        address collateralAsset = isPut ? USDC : underlying;
        _ensureProduct(underlying, collateralAsset, isPut);
        uint256 expiry = _nextExpiry();
        oToken = _createOption(underlying, collateralAsset, strike, expiry, isPut);

        IB494BatchSettler.Quote memory quote = IB494BatchSettler.Quote({
            oToken: oToken,
            bidPrice: 1e6,
            deadline: block.timestamp + 1 hours,
            quoteId: uint256(keccak256(abi.encode(underlying, isPut, strike, expiry))),
            maxAmount: OPTION_AMOUNT,
            makerNonce: settler.makerNonce(mm)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, settler.hashQuote(quote));
        bytes memory signature = abi.encodePacked(r, s, v);
        collateral = isPut ? (OPTION_AMOUNT * strike) / 1e10 : _scaleUnderlying(OPTION_AMOUNT, underlying);

        vm.prank(user);
        uint256 vaultId = settler.executeOrder(quote, signature, OPTION_AMOUNT, collateral);
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

    function _redeem(address oToken, address underlying, bool isPut, uint256 slippage)
        internal
        returns (Outcome memory outcome)
    {
        address output = isPut ? underlying : USDC;
        uint256 userBefore = IERC20(output).balanceOf(user);
        uint256 makerBefore = IERC20(USDC).balanceOf(mm);
        vm.recordLogs();
        vm.prank(OPERATOR);
        settler.physicalRedeem(oToken, user, OPTION_AMOUNT, slippage, mm);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        outcome.userOutput = IERC20(output).balanceOf(user) - userBefore;
        outcome.makerSurplus = IERC20(USDC).balanceOf(mm) - makerBefore;
        (outcome.contraAmount, outcome.collateralUsed) = _physicalEvent(logs, oToken);
    }

    function _spotFromExactInput(address underlying) internal returns (uint256 spot) {
        AerodromeSlipstreamAdapter adapter = adapters[underlying];
        uint256 snapshot = vm.snapshotState();
        uint256 amountIn = _scaleUnderlying(OPTION_AMOUNT, underlying);
        _fundAsset(underlying, address(this), amountIn);
        IERC20(underlying).approve(adapter.venueRouter(), amountIn);
        uint256 beforeOut = IERC20(USDC).balanceOf(address(this));
        IAerodromeSlipstreamRouter(adapter.venueRouter())
            .exactInputSingle(
                IAerodromeSlipstreamRouter.ExactInputSingleParams({
                    tokenIn: underlying,
                    tokenOut: USDC,
                    tickSpacing: adapter.tickSpacing(),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        uint256 amountOut = IERC20(USDC).balanceOf(address(this)) - beforeOut;
        spot = (amountOut * 1e10) / OPTION_AMOUNT;
        assertGt(spot, 0);
        assertTrue(vm.revertToState(snapshot));
    }

    function _deployRoute(
        address asset,
        address pool,
        address venueRouter,
        address venueFactory,
        int24 spacing,
        uint24 expectedFee
    ) internal {
        AerodromeSlipstreamAdapter adapter = new AerodromeSlipstreamAdapter(
            address(facade), venueRouter, venueFactory, pool, asset, USDC, spacing
        );
        assertEq(adapter.effectiveFee(), expectedFee);
        adapters[asset] = adapter;
        _activate(asset, USDC, PairRoutingSwapRouter.SwapKind.ExactInput, address(adapter));
        _activate(USDC, asset, PairRoutingSwapRouter.SwapKind.ExactOutput, address(adapter));
    }

    function _activate(address tokenIn, address tokenOut, PairRoutingSwapRouter.SwapKind kind, address adapter)
        internal
    {
        facade.proposeRoute(tokenIn, tokenOut, kind, adapter);
        vm.warp(block.timestamp + facade.ROUTE_DELAY());
        facade.activateRoute(tokenIn, tokenOut, kind);
    }

    function _assertIdentity(
        address asset,
        address expectedPool,
        address expectedRouter,
        address expectedFactory,
        int24 expectedSpacing,
        uint24 expectedFee,
        uint8 expectedDecimals
    ) internal view {
        AerodromeSlipstreamAdapter adapter = adapters[asset];
        IAerodromeSlipstreamPool boundPool = IAerodromeSlipstreamPool(expectedPool);
        assertEq(IERC20Metadata(asset).decimals(), expectedDecimals);
        assertEq(adapter.pool(), expectedPool);
        assertEq(adapter.venueRouter(), expectedRouter);
        assertEq(adapter.factory(), expectedFactory);
        assertEq(adapter.tickSpacing(), expectedSpacing);
        assertEq(adapter.effectiveFee(), expectedFee);
        assertEq(IAerodromeSlipstreamRouter(expectedRouter).factory(), expectedFactory);
        assertEq(boundPool.factory(), expectedFactory);
        assertEq(boundPool.tickSpacing(), expectedSpacing);
        assertEq(boundPool.fee(), expectedFee);
        assertEq(IAerodromeSlipstreamFactory(expectedFactory).getSwapFee(expectedPool), expectedFee);
        assertEq(IAerodromeSlipstreamFactory(expectedFactory).getPool(asset, USDC, expectedSpacing), expectedPool);
        assertGt(boundPool.liquidity(), 0);
    }

    function _assertNoResidue(address underlying) internal view {
        AerodromeSlipstreamAdapter adapter = adapters[underlying];
        assertEq(IERC20(underlying).balanceOf(address(facade)), 0);
        assertEq(IERC20(USDC).balanceOf(address(facade)), 0);
        assertEq(IERC20(underlying).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(underlying).allowance(address(facade), address(adapter)), 0);
        assertEq(IERC20(USDC).allowance(address(facade), address(adapter)), 0);
        assertEq(IERC20(underlying).allowance(address(adapter), adapter.venueRouter()), 0);
        assertEq(IERC20(USDC).allowance(address(adapter), adapter.venueRouter()), 0);
    }

    function _physicalEvent(Vm.Log[] memory logs, address oToken)
        internal
        pure
        returns (uint256 contraAmount, uint256 collateralUsed)
    {
        for (uint256 i; i < logs.length; ++i) {
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
        oToken = oTokenFactory.getTargetOTokenAddress(underlying, USDC, collateralAsset, strike, expiry, isPut);
        if (oToken.code.length == 0) {
            vm.prank(OPERATOR);
            oToken = oTokenFactory.createOToken(underlying, USDC, collateralAsset, strike, expiry, isPut);
        }
    }

    function _fundAsset(address asset, address to, uint256 amount) internal {
        address holder;
        if (asset == NVDAC) holder = NVDAC_HOLDER;
        else if (asset == CBZEC) holder = CBZEC_POOL;
        else if (asset == CBHYPE) holder = CBHYPE_POOL;
        if (holder == address(0)) {
            deal(asset, to, amount);
        } else {
            vm.prank(holder);
            assertTrue(IERC20(asset).transfer(to, amount));
        }
    }

    function _scaleUnderlying(uint256 amount, address underlying) internal view returns (uint256) {
        return amount * (10 ** (IERC20Metadata(underlying).decimals() - 8));
    }

    function _nextExpiry() internal view returns (uint256 expiry) {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }
}
