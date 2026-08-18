// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundVault} from "../../src/fund/FundVault.sol";
import {B1N352ZeroDelayFundFactory} from "../../src/fund/B1N352ZeroDelayFundFactory.sol";
import {B1N352DeploymentReconciler} from "./ReconcileB1N352Deployment.s.sol";

abstract contract B1N352V2DeploymentReconciler is B1N352DeploymentReconciler {
    function _reconcileV2(bool expectedOnboarded, bool expectedActive, bool expectedDepositsPaused) internal view {
        _reconcileWithDelays(expectedOnboarded, expectedActive, 0, 0, 0);
        require(
            FundVault(vm.envAddress("FUND_VAULT_PROXY")).depositsPaused() == expectedDepositsPaused,
            "B1N352V2: deposit pause state"
        );
        require(
            B1N352ZeroDelayFundFactory(vm.envAddress("FUND_FACTORY")).fundCreated(), "B1N352V2: factory creation state"
        );
    }
}

/// @notice Strict post-policy gate before mutating the isolated B1N-336 onboarding allowlist.
contract ReconcileB1N352V2Configured is B1N352V2DeploymentReconciler {
    function run() external view {
        _reconcileV2(false, false, true);
    }
}

/// @notice Strict post-onboarding gate before strategy activation.
contract ReconcileB1N352V2Onboarded is B1N352V2DeploymentReconciler {
    function run() external view {
        _reconcileV2(true, false, true);
    }
}

/// @notice Strict handoff-ready gate: zero delays, onboarded, active strategy, deposits still paused.
contract ReconcileB1N352V2Activated is B1N352V2DeploymentReconciler {
    function run() external view {
        _reconcileV2(true, true, true);
    }
}

/// @notice Final live-test gate after the explicit deposit opening transaction.
contract ReconcileB1N352V2Open is B1N352V2DeploymentReconciler {
    function run() external view {
        _reconcileV2(true, true, false);
    }
}
