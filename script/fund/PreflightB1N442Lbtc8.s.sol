// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";

interface IPreflightFeedV2 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IPreflightPoolV2 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
}

interface IPreflightRouterV2 {
    function factory() external view returns (address);
}

interface IPreflightFactoryV2 {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPreflightAuthorityV2 {
    function authority() external view returns (address);
}

interface IPreflightValuatorV2 {
    function interfaceVersion() external pure returns (uint64);
    function expectedStrategyKind() external pure returns (IAdapter.StrategyKind);
    function expectedAdapter() external view returns (address);
    function expectedFund() external view returns (address);
    function expectedAddressBook() external view returns (address);
    function expectedUnderlying() external view returns (address);
    function expectedSettlement() external view returns (address);
    function expectedPolicyHash() external view returns (bytes32);
    function spotFeed() external view returns (address);
    function spotFeedDecimals() external view returns (uint8);
    function maxSpotStaleness() external view returns (uint64);
}

/// @notice Read-only B1N-442 current-v2 onboarding and release-readiness gate.
/// @dev checkIdentityOnly() cannot attest release readiness. check() always requires complete paused deployment readback.
contract PreflightB1N442Lbtc8 {
    address public constant LBTC8 = 0x39fA11EbBE82699Fd9F79C566D7384064571d2b4;
    bytes32 public constant LBTC8_RUNTIME_CODEHASH = 0x599a6b80cccf2c7082103129c3725529a49d37b569dc0ecc031f0444b0ce0fff;
    bytes32 public constant LBTC8_VERIFIED_SOURCE_ARTIFACT_SHA256 =
        0xb56bda7d0ad8c8cd7519779294d53af692da257ea41b31769d19a5826b012cec;
    bytes32 public constant LBTC8_VERIFIED_SOURCE_SHA256 =
        0x736cb364367e0b2c03a3b8c98968554cd586c9850b517ae904c3f46a9772fa79;
    bytes32 public constant LBTC8_CREATION_TRANSACTION =
        0x840289b3d7c49de8d281e1ed09d0f31d5a42ae57601537fc632f27f02b216a61;
    bytes32 public constant POLICY_HASH = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;
    uint256 public constant MAX_ORACLE_STALENESS = 1_200;

    struct Inputs {
        address settlement;
        address addressBook;
        address router;
        address swapFactory;
        uint24 swapFeeTier;
        address expectedAuthority;
        address cspProxy;
        address callProxy;
        address cspValuator;
        address callValuator;
    }

    error PreflightFailed(bytes32 checkName);

    /// @notice Token identity evidence only. Success here MUST NOT be treated as release readiness.
    function checkIdentityOnly() external view returns (bool) {
        _chainAndIdentity();
        return true;
    }

    /// @notice Complete release-readiness readback. No predeployment or optional-readback mode exists.
    function check(Inputs calldata x) external view returns (bool) {
        if (block.chainid != 84532) revert PreflightFailed("CHAIN");
        _requiredReleaseInputs(x);
        _identity();
        if (x.settlement.code.length == 0 || IERC20Metadata(x.settlement).decimals() != 6) {
            revert PreflightFailed("SETTLEMENT");
        }
        AddressBook b = AddressBook(x.addressBook);
        _protocol(b, x.addressBook);
        address feed = _freshOracle(b.oracle());
        _route(b.batchSettler(), x);
        _product(b.whitelist(), x.settlement, true);
        _product(b.whitelist(), x.settlement, false);
        (address cspFund, address cspManager) = _adapter(x.cspProxy, x, IAdapter.StrategyKind.Csp);
        (address callFund, address callManager) = _adapter(x.callProxy, x, IAdapter.StrategyKind.CoveredCall);
        _valuator(x.cspValuator, x.cspProxy, cspFund, x.addressBook, x.settlement, feed, IAdapter.StrategyKind.Csp);
        _valuator(
            x.callValuator, x.callProxy, callFund, x.addressBook, x.settlement, feed, IAdapter.StrategyKind.CoveredCall
        );
        if (
            StrategyManager(cspManager).strategyConfig(x.cspProxy).valuator != x.cspValuator
                || StrategyManager(callManager).strategyConfig(x.callProxy).valuator != x.callValuator
        ) revert PreflightFailed("VALUATOR_REGISTRATION");
        return true;
    }

    function _requiredReleaseInputs(Inputs calldata x) private view {
        if (
            x.settlement == address(0) || x.addressBook == address(0) || x.router == address(0)
                || x.swapFactory == address(0) || x.expectedAuthority == address(0)
        ) revert PreflightFailed("INPUTS");
        if (
            x.cspProxy == address(0) || x.callProxy == address(0) || x.cspValuator == address(0)
                || x.callValuator == address(0)
        ) revert PreflightFailed("RELEASE_READBACK_REQUIRED");
        if (
            x.addressBook.code.length == 0 || x.router.code.length == 0 || x.swapFactory.code.length == 0
                || x.expectedAuthority.code.length == 0 || x.cspProxy.code.length == 0 || x.callProxy.code.length == 0
                || x.cspValuator.code.length == 0 || x.callValuator.code.length == 0
        ) revert PreflightFailed("RELEASE_CODE_REQUIRED");
    }

    function _chainAndIdentity() private view {
        if (block.chainid != 84532) revert PreflightFailed("CHAIN");
        _identity();
    }

    function _identity() private view {
        if (LBTC8.codehash != LBTC8_RUNTIME_CODEHASH || IERC20Metadata(LBTC8).decimals() != 8) {
            revert PreflightFailed("LBTC8_IDENTITY");
        }
    }

    function _protocol(AddressBook b, address expectedBook) private view {
        if (
            b.controller().code.length == 0 || b.batchSettler().code.length == 0 || b.marginPool().code.length == 0
                || b.oracle().code.length == 0 || b.whitelist().code.length == 0 || b.oTokenFactory().code.length == 0
        ) revert PreflightFailed("PROTOCOL");
        _boundComponent(b.controller(), expectedBook);
        _boundComponent(b.batchSettler(), expectedBook);
        _boundComponent(b.marginPool(), expectedBook);
        _boundComponent(b.oracle(), expectedBook);
        _boundComponent(b.oTokenFactory(), expectedBook);
    }

    function _freshOracle(address oracleAddress) private view returns (address feed) {
        Oracle oracle = Oracle(oracleAddress);
        uint256 age = oracle.maxOracleStaleness();
        feed = oracle.priceFeed(LBTC8);
        if (
            age == 0 || age > MAX_ORACLE_STALENESS || feed == address(0) || feed.code.length == 0
                || IPreflightFeedV2(feed).decimals() != 8
        ) revert PreflightFailed("ORACLE_POLICY");
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) = IPreflightFeedV2(feed).latestRoundData();
        if (
            answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > age
                || answered < round
        ) revert PreflightFailed("ORACLE_FRESHNESS");
    }

