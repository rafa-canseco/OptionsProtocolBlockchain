// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

interface IStrategyManager {
    error AdapterNotActive(address adapter);
    error AllocationCapExceeded(address adapter);
    error InvalidAdapterVersion(uint64 expected, uint64 actual);
    error MinimumIdleViolation();
    error StaleAllocationResume(address adapter, uint64 expectedPauseNonce, uint64 actualPauseNonce);

    function fund() external view returns (address);
    function compatibilityVersion() external view returns (uint64);
    function positionsHash() external view returns (bytes32);
    function minimumIdleBps() external view returns (uint16);
    function strategyConfig(address adapter) external view returns (FundTypes.StrategyConfig memory);
    function allocationPauseNonce(address adapter) external view returns (uint64);

    function allocate(address adapter, address asset, uint256 amount, bytes calldata data) external;
    function deallocate(address adapter, uint256 targetValue, uint256 minAssetsOut, bytes calldata data)
        external
        returns (uint256 assetsOut);
    function deallocateInKind(bytes32 batchId, address adapter, uint256 fractionWad, bytes calldata data)
        external
        returns (address[] memory assets, uint256[] memory amounts);
    function emergencyExit(address adapter, bytes calldata data)
        external
        returns (address[] memory assets, uint256[] memory amounts);
    function setStrategyConfig(address adapter, FundTypes.StrategyConfig calldata config) external;
    function reduceStrategyCap(address adapter, uint256 absoluteCap, uint16 maxAllocationBps) external;
    function setMinimumIdleBps(uint16 newMinimumIdleBps) external;
    function pauseAllocation(address adapter) external;
    function resumeAllocation(address adapter, uint64 expectedPauseNonce) external;
}
