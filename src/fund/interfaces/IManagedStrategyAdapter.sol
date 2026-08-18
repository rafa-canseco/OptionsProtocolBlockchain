// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IManagedStrategyAdapter {
    function executeManagedOperation(uint8 operationClass, bytes calldata data) external returns (bytes memory result);
}