    function _route(address settlerAddress, Inputs calldata x) private view {
        BatchSettler settler = BatchSettler(settlerAddress);
        uint24 tier = settler.assetSwapFeeTier(LBTC8);
        if (tier == 0) tier = settler.swapFeeTier();
        if (settler.swapRouter() != x.router || tier != x.swapFeeTier) revert PreflightFailed("ROUTER");
        if (IPreflightRouterV2(x.router).factory() != x.swapFactory) revert PreflightFailed("ROUTER_FACTORY");
        address poolAddress = IPreflightFactoryV2(x.swapFactory).getPool(LBTC8, x.settlement, x.swapFeeTier);
        if (poolAddress == address(0) || poolAddress.code.length == 0) revert PreflightFailed("ROUTE_POOL");
        IPreflightPoolV2 pool = IPreflightPoolV2(poolAddress);
        address a = pool.token0();
        address z = pool.token1();
        if (
            !((a == LBTC8 && z == x.settlement) || (a == x.settlement && z == LBTC8)) || pool.fee() != x.swapFeeTier
                || pool.liquidity() == 0
        ) revert PreflightFailed("POOL");
    }

    function _adapter(address target, Inputs calldata x, IAdapter.StrategyKind kind)
        private
        view
        returns (address fund_, address manager)
    {
        IAdapter a = IAdapter(target);
        IAdapter.AssetConfigV2 memory c = a.assetConfigV2();
        IOperations.AdapterConfigV2 memory ac = IOperations(target).adapterConfigV2();
        fund_ = IOperations(target).fund();
        manager = IOperations(target).strategyManager();
        address expectedAsset = kind == IAdapter.StrategyKind.Csp ? x.settlement : LBTC8;
        if (
            a.interfaceVersion() != 2 || a.strategyKind() != kind || a.underlyingAsset() != LBTC8
                || a.settlementAsset() != x.settlement || a.policyHash() != POLICY_HASH || c.underlyingAsset != LBTC8
                || c.settlementAsset != x.settlement || c.oTokenDecimals != 8 || c.underlyingDecimals != 8
                || c.priceDecimals != 8 || c.settlementDecimals != 6 || ac.swapRouter != x.router
                || ac.swapFeeTier != x.swapFeeTier
        ) revert PreflightFailed("ADAPTER_READBACK");
        if (
            IOperations(target).addressBook() != x.addressBook
                || IPreflightAuthorityV2(target).authority() != x.expectedAuthority || fund_.code.length == 0
                || manager.code.length == 0 || FundVault(fund_).strategyManager() != manager
                || FundVault(fund_).asset() != expectedAsset || StrategyManager(manager).fund() != fund_
                || !FundVault(fund_).depositsPaused() || StrategyManager(manager).strategyConfig(target).active
        ) revert PreflightFailed("ADAPTER_BINDING");
    }

