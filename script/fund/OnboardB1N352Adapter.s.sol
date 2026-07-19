// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {B1N352Base} from "./B1N352Base.sol";

/// @notice The only V1 mutation permitted by B1N-352. This script never upgrades V1 implementations.
contract OnboardB1N352Adapter is B1N352Base {
    function run() external {
        _requireBaseSepolia();
        address addressBook_ = vm.envAddress("FUND_V1_ADDRESS_BOOK");
        address accountingAsset = vm.envAddress("FUND_ACCOUNTING_ASSET");
        address weth = vm.envAddress("FUND_WETH");
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        _validateV1(addressBook_, accountingAsset, weth);
        _logV1Baseline(addressBook_);

        BatchSettler settler = BatchSettler(AddressBook(addressBook_).batchSettler());
        if (settler.authorizedPhysicalDeliveryVault(adapter)) {
            require(ICspFundAdapter(adapter).isOnboarded(), "B1N352: inconsistent onboarding");
            _logV1Baseline(addressBook_);
            return;
        }
        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        require(settler.owner() == vm.addr(ownerKey), "B1N352: settler owner key");

        vm.startBroadcast(ownerKey);
        settler.setPhysicalDeliveryVault(adapter, true);
        vm.stopBroadcast();

        require(settler.authorizedPhysicalDeliveryVault(adapter), "B1N352: onboarding failed");
        require(ICspFundAdapter(adapter).isOnboarded(), "B1N352: adapter preflight failed");
        _logV1Baseline(addressBook_);
    }
}
