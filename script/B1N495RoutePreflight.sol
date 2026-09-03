// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PairRoutingSwapRouter} from "../src/routers/PairRoutingSwapRouter.sol";
import {AerodromeSlipstreamAdapter} from "../src/routers/AerodromeSlipstreamAdapter.sol";
import {UniswapV3SettlementAdapter} from "../src/routers/UniswapV3SettlementAdapter.sol";

interface IB1N495PreflightB20 is IERC20Metadata {
    function multiplier() external view returns (uint256);
    function pausedFeatures() external view returns (uint8[] memory);
    function isPaused(uint8 feature) external view returns (bool);
    function TRANSFER_SENDER_POLICY() external view returns (bytes32);
    function TRANSFER_RECEIVER_POLICY() external view returns (bytes32);
    function TRANSFER_EXECUTOR_POLICY() external view returns (bytes32);
    function policyId(bytes32 scope) external view returns (uint64);
}

interface IB1N495PreflightPolicyRegistry {
    function policyExists(uint64 policyId) external view returns (bool);
    function isAuthorized(uint64 policyId, address account) external view returns (bool);
}

interface IB1N495PreflightOracleRegistry {
    function getOracleParams(address token) external view returns (uint256 multiplier, bool paused);
}

interface IB1N495PreflightFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IB1N495PreflightPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

interface IB1N495PreflightAeroFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
    function getSwapFee(address pool) external view returns (uint24);
    function isPool(address pool) external view returns (bool);
}

interface IB1N495PreflightAeroRouter {
    function factory() external view returns (address);
}

