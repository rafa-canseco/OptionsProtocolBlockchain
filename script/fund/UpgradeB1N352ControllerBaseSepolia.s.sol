// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {Controller} from "../../src/core/Controller.sol";

interface IProxiableControllerImplementation {
    function proxiableUUID() external view returns (bytes32);
}

/// @notice Shared approved-input and state checks for the B1N-352 Base Sepolia Controller upgrade.
abstract contract B1N352ControllerUpgradeBase is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant APPROVED_STATUS = keccak256("APPROVED_FOR_BASE_SEPOLIA_VALIDATION");

    struct UpgradeConfig {
        address proxy;
        address previousImplementation;
        bytes32 previousImplementationCodehash;
        address candidateImplementation;
        bytes32 candidateImplementationCodehash;
        address owner;
        address pendingOwner;
        address addressBook;
        address partialPauser;
        bool systemPartiallyPaused;
        bool systemFullyPaused;
    }

    struct ControllerSnapshot {
        address owner;
        address pendingOwner;
        address addressBook;
        address partialPauser;
        bool systemPartiallyPaused;
        bool systemFullyPaused;
    }

    function _approvedInput() internal view returns (string memory json) {
        json = vm.readFile(vm.envString("B1N352_CONTROLLER_UPGRADE_INPUTS_PATH"));
        require(
            sha256(bytes(json)) == vm.envBytes32("B1N352_CONTROLLER_UPGRADE_INPUTS_SHA256"),
            "B1N352 controller: approved input digest"
        );
        require(
            keccak256(bytes(vm.parseJsonString(json, ".approval.status"))) == APPROVED_STATUS,
            "B1N352 controller: approval status"
        );
        require(vm.parseJsonUint(json, ".network.chainId") == BASE_SEPOLIA_CHAIN_ID, "B1N352 controller: input chain");
    }

    function _loadConfig() internal view returns (UpgradeConfig memory config) {
        string memory json = _approvedInput();
        config.proxy = vm.parseJsonAddress(json, ".baseline.proxy");
        config.previousImplementation = vm.parseJsonAddress(json, ".baseline.implementation");
        config.previousImplementationCodehash = vm.parseJsonBytes32(json, ".baseline.implementationCodehash");
        config.candidateImplementation = vm.parseJsonAddress(json, ".candidate.implementation");
        config.candidateImplementationCodehash = vm.parseJsonBytes32(json, ".candidate.implementationCodehash");
        config.owner = vm.parseJsonAddress(json, ".baseline.owner");
        config.pendingOwner = vm.parseJsonAddress(json, ".baseline.pendingOwner");
        config.addressBook = vm.parseJsonAddress(json, ".baseline.addressBook");
        config.partialPauser = vm.parseJsonAddress(json, ".baseline.partialPauser");
        config.systemPartiallyPaused = vm.parseJsonBool(json, ".baseline.systemPartiallyPaused");
        config.systemFullyPaused = vm.parseJsonBool(json, ".baseline.systemFullyPaused");
    }

    function _requireBaseSepolia() internal view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "B1N352 controller: wrong chain");
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _snapshot(Controller controller) internal view returns (ControllerSnapshot memory snapshot) {
        snapshot.owner = controller.owner();
        snapshot.pendingOwner = controller.pendingOwner();
        snapshot.addressBook = address(controller.addressBook());
        snapshot.partialPauser = controller.partialPauser();
        snapshot.systemPartiallyPaused = controller.systemPartiallyPaused();
        snapshot.systemFullyPaused = controller.systemFullyPaused();
    }

    function _requireSnapshot(ControllerSnapshot memory actual, ControllerSnapshot memory expected) internal pure {
        require(actual.owner == expected.owner, "B1N352 controller: owner changed");
        require(actual.pendingOwner == expected.pendingOwner, "B1N352 controller: pending owner changed");
        require(actual.addressBook == expected.addressBook, "B1N352 controller: address book changed");
        require(actual.partialPauser == expected.partialPauser, "B1N352 controller: partial pauser changed");
        require(
            actual.systemPartiallyPaused == expected.systemPartiallyPaused, "B1N352 controller: partial pause changed"
        );
        require(actual.systemFullyPaused == expected.systemFullyPaused, "B1N352 controller: full pause changed");
    }

    function _expectedSnapshot(UpgradeConfig memory config) internal pure returns (ControllerSnapshot memory snapshot) {
        snapshot = ControllerSnapshot({
            owner: config.owner,
            pendingOwner: config.pendingOwner,
            addressBook: config.addressBook,
            partialPauser: config.partialPauser,
            systemPartiallyPaused: config.systemPartiallyPaused,
            systemFullyPaused: config.systemFullyPaused
        });
    }

    function _requireCandidate(UpgradeConfig memory config) internal view {
        require(config.candidateImplementation != address(0), "B1N352 controller: candidate zero");
        require(
            config.candidateImplementation != config.previousImplementation, "B1N352 controller: candidate is previous"
        );
        require(config.candidateImplementation.code.length != 0, "B1N352 controller: candidate code");
        require(
            config.candidateImplementation.codehash == config.candidateImplementationCodehash,
            "B1N352 controller: candidate codehash"
        );
        require(
            IProxiableControllerImplementation(config.candidateImplementation).proxiableUUID()
                == ERC1967_IMPLEMENTATION_SLOT,
            "B1N352 controller: candidate UUID"
        );

        (bool success, bytes memory result) =
            config.candidateImplementation.staticcall(abi.encodeWithSignature("custodiedRedemptionOnly()"));
        require(success && result.length >= 32, "B1N352 controller: candidate custodial selector");
    }

    function _requireBefore(UpgradeConfig memory config) internal view returns (ControllerSnapshot memory snapshot) {
        require(config.proxy.code.length != 0, "B1N352 controller: proxy code");
        require(_implementationOf(config.proxy) == config.previousImplementation, "B1N352 controller: implementation");
        require(
            config.previousImplementation.codehash == config.previousImplementationCodehash,
            "B1N352 controller: implementation codehash"
        );
        Controller controller = Controller(config.proxy);
        snapshot = _snapshot(controller);
        _requireSnapshot(snapshot, _expectedSnapshot(config));
        require(AddressBook(config.addressBook).controller() == config.proxy, "B1N352 controller: address book wiring");

        (bool success,) = config.proxy.staticcall(abi.encodeWithSignature("custodiedRedemptionOnly()"));
        require(!success, "B1N352 controller: legacy selector unexpectedly present");
        _requireCandidate(config);
    }

    function _requireAfter(UpgradeConfig memory config, ControllerSnapshot memory beforeSnapshot) internal view {
        require(
            _implementationOf(config.proxy) == config.candidateImplementation,
            "B1N352 controller: candidate not installed"
        );
        require(Controller(config.proxy).custodiedRedemptionOnly(), "B1N352 controller: custodial mode disabled");
        _requireSnapshot(_snapshot(Controller(config.proxy)), beforeSnapshot);
        require(AddressBook(config.addressBook).controller() == config.proxy, "B1N352 controller: wiring changed");
    }

    function _logConfig(UpgradeConfig memory config) internal pure {
        console2.log("B1N352_CONTROLLER_PROXY", config.proxy);
        console2.log("B1N352_CONTROLLER_PREVIOUS_IMPLEMENTATION", config.previousImplementation);
        console2.log("B1N352_CONTROLLER_PREVIOUS_IMPLEMENTATION_CODEHASH");
        console2.logBytes32(config.previousImplementationCodehash);
        console2.log("B1N352_CONTROLLER_CANDIDATE_IMPLEMENTATION", config.candidateImplementation);
        console2.log("B1N352_CONTROLLER_CANDIDATE_IMPLEMENTATION_CODEHASH");
        console2.logBytes32(config.candidateImplementationCodehash);
        console2.log("B1N352_CONTROLLER_OWNER", config.owner);
        console2.log("B1N352_CONTROLLER_ADDRESS_BOOK", config.addressBook);
    }
}

