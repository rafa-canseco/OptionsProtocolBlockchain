// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundAccounting} from "../interfaces/IFundAccounting.sol";
import {IFundFlowManager} from "../interfaces/IFundFlowManager.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";
import {ICspFundAdapter} from "../interfaces/ICspFundAdapter.sol";
import {IStrategyAssetEscrow} from "../interfaces/IStrategyAssetEscrow.sol";
import {FundConstants} from "../FundConstants.sol";

library FundAccessPolicy {
    bytes4 internal constant UPGRADE_TO_AND_CALL_SELECTOR = bytes4(keccak256("upgradeToAndCall(address,bytes)"));

    struct Rule {
        bytes4 selector;
        uint64 role;
        uint32 executionDelay;
    }

    function vaultRules() internal pure returns (Rule[] memory rules) {
        rules = new Rule[](5);
        rules[0] = Rule(UPGRADE_TO_AND_CALL_SELECTOR, FundConstants.UPGRADER_ROLE, FundConstants.CORE_UPGRADE_DELAY);
        rules[1] = Rule(IFundVault.pauseDeposits.selector, FundConstants.GUARDIAN_ROLE, 0);
        rules[2] = Rule(IFundVault.pauseRedemptions.selector, FundConstants.GUARDIAN_ROLE, 0);
        rules[3] = Rule(IFundVault.resumeDeposits.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        rules[4] = Rule(IFundVault.resumeRedemptions.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
    }

    function shareRules() internal pure returns (Rule[] memory rules) {
        rules = new Rule[](1);
        rules[0] = Rule(UPGRADE_TO_AND_CALL_SELECTOR, FundConstants.UPGRADER_ROLE, FundConstants.CORE_UPGRADE_DELAY);
    }

    function accountingRules() internal pure returns (Rule[] memory rules) {
        rules = new Rule[](5);
        rules[0] = Rule(UPGRADE_TO_AND_CALL_SELECTOR, FundConstants.UPGRADER_ROLE, FundConstants.CORE_UPGRADE_DELAY);
        rules[1] = Rule(IFundAccounting.submitNav.selector, FundConstants.ACCOUNTING_ROLE, 0);
        rules[2] =
            Rule(IFundAccounting.setReporterSet.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        rules[3] = Rule(IFundAccounting.setComponent.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        rules[4] = Rule(IFundAccounting.setFeeConfig.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
    }

    function flowRules() internal pure returns (Rule[] memory rules) {
        rules = new Rule[](8);
        rules[0] = Rule(UPGRADE_TO_AND_CALL_SELECTOR, FundConstants.UPGRADER_ROLE, FundConstants.CORE_UPGRADE_DELAY);
        rules[1] = Rule(IFundFlowManager.sealRedeemBatch.selector, FundConstants.PROCESSOR_ROLE, 0);
        rules[2] = Rule(IFundFlowManager.releaseRedeemBatch.selector, FundConstants.PROCESSOR_ROLE, 0);
        rules[3] = Rule(IFundFlowManager.startRedeemBatch.selector, FundConstants.PROCESSOR_ROLE, 0);
        rules[4] = Rule(IFundFlowManager.processRedeemBatch.selector, FundConstants.PROCESSOR_ROLE, 0);
        rules[5] =
            Rule(IFundFlowManager.setExitPolicy.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        rules[6] = Rule(
            IFundFlowManager.setStrategyExitEscrows.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
        rules[7] = Rule(
            IFundFlowManager.authorizeStrategyInKindBatch.selector,
            FundConstants.CURATOR_ROLE,
            FundConstants.CURATOR_DELAY
        );
    }

    function strategyRules() internal pure returns (Rule[] memory rules) {
        rules = new Rule[](10);
        rules[0] = Rule(UPGRADE_TO_AND_CALL_SELECTOR, FundConstants.UPGRADER_ROLE, FundConstants.CORE_UPGRADE_DELAY);
        rules[1] = Rule(IStrategyManager.allocate.selector, FundConstants.ALLOCATOR_ROLE, 0);
        rules[2] = Rule(IStrategyManager.deallocate.selector, FundConstants.ALLOCATOR_ROLE, 0);
        rules[3] =
            Rule(IStrategyManager.setStrategyConfig.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        rules[4] =
            Rule(IStrategyManager.setMinimumIdleBps.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        rules[5] = Rule(IStrategyManager.reduceStrategyCap.selector, FundConstants.GUARDIAN_ROLE, 0);
        rules[6] = Rule(IStrategyManager.pauseAllocation.selector, FundConstants.GUARDIAN_ROLE, 0);
        rules[7] =
            Rule(IStrategyManager.resumeAllocation.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        rules[8] = Rule(IStrategyManager.deallocateInKind.selector, FundConstants.PROCESSOR_ROLE, 0);
        rules[9] = Rule(IStrategyManager.emergencyExit.selector, FundConstants.GUARDIAN_ROLE, 0);
    }

    function cspAdapterRules() internal pure returns (Rule[] memory rules) {
        rules = new Rule[](2);
        rules[0] = Rule(
            UPGRADE_TO_AND_CALL_SELECTOR, FundConstants.ADAPTER_UPGRADER_ROLE, FundConstants.ADAPTER_UPGRADE_DELAY
        );
        rules[1] =
            Rule(ICspFundAdapter.setAdapterConfig.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
    }

    function strategyAssetEscrowRules() internal pure returns (Rule[] memory rules) {
        rules = new Rule[](1);
        rules[0] =
            Rule(IStrategyAssetEscrow.releaseToFund.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
    }
}
