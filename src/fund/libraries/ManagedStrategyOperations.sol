// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";
import {StrategyManagerStorage} from "../storage/StrategyManagerStorage.sol";
import {IFundStrategyAdapter} from "../interfaces/IFundStrategyAdapter.sol";
import {IManagedStrategyAdapter} from "../interfaces/IManagedStrategyAdapter.sol";
import {IFundVault} from "../interfaces/IFundVault.sol";
import {IFundVaultModuleCallbacks, IFundAccountingModuleCallbacks} from "../interfaces/IFundModuleCallbacks.sol";

interface IManagedFundVault is IFundVault, IFundVaultModuleCallbacks {
    function flowManager() external view returns (address);
    function accounting() external view returns (address);
}

interface IManagedFlowState {
    function hasActiveProcessing() external view returns (bool);
}

/// @notice Linked lock/NAV/synchronization envelope for classified adapter operations.
library ManagedStrategyOperations {
    error AdapterNotActive(address adapter);
    error AllocationCapExceeded(address adapter);

    event StrategyManagedOperationExecuted(address indexed adapter, uint8 indexed operationClass, uint64 positionNonce);

    function executeActive(
        StrategyManagerStorage.StrategyManagerStorageLayout storage $,
        address adapter,
        uint8 operationClass,
        bytes calldata data
    ) public {
        _execute($, adapter, operationClass, data, true);
    }

    function execute(
        StrategyManagerStorage.StrategyManagerStorageLayout storage $,
        address adapter,
        uint8 operationClass,
        bytes calldata data
    ) public {
        _execute($, adapter, operationClass, data, false);
    }

    function _execute(
        StrategyManagerStorage.StrategyManagerStorageLayout storage $,
        address adapter,
        uint8 operationClass,
        bytes calldata data,
        bool requireActive
    ) private {
        FundTypes.StrategyConfig storage config = $.strategies[adapter];
        if (config.interfaceVersion == 0 || (requireActive && !config.active)) revert AdapterNotActive(adapter);
        IManagedFundVault vault = IManagedFundVault($.fund);
        if (requireActive && IManagedFlowState(vault.flowManager()).hasActiveProcessing()) {
            revert AllocationCapExceeded(adapter);
        }

        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.invalidateNav();
        IManagedStrategyAdapter(adapter).executeManagedOperation(operationClass, data);
        uint64 nonce = ++$.positionNonces[adapter];
        bytes32 stateHash = IFundStrategyAdapter(adapter).positionStateHash();
        $.positionsHash = keccak256(abi.encode($.positionsHash, adapter, nonce, stateHash));
        vault.recordStrategyPositions($.positionsHash);
        IFundAccountingModuleCallbacks(vault.accounting()).syncStrategyComponent(adapter, nonce, stateHash);
        vault.endModuleExecution(lockId);
        emit StrategyManagedOperationExecuted(adapter, operationClass, nonce);
    }
}
