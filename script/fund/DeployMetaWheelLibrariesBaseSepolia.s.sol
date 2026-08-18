// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

/// @notice Isolated prephase for the five external libraries required by the final Meta Wheel ABI.
/// @dev `run()` is intentionally disabled. The shell orchestrator invokes `deployLibraries()` explicitly and
///      decides whether Foundry only simulates or broadcasts the five CREATE transactions.
contract DeployMetaWheelLibrariesBaseSepolia is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 internal constant LIBRARY_COUNT = 5;

    error UseExplicitLibraryDeploymentEntryPoint();

    event MetaWheelLibraryDeployed(uint256 indexed index, string artifact, address libraryAddress, bytes32 codehash);

    function run() external pure {
        revert UseExplicitLibraryDeploymentEntryPoint();
    }

    function deployLibraries() external returns (address[5] memory libraries, bytes32[5] memory codehashes) {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "B1N419: wrong library chain");
        address broadcaster = vm.envAddress("B1N419_LIBRARY_BROADCASTER");
        require(broadcaster != address(0), "B1N419: zero library broadcaster");
        string memory sourceCommit = vm.envString("B1N419_LIBRARY_SOURCE_COMMIT");
        require(bytes(sourceCommit).length == 40, "B1N419: full source commit");

        string[5] memory artifacts = _artifacts();
        vm.startBroadcast(broadcaster);
        for (uint256 i; i < LIBRARY_COUNT; ++i) {
            libraries[i] = _deploy(vm.getCode(artifacts[i]));
            codehashes[i] = libraries[i].codehash;
            emit MetaWheelLibraryDeployed(i, artifacts[i], libraries[i], codehashes[i]);
        }
        vm.stopBroadcast();

        _writeDraft(sourceCommit, broadcaster, artifacts, libraries, codehashes);
    }

    function _deploy(bytes memory creationCode) private returns (address deployed) {
        require(creationCode.length != 0, "B1N419: empty library creation code");
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "B1N419: library deployment failed");
    }

    function _writeDraft(
        string memory sourceCommit,
        address broadcaster,
        string[5] memory artifacts,
        address[5] memory libraries,
        bytes32[5] memory codehashes
    ) private {
        string memory object = "b1n419LibraryPrephaseDraft";
        string memory json = vm.serializeString(object, "schemaVersion", "1.0.0");
        vm.serializeString(object, "issue", "B1N-419");
        vm.serializeString(object, "status", "SIMULATED_UNCONFIRMED");
        vm.serializeString(object, "sourceCommit", sourceCommit);
        vm.serializeUint(object, "chainId", BASE_SEPOLIA_CHAIN_ID);
        vm.serializeAddress(object, "broadcaster", broadcaster);
        vm.serializeString(object, "orderedArtifacts", _dynamic(artifacts));
        vm.serializeAddress(object, "linkedLibraries", _dynamic(libraries));
        json = vm.serializeBytes32(object, "linkedLibraryCodehashes", _dynamic(codehashes));
        vm.writeJson(json, vm.envString("B1N419_LIBRARY_DRAFT_PATH"));
    }

    function _artifacts() private pure returns (string[5] memory artifacts) {
        artifacts[0] = "src/fund/libraries/CspFundAdapterOperations.sol:CspFundAdapterOperations";
        artifacts[1] = "src/fund/libraries/CoveredCallFundAdapterOperations.sol:CoveredCallFundAdapterOperations";
        artifacts[2] = "src/fund/libraries/ManagedStrategyOperations.sol:ManagedStrategyOperations";
        artifacts[3] = "src/fund/libraries/WheelManagedOperationDispatcher.sol:WheelManagedOperationDispatcher";
        artifacts[4] = "src/fund/libraries/WheelCoordinatorPositionOperations.sol:WheelCoordinatorPositionOperations";
    }

    function _dynamic(string[5] memory fixedValues) private pure returns (string[] memory values) {
        values = new string[](LIBRARY_COUNT);
        for (uint256 i; i < LIBRARY_COUNT; ++i) {
            values[i] = fixedValues[i];
        }
    }

    function _dynamic(address[5] memory fixedValues) private pure returns (address[] memory values) {
        values = new address[](LIBRARY_COUNT);
        for (uint256 i; i < LIBRARY_COUNT; ++i) {
            values[i] = fixedValues[i];
        }
    }

    function _dynamic(bytes32[5] memory fixedValues) private pure returns (bytes32[] memory values) {
        values = new bytes32[](LIBRARY_COUNT);
        for (uint256 i; i < LIBRARY_COUNT; ++i) {
            values[i] = fixedValues[i];
        }
    }
}
