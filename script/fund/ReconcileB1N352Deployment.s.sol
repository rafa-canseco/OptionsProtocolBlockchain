// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {ClaimEscrow} from "../../src/fund/ClaimEscrow.sol";
import {NavReportVerifier} from "../../src/fund/NavReportVerifier.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";
import {B1N352Operations} from "./B1N352Operations.sol";

/// @notice Read-only state reconciliation for manifest finalization and post-configuration checks.
abstract contract B1N352DeploymentReconciler is B1N352Operations {
    function _reconcile(bool expectedOnboarded, bool expectedActive) internal view {
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
        FundAccessManager manager = FundAccessManager(vm.envAddress("FUND_ACCESS_MANAGER"));

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

        _verifyImmutableArtifacts(deployConfig, vault, accounting, flow, adapter, manager);

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

        require(adapter.isOnboarded() == expectedOnboarded, "B1N352: onboarded state");
        require(strategy.strategyConfig(address(adapter)).active == expectedActive, "B1N352: strategy active state");
        _verifyDeployedPolicy(deployConfig, policyConfig, expectedActive);
        _verifyFactoryDeployment(deployConfig, vault, share, accounting, flow, strategy, manager);
    }

    function _verifyImmutableArtifacts(
        DeployConfig memory deployConfig,
        FundVault vault,
        FundAccounting accounting,
        FundFlowManager flow,
        CspFundAdapter adapter,
        FundAccessManager manager
    ) private view {
        address navVerifier = vm.envAddress("FUND_NAV_REPORT_VERIFIER");
        require(navVerifier.code.length != 0, "B1N352: NAV verifier code");
        require(navVerifier.codehash == vm.envBytes32("FUND_NAV_REPORT_VERIFIER_CODEHASH"), "B1N352: NAV verifier hash");
        require(accounting.navVerifier() == navVerifier, "B1N352: NAV verifier");
        require(
            accounting.navVerifierVersion() == NavReportVerifier(navVerifier).interfaceVersion(),
            "B1N352: NAV verifier version"
        );

        address claimEscrow = vm.envAddress("FUND_CLAIM_ESCROW");
        require(claimEscrow.code.length != 0, "B1N352: claim escrow code");
        require(claimEscrow.codehash == vm.envBytes32("FUND_CLAIM_ESCROW_CODEHASH"), "B1N352: claim escrow hash");
        require(vault.claimEscrow() == claimEscrow, "B1N352: vault claim escrow");
        require(flow.claimEscrow() == claimEscrow, "B1N352: flow claim escrow");
        require(address(ClaimEscrow(claimEscrow).ASSET()) == deployConfig.accountingAsset, "B1N352: claim asset");
        require(ClaimEscrow(claimEscrow).FUND_VAULT() == address(vault), "B1N352: claim fund");

        address operations = vm.envAddress("FUND_CSP_ADAPTER_OPERATIONS");
        require(operations.code.length != 0, "B1N352: adapter operations code");
        require(
            operations.codehash == vm.envBytes32("FUND_CSP_ADAPTER_OPERATIONS_CODEHASH"),
            "B1N352: adapter operations hash"
        );
        require(
            _codeContainsAddress(_implementationOf(address(adapter)), operations), "B1N352: adapter operations binding"
        );
        require(
            address(manager).codehash == vm.envBytes32("FUND_ACCESS_MANAGER_CODEHASH"), "B1N352: access manager hash"
        );
    }

    function _verifyFactoryDeployment(
        DeployConfig memory deployConfig,
        FundVault vault,
        FundShare share,
        FundAccounting accounting,
        FundFlowManager flow,
        StrategyManager strategy,
        FundAccessManager manager
    ) private view {
        FundFactory factory = FundFactory(vm.envAddress("FUND_FACTORY"));
        require(factory.owner() == deployConfig.factoryOwner, "B1N352: factory owner");
        address managerDeployer = vm.envAddress("FUND_ACCESS_MANAGER_DEPLOYER");
        require(address(factory.accessManagerDeployer()) == managerDeployer, "B1N352: manager deployer binding");
        require(managerDeployer.code.length != 0, "B1N352: manager deployer code");
        require(
            managerDeployer.codehash == vm.envBytes32("FUND_ACCESS_MANAGER_DEPLOYER_CODEHASH"),
            "B1N352: manager deployer hash"
        );
        FundFactory.FundDeployment memory deployed = factory.deployment(vm.envBytes32("FUND_DEPLOYMENT_ID"));
        require(deployed.vault == address(vault), "B1N352: factory vault");
        require(deployed.share == address(share), "B1N352: factory share");
        require(deployed.accounting == address(accounting), "B1N352: factory accounting");
        require(deployed.navVerifier == vm.envAddress("FUND_NAV_REPORT_VERIFIER"), "B1N352: factory verifier");
        require(deployed.flowManager == address(flow), "B1N352: factory flow");
        require(deployed.strategyManager == address(strategy), "B1N352: factory strategy");
        require(deployed.claimEscrow == vm.envAddress("FUND_CLAIM_ESCROW"), "B1N352: factory claim escrow");
        require(deployed.accessManager == address(manager), "B1N352: factory access manager");
        require(deployed.implementationVersion == deployConfig.implementationVersion, "B1N352: factory version");
    }

    function _verifyAccessManager(
        FundAccessManager manager,
        address vault,
        address share,
        address accounting,
        address flow,
        address strategy,
        address adapter,
        address inKindEscrow,
        address emergencyEscrow
    ) private view {
        _verifyRole(
            manager,
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            FundConstants.CORE_UPGRADE_DELAY,
            vm.envAddress("FUND_ADMIN"),
            FundConstants.CORE_UPGRADE_DELAY,
            1
        );
        _verifyRole(
            manager,
            FundConstants.UPGRADER_ROLE,
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            FundConstants.CORE_UPGRADE_DELAY,
            vm.envAddress("FUND_UPGRADER"),
            FundConstants.CORE_UPGRADE_DELAY,
            1
        );
        _verifyRole(
            manager,
            FundConstants.ACCOUNTING_ROLE,
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            0,
            vm.envAddress("FUND_ACCOUNTING_OPERATOR"),
            0,
            1
        );
        _verifyRole(
            manager,
            FundConstants.ALLOCATOR_ROLE,
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            0,
            vm.envAddress("FUND_ALLOCATOR"),
            0,
            1
        );
        _verifyRole(
            manager,
            FundConstants.PROCESSOR_ROLE,
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            0,
            vm.envAddress("FUND_PROCESSOR"),
            0,
            1
        );
        _verifyRole(
            manager,
            FundConstants.CURATOR_ROLE,
            manager.ADMIN_ROLE(),
            FundConstants.GUARDIAN_ROLE,
            FundConstants.CURATOR_DELAY,
            vm.envAddress("FUND_CURATOR"),
            FundConstants.CURATOR_DELAY,
            1
        );
        _verifyRole(
            manager,
            FundConstants.GUARDIAN_ROLE,
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            0,
            vm.envAddress("FUND_GUARDIAN"),
            0,
            1
        );
        _verifyRole(
            manager, FundConstants.REPORTER_ROLE, manager.ADMIN_ROLE(), manager.ADMIN_ROLE(), 0, address(0), 0, 0
        );
        _verifyRole(
            manager,
            FundConstants.ADAPTER_UPGRADER_ROLE,
            manager.ADMIN_ROLE(),
            manager.ADMIN_ROLE(),
            FundConstants.ADAPTER_UPGRADE_DELAY,
            vm.envAddress("FUND_UPGRADER"),
            FundConstants.ADAPTER_UPGRADE_DELAY,
            1
        );
        require(!manager.isTargetClosed(address(manager)), "B1N352: manager closed");

        _verifyRules(manager, vault, FundAccessPolicy.vaultRules(), 0);
        _verifyRules(manager, share, FundAccessPolicy.shareRules(), 0);
        _verifyRules(manager, accounting, FundAccessPolicy.accountingRules(), 1);
        _verifyTargetRole(manager, accounting, FundAccounting.setComponentState.selector, FundConstants.CURATOR_ROLE);
        _verifyRules(manager, flow, FundAccessPolicy.flowRules(), 0);
        _verifyRules(manager, strategy, FundAccessPolicy.strategyRules(), 0);
        _verifyRules(manager, adapter, FundAccessPolicy.cspAdapterRules(), 0);
        _verifyRules(manager, inKindEscrow, FundAccessPolicy.strategyAssetEscrowRules(), 0);
        _verifyRules(manager, emergencyEscrow, FundAccessPolicy.strategyAssetEscrowRules(), 0);

        _verifyTargetAdminDelay(manager, vault);
        _verifyTargetAdminDelay(manager, share);
        _verifyTargetAdminDelay(manager, accounting);
        _verifyTargetAdminDelay(manager, flow);
        _verifyTargetAdminDelay(manager, strategy);
        _verifyTargetAdminDelay(manager, adapter);
        _verifyTargetAdminDelay(manager, inKindEscrow);
        _verifyTargetAdminDelay(manager, emergencyEscrow);
    }

    function _verifyRole(
        FundAccessManager manager,
        uint64 role,
        uint64 expectedAdmin,
        uint64 expectedGuardian,
        uint32 expectedGrantDelay,
        address expectedMember,
        uint32 expectedMemberDelay,
        uint256 expectedMemberCount
    ) private view {
        require(manager.getRoleAdmin(role) == expectedAdmin, "B1N352: role admin");
        require(manager.getRoleGuardian(role) == expectedGuardian, "B1N352: role guardian");
        (uint32 grantDelay, uint32 pendingGrantDelay, uint48 grantDelayEffect) = manager.getRoleGrantDelayFull(role);
        require(grantDelay == expectedGrantDelay, "B1N352: role grant delay");
        require(pendingGrantDelay == 0 && grantDelayEffect == 0, "B1N352: pending role grant delay");
        require(manager.roleMemberCount(role) == expectedMemberCount, "B1N352: role member count");
        if (expectedMemberCount == 0) return;
        require(manager.roleMemberAt(role, 0) == expectedMember, "B1N352: unexpected role member");
        (uint48 since, uint32 currentDelay, uint32 pendingDelay, uint48 effect) =
            manager.getAccess(role, expectedMember);
        require(since != 0 && since <= block.timestamp, "B1N352: inactive role member");
        require(currentDelay == expectedMemberDelay, "B1N352: role member delay");
        require(pendingDelay == 0 && effect == 0, "B1N352: pending member delay");
    }

    function _verifyRules(
        FundAccessManager manager,
        address target,
        FundAccessPolicy.Rule[] memory rules,
        uint256 additionalSelectors
    ) private view {
        require(!manager.isTargetClosed(target), "B1N352: target closed");
        require(
            manager.configuredSelectorCount(target) == rules.length + additionalSelectors,
            "B1N352: target selector count"
        );
        for (uint256 i; i < rules.length; ++i) {
            _verifyTargetRole(manager, target, rules[i].selector, rules[i].role);
        }
    }

    function _verifyTargetRole(FundAccessManager manager, address target, bytes4 selector, uint64 expectedRole)
        private
        view
    {
        require(manager.getTargetFunctionRole(target, selector) == expectedRole, "B1N352: target role");
    }

    function _verifyTargetAdminDelay(FundAccessManager manager, address target) private view {
        (uint32 currentDelay, uint32 pendingDelay, uint48 effect) = manager.getTargetAdminDelayFull(target);
        require(currentDelay == FundConstants.CORE_UPGRADE_DELAY, "B1N352: target admin delay");
        require(pendingDelay == 0 && effect == 0, "B1N352: pending target admin delay");
    }

    function _verifyProxy(string memory implementationEnv, address proxy) private view {
        address expectedImplementation = vm.envAddress(implementationEnv);
        require(proxy.code.length != 0, "B1N352: proxy code");
        require(_implementationOf(proxy) == expectedImplementation, "B1N352: proxy implementation");
        require(expectedImplementation.code.length != 0, "B1N352: implementation code");
    }

    function _codeContainsAddress(address target, address expectedAddress) private view returns (bool) {
        bytes memory code = target.code;
        bytes20 expected = bytes20(expectedAddress);
        if (code.length < 20) return false;
        for (uint256 i; i <= code.length - 20; ++i) {
            bool matches = true;
            for (uint256 j; j < 20; ++j) {
                if (code[i + j] != expected[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }
}

/// @notice Final reconciliation. It cannot be configured to accept skipped onboarding or activation.
contract ReconcileB1N352Deployment is B1N352DeploymentReconciler {
    function run() external view {
        _reconcile(true, true);
    }
}

/// @notice Explicit inspection command for approved intermediate states before final activation.
contract ReconcileB1N352IntermediateDeployment is B1N352DeploymentReconciler {
    function run() external view {
        _reconcile(vm.envBool("FUND_EXPECT_ADAPTER_ONBOARDED"), vm.envBool("FUND_EXPECT_STRATEGY_ACTIVE"));
    }
}
