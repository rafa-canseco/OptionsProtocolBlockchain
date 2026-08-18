// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";

/// @notice OpenZeppelin AccessManager with exact on-chain role-member enumeration.
/// @dev Membership events remain the canonical history; these getters certify the complete current set.
contract FundAccessManager is AccessManager {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Time for Time.Delay;

    mapping(uint64 roleId => EnumerableSet.AddressSet members) private _roleMembers;
    mapping(address target => EnumerableSet.Bytes32Set selectors) private _configuredSelectors;
    mapping(uint64 roleId => Time.Delay delay) private _trackedGrantDelays;
    mapping(address target => Time.Delay delay) private _trackedTargetAdminDelays;

    constructor(address initialAdmin) AccessManager(initialAdmin) {
        _roleMembers[ADMIN_ROLE].add(initialAdmin);
    }

    function roleMemberCount(uint64 roleId) external view returns (uint256) {
        return _roleMembers[roleId].length();
    }

    function roleMemberAt(uint64 roleId, uint256 index) external view returns (address) {
        return _roleMembers[roleId].at(index);
    }

    function configuredSelectorCount(address target) external view returns (uint256) {
        return _configuredSelectors[target].length();
    }

    function getRoleGrantDelayFull(uint64 roleId)
        external
        view
        returns (uint32 currentDelay, uint32 pendingDelay, uint48 effect)
    {
        return _trackedGrantDelays[roleId].getFull();
    }

    function getTargetAdminDelayFull(address target)
        external
        view
        returns (uint32 currentDelay, uint32 pendingDelay, uint48 effect)
    {
        return _trackedTargetAdminDelays[target].getFull();
    }

    function setTargetFunctionRole(address target, bytes4[] calldata selectors, uint64 roleId) public override {
        super.setTargetFunctionRole(target, selectors, roleId);
        for (uint256 i; i < selectors.length; ++i) {
            bytes32 selector = bytes32(selectors[i]);
            if (roleId == ADMIN_ROLE) {
                _configuredSelectors[target].remove(selector);
            } else {
                _configuredSelectors[target].add(selector);
            }
        }
    }

    function setGrantDelay(uint64 roleId, uint32 newDelay) public override {
        super.setGrantDelay(roleId, newDelay);
        (_trackedGrantDelays[roleId],) = _trackedGrantDelays[roleId].withUpdate(newDelay, minSetback());
    }

    function setTargetAdminDelay(address target, uint32 newDelay) public override {
        super.setTargetAdminDelay(target, newDelay);
        (_trackedTargetAdminDelays[target],) = _trackedTargetAdminDelays[target].withUpdate(newDelay, minSetback());
    }

    function _grantRole(uint64 roleId, address account, uint32 grantDelay, uint32 executionDelay)
        internal
        override
        returns (bool newMember)
    {
        newMember = super._grantRole(roleId, account, grantDelay, executionDelay);
        if (newMember) _roleMembers[roleId].add(account);
    }

    function _revokeRole(uint64 roleId, address account) internal override returns (bool removed) {
        removed = super._revokeRole(roleId, account);
        if (removed) _roleMembers[roleId].remove(account);
    }
}
