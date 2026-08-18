// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {B1N360Base} from "./B1N360Base.sol";

contract PrepareB1N360Onboarding is B1N360Base {
    function run() external view {
        _requireBaseSepolia();
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        address adapter = vm.envAddress("FUND_CC_ADAPTER_PROXY");
        _validateV1(addressBook_, _approvedAddress("FUND_ACCOUNTING_ASSET"), _approvedAddress("FUND_USDC"));
        _requireExpectedV1Baseline(addressBook_);
        require(adapter.code.length != 0, "B1N360: adapter code");

        BatchSettler settler = BatchSettler(AddressBook(addressBook_).batchSettler());
        _requireNotOnboarded(settler, adapter);
        console2.log("ONBOARDING_OWNER", settler.owner());
        console2.log("ONBOARDING_TARGET", address(settler));
        console2.log("ONBOARDING_IMPLEMENTATION", _implementationOf(address(settler)));
        console2.log("ONBOARDING_CALLDATA");
        console2.logBytes(abi.encodeCall(settler.setPhysicalDeliveryVault, (adapter, true)));
    }
}

contract OnboardB1N360Adapter is B1N360Base {
    function run() external {
        _requireBaseSepolia();
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        address adapter = vm.envAddress("FUND_CC_ADAPTER_PROXY");
        _validateV1(addressBook_, _approvedAddress("FUND_ACCOUNTING_ASSET"), _approvedAddress("FUND_USDC"));
        _requireExpectedV1Baseline(addressBook_);
        require(adapter.code.length != 0, "B1N360: adapter code");

        BatchSettler settler = BatchSettler(AddressBook(addressBook_).batchSettler());
        _requireNotOnboarded(settler, adapter);
        address implementationBefore = _implementationOf(address(settler));
        uint256 broadcasterKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(broadcasterKey) == settler.owner(), "B1N360: settler owner key");

        vm.startBroadcast(broadcasterKey);
        settler.setPhysicalDeliveryVault(adapter, true);
        vm.stopBroadcast();

        require(_implementationOf(address(settler)) == implementationBefore, "B1N360: settler implementation changed");
        require(settler.authorizedPhysicalDeliveryVault(adapter), "B1N360: onboarding failed");
        require(ICoveredCallFundAdapter(adapter).isOnboarded(), "B1N360: adapter still not onboarded");
        _requireExpectedV1Baseline(addressBook_);
        console2.log("CC_ADAPTER_PROXY", adapter);
        console2.log("CC_ADAPTER_IS_ONBOARDED", true);
    }
}
