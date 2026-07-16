// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

interface IFundAccounting {
    error DuplicateComponent(bytes32 componentId);
    error IncompleteComponentSet();
    error InvalidPositionState(bytes32 componentId);
    error InvalidReporterSet(uint64 version);
    error InvalidSnapshotBlock(uint64 snapshotBlock);
    error StaleComponent(bytes32 componentId);

    function fund() external view returns (address);
    function compatibilityVersion() external view returns (uint64);
    function reporterSetVersion() external view returns (uint64);
    function componentNonce(bytes32 componentId) external view returns (uint64);
    function submitNav(
        FundTypes.ComponentReport[] calldata reports,
        address[] calldata reporters,
        bytes[] calldata signatures
    ) external returns (FundTypes.NavCommit memory nav);
    function setReporterSet(address[] calldata reporters, uint16 threshold, uint64 version) external;
    function setComponent(bytes32 componentId, address valuator, uint64 interfaceVersion, bool active) external;
    function setFeeConfig(FundTypes.FeeConfig calldata config) external;
}
