// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {DeployMetaWheelBaseSepolia} from "./DeployMetaWheelBaseSepolia.s.sol";

/// @notice Atomically replaces bootstrap authority with the final separated role accounts.
/// @dev Run before configuration, child onboarding or any activation phase.
contract RotateMetaWheelRolesBaseSepolia is DeployMetaWheelBaseSepolia {
    function run() external override returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadConfig();
        string memory manifest = _loadBoundManifest(config);
        deployed.accessManager = vm.parseJsonAddress(manifest, ".accessManager");
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        address bootstrapAdmin = vm.envAddress("B1N419_BROADCASTER");
        require(bootstrapAdmin == config.fund.roles.admin, "B1N419: bootstrap admin");
        _requireBootstrapRoles(manager, config.fund.roles);

        vm.startBroadcast(bootstrapAdmin);
        _rotateRoles(manager, bootstrapAdmin, config.finalRoles);
        vm.stopBroadcast();

        _requireFinalRoles(manager, config.finalRoles);
    }

    function _requireBootstrapRoles(FundAccessManager manager, FundFactory.RoleAccounts memory roles) internal view {
        _requireSingleImmediateRole(manager, manager.ADMIN_ROLE(), roles.admin);
        _requireSingleImmediateRole(manager, FundConstants.UPGRADER_ROLE, roles.upgrader);
        _requireSingleImmediateRole(manager, FundConstants.ADAPTER_UPGRADER_ROLE, roles.upgrader);
        _requireSingleImmediateRole(manager, FundConstants.ACCOUNTING_ROLE, roles.accounting);
        _requireSingleImmediateRole(manager, FundConstants.ALLOCATOR_ROLE, roles.allocator);
        _requireSingleImmediateRole(manager, FundConstants.PROCESSOR_ROLE, roles.processor);
        _requireSingleImmediateRole(manager, FundConstants.CURATOR_ROLE, roles.curator);
        _requireSingleImmediateRole(manager, FundConstants.GUARDIAN_ROLE, roles.guardian);
    }

    function _rotateRoles(FundAccessManager manager, address bootstrap, FundFactory.RoleAccounts memory finalRoles)
        internal
    {
        bytes[] memory calls = new bytes[](16);
        calls[0] = abi.encodeCall(manager.grantRole, (manager.ADMIN_ROLE(), finalRoles.admin, uint32(0)));
        calls[1] = abi.encodeCall(manager.grantRole, (FundConstants.UPGRADER_ROLE, finalRoles.upgrader, uint32(0)));
        calls[2] =
            abi.encodeCall(manager.grantRole, (FundConstants.ADAPTER_UPGRADER_ROLE, finalRoles.upgrader, uint32(0)));
        calls[3] = abi.encodeCall(manager.grantRole, (FundConstants.ACCOUNTING_ROLE, finalRoles.accounting, uint32(0)));
        calls[4] = abi.encodeCall(manager.grantRole, (FundConstants.ALLOCATOR_ROLE, finalRoles.allocator, uint32(0)));
        calls[5] = abi.encodeCall(manager.grantRole, (FundConstants.PROCESSOR_ROLE, finalRoles.processor, uint32(0)));
        calls[6] = abi.encodeCall(manager.grantRole, (FundConstants.CURATOR_ROLE, finalRoles.curator, uint32(0)));
        calls[7] = abi.encodeCall(manager.grantRole, (FundConstants.GUARDIAN_ROLE, finalRoles.guardian, uint32(0)));
        calls[8] = abi.encodeCall(manager.revokeRole, (FundConstants.UPGRADER_ROLE, bootstrap));
        calls[9] = abi.encodeCall(manager.revokeRole, (FundConstants.ADAPTER_UPGRADER_ROLE, bootstrap));
        calls[10] = abi.encodeCall(manager.revokeRole, (FundConstants.ACCOUNTING_ROLE, bootstrap));
        calls[11] = abi.encodeCall(manager.revokeRole, (FundConstants.ALLOCATOR_ROLE, bootstrap));
        calls[12] = abi.encodeCall(manager.revokeRole, (FundConstants.PROCESSOR_ROLE, bootstrap));
        calls[13] = abi.encodeCall(manager.revokeRole, (FundConstants.CURATOR_ROLE, bootstrap));
        calls[14] = abi.encodeCall(manager.revokeRole, (FundConstants.GUARDIAN_ROLE, bootstrap));
        calls[15] = abi.encodeCall(manager.revokeRole, (manager.ADMIN_ROLE(), bootstrap));
        manager.multicall(calls);
    }
}
