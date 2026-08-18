// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

/// @notice Idempotently authorizes the v2 adapter on the unchanged, pinned B1N-336 BatchSettler.
contract OnboardB1N352V2Adapter is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address addressBook_ = _approvedAddress("FUND_V1_ADDRESS_BOOK");
        _validateV1(addressBook_, _approvedAddress("FUND_ACCOUNTING_ASSET"), _approvedAddress("FUND_WETH"));
        _requireExpectedV1Baseline(addressBook_);

        BatchSettler settler = BatchSettler(AddressBook(addressBook_).batchSettler());
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        require(adapter.code.length != 0, "B1N352V2: adapter code");
        if (settler.authorizedPhysicalDeliveryVault(adapter)) {
            require(ICspFundAdapter(adapter).isOnboarded(), "B1N352V2: inconsistent onboarding");
            console2.log("PHASE_ALREADY_FINALIZED");
            return;
        }

        uint256 callerKey = _phaseSchedulerKey();
        require(vm.addr(callerKey) == settler.owner(), "B1N352V2: settler owner");
        address implementationBefore = _implementationOf(address(settler));
        vm.startBroadcast(callerKey);
        settler.setPhysicalDeliveryVault(adapter, true);
        vm.stopBroadcast();
        require(_implementationOf(address(settler)) == implementationBefore, "B1N352V2: settler changed");
        require(settler.authorizedPhysicalDeliveryVault(adapter), "B1N352V2: onboarding failed");
        require(ICspFundAdapter(adapter).isOnboarded(), "B1N352V2: adapter not onboarded");
        _requireExpectedV1Baseline(addressBook_);
    }
}

/// @notice Activates only the approved strategy config; deposits remain paused.
contract ActivateB1N352V2Strategy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        require(ICspFundAdapter(adapter).isOnboarded(), "B1N352V2: adapter not onboarded");
        FundVault vault = FundVault(vm.envAddress("FUND_VAULT_PROXY"));
        require(vault.depositsPaused(), "B1N352V2: deposits open");
        address strategyManager_ = vm.envAddress("FUND_STRATEGY_MANAGER_PROXY");
        StrategyManager strategy = StrategyManager(strategyManager_);
        PolicyConfig memory policyConfig = _loadPolicyConfig();
        require(_isPolicyPhaseFinalized(policyConfig), "B1N352V2: policy incomplete");

        Operation[] memory operations = new Operation[](1);
        operations[0] = _activationOperation(strategyManager_, adapter);
        _executeImmediateOperations(
            AccessManager(vm.envAddress("FUND_ACCESS_MANAGER")),
            operations,
            _phaseSchedulerKey(),
            _isActivationPhaseFinalized(strategyManager_, adapter)
        );
        require(strategy.strategyConfig(adapter).active, "B1N352V2: activation failed");
        require(vault.depositsPaused(), "B1N352V2: deposits opened during activation");
    }
}

/// @notice Explicit final gate for deposits after strategy activation and reconciliation.
contract OpenB1N352V2Deposits is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        require(ICspFundAdapter(adapter).isOnboarded(), "B1N352V2: adapter not onboarded");
        require(
            StrategyManager(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY")).strategyConfig(adapter).active,
            "B1N352V2: strategy inactive"
        );
        FundVault vault = FundVault(vm.envAddress("FUND_VAULT_PROXY"));
        if (!vault.depositsPaused()) {
            console2.log("PHASE_ALREADY_FINALIZED");
            return;
        }

        Operation[] memory operations = new Operation[](1);
        operations[0] = Operation({
            target: address(vault),
            data: abi.encodeCall(vault.resumeDeposits, ()),
            label: keccak256("OPEN_B1N352_V2_DEPOSITS")
        });
        _executeImmediateOperations(
            AccessManager(vm.envAddress("FUND_ACCESS_MANAGER")), operations, _phaseSchedulerKey(), false
        );
        require(!vault.depositsPaused(), "B1N352V2: deposits still paused");
    }
}
