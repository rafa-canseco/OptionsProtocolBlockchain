// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WheelTypes} from "../WheelTypes.sol";
import {IWheelCoordinatorManagedActions} from "../interfaces/IWheelCoordinatorManagedActions.sol";

/// @notice Closed dispatcher kept outside the coordinator runtime for EIP-170 headroom.
library WheelManagedOperationDispatcher {
    error InvalidManagedOperation(uint8 operationClass, WheelTypes.ManagedOperation operation);

    function dispatch(uint8 rawClass, bytes calldata data) external returns (bytes memory result) {
        WheelTypes.ManagedOperationClass operationClass = WheelTypes.ManagedOperationClass(rawClass);
        (WheelTypes.ManagedOperation operation, bytes memory arguments) =
            abi.decode(data, (WheelTypes.ManagedOperation, bytes));
        IWheelCoordinatorManagedActions coordinator = IWheelCoordinatorManagedActions(address(this));

        if (operationClass == WheelTypes.ManagedOperationClass.Allocation) {
            if (operation == WheelTypes.ManagedOperation.OpenCsp) {
                (uint256 trancheId, address lane, bytes memory openData) =
                    abi.decode(arguments, (uint256, address, bytes));
                coordinator.openCspTranche(trancheId, lane, openData);
            } else if (operation == WheelTypes.ManagedOperation.OpenCoveredCall) {
                (uint256 trancheId, address lane, bytes memory openData) =
                    abi.decode(arguments, (uint256, address, bytes));
                coordinator.openCoveredCallTranche(trancheId, lane, openData);
            } else if (operation == WheelTypes.ManagedOperation.SplitPendingCsp) {
                (uint256 trancheId, uint256 amount) = abi.decode(arguments, (uint256, uint256));
                result = abi.encode(coordinator.splitPendingCspTranche(trancheId, amount));
            } else {
                revert InvalidManagedOperation(rawClass, operation);
            }
        } else if (operationClass == WheelTypes.ManagedOperationClass.Processing) {
            if (operation == WheelTypes.ManagedOperation.SettleCsp) {
                coordinator.settleCspTranche(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.HandoffCsp) {
                result = abi.encode(coordinator.handoffCspTranche(abi.decode(arguments, (uint256))));
            } else if (operation == WheelTypes.ManagedOperation.SettleCoveredCall) {
                coordinator.settleCoveredCallTranche(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.HandoffCoveredCall) {
                coordinator.handoffCoveredCallTranche(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.ReserveRedemption) {
                (uint256 trancheId, uint256 amount) = abi.decode(arguments, (uint256, uint256));
                coordinator.reserveRedemptionUsdc(trancheId, amount);
            } else if (operation == WheelTypes.ManagedOperation.ReleaseRedemption) {
                result = abi.encode(coordinator.releaseRedemptionUsdc(abi.decode(arguments, (uint256))));
            } else {
                revert InvalidManagedOperation(rawClass, operation);
            }
        } else if (operationClass == WheelTypes.ManagedOperationClass.Guardian) {
            if (operation != WheelTypes.ManagedOperation.PauseAllocations) {
                revert InvalidManagedOperation(rawClass, operation);
            }
            coordinator.pauseAllocations();
        } else if (operationClass == WheelTypes.ManagedOperationClass.Configuration) {
            if (operation == WheelTypes.ManagedOperation.RegisterLane) {
                (address lane, WheelTypes.LaneKind kind) = abi.decode(arguments, (address, WheelTypes.LaneKind));
                coordinator.registerLane(lane, kind);
            } else if (operation == WheelTypes.ManagedOperation.RemoveLane) {
                coordinator.removeLane(abi.decode(arguments, (address)));
            } else if (operation == WheelTypes.ManagedOperation.SetLaneActive) {
                (address lane, bool active) = abi.decode(arguments, (address, bool));
                coordinator.setLaneActive(lane, active);
            } else if (operation == WheelTypes.ManagedOperation.SetPolicyHash) {
                coordinator.setPolicyHash(abi.decode(arguments, (bytes32)));
            } else if (operation == WheelTypes.ManagedOperation.SetFloorBuffer) {
                coordinator.setFloorBufferUsd8(abi.decode(arguments, (uint256)));
            } else if (operation == WheelTypes.ManagedOperation.ResumeAllocations) {
                coordinator.resumeAllocations();
            } else {
                revert InvalidManagedOperation(rawClass, operation);
            }
        } else {
            revert InvalidManagedOperation(rawClass, operation);
        }
    }
}
