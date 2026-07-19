// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {B1N352Base} from "./B1N352Base.sol";

/// @notice Read-only custodial and wiring gate. It never starts a broadcast.
contract PreflightB1N352BaseSepolia is B1N352Base {
    function run() external view {
        _requireBaseSepolia();
        address addressBook_ = vm.envAddress("FUND_V1_ADDRESS_BOOK");
        _validateV1(addressBook_, vm.envAddress("FUND_ACCOUNTING_ASSET"), vm.envAddress("FUND_WETH"));
        _requireExpectedV1Baseline(addressBook_);
        _logV1Baseline(addressBook_);

        address adapter = vm.envOr("FUND_CSP_ADAPTER_PROXY", address(0));
        if (adapter != address(0)) {
            require(adapter.code.length != 0, "B1N352: adapter code");
            console2.log("CSP_ADAPTER_PROXY", adapter);
            console2.log("CSP_ADAPTER_IS_ONBOARDED", ICspFundAdapter(adapter).isOnboarded());
        }
    }
}