/// @notice Installs the approved, already-verified Controller implementation and enables custodial redemption atomically.
contract UpgradeB1N352ControllerBaseSepolia is B1N352ControllerUpgradeBase {
    function run() external {
        _requireBaseSepolia();
        UpgradeConfig memory config = _loadConfig();
        ControllerSnapshot memory beforeSnapshot = _requireBefore(config);
        _logConfig(config);

        vm.startBroadcast();
        Controller(config.proxy)
            .upgradeToAndCall(
                config.candidateImplementation, abi.encodeCall(Controller.setCustodiedRedemptionOnly, (true))
            );
        vm.stopBroadcast();

        _requireAfter(config, beforeSnapshot);
        console2.log("B1N352_CONTROLLER_CUSTODIED_REDEMPTION_ONLY", true);
    }
}

/// @notice Read-only post-upgrade verification suitable for manifest and transaction-ledger reconciliation.
contract ReconcileB1N352ControllerBaseSepolia is B1N352ControllerUpgradeBase {
    function run() external view {
        _requireBaseSepolia();
        UpgradeConfig memory config = _loadConfig();
        ControllerSnapshot memory expected = _expectedSnapshot(config);
        _requireCandidate(config);
        _requireAfter(config, expected);
        _logConfig(config);
        console2.log("B1N352_CONTROLLER_CUSTODIED_REDEMPTION_ONLY", true);
    }
}

/// @notice Read-only rollback preparation. A rollback broadcast always requires a separate incident approval.
contract PrepareB1N352ControllerRollback is B1N352ControllerUpgradeBase {
    function run() external view {
        _requireBaseSepolia();
        UpgradeConfig memory config = _loadConfig();
        _requireAfter(config, _expectedSnapshot(config));

        console2.log("B1N352_CONTROLLER_ROLLBACK_TARGET", config.proxy);
        console2.log("B1N352_CONTROLLER_ROLLBACK_IMPLEMENTATION", config.previousImplementation);
        console2.log("B1N352_CONTROLLER_ROLLBACK_CALLDATA");
        console2.logBytes(
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", config.previousImplementation, bytes(""))
        );
    }
}
