// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {B1N352Base} from "./B1N352Base.sol";

/// @notice Read-only preparation for the isolated B1N-336 Base Sepolia stack onboarding.
contract PrepareB1N352Onboarding is B1N352Base {
    function run() external view {
        _requireBaseSepolia();
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        _validateV1(addressBook_, _approvedAddress("FUND_ACCOUNTING_ASSET"), _approvedAddress("FUND_WETH"));
        _requireExpectedV1Baseline(addressBook_);

        BatchSettler settler = BatchSettler(AddressBook(addressBook_).batchSettler());
        _requireNotOnboarded(settler, adapter);
        console2.log("ONBOARDING_OWNER", settler.owner());
        console2.log("ONBOARDING_TARGET", address(settler));
        console2.log("ONBOARDING_IMPLEMENTATION", _implementationOf(address(settler)));
        console2.log("ONBOARDING_CALLDATA");
        console2.logBytes(abi.encodeCall(settler.setPhysicalDeliveryVault, (adapter, true)));
        _logV1Baseline(addressBook_);
    }
}

/// @notice Authorizes the deployed Fund adapter on the isolated, codehash-pinned B1N-336 BatchSettler.
contract OnboardB1N352Adapter is B1N352Base {
    function run() external {
        _requireBaseSepolia();
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        _validateV1(addressBook_, _approvedAddress("FUND_ACCOUNTING_ASSET"), _approvedAddress("FUND_WETH"));
        _requireExpectedV1Baseline(addressBook_);
        require(adapter.code.length != 0, "B1N352: adapter code");

        BatchSettler settler = BatchSettler(AddressBook(addressBook_).batchSettler());
        _requireNotOnboarded(settler, adapter);
        address implementationBefore = _implementationOf(address(settler));

        vm.startBroadcast();
        settler.setPhysicalDeliveryVault(adapter, true);
        vm.stopBroadcast();

        require(_implementationOf(address(settler)) == implementationBefore, "B1N352: settler implementation changed");
        require(settler.authorizedPhysicalDeliveryVault(adapter), "B1N352: onboarding failed");
        _requireExpectedV1Baseline(addressBook_);
        console2.log("CSP_ADAPTER_PROXY", adapter);
        console2.log("CSP_ADAPTER_IS_ONBOARDED", true);
    }
}
