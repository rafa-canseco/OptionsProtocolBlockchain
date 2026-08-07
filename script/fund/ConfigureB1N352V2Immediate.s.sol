// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {B1N352Operations} from "./B1N352Operations.sol";
import {B1N352V2Profile} from "./B1N352V2Profile.sol";

/// @notice Atomically configures the adapter and escrow selector roles with zero admin delay.
contract ConfigureB1N352V2Access is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        address adapter = vm.envAddress("FUND_CSP_ADAPTER_PROXY");
        address inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        address emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        Operation[] memory operations =
            _accessOperationsWithAdminDelay(address(manager), adapter, inKindEscrow, emergencyEscrow, 0);
        _executeImmediateManagerOperations(
            manager,
            operations,
            _phaseSchedulerKey(),
            _isAccessPhaseFinalizedWithAdminDelay(manager, adapter, inKindEscrow, emergencyEscrow, 0)
        );
        require(
            _isAccessPhaseFinalizedWithAdminDelay(manager, adapter, inKindEscrow, emergencyEscrow, 0),
            "B1N352V2: access incomplete"
        );
    }
}

/// @notice Atomically applies the approved low-cap policy while the strategy and deposits remain inactive.
contract ConfigureB1N352V2Policy is B1N352Operations {
    function run() external {
        _requireBaseSepolia();
        DeployConfig memory deployConfig = _loadDeployConfig();
        PolicyConfig memory policyConfig = _loadPolicyConfig();
        _requireV2Policy(deployConfig, policyConfig);

        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        address adapter = policyConfig.adapter;
        require(
            _isAccessPhaseFinalizedWithAdminDelay(
                manager, adapter, policyConfig.inKindEscrow, policyConfig.emergencyEscrow, 0
            ),
            "B1N352V2: access not configured"
        );
        FundVault vault = FundVault(vm.envAddress("FUND_VAULT_PROXY"));
        require(vault.depositsPaused(), "B1N352V2: deposits open");
        StrategyManager strategy = StrategyManager(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"));
        require(!strategy.strategyConfig(adapter).active, "B1N352V2: strategy already active");

        _executeImmediateOperations(
            manager, _policyOperations(policyConfig), _phaseSchedulerKey(), _isPolicyPhaseFinalized(policyConfig)
        );
        require(_isPolicyPhaseFinalized(policyConfig), "B1N352V2: policy incomplete");
        _verifyDeployedPolicy(deployConfig, policyConfig, false);
        require(vault.depositsPaused(), "B1N352V2: deposits opened");
        require(!strategy.strategyConfig(adapter).active, "B1N352V2: strategy activated");
    }

    function _requireV2Policy(DeployConfig memory deployConfig, PolicyConfig memory policyConfig) private pure {
        require(deployConfig.navActivationDelay == B1N352V2Profile.NAV_ACTIVATION_BLOCKS, "B1N352V2: NAV delay");
        require(policyConfig.maxExitFeeBps == B1N352V2Profile.MAX_EXIT_FEE_BPS, "B1N352V2: exit fee");
        require(policyConfig.minimumIdleBps == B1N352V2Profile.MINIMUM_IDLE_BPS, "B1N352V2: minimum idle");
        require(policyConfig.maxAllocationBps == B1N352V2Profile.MAX_ALLOCATION_BPS, "B1N352V2: max allocation");
        require(policyConfig.cooldown == B1N352V2Profile.STRATEGY_COOLDOWN_SECONDS, "B1N352V2: cooldown");
        require(policyConfig.absoluteCap == B1N352V2Profile.FUND_CAP, "B1N352V2: fund cap");
        require(
            deployConfig.adapterRiskConfig.minExpiryDelay == B1N352V2Profile.MIN_EXPIRY_SECONDS, "B1N352V2: min expiry"
        );
        require(
            deployConfig.adapterRiskConfig.maxExpiryDelay == B1N352V2Profile.MAX_EXPIRY_SECONDS, "B1N352V2: max expiry"
        );
        require(
            deployConfig.adapterRiskConfig.minPremiumBps == B1N352V2Profile.MIN_PREMIUM_BPS, "B1N352V2: min premium"
        );
        require(
            deployConfig.adapterRiskConfig.maxCollateralPerPosition == B1N352V2Profile.COLLATERAL_CAP,
            "B1N352V2: collateral cap"
        );
        require(
            deployConfig.adapterRiskConfig.maxOpenPositions == B1N352V2Profile.MAX_POSITIONS, "B1N352V2: max positions"
        );
    }
}
