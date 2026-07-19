// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

/// @notice Read-only state reconciliation for manifest finalization and post-configuration checks.
contract ReconcileB1N352Deployment is B1N352Operations {
    function run() external view {
        _requireBaseSepolia();
        DeployConfig memory deployConfig = _loadDeployConfig();
        PolicyConfig memory policyConfig = _loadPolicyConfig();
        _validateExternalConfig(deployConfig);
        _requireExpectedV1Baseline(deployConfig.addressBook);

        address addressBook_ = deployConfig.addressBook;
        address accountingAsset = deployConfig.accountingAsset;
        address weth = deployConfig.weth;

        FundVault vault = FundVault(vm.envAddress("FUND_VAULT_PROXY"));
        FundShare share = FundShare(vm.envAddress("FUND_SHARE_PROXY"));
        FundAccounting accounting = FundAccounting(vm.envAddress("FUND_ACCOUNTING_PROXY"));
        FundFlowManager flow = FundFlowManager(vm.envAddress("FUND_FLOW_MANAGER_PROXY"));
        StrategyManager strategy = StrategyManager(vm.envAddress("FUND_STRATEGY_MANAGER_PROXY"));
        CspFundAdapter adapter = CspFundAdapter(vm.envAddress("FUND_CSP_ADAPTER_PROXY"));
        AccessManager manager = AccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));

        require(vault.asset() == accountingAsset, "B1N352: vault asset");
        require(vault.share() == address(share), "B1N352: vault share");
        require(vault.accounting() == address(accounting), "B1N352: vault accounting");
        require(vault.flowManager() == address(flow), "B1N352: vault flow");
        require(vault.strategyManager() == address(strategy), "B1N352: vault strategy");
        require(share.vault(accountingAsset) == address(vault), "B1N352: share vault");
        require(accounting.fund() == address(vault), "B1N352: accounting fund");
        require(flow.fund() == address(vault), "B1N352: flow fund");
        require(strategy.fund() == address(vault), "B1N352: strategy fund");
        require(adapter.fund() == address(vault), "B1N352: adapter fund");
        require(adapter.strategyManager() == address(strategy), "B1N352: adapter strategy");
        require(adapter.addressBook() == addressBook_, "B1N352: adapter address book");
        require(adapter.accountingAsset() == accountingAsset, "B1N352: adapter asset");
        require(adapter.weth() == weth, "B1N352: adapter WETH");
        require(vault.authority() == address(manager), "B1N352: vault authority");
        require(share.authority() == address(manager), "B1N352: share authority");
        require(accounting.authority() == address(manager), "B1N352: accounting authority");
        require(flow.authority() == address(manager), "B1N352: flow authority");
        require(strategy.authority() == address(manager), "B1N352: strategy authority");
        require(adapter.authority() == address(manager), "B1N352: adapter authority");

        _verifyProxy("FUND_VAULT_IMPLEMENTATION", address(vault));
        _verifyProxy("FUND_SHARE_IMPLEMENTATION", address(share));
        _verifyProxy("FUND_ACCOUNTING_IMPLEMENTATION", address(accounting));
        _verifyProxy("FUND_FLOW_MANAGER_IMPLEMENTATION", address(flow));
        _verifyProxy("FUND_STRATEGY_MANAGER_IMPLEMENTATION", address(strategy));
        _verifyProxy("FUND_CSP_ADAPTER_IMPLEMENTATION", address(adapter));

        address inKindEscrow = vm.envAddress("FUND_IN_KIND_STRATEGY_ESCROW");
        address emergencyEscrow = vm.envAddress("FUND_EMERGENCY_STRATEGY_ESCROW");
        require(StrategyAssetEscrow(inKindEscrow).FUND() == address(vault), "B1N352: in-kind fund");
        require(StrategyAssetEscrow(inKindEscrow).authority() == address(manager), "B1N352: in-kind authority");
        require(StrategyAssetEscrow(inKindEscrow).PURPOSE() == IN_KIND_ESCROW_PURPOSE, "B1N352: in-kind purpose");
        require(StrategyAssetEscrow(emergencyEscrow).FUND() == address(vault), "B1N352: emergency fund");
        require(StrategyAssetEscrow(emergencyEscrow).authority() == address(manager), "B1N352: emergency authority");
        require(StrategyAssetEscrow(emergencyEscrow).PURPOSE() == EMERGENCY_ESCROW_PURPOSE, "B1N352: emergency purpose");

        _verifyAccessManager(
            manager,
            address(vault),
            address(share),
            address(accounting),
            address(flow),
            address(strategy),
            address(adapter),
            inKindEscrow,
            emergencyEscrow
        );

        require(adapter.isOnboarded() == vm.envBool("FUND_EXPECT_ADAPTER_ONBOARDED"), "B1N352: onboarded state");
        require(
            strategy.strategyConfig(address(adapter)).active == vm.envBool("FUND_EXPECT_STRATEGY_ACTIVE"),
            "B1N352: strategy active state"
        );
        _verifyDeployedPolicy(deployConfig, policyConfig, vm.envBool("FUND_EXPECT_STRATEGY_ACTIVE"));
        require(FundFactory(vm.envAddress("FUND_FACTORY")).owner() == vm.envAddress("FUND_FACTORY_OWNER"));
    }

    function _verifyAccessManager(
        AccessManager manager,
        address vault,
        address share,
        address accounting,
        address flow,
        address strategy,
        address adapter,
        address inKindEscrow,
        address emergencyEscrow
    ) private view {
        _verifyMember(manager, manager.ADMIN_ROLE(), vm.envAddress("FUND_ADMIN"), FundConstants.CORE_UPGRADE_DELAY);
        _verifyMember(
            manager, FundConstants.UPGRADER_ROLE, vm.envAddress("FUND_UPGRADER"), FundConstants.CORE_UPGRADE_DELAY
        );
        _verifyMember(
            manager,
            FundConstants.ADAPTER_UPGRADER_ROLE,
            vm.envAddress("FUND_UPGRADER"),
            FundConstants.ADAPTER_UPGRADE_DELAY
        );
        _verifyMember(manager, FundConstants.ACCOUNTING_ROLE, vm.envAddress("FUND_ACCOUNTING_OPERATOR"), 0);
        _verifyMember(manager, FundConstants.ALLOCATOR_ROLE, vm.envAddress("FUND_ALLOCATOR"), 0);
        _verifyMember(manager, FundConstants.PROCESSOR_ROLE, vm.envAddress("FUND_PROCESSOR"), 0);
        _verifyMember(manager, FundConstants.CURATOR_ROLE, vm.envAddress("FUND_CURATOR"), FundConstants.CURATOR_DELAY);
        _verifyMember(manager, FundConstants.GUARDIAN_ROLE, vm.envAddress("FUND_GUARDIAN"), 0);

        require(
            manager.getRoleGrantDelay(manager.ADMIN_ROLE()) == FundConstants.CORE_UPGRADE_DELAY,
            "B1N352: admin grant delay"
        );
        require(
            manager.getRoleGrantDelay(FundConstants.UPGRADER_ROLE) == FundConstants.CORE_UPGRADE_DELAY,
            "B1N352: upgrader grant delay"
        );
        require(
            manager.getRoleGrantDelay(FundConstants.ADAPTER_UPGRADER_ROLE) == FundConstants.ADAPTER_UPGRADE_DELAY,
            "B1N352: adapter grant delay"
        );
        require(
            manager.getRoleGrantDelay(FundConstants.CURATOR_ROLE) == FundConstants.CURATOR_DELAY,
            "B1N352: curator grant delay"
        );
        require(
            manager.getRoleGuardian(FundConstants.CURATOR_ROLE) == FundConstants.GUARDIAN_ROLE,
            "B1N352: curator guardian"
        );

        _verifyRules(manager, vault, FundAccessPolicy.vaultRules());
        _verifyRules(manager, share, FundAccessPolicy.shareRules());
        _verifyRules(manager, accounting, FundAccessPolicy.accountingRules());
        _verifyTargetRole(manager, accounting, FundAccounting.setComponentState.selector, FundConstants.CURATOR_ROLE);
        _verifyRules(manager, flow, FundAccessPolicy.flowRules());
        _verifyRules(manager, strategy, FundAccessPolicy.strategyRules());
        _verifyRules(manager, adapter, FundAccessPolicy.cspAdapterRules());
        _verifyRules(manager, inKindEscrow, FundAccessPolicy.strategyAssetEscrowRules());
        _verifyRules(manager, emergencyEscrow, FundAccessPolicy.strategyAssetEscrowRules());

        _verifyTargetAdminDelay(manager, vault);
        _verifyTargetAdminDelay(manager, share);
        _verifyTargetAdminDelay(manager, accounting);
        _verifyTargetAdminDelay(manager, flow);
        _verifyTargetAdminDelay(manager, strategy);
        _verifyTargetAdminDelay(manager, adapter);
        _verifyTargetAdminDelay(manager, inKindEscrow);
        _verifyTargetAdminDelay(manager, emergencyEscrow);
    }

    function _verifyMember(AccessManager manager, uint64 role, address account, uint32 expectedDelay) private view {
        (bool member, uint32 actualDelay) = manager.hasRole(role, account);
        require(member && actualDelay == expectedDelay, "B1N352: role member");
    }

    function _verifyRules(AccessManager manager, address target, FundAccessPolicy.Rule[] memory rules) private view {
        for (uint256 i; i < rules.length; ++i) {
            _verifyTargetRole(manager, target, rules[i].selector, rules[i].role);
        }
    }

    function _verifyTargetRole(AccessManager manager, address target, bytes4 selector, uint64 expectedRole)
        private
        view
    {
        require(manager.getTargetFunctionRole(target, selector) == expectedRole, "B1N352: target role");
    }

    function _verifyTargetAdminDelay(AccessManager manager, address target) private view {
        require(manager.getTargetAdminDelay(target) == FundConstants.CORE_UPGRADE_DELAY, "B1N352: target admin delay");
    }

    function _verifyProxy(string memory implementationEnv, address proxy) private view {
        address expectedImplementation = vm.envAddress(implementationEnv);
        require(proxy.code.length != 0, "B1N352: proxy code");
        require(_implementationOf(proxy) == expectedImplementation, "B1N352: proxy implementation");
        require(expectedImplementation.code.length != 0, "B1N352: implementation code");
    }
}
