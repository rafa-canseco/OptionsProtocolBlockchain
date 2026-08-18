// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {Script} from "forge-std/Script.sol";

interface IB1N394ValuatorPolicy {
    function spotFeed() external view returns (address);
    function spotFeedDecimals() external view returns (uint8);
    function maxSpotStaleness() external view returns (uint64);
    function maxObservationWindow() external view returns (uint64);
    function observationQuorum() external view returns (uint8);
    function approvedObserverCount() external view returns (uint256);
    function approvedObserverAt(uint256 index) external view returns (address);
}

abstract contract B1N394Base is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint64 internal constant MANAGEMENT_FEE_WAD = 0.02e18;
    uint16 internal constant PERFORMANCE_FEE_BPS = 1_000;
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 200;
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 2_000;
    uint32 internal constant MAX_ACCRUAL_INTERVAL = 30 days;
    uint32 internal constant CRYSTALLIZATION_PERIOD = 1 days;
    uint256 internal constant PREMIUM_FEE_BPS = 1_000;

    address internal constant BATCH_SETTLER = 0xb94D6270B336dca566C2077d50c2C50F06398cB8;

    address internal constant CSP_ACCESS = 0x729d5076C1C59a7C2676Faf3fB9133Ff80cDaB12;
    address internal constant CSP_VAULT = 0x53e38Baf2fC55259729085b7542BFF066F6a509e;
    address internal constant CSP_ACCOUNTING = 0x21d3acc5a2c64666dA93ABC8c77AB483b96836a3;
    address internal constant CSP_FLOW = 0x0206C0A5050b09B7A2AD4E8CbF83a06ae2193080;
    address internal constant CSP_MANAGER = 0xfC28237145596D4E1dfD28B80e186EFC09A1F988;
    address internal constant CSP_ADAPTER = 0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3;
    address internal constant CSP_CURRENT_VALUATOR = 0x63aB18b546d2b7a6e9e68eF7C784Ecfa41B76798;

    address internal constant CC_ACCESS = 0x5AfD3d840ec2f7fE078b44b75462C2dCD3DC3F6D;
    address internal constant CC_VAULT = 0x9060946E6ACC4E430A823E90120743c7305EE2CA;
    address internal constant CC_ACCOUNTING = 0x9a112A65FE8510bCf5DC894fFBf06aEa8d12d311;
    address internal constant CC_FLOW = 0x59fc0d88aAF3D14b82696cc7E91ea37b629E48cc;
    address internal constant CC_MANAGER = 0x745422dd14E84ee27C2E56D2845C3BB1658027d9;
    address internal constant CC_ADAPTER = 0x0BF96C5cE0D637d4D686d342aE42Bc00fDa19De9;
    address internal constant CC_CURRENT_VALUATOR = 0xA1BFC1bE3C7fCA77CA0b32d25de1Ce58A50333A0;

    struct Implementations {
        address accounting;
        address flow;
        address manager;
        address cspAdapter;
        address ccAdapter;
        address cspValuator;
        address ccValuator;
    }

    function _requireBaseSepolia() internal view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "B1N394: Base Sepolia only");
    }

    function _loadImplementations() internal view returns (Implementations memory implementations) {
        implementations.accounting = vm.envAddress("B1N394_FUND_ACCOUNTING_IMPLEMENTATION");
        implementations.flow = vm.envAddress("B1N394_FUND_FLOW_IMPLEMENTATION");
        implementations.manager = vm.envAddress("B1N394_STRATEGY_MANAGER_IMPLEMENTATION");
        implementations.cspAdapter = vm.envAddress("B1N394_CSP_ADAPTER_IMPLEMENTATION");
        implementations.ccAdapter = vm.envAddress("B1N394_CC_ADAPTER_IMPLEMENTATION");
        implementations.cspValuator = vm.envAddress("B1N394_CSP_VALUATOR");
        implementations.ccValuator = vm.envAddress("B1N394_CC_VALUATOR");
    }

    function _feeConfig(address recipient) internal pure returns (FundTypes.FeeConfig memory config) {
        config = FundTypes.FeeConfig({
            managementFeeWad: MANAGEMENT_FEE_WAD,
            performanceFeeBps: PERFORMANCE_FEE_BPS,
            maxManagementFeeBps: MAX_MANAGEMENT_FEE_BPS,
            maxPerformanceFeeBps: MAX_PERFORMANCE_FEE_BPS,
            maxAccrualInterval: MAX_ACCRUAL_INTERVAL,
            crystallizationPeriod: CRYSTALLIZATION_PERIOD,
            feeRecipient: recipient
        });
    }

    function _approvedObservers(address valuator) internal view returns (address[] memory observers) {
        IB1N394ValuatorPolicy policy = IB1N394ValuatorPolicy(valuator);
        observers = new address[](policy.approvedObserverCount());
        for (uint256 i; i < observers.length; ++i) {
            observers[i] = policy.approvedObserverAt(i);
        }
    }

    function _requireMatchingPolicy(address prior, address replacement) internal view {
        IB1N394ValuatorPolicy beforePolicy = IB1N394ValuatorPolicy(prior);
        IB1N394ValuatorPolicy afterPolicy = IB1N394ValuatorPolicy(replacement);
        require(afterPolicy.spotFeed() == beforePolicy.spotFeed(), "B1N394: spot feed");
        require(afterPolicy.spotFeedDecimals() == beforePolicy.spotFeedDecimals(), "B1N394: spot decimals");
        require(afterPolicy.maxSpotStaleness() == beforePolicy.maxSpotStaleness(), "B1N394: spot staleness");
        require(afterPolicy.maxObservationWindow() == beforePolicy.maxObservationWindow(), "B1N394: observation window");
        require(afterPolicy.observationQuorum() == beforePolicy.observationQuorum(), "B1N394: quorum");
        require(afterPolicy.approvedObserverCount() == beforePolicy.approvedObserverCount(), "B1N394: observer count");
        for (uint256 i; i < beforePolicy.approvedObserverCount(); ++i) {
            require(afterPolicy.approvedObserverAt(i) == beforePolicy.approvedObserverAt(i), "B1N394: observer order");
        }
    }

    function _requireImmediateRole(AccessManager manager, uint64 role, address member) internal view {
        (bool active, uint32 executionDelay) = manager.hasRole(role, member);
        require(active && executionDelay == 0, "B1N394: immediate role unavailable");
    }

    function _managedCall(
        AccessManager manager,
        address broadcaster,
        address target,
        bytes memory data,
        uint64 expectedRole
    ) internal view returns (bytes memory) {
        bytes4 selector;
        assembly {
            selector := mload(add(data, 0x20))
        }
        require(manager.getTargetFunctionRole(target, selector) == expectedRole, "B1N394: selector role");
        _requireImmediateRole(manager, expectedRole, broadcaster);
        require(manager.getSchedule(manager.hashOperation(broadcaster, target, data)) == 0, "B1N394: live schedule");
        return abi.encodeCall(manager.execute, (target, data));
    }

    function _requireFeeConfig(FundAccounting accounting, address expectedRecipient) internal view {
        FundTypes.FeeConfig memory config = accounting.feeConfig();
        require(config.managementFeeWad == MANAGEMENT_FEE_WAD, "B1N394: management fee");
        require(config.performanceFeeBps == PERFORMANCE_FEE_BPS, "B1N394: performance fee");
        require(config.maxManagementFeeBps == MAX_MANAGEMENT_FEE_BPS, "B1N394: management cap");
        require(config.maxPerformanceFeeBps == MAX_PERFORMANCE_FEE_BPS, "B1N394: performance cap");
        require(config.maxAccrualInterval == MAX_ACCRUAL_INTERVAL, "B1N394: accrual interval");
        require(config.crystallizationPeriod == CRYSTALLIZATION_PERIOD, "B1N394: crystallization");
        require(config.feeRecipient == expectedRecipient, "B1N394: fee recipient");
    }

    function _requirePaused(FundVault vault, StrategyManager manager, address adapter) internal view {
        require(vault.depositsPaused(), "B1N394: deposits not paused");
        require(vault.redemptionsPaused(), "B1N394: redemptions not paused");
        require(!manager.strategyConfig(adapter).active, "B1N394: allocation not paused");
    }
}
