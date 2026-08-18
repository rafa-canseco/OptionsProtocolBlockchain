// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {B1N360Base} from "./B1N360Base.sol";

/// @notice Repairs the B1N-360 NAV submitter role without changing its reporter set.
/// @dev Deployment-specific and idempotent. Grant + revoke execute atomically through multicall.
contract RepairB1N360AccountingRole is B1N360Base {
    address internal constant ACCESS_MANAGER = 0x5AfD3d840ec2f7fE078b44b75462C2dCD3DC3F6D;
    address internal constant FUND_ACCOUNTING = 0x9a112A65FE8510bCf5DC894fFBf06aEa8d12d311;
    address internal constant OLD_ACCOUNTING = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address internal constant NAV_SUBMITTER = 0x195De7eDc5e912D7b7001d3F268bbE0d14f7E1C3;

    function run() external {
        _requireBaseSepolia();
        FundAccessManager manager = FundAccessManager(ACCESS_MANAGER);
        FundAccounting accounting = FundAccounting(FUND_ACCOUNTING);
        uint256 schedulerKey = vm.envUint("PRIVATE_KEY");
        require(vm.addr(schedulerKey) == OLD_ACCOUNTING, "B1N360 repair: broadcaster");
        require(
            manager.getTargetFunctionRole(FUND_ACCOUNTING, FundAccounting.submitNav.selector)
                == FundConstants.ACCOUNTING_ROLE,
            "B1N360 repair: submit selector"
        );

        bytes32 reportersBefore = _reporterSetHash(accounting);
        bytes32 otherRolesBefore = _otherRolesHash(manager);
        if (_isFinalized(manager)) {
            _requireUnchanged(accounting, manager, reportersBefore, otherRolesBefore);
            console2.log("PHASE_ALREADY_FINALIZED");
            return;
        }
        _requireInitialState(manager);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(manager.grantRole, (FundConstants.ACCOUNTING_ROLE, NAV_SUBMITTER, uint32(0)));
        calls[1] = abi.encodeCall(manager.revokeRole, (FundConstants.ACCOUNTING_ROLE, OLD_ACCOUNTING));
        vm.startBroadcast(schedulerKey);
        manager.multicall(calls);
        vm.stopBroadcast();

        require(_isFinalized(manager), "B1N360 repair: role migration");
        _requireUnchanged(accounting, manager, reportersBefore, otherRolesBefore);
        console2.log("B1N360_ACCOUNTING_ROLE", NAV_SUBMITTER);
    }

    function _requireInitialState(FundAccessManager manager) private view {
        require(manager.roleMemberCount(FundConstants.ACCOUNTING_ROLE) == 1, "B1N360 repair: member count");
        require(manager.roleMemberAt(FundConstants.ACCOUNTING_ROLE, 0) == OLD_ACCOUNTING, "B1N360 repair: old member");
        (bool oldActive, uint32 oldDelay) = manager.hasRole(FundConstants.ACCOUNTING_ROLE, OLD_ACCOUNTING);
        (bool newActive,) = manager.hasRole(FundConstants.ACCOUNTING_ROLE, NAV_SUBMITTER);
        require(oldActive && oldDelay == 0 && !newActive, "B1N360 repair: initial role");
    }

    function _isFinalized(FundAccessManager manager) private view returns (bool) {
        if (manager.roleMemberCount(FundConstants.ACCOUNTING_ROLE) != 1) return false;
        if (manager.roleMemberAt(FundConstants.ACCOUNTING_ROLE, 0) != NAV_SUBMITTER) return false;
        (bool oldActive,) = manager.hasRole(FundConstants.ACCOUNTING_ROLE, OLD_ACCOUNTING);
        (bool newActive, uint32 newDelay) = manager.hasRole(FundConstants.ACCOUNTING_ROLE, NAV_SUBMITTER);
        return !oldActive && newActive && newDelay == 0;
    }

    function _requireUnchanged(
        FundAccounting accounting,
        FundAccessManager manager,
        bytes32 reportersBefore,
        bytes32 otherRolesBefore
    ) private view {
        require(_reporterSetHash(accounting) == reportersBefore, "B1N360 repair: reporters changed");
        require(_otherRolesHash(manager) == otherRolesBefore, "B1N360 repair: other roles changed");
        require(
            manager.getTargetFunctionRole(FUND_ACCOUNTING, FundAccounting.submitNav.selector)
                == FundConstants.ACCOUNTING_ROLE,
            "B1N360 repair: selector changed"
        );
    }

    function _reporterSetHash(FundAccounting accounting) private view returns (bytes32 hash_) {
        uint256 count = accounting.activeReporterCount();
        address[] memory reporters = new address[](count);
        for (uint256 i; i < count; ++i) {
            reporters[i] = accounting.activeReporterAt(i);
        }
        hash_ = keccak256(abi.encode(accounting.reporterSetVersion(), accounting.reporterThreshold(), reporters));
    }

    function _otherRolesHash(FundAccessManager manager) private view returns (bytes32 hash_) {
        uint64[7] memory roles = [
            manager.ADMIN_ROLE(),
            FundConstants.UPGRADER_ROLE,
            FundConstants.ALLOCATOR_ROLE,
            FundConstants.PROCESSOR_ROLE,
            FundConstants.CURATOR_ROLE,
            FundConstants.GUARDIAN_ROLE,
            FundConstants.ADAPTER_UPGRADER_ROLE
        ];
        bytes memory encoded;
        for (uint256 i; i < roles.length; ++i) {
            uint256 count = manager.roleMemberCount(roles[i]);
            encoded = abi.encodePacked(encoded, roles[i], count);
            for (uint256 j; j < count; ++j) {
                address member = manager.roleMemberAt(roles[i], j);
                (bool active, uint32 delay) = manager.hasRole(roles[i], member);
                encoded = abi.encodePacked(encoded, member, active, delay);
            }
        }
        hash_ = keccak256(encoded);
    }
}
