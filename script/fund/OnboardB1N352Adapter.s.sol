// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {B1N352Base} from "./B1N352Base.sol";

/// @notice Read-only preparation for an atomic owner-controlled V1 onboarding transaction.
/// @dev The repository deliberately provides no direct broadcast path for this privileged mutation.
contract PrepareB1N352AtomicOnboarding is B1N352Base {
    function run() external view {
        _requireBaseSepolia();
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        _validateV1(addressBook_, _approvedAddress("FUND_ACCOUNTING_ASSET"), _approvedAddress("FUND_WETH"));
        _requireExpectedV1Baseline(addressBook_);

        BatchSettler settler = BatchSettler(AddressBook(addressBook_).batchSettler());
        require(!settler.authorizedPhysicalDeliveryVault(adapter), "B1N352: already onboarded");
        require(settler.owner().code.length != 0, "B1N352: atomic owner required");

        console2.log("ATOMIC_ONBOARDING_OWNER", settler.owner());
        console2.log("ATOMIC_ONBOARDING_TARGET", address(settler));
        console2.log("ATOMIC_ONBOARDING_CALLDATA");
        console2.logBytes(abi.encodeCall(settler.setPhysicalDeliveryVault, (adapter, true)));
        _logV1Baseline(addressBook_);
    }
}

/// @notice Disabled legacy entry point retained to prevent accidental non-atomic onboarding broadcasts.
contract OnboardB1N352Adapter is B1N352Base {
    function run() external pure {
        revert("B1N352: atomic onboarding only");
    }
}