    function _valuator(
        address target,
        address adapter,
        address fund_,
        address book,
        address settlement,
        address feed,
        IAdapter.StrategyKind kind
    ) private view {
        IPreflightValuatorV2 v = IPreflightValuatorV2(target);
        uint256 valuatorAge = v.maxSpotStaleness();
        if (
            v.interfaceVersion() != 2 || v.expectedStrategyKind() != kind || v.expectedAdapter() != adapter
                || v.expectedFund() != fund_ || v.expectedAddressBook() != book || v.expectedUnderlying() != LBTC8
                || v.expectedSettlement() != settlement || v.expectedPolicyHash() != POLICY_HASH || v.spotFeed() != feed
                || v.spotFeedDecimals() != 8 || valuatorAge == 0 || valuatorAge > MAX_ORACLE_STALENESS
        ) revert PreflightFailed("VALUATOR_BINDING");

        uint256 oracleAge = Oracle(AddressBook(book).oracle()).maxOracleStaleness();
        uint256 effectiveMaxAge = oracleAge < valuatorAge ? oracleAge : valuatorAge;
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) = IPreflightFeedV2(feed).latestRoundData();
        if (
            effectiveMaxAge == 0 || answer <= 0 || updated == 0 || updated > block.timestamp
                || block.timestamp - updated > effectiveMaxAge || answered < round
        ) revert PreflightFailed("VALUATOR_FRESHNESS");
    }

    function _boundComponent(address target, address expectedBook) private view {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature("addressBook()"));
        if (!ok || data.length < 32 || abi.decode(data, (address)) != expectedBook) {
            revert PreflightFailed("COMPONENT_BINDING");
        }
    }

    function _product(address whitelist, address settlement, bool put) private view {
        (bool a, bytes memory ar) =
            whitelist.staticcall(abi.encodeWithSignature("isWhitelistedUnderlying(address)", LBTC8));
        (bool c, bytes memory cr) =
            whitelist.staticcall(abi.encodeWithSignature("isWhitelistedCollateral(address)", put ? settlement : LBTC8));
        (bool p, bytes memory pr) = whitelist.staticcall(
            abi.encodeWithSignature(
                "isProductWhitelisted(address,address,address,bool)", LBTC8, settlement, put ? settlement : LBTC8, put
            )
        );
        if (
            !a || !c || !p || ar.length < 32 || cr.length < 32 || pr.length < 32 || !abi.decode(ar, (bool))
                || !abi.decode(cr, (bool)) || !abi.decode(pr, (bool))
        ) revert PreflightFailed("PRODUCT");
    }
}
