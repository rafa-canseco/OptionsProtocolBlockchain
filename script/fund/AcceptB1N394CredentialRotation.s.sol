// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {console2} from "forge-std/console2.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {B1N394Base} from "./B1N394Base.sol";

interface IB1N394AcceptOwner {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

/// @notice Accepts core ownership and replaces the immutable-owner test router under the new governance key.
contract AcceptB1N394CredentialRotation is B1N394Base {
    address private constant ADDRESS_BOOK = 0x033d9d37Baf83dBc71935239b6fA22a6905dbaa0;
    address private constant CONTROLLER = 0xD52EFbBaA1b02BA65A7f0A1604A5dFb4C4dB1572;
    address private constant ORACLE = 0xF95CC4aED4a0bD68e0F1BE7c779BC281189F8187;
    address private constant WHITELIST = 0xe0Ca66a93341eB0af0C136651c8B57C187aa60Ab;
    address private constant PRIOR_ROUTER = 0x7442287A564D7A7f412a12Ff986a242E1A969abB;
    address private constant USDC = 0xAB51a471493832C1D70cef8ff937A850cf37c860;
    address private constant WETH = 0x8A6Aa2304797898d46eC1d342Fedc817D3a973B6;

    function run() external returns (address replacementRouter) {
        _requireBaseSepolia();
        address governance = vm.envAddress("B1N394_NEW_GOVERNANCE");
        address spotFeed = MockSwapRouter(PRIOR_ROUTER).priceFeeds(WETH);
        require(
            governance != address(0) && spotFeed != address(0) && MockSwapRouter(PRIOR_ROUTER).usdc() == USDC,
            "B1N394: router boundary"
        );
        _requirePending(governance);

        CspFundAdapter.AdapterConfig memory cspBefore = CspFundAdapter(CSP_ADAPTER).adapterConfig();
        CoveredCallFundAdapter.AdapterConfig memory ccBefore = CoveredCallFundAdapter(CC_ADAPTER).adapterConfig();
        bytes32 cspStateHash = CspFundAdapter(CSP_ADAPTER).positionStateHash();
        bytes32 ccStateHash = CoveredCallFundAdapter(CC_ADAPTER).positionStateHash();
        bytes32 cspPositionsHash = StrategyManager(CSP_MANAGER).positionsHash();
        bytes32 ccPositionsHash = StrategyManager(CC_MANAGER).positionsHash();
        require(cspBefore.swapRouter == PRIOR_ROUTER && ccBefore.swapRouter == PRIOR_ROUTER, "B1N394: prior router");

        vm.startBroadcast(governance);
        IB1N394AcceptOwner(ADDRESS_BOOK).acceptOwnership();
        IB1N394AcceptOwner(CONTROLLER).acceptOwnership();
        IB1N394AcceptOwner(ORACLE).acceptOwnership();
        IB1N394AcceptOwner(WHITELIST).acceptOwnership();
        IB1N394AcceptOwner(BATCH_SETTLER).acceptOwnership();
        replacementRouter = address(new MockSwapRouter(USDC));
        MockSwapRouter(replacementRouter).setPriceFeed(WETH, spotFeed);
        _setCspRouter(AccessManager(CSP_ACCESS), governance, cspBefore, replacementRouter);
        _setCcRouter(AccessManager(CC_ACCESS), governance, ccBefore, replacementRouter);
        vm.stopBroadcast();

        _requireOwned(governance);
        require(MockSwapRouter(replacementRouter).owner() == governance, "B1N394: router owner");
        require(MockSwapRouter(replacementRouter).priceFeeds(WETH) == spotFeed, "B1N394: router feed");
        CspFundAdapter.AdapterConfig memory cspAfter = CspFundAdapter(CSP_ADAPTER).adapterConfig();
        CoveredCallFundAdapter.AdapterConfig memory ccAfter = CoveredCallFundAdapter(CC_ADAPTER).adapterConfig();
        require(
            cspAfter.swapRouter == replacementRouter && cspAfter.swapFeeTier == cspBefore.swapFeeTier
                && keccak256(abi.encode(cspAfter.riskConfig)) == keccak256(abi.encode(cspBefore.riskConfig))
                && CspFundAdapter(CSP_ADAPTER).positionStateHash() == cspStateHash
                && StrategyManager(CSP_MANAGER).positionsHash() == cspPositionsHash,
            "B1N394: CSP router replacement"
        );
        require(
            ccAfter.swapRouter == replacementRouter && ccAfter.swapFeeTier == ccBefore.swapFeeTier
                && keccak256(abi.encode(ccAfter.riskConfig)) == keccak256(abi.encode(ccBefore.riskConfig))
                && CoveredCallFundAdapter(CC_ADAPTER).positionStateHash() == ccStateHash
                && StrategyManager(CC_MANAGER).positionsHash() == ccPositionsHash,
            "B1N394: CC router replacement"
        );
        console2.log("B1N394_REPLACEMENT_SWAP_ROUTER", replacementRouter);
        console2.log("B1N394_REPLACEMENT_SWAP_ROUTER_CODEHASH");
        console2.logBytes32(replacementRouter.codehash);
    }

    function _setCspRouter(
        AccessManager access,
        address governance,
        CspFundAdapter.AdapterConfig memory config,
        address replacement
    ) private {
        bytes memory data = abi.encodeCall(
            CspFundAdapter(CSP_ADAPTER).setAdapterConfig, (config.riskConfig, replacement, config.swapFeeTier)
        );
        access.execute(CSP_ADAPTER, data);
        _requireImmediateRole(access, FundConstants.CURATOR_ROLE, governance);
    }

    function _setCcRouter(
        AccessManager access,
        address governance,
        CoveredCallFundAdapter.AdapterConfig memory config,
        address replacement
    ) private {
        bytes memory data = abi.encodeCall(
            CoveredCallFundAdapter(CC_ADAPTER).setAdapterConfig, (config.riskConfig, replacement, config.swapFeeTier)
        );
        access.execute(CC_ADAPTER, data);
        _requireImmediateRole(access, FundConstants.CURATOR_ROLE, governance);
    }

    function _requirePending(address governance) private view {
        require(IB1N394AcceptOwner(ADDRESS_BOOK).pendingOwner() == governance, "B1N394: address book pending");
        require(IB1N394AcceptOwner(CONTROLLER).pendingOwner() == governance, "B1N394: controller pending");
        require(IB1N394AcceptOwner(ORACLE).pendingOwner() == governance, "B1N394: oracle pending");
        require(IB1N394AcceptOwner(WHITELIST).pendingOwner() == governance, "B1N394: whitelist pending");
        require(IB1N394AcceptOwner(BATCH_SETTLER).pendingOwner() == governance, "B1N394: settler pending");
    }

    function _requireOwned(address governance) private view {
        require(IB1N394AcceptOwner(ADDRESS_BOOK).owner() == governance, "B1N394: address book owner");
        require(IB1N394AcceptOwner(CONTROLLER).owner() == governance, "B1N394: controller owner");
        require(IB1N394AcceptOwner(ORACLE).owner() == governance, "B1N394: oracle owner");
        require(IB1N394AcceptOwner(WHITELIST).owner() == governance, "B1N394: whitelist owner");
        require(IB1N394AcceptOwner(BATCH_SETTLER).owner() == governance, "B1N394: settler owner");
    }
}
