// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {IFundFlowManager} from "../../src/fund/interfaces/IFundFlowManager.sol";
import {IFundVault} from "../../src/fund/interfaces/IFundVault.sol";
import {IStrategyManager} from "../../src/fund/interfaces/IStrategyManager.sol";

contract FundAccessTarget is AccessManaged {
    uint256 public pauses;
    uint256 public resumes;
    uint256 public allocations;
    address public implementation;

    constructor(address authority_) AccessManaged(authority_) {}

    function pauseDeposits() external restricted {
        ++pauses;
    }

    function resumeDeposits() external restricted {
        ++resumes;
    }

    function allocate(address, address, uint256 amount, bytes calldata) external restricted {
        allocations += amount;
    }

    function upgradeToAndCall(address newImplementation, bytes calldata) external restricted {
        implementation = newImplementation;
    }
}

contract AccessPolicySpecTest is Test {
    AccessManager internal manager;
    FundAccessTarget internal target;
    address internal guardian = address(0x600D);
    address internal curator = address(0xC0A7);
    address internal allocator = address(0xA110);
    address internal upgrader = address(0xA9);

    function setUp() public {
        manager = new AccessManager(address(this));
        target = new FundAccessTarget(address(manager));

        _applyRules(FundAccessPolicy.vaultRules());
        _applyRules(FundAccessPolicy.strategyRules());

        manager.grantRole(FundConstants.GUARDIAN_ROLE, guardian, 0);
        manager.grantRole(FundConstants.CURATOR_ROLE, curator, FundConstants.CURATOR_DELAY);
        manager.grantRole(FundConstants.ALLOCATOR_ROLE, allocator, 0);
        manager.grantRole(FundConstants.UPGRADER_ROLE, upgrader, FundConstants.CORE_UPGRADE_DELAY);
        manager.setRoleGuardian(FundConstants.CURATOR_ROLE, FundConstants.GUARDIAN_ROLE);
    }

    function test_guardianCanPauseImmediatelyButCannotResume() public {
        vm.prank(guardian);
        target.pauseDeposits();
        assertEq(target.pauses(), 1);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, guardian));
        target.resumeDeposits();
    }

    function test_curatorResumeRequiresScheduledDelay() public {
        bytes memory data = abi.encodeCall(target.resumeDeposits, ());

        vm.prank(curator);
        vm.expectRevert();
        target.resumeDeposits();

        vm.prank(curator);
        manager.schedule(address(target), data, 0);
        vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
        vm.prank(curator);
        target.resumeDeposits();

        assertEq(target.resumes(), 1);
    }

    function test_guardianCanCancelCuratorSchedule() public {
        bytes memory data = abi.encodeCall(target.resumeDeposits, ());
        vm.prank(curator);
        manager.schedule(address(target), data, 0);

        vm.prank(guardian);
        manager.cancel(curator, address(target), data);

        vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
        vm.prank(curator);
        vm.expectRevert();
        target.resumeDeposits();
    }

    function test_allocatorCanAllocateImmediatelyButCannotUpgrade() public {
        vm.prank(allocator);
        target.allocate(address(1), address(2), 123, "");
        assertEq(target.allocations(), 123);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, allocator));
        target.upgradeToAndCall(address(0xBEEF), "");
    }

    function test_upgradeRequiresSeventyTwoHourSchedule() public {
        bytes memory data = abi.encodeCall(target.upgradeToAndCall, (address(0xBEEF), bytes("")));
        vm.prank(upgrader);
        manager.schedule(address(target), data, 0);

        vm.warp(block.timestamp + FundConstants.CORE_UPGRADE_DELAY - 1);
        vm.prank(upgrader);
        vm.expectRevert();
        target.upgradeToAndCall(address(0xBEEF), "");

        vm.warp(block.timestamp + 1);
        vm.prank(upgrader);
        target.upgradeToAndCall(address(0xBEEF), "");
        assertEq(target.implementation(), address(0xBEEF));
    }

    function test_policySeparatesRiskReductionAndRiskResumptionSelectors() public pure {
        FundAccessPolicy.Rule[] memory rules = FundAccessPolicy.strategyRules();
        assertEq(rules[6].selector, IStrategyManager.pauseAllocation.selector);
        assertEq(rules[6].role, FundConstants.GUARDIAN_ROLE);
        assertEq(rules[6].executionDelay, 0);
        assertEq(rules[7].selector, IStrategyManager.resumeAllocation.selector);
        assertEq(rules[7].role, FundConstants.CURATOR_ROLE);
        assertEq(rules[7].executionDelay, FundConstants.CURATOR_DELAY);
    }

    function test_vaultPolicyUsesDifferentPauseAndResumeSelectors() public pure {
        FundAccessPolicy.Rule[] memory rules = FundAccessPolicy.vaultRules();
        assertEq(rules[1].selector, IFundVault.pauseDeposits.selector);
        assertEq(rules[3].selector, IFundVault.resumeDeposits.selector);
        assertTrue(rules[1].selector != rules[3].selector);
    }

    function test_processorRoleControlsEveryBoundedBatchPhase() public pure {
        FundAccessPolicy.Rule[] memory rules = FundAccessPolicy.flowRules();
        assertEq(rules[1].selector, IFundFlowManager.sealRedeemBatch.selector);
        assertEq(rules[2].selector, IFundFlowManager.releaseRedeemBatch.selector);
        assertEq(rules[3].selector, IFundFlowManager.startRedeemBatch.selector);
        assertEq(rules[4].selector, IFundFlowManager.processRedeemBatch.selector);
        assertEq(rules[1].role, FundConstants.PROCESSOR_ROLE);
        assertEq(rules[2].role, FundConstants.PROCESSOR_ROLE);
        assertEq(rules[3].role, FundConstants.PROCESSOR_ROLE);
        assertEq(rules[4].role, FundConstants.PROCESSOR_ROLE);
    }

    function _applyRules(FundAccessPolicy.Rule[] memory rules) private {
        for (uint256 i; i < rules.length; ++i) {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = rules[i].selector;
            manager.setTargetFunctionRole(address(target), selectors, rules[i].role);
        }
    }
}
