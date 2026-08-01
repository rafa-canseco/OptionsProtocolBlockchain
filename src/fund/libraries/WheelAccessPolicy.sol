// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundConstants} from "../FundConstants.sol";
import {FundAccessPolicy} from "./FundAccessPolicy.sol";
import {WheelCoordinatorAdapter} from "../WheelCoordinatorAdapter.sol";
import {WheelCspChildLane} from "../WheelCspChildLane.sol";
import {WheelCoveredCallChildLane} from "../WheelCoveredCallChildLane.sol";

/// @notice Canonical AccessManager selector policy for fresh Meta Wheel contracts.
library WheelAccessPolicy {
    function coordinatorRules() internal pure returns (FundAccessPolicy.Rule[] memory rules) {
        rules = new FundAccessPolicy.Rule[](15);
        rules[0] = FundAccessPolicy.Rule(
            FundAccessPolicy.UPGRADE_TO_AND_CALL_SELECTOR,
            FundConstants.ADAPTER_UPGRADER_ROLE,
            FundConstants.ADAPTER_UPGRADE_DELAY
        );
        rules[1] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.registerLane.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
        rules[2] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.setLaneActive.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
        rules[3] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.setPolicyHash.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
        rules[4] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.setFloorBufferUsd8.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
        rules[5] =
            FundAccessPolicy.Rule(WheelCoordinatorAdapter.openCspTranche.selector, FundConstants.ALLOCATOR_ROLE, 0);
        rules[6] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.openCoveredCallTranche.selector, FundConstants.ALLOCATOR_ROLE, 0
        );
        rules[7] =
            FundAccessPolicy.Rule(WheelCoordinatorAdapter.settleCspTranche.selector, FundConstants.PROCESSOR_ROLE, 0);
        rules[8] =
            FundAccessPolicy.Rule(WheelCoordinatorAdapter.handoffCspTranche.selector, FundConstants.PROCESSOR_ROLE, 0);
        rules[9] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.settleCoveredCallTranche.selector, FundConstants.PROCESSOR_ROLE, 0
        );
        rules[10] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.handoffCoveredCallTranche.selector, FundConstants.PROCESSOR_ROLE, 0
        );
        rules[11] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.reserveRedemptionUsdc.selector, FundConstants.PROCESSOR_ROLE, 0
        );
        rules[12] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.releaseRedemptionUsdc.selector, FundConstants.PROCESSOR_ROLE, 0
        );
        rules[13] =
            FundAccessPolicy.Rule(WheelCoordinatorAdapter.pauseAllocations.selector, FundConstants.GUARDIAN_ROLE, 0);
        rules[14] = FundAccessPolicy.Rule(
            WheelCoordinatorAdapter.resumeAllocations.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
    }

    function cspLaneRules() internal pure returns (FundAccessPolicy.Rule[] memory rules) {
        rules = new FundAccessPolicy.Rule[](4);
        rules[0] = FundAccessPolicy.Rule(
            FundAccessPolicy.UPGRADE_TO_AND_CALL_SELECTOR,
            FundConstants.ADAPTER_UPGRADER_ROLE,
            FundConstants.ADAPTER_UPGRADE_DELAY
        );
        rules[1] = FundAccessPolicy.Rule(
            WheelCspChildLane.setMaxAssets.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
        rules[2] = FundAccessPolicy.Rule(WheelCspChildLane.pauseAllocations.selector, FundConstants.GUARDIAN_ROLE, 0);
        rules[3] = FundAccessPolicy.Rule(
            WheelCspChildLane.resumeAllocations.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
    }

    function coveredCallLaneRules() internal pure returns (FundAccessPolicy.Rule[] memory rules) {
        rules = new FundAccessPolicy.Rule[](5);
        rules[0] = FundAccessPolicy.Rule(
            FundAccessPolicy.UPGRADE_TO_AND_CALL_SELECTOR,
            FundConstants.ADAPTER_UPGRADER_ROLE,
            FundConstants.ADAPTER_UPGRADE_DELAY
        );
        rules[1] = FundAccessPolicy.Rule(
            WheelCoveredCallChildLane.setMaxAssets.selector, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY
        );
        rules[2] = FundAccessPolicy.Rule(
            WheelCoveredCallChildLane.setExecutionCostBuffer8.selector,
            FundConstants.CURATOR_ROLE,
            FundConstants.CURATOR_DELAY
        );
        rules[3] =
            FundAccessPolicy.Rule(WheelCoveredCallChildLane.pauseAllocations.selector, FundConstants.GUARDIAN_ROLE, 0);
        rules[4] = FundAccessPolicy.Rule(
            WheelCoveredCallChildLane.resumeAllocations.selector,
            FundConstants.CURATOR_ROLE,
            FundConstants.CURATOR_DELAY
        );
    }
}