interface IB1N495PreflightUniFactory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice Read-only Base route gate. Foreign-chain observations must be collected by the finalized-fork script.
contract B1N495RoutePreflight {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_ORACLE_AGE = 1 hours;
    uint256 private constant MAX_ORACLE_DEVIATION_BPS = 100;
    uint256 private constant Q96 = 1 << 96;
    bytes4 private constant SLOT0_SELECTOR = bytes4(keccak256("slot0()"));

    address private constant SETTLER = 0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B;
    address private constant MARGIN_POOL = 0xa1e04873F6d112d84824C88c9D6937bE38811657;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant WETH = 0x4200000000000000000000000000000000000006;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant NVDAC = 0xb20000000000000000000078ee7ce2fE4908108C;
    address private constant CBZEC = 0xB2000000000000000000008501b13360000cb2EC;
    address private constant CBHYPE = 0xB200000000000000000000451d033a5000cb479e;
    address private constant VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;
    address private constant AERO_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address private constant AERO_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address private constant UNI_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address private constant UNI_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address private constant NVDAC_POOL = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    address private constant CBZEC_POOL = 0x0Fc47C17AF86078d809358db1b4db2DeBC988566;
    address private constant CBHYPE_POOL = 0xD5Eaea9da564217EA101D1E369fDA168A3025686;
    address private constant WETH_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address private constant CBBTC_POOL = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    address private constant VVV_POOL = 0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530;
    address private constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;
    address private constant ORACLE_REGISTRY = 0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD;
    address private constant NVDAC_FEED = 0x04689a41629776563E6822F76f2e57D148d28513;
    address private constant VVV_FEED = 0xaABc55Ca55D70B034e4daA2551A224239890282F;

    struct Deployment {
        address routeOwner;
        address settlementRecipient;
        address facade;
        address nvdacAdapter;
        address cbzecAdapter;
        address cbhypeAdapter;
        address uniswapAdapter;
    }

    struct OracleEvidence {
        uint256 observedAt;
        uint256 cbzecPrice8;
        uint256 cbzecUpdatedAt;
        uint256 cbhypePrice8;
        uint256 cbhypeUpdatedAt;
    }

    struct Result {
        bool nvdacEligible;
        bool cbzecEvidencePass;
        bool cbhypeEligible;
        bool vvvEvidencePass;
        uint256 nvdacDeviationBps;
        uint256 cbzecDeviationBps;
        uint256 cbhypeDeviationBps;
        uint256 vvvDeviationBps;
    }

    error PreflightFailed(bytes32 checkName);

    function check(Deployment calldata d, OracleEvidence calldata evidence) external view returns (Result memory r) {
        if (block.chainid != 8453) revert PreflightFailed("CHAIN");
        _deployment(d);
        uint256 nvdacMultiplier = _b20(NVDAC, 8, 5, d, d.nvdacAdapter, NVDAC_POOL);
        uint256 cbzecMultiplier = _b20(CBZEC, 8, 118, d, d.cbzecAdapter, CBZEC_POOL);
        uint256 cbhypeMultiplier = _b20(CBHYPE, 18, 119, d, d.cbhypeAdapter, CBHYPE_POOL);
        _aeroPool(NVDAC, NVDAC_POOL, 10, 500);
        _aeroPool(CBZEC, CBZEC_POOL, 200, 2000);
        _aeroPool(CBHYPE, CBHYPE_POOL, 200, 2000);
        _uniPool(WETH, WETH_POOL, WETH, USDC, 500, 10);
        _uniPool(CBBTC, CBBTC_POOL, USDC, CBBTC, 500, 10);
        _uniPool(VVV, VVV_POOL, USDC, VVV, 3000, 60);

        (uint256 nvdaPrice8, bool nvdaFresh) = _baseFeed(NVDAC_FEED, 8);
        (uint256 vvvPrice18, bool vvvFresh) = _baseFeed(VVV_FEED, 18);
        uint256 nvdacOracle8 = nvdaPrice8 * nvdacMultiplier / WAD;
        uint256 cbzecOracle8 = evidence.cbzecPrice8 * cbzecMultiplier / WAD;
        uint256 cbhypeOracle8 = evidence.cbhypePrice8 * cbhypeMultiplier / WAD;
        uint256 vvvOracle8 = vvvPrice18 / 1e10;

        r.nvdacDeviationBps = _deviationBps(_spotPrice8(NVDAC_POOL, 8), nvdacOracle8);
        r.cbzecDeviationBps = _deviationBps(_spotPrice8(CBZEC_POOL, 8), cbzecOracle8);
        r.cbhypeDeviationBps = _deviationBps(_spotPrice8(CBHYPE_POOL, 18), cbhypeOracle8);
        r.vvvDeviationBps = _deviationBps(_spotPrice8(VVV_POOL, 18), vvvOracle8);
        r.nvdacEligible = nvdaFresh && r.nvdacDeviationBps <= MAX_ORACLE_DEVIATION_BPS;
        r.cbzecEvidencePass = _freshAt(evidence.cbzecPrice8, evidence.cbzecUpdatedAt, evidence.observedAt)
            && r.cbzecDeviationBps <= MAX_ORACLE_DEVIATION_BPS;
        r.cbhypeEligible = _freshAt(evidence.cbhypePrice8, evidence.cbhypeUpdatedAt, evidence.observedAt)
            && r.cbhypeDeviationBps <= MAX_ORACLE_DEVIATION_BPS;
        r.vvvEvidencePass = vvvFresh && r.vvvDeviationBps <= MAX_ORACLE_DEVIATION_BPS;
    }

    function _deployment(Deployment calldata d) private view {
        if (d.routeOwner == address(0) || d.settlementRecipient == address(0)) revert PreflightFailed("PARTICIPANTS");
        PairRoutingSwapRouter facade = PairRoutingSwapRouter(payable(d.facade));
        if (
            d.facade.code.length == 0 || facade.settler() != SETTLER || facade.owner() != d.routeOwner
                || facade.ROUTE_DELAY() != 1 days
        ) revert PreflightFailed("FACADE");
        _adapter(d.nvdacAdapter, d.facade, NVDAC, NVDAC_POOL, 10, 500);
        _adapter(d.cbzecAdapter, d.facade, CBZEC, CBZEC_POOL, 200, 2000);
        _adapter(d.cbhypeAdapter, d.facade, CBHYPE, CBHYPE_POOL, 200, 2000);
        UniswapV3SettlementAdapter uni = UniswapV3SettlementAdapter(d.uniswapAdapter);
        if (
            d.uniswapAdapter.code.length == 0 || uni.facade() != d.facade || uni.settler() != SETTLER
                || uni.SWAP_ROUTER() != UNI_ROUTER
        ) revert PreflightFailed("UNISWAP_ADAPTER");
    }

    function _b20(
        address asset,
        uint8 expectedDecimals,
        uint64 expectedPolicy,
        Deployment calldata d,
        address adapter,
        address pool
    ) private view returns (uint256 multiplier) {
        IB1N495PreflightB20 token = IB1N495PreflightB20(asset);
        if (token.decimals() != expectedDecimals || token.isPaused(0) || token.pausedFeatures().length != 0) {
            revert PreflightFailed("B20_TOKEN");
        }
        multiplier = token.multiplier();
        (uint256 registryMultiplier, bool oraclePaused) =
            IB1N495PreflightOracleRegistry(ORACLE_REGISTRY).getOracleParams(asset);
        if (multiplier == 0 || multiplier != registryMultiplier || oraclePaused) revert PreflightFailed("B20_ORACLE");

        uint64[3] memory policies = [
            token.policyId(token.TRANSFER_SENDER_POLICY()),
            token.policyId(token.TRANSFER_RECEIVER_POLICY()),
            token.policyId(token.TRANSFER_EXECUTOR_POLICY())
        ];
        address[8] memory actors =
            [SETTLER, MARGIN_POOL, d.facade, adapter, AERO_ROUTER, pool, d.routeOwner, d.settlementRecipient];
        IB1N495PreflightPolicyRegistry registry = IB1N495PreflightPolicyRegistry(POLICY_REGISTRY);
        for (uint256 policyIndex; policyIndex < policies.length; ++policyIndex) {
            uint64 policy = policies[policyIndex];
            if (policy != expectedPolicy || !registry.policyExists(policy) || uint8(policy >> 56) > 3) {
                revert PreflightFailed("B20_POLICY");
            }
            for (uint256 actor; actor < actors.length; ++actor) {
                if (!registry.isAuthorized(policy, actors[actor])) revert PreflightFailed("B20_AUTHORIZATION");
            }
        }
    }

    function _adapter(address target, address facade, address asset, address pool, int24 spacing, uint24 fee)
        private
        view
    {
        AerodromeSlipstreamAdapter adapter = AerodromeSlipstreamAdapter(payable(target));
        if (
            target.code.length == 0 || adapter.facade() != facade || adapter.settler() != SETTLER
                || adapter.venueRouter() != AERO_ROUTER || adapter.factory() != AERO_FACTORY || adapter.pool() != pool
                || adapter.tokenA() != asset || adapter.tokenB() != USDC || adapter.tickSpacing() != spacing
                || adapter.effectiveFee() != fee
        ) revert PreflightFailed("AERODROME_ADAPTER");
    }

    function _aeroPool(address asset, address poolAddress, int24 spacing, uint24 fee) private view {
        IB1N495PreflightPool pool = IB1N495PreflightPool(poolAddress);
        IB1N495PreflightAeroFactory factory = IB1N495PreflightAeroFactory(AERO_FACTORY);
        if (
            pool.token0() != USDC || pool.token1() != asset || pool.factory() != AERO_FACTORY
                || pool.tickSpacing() != spacing || pool.fee() != fee || pool.liquidity() == 0
                || IB1N495PreflightAeroRouter(AERO_ROUTER).factory() != AERO_FACTORY
                || factory.getPool(asset, USDC, spacing) != poolAddress || factory.getSwapFee(poolAddress) != fee
                || !factory.isPool(poolAddress)
        ) revert PreflightFailed("AERODROME_POOL");
    }

    function _uniPool(address asset, address poolAddress, address token0, address token1, uint24 fee, int24 spacing)
        private
        view
    {
        IB1N495PreflightPool pool = IB1N495PreflightPool(poolAddress);
        if (
            pool.token0() != token0 || pool.token1() != token1 || pool.factory() != UNI_FACTORY || pool.fee() != fee
                || pool.tickSpacing() != spacing || pool.liquidity() == 0
                || IB1N495PreflightUniFactory(UNI_FACTORY).getPool(asset, USDC, fee) != poolAddress
        ) revert PreflightFailed("UNISWAP_POOL");
    }

    function _baseFeed(address feed, uint8 expectedDecimals) private view returns (uint256 answer, bool fresh) {
        if (feed.code.length == 0 || IB1N495PreflightFeed(feed).decimals() != expectedDecimals) {
            revert PreflightFailed("FEED_IDENTITY");
        }
        (uint80 roundId, int256 signedAnswer,, uint256 updatedAt, uint80 answeredInRound) =
            IB1N495PreflightFeed(feed).latestRoundData();
        if (signedAnswer <= 0 || answeredInRound < roundId) return (0, false);
        answer = uint256(signedAnswer);
        fresh = _fresh(answer, updatedAt);
    }

    function _fresh(uint256 answer, uint256 updatedAt) private view returns (bool) {
        return _freshAt(answer, updatedAt, block.timestamp);
    }

    function _freshAt(uint256 answer, uint256 updatedAt, uint256 observedAt) private pure returns (bool) {
        return answer != 0 && updatedAt != 0 && updatedAt <= observedAt && observedAt - updatedAt <= MAX_ORACLE_AGE;
    }

    function _spotPrice8(address pool, uint8 assetDecimals) private view returns (uint256) {
        (bool ok, bytes memory result) = pool.staticcall(abi.encodeWithSelector(SLOT0_SELECTOR));
        if (!ok || result.length < 32) revert PreflightFailed("POOL_PRICE");
        uint160 sqrtPriceX96 = abi.decode(result, (uint160));
        uint256 assetUnit = 10 ** assetDecimals;
        uint256 usdcRaw = (assetUnit * Q96 / uint256(sqrtPriceX96)) * Q96 / uint256(sqrtPriceX96);
        return usdcRaw * 100;
    }

    function _deviationBps(uint256 observed, uint256 expected) internal pure returns (uint256) {
        if (expected == 0) return type(uint256).max;
        uint256 difference = observed > expected ? observed - expected : expected - observed;
        return Math.mulDiv(difference, 10_000, expected, Math.Rounding.Ceil);
    }
}
