// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {console2} from "forge-std/console2.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {B1N394Base, IB1N394ValuatorPolicy} from "./B1N394Base.sol";

interface IB1N394OwnedFeed {
    function owner() external view returns (address);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Removes the retired signer's remaining authority from shared pricing, swap, fee, and MM dependencies.
/// @dev Uses the same Base Sepolia Chainlink feed already pinned by both V2 valuators.
contract CompleteB1N394AuthorityRotation is B1N394Base {
    address private constant RETIRING_SIGNER = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant ORACLE = 0xF95CC4aED4a0bD68e0F1BE7c779BC281189F8187;
    address private constant WETH = 0x8A6Aa2304797898d46eC1d342Fedc817D3a973B6;
    address private constant REPLACEMENT_ROUTER = 0x0Cd738d1F80FaDBbF6171280eD01Cfa33F8E17b3;

    struct Snapshot {
        bytes32 cspAdapterState;
        bytes32 ccAdapterState;
        bytes32 cspManagerPositions;
        bytes32 ccManagerPositions;
        uint256 retiredMakerNonce;
        bool retiredWhitelisted;
    }

    function run() external {
        _requireBaseSepolia();
        address governance = vm.envAddress("B1N394_NEW_GOVERNANCE");
        BatchSettler settler = BatchSettler(BATCH_SETTLER);
        Oracle oracle = Oracle(ORACLE);
        MockSwapRouter router = MockSwapRouter(REPLACEMENT_ROUTER);
        address trustedSpotFeed = _trustedSpotFeed();
        Snapshot memory before_ = _snapshot(settler);

        require(governance != address(0) && governance != RETIRING_SIGNER, "B1N394: governance");
        require(settler.owner() == governance, "B1N394: settler owner");
        require(oracle.owner() == governance, "B1N394: oracle owner");
        require(router.owner() == governance, "B1N394: router owner");
        require(trustedSpotFeed.code.length != 0, "B1N394: trusted feed code");
        require(IB1N394OwnedFeed(trustedSpotFeed).owner() != RETIRING_SIGNER, "B1N394: retired feed owner");
        (, int256 spotPrice,,,) = IB1N394OwnedFeed(trustedSpotFeed).latestRoundData();
        require(spotPrice > 0, "B1N394: trusted feed price");

        vm.startBroadcast(governance);
        router.setPriceFeed(WETH, trustedSpotFeed);
        oracle.setPriceFeed(WETH, trustedSpotFeed);
        settler.setSwapRouter(REPLACEMENT_ROUTER);
        settler.setTreasury(governance);
        if (before_.retiredWhitelisted) settler.setWhitelistedMM(RETIRING_SIGNER, false);
        vm.stopBroadcast();

        require(router.priceFeeds(WETH) == trustedSpotFeed, "B1N394: router feed");
        require(oracle.priceFeed(WETH) == trustedSpotFeed, "B1N394: oracle feed");
        require(settler.swapRouter() == REPLACEMENT_ROUTER, "B1N394: settler router");
        require(settler.treasury() == governance, "B1N394: treasury");
        require(!settler.whitelistedMMs(RETIRING_SIGNER), "B1N394: retired MM");
        require(
            settler.makerNonce(RETIRING_SIGNER) == before_.retiredMakerNonce + (before_.retiredWhitelisted ? 1 : 0),
            "B1N394: retired maker nonce"
        );
        _requireFundStateUnchanged(before_);
        _requireNoFundRoles(AccessManager(CSP_ACCESS));
        _requireNoFundRoles(AccessManager(CC_ACCESS));

        console2.log("B1N394_TRUSTED_SPOT_FEED", trustedSpotFeed);
        console2.log("B1N394_RETIRED_MAKER_NONCE", settler.makerNonce(RETIRING_SIGNER));
    }

    function _trustedSpotFeed() private view returns (address feed) {
        address cspValuator = StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER).valuator;
        address ccValuator = StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER).valuator;
        feed = IB1N394ValuatorPolicy(cspValuator).spotFeed();
        require(feed == IB1N394ValuatorPolicy(ccValuator).spotFeed(), "B1N394: valuator feed mismatch");
        require(
            IB1N394ValuatorPolicy(cspValuator).spotFeedDecimals()
                == IB1N394ValuatorPolicy(ccValuator).spotFeedDecimals(),
            "B1N394: valuator decimals mismatch"
        );
    }

    function _snapshot(BatchSettler settler) private view returns (Snapshot memory before_) {
        before_.cspAdapterState = CspFundAdapter(CSP_ADAPTER).positionStateHash();
        before_.ccAdapterState = CoveredCallFundAdapter(CC_ADAPTER).positionStateHash();
        before_.cspManagerPositions = StrategyManager(CSP_MANAGER).positionsHash();
        before_.ccManagerPositions = StrategyManager(CC_MANAGER).positionsHash();
        before_.retiredMakerNonce = settler.makerNonce(RETIRING_SIGNER);
        before_.retiredWhitelisted = settler.whitelistedMMs(RETIRING_SIGNER);
    }

    function _requireFundStateUnchanged(Snapshot memory before_) private view {
        require(CspFundAdapter(CSP_ADAPTER).positionStateHash() == before_.cspAdapterState, "B1N394: CSP adapter state");
        require(
            CoveredCallFundAdapter(CC_ADAPTER).positionStateHash() == before_.ccAdapterState, "B1N394: CC adapter state"
        );
        require(
            StrategyManager(CSP_MANAGER).positionsHash() == before_.cspManagerPositions, "B1N394: CSP manager state"
        );
        require(StrategyManager(CC_MANAGER).positionsHash() == before_.ccManagerPositions, "B1N394: CC manager state");
    }

    function _requireNoFundRoles(AccessManager access) private view {
        for (uint64 role; role <= FundConstants.ADAPTER_UPGRADER_ROLE; ++role) {
            (bool active,) = access.hasRole(role, RETIRING_SIGNER);
            require(!active, "B1N394: retired fund role");
        }
    }
}
