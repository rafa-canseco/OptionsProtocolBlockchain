// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {B1N360ZeroDelayFundFactory} from "../../src/fund/B1N360ZeroDelayFundFactory.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {B1N360Operations} from "./B1N360Operations.sol";

contract ReconcileB1N360Deployment is B1N360Operations {
    function run() external view {
        _requireBaseSepolia();
        DeployConfig memory deployConfig = _loadDeployConfig();
        PolicyConfig memory policyConfig = _loadPolicyConfig();
        _validateExternalConfig(deployConfig);
        _requireExpectedV1Baseline(deployConfig.addressBook);
        _reconcileTopology(deployConfig, policyConfig);
        _verifyDeployedPolicy(deployConfig, policyConfig);

        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));
        require(
            _isAccessPhaseFinalized(
                manager, policyConfig.adapter, policyConfig.inKindEscrow, policyConfig.emergencyEscrow
            ),
            "B1N360: access incomplete"
        );
        _reconcileRoles(manager, deployConfig);
        require(_isPolicyPhaseFinalized(policyConfig), "B1N360: policy incomplete");
        require(FundVault(vm.envAddress("FUND_VAULT_PROXY")).depositsPaused(), "B1N360: deposits open");
        require(
            !StrategyManager(policyConfig.strategyManager).strategyConfig(policyConfig.adapter).active, "B1N360: active"
        );
        require(ICoveredCallFundAdapter(policyConfig.adapter).isOnboarded(), "B1N360: adapter not onboarded");
    }

    function _reconcileTopology(DeployConfig memory config, PolicyConfig memory policy) private view {
        address vaultAddress = vm.envAddress("FUND_VAULT_PROXY");
        address shareAddress = vm.envAddress("FUND_SHARE_PROXY");
        address accountingAddress = vm.envAddress("FUND_ACCOUNTING_PROXY");
        address flowAddress = vm.envAddress("FUND_FLOW_MANAGER_PROXY");
        address strategyAddress = vm.envAddress("FUND_STRATEGY_MANAGER_PROXY");
        address claimEscrow = vm.envAddress("FUND_CLAIM_ESCROW");
        address accessManager = vm.envAddress("FUND_ACCESS_MANAGER");

        require(
            B1N360ZeroDelayFundFactory(vm.envAddress("FUND_FACTORY")).fundCreated(), "B1N360: factory creation state"
        );
        FundVault vault = FundVault(vaultAddress);
        require(vault.asset() == config.weth, "B1N360: vault asset");
        require(vault.share() == shareAddress, "B1N360: vault share");
        require(vault.accounting() == accountingAddress, "B1N360: vault accounting");
        require(vault.flowManager() == flowAddress, "B1N360: vault flow");
        require(vault.strategyManager() == strategyAddress, "B1N360: vault strategy");
        require(vault.claimEscrow() == claimEscrow, "B1N360: vault claim escrow");
        require(FundShare(shareAddress).asset() == config.weth, "B1N360: share asset");
        require(FundShare(shareAddress).vault(config.weth) == vaultAddress, "B1N360: share vault");
        require(FundAccounting(accountingAddress).fund() == vaultAddress, "B1N360: accounting fund");
        require(FundFlowManager(flowAddress).fund() == vaultAddress, "B1N360: flow fund");
        require(FundFlowManager(flowAddress).claimEscrow() == claimEscrow, "B1N360: flow claim escrow");
        require(StrategyManager(strategyAddress).fund() == vaultAddress, "B1N360: strategy fund");
        require(StrategyAssetEscrow(policy.inKindEscrow).FUND() == vaultAddress, "B1N360: in-kind fund");
        require(StrategyAssetEscrow(policy.emergencyEscrow).FUND() == vaultAddress, "B1N360: emergency fund");
        require(ICoveredCallFundAdapter(policy.adapter).fund() == vaultAddress, "B1N360: adapter fund");
        require(
            ICoveredCallFundAdapter(policy.adapter).strategyManager() == strategyAddress, "B1N360: adapter strategy"
        );
        require(ICoveredCallFundAdapter(policy.adapter).accountingAsset() == config.weth, "B1N360: adapter WETH");
        require(ICoveredCallFundAdapter(policy.adapter).usdc() == config.usdc, "B1N360: adapter USDC");

        _requireProxyImplementation(vaultAddress, "FUND_VAULT_IMPLEMENTATION", "vault");
        _requireProxyImplementation(shareAddress, "FUND_SHARE_IMPLEMENTATION", "share");
        _requireProxyImplementation(accountingAddress, "FUND_ACCOUNTING_IMPLEMENTATION", "accounting");
        _requireProxyImplementation(flowAddress, "FUND_FLOW_MANAGER_IMPLEMENTATION", "flow");
        _requireProxyImplementation(strategyAddress, "FUND_STRATEGY_MANAGER_IMPLEMENTATION", "strategy");
        _requireProxyImplementation(policy.adapter, "FUND_CC_ADAPTER_IMPLEMENTATION", "adapter");
        require(FundAccessManager(accessManager).configuredSelectorCount(policy.adapter) == 2, "B1N360: adapter rules");
    }

    function _reconcileRoles(FundAccessManager manager, DeployConfig memory config) private view {
        _requireSingleRoleMember(manager, manager.ADMIN_ROLE(), config.roles.admin, "admin");
        _requireSingleRoleMember(manager, FundConstants.UPGRADER_ROLE, config.roles.upgrader, "upgrader");
        _requireSingleRoleMember(
            manager, FundConstants.ADAPTER_UPGRADER_ROLE, config.roles.upgrader, "adapter upgrader"
        );
        _requireSingleRoleMember(manager, FundConstants.ACCOUNTING_ROLE, config.roles.accounting, "accounting");
        _requireSingleRoleMember(manager, FundConstants.ALLOCATOR_ROLE, config.roles.allocator, "allocator");
        _requireSingleRoleMember(manager, FundConstants.PROCESSOR_ROLE, config.roles.processor, "processor");
        _requireSingleRoleMember(manager, FundConstants.CURATOR_ROLE, config.roles.curator, "curator");
        _requireSingleRoleMember(manager, FundConstants.GUARDIAN_ROLE, config.roles.guardian, "guardian");
    }

    function _requireSingleRoleMember(FundAccessManager manager, uint64 role, address expected, string memory label)
        private
        view
    {
        require(manager.roleMemberCount(role) == 1, string.concat("B1N360: ", label, " member count"));
        require(manager.roleMemberAt(role, 0) == expected, string.concat("B1N360: ", label, " member"));
        (bool active, uint32 executionDelay) = manager.hasRole(role, expected);
        require(active && executionDelay == 0, string.concat("B1N360: ", label, " delay"));
        (uint32 currentDelay, uint32 pendingDelay, uint48 effect) = manager.getRoleGrantDelayFull(role);
        require(currentDelay == 0 && pendingDelay == 0 && effect == 0, string.concat("B1N360: ", label, " grant delay"));
    }

    function _requireProxyImplementation(address proxy, string memory envKey, string memory component) private view {
        require(_implementationOf(proxy) == vm.envAddress(envKey), string.concat("B1N360: ", component, " impl"));
    }
}
