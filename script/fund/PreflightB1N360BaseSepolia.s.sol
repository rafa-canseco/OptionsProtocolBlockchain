// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {B1N360Base} from "./B1N360Base.sol";

/// @notice Read-only gate for approved artifacts, broadcaster, V1 boundary and call-product wiring.
contract PreflightB1N360BaseSepolia is B1N360Base {
    function run() external view {
        _requireBaseSepolia();
        DeployConfig memory config = _loadDeployConfig();
        _validateExternalConfig(config);
        _requireExpectedV1Baseline(config.addressBook);
        _logV1Baseline(config.addressBook);

        address broadcaster = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(broadcaster == _approvedAddress("FUND_PHASE_SCHEDULER"), "B1N360: broadcaster");
        require(broadcaster.balance >= _approvedUint("FUND_MIN_BROADCASTER_BALANCE_WEI"), "B1N360: broadcaster balance");
        console2.log("PREFLIGHT_CHAIN_ID", block.chainid);
        console2.log("PREFLIGHT_BROADCASTER", broadcaster);
        console2.log("PREFLIGHT_BROADCASTER_BALANCE", broadcaster.balance);
        console2.log("PREFLIGHT_FUND_KEY", _approvedString("FUND_KEY"));
        console2.log("PREFLIGHT_STRATEGY_KIND", _approvedString("FUND_STRATEGY_KIND"));

        address adapter = vm.envOr("FUND_CC_ADAPTER_PROXY", address(0));
        if (adapter != address(0)) {
            require(adapter.code.length != 0, "B1N360: adapter code");
            console2.log("CC_ADAPTER_PROXY", adapter);
            console2.log("CC_ADAPTER_IS_ONBOARDED", ICoveredCallFundAdapter(adapter).isOnboarded());
        }
    }
}
