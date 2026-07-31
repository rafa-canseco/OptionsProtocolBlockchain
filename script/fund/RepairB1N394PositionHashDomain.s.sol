// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {FundAccountingStorage} from "../../src/fund/storage/FundAccountingStorage.sol";
import {B1N394Base} from "./B1N394Base.sol";

/// @notice Migrates the active strategy component hash to the B1N-392 adapter hash domain.
/// @dev The two vaults must remain paused from ExecuteB1N394Upgrade until a fresh NAV is finalized.
contract RepairB1N394PositionHashDomain is B1N394Base {
    struct Snapshot {
        bytes32 adapterState;
        bytes32 managerPositions;
        bytes32 componentHash;
        address valuator;
        uint64 interfaceVersion;
        uint64 componentNonce;
        uint256 allocation;
        uint256 idle;
        uint256 nav;
        uint256 supply;
        uint256 highWaterMark;
    }

    function run() external {
        _requireBaseSepolia();
        address implementation = vm.envAddress("B1N394_HASH_DOMAIN_ACCOUNTING_IMPLEMENTATION");
        require(
            implementation.codehash == vm.envBytes32("B1N394_HASH_DOMAIN_ACCOUNTING_IMPLEMENTATION_CODEHASH"),
            "B1N394: accounting bytecode"
        );
        address broadcaster = vm.envAddress("B1N394_BROADCASTER");

        Snapshot memory cspBefore = _cspSnapshot();
        Snapshot memory ccBefore = _ccSnapshot();
        _requireReady(cspBefore, ccBefore);

        vm.startBroadcast(broadcaster);
        _repair(AccessManager(CSP_ACCESS), broadcaster, CSP_ACCOUNTING, CSP_ADAPTER, implementation);
        _repair(AccessManager(CC_ACCESS), broadcaster, CC_ACCOUNTING, CC_ADAPTER, implementation);
        vm.stopBroadcast();

        _requireCspAfter(cspBefore);
        _requireCcAfter(ccBefore);
        console2.log("B1N394_HASH_DOMAIN_MIGRATION_BLOCK", block.number);
    }

    function _repair(
        AccessManager access,
        address broadcaster,
        address accountingAddress,
        address adapter,
        address implementation
    ) private {
        _requireImmediateRole(access, access.ADMIN_ROLE(), broadcaster);
        _requireImmediateRole(access, FundConstants.UPGRADER_ROLE, broadcaster);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FundAccounting.reinitializePositionHashDomain.selector;
        bytes memory migration = abi.encodeCall(FundAccounting.reinitializePositionHashDomain, (adapter));
        bytes memory upgrade =
            abi.encodeCall(FundAccounting(accountingAddress).upgradeToAndCall, (implementation, migration));

        bytes[] memory calls = new bytes[](2);
        calls[0] =
            abi.encodeCall(access.setTargetFunctionRole, (accountingAddress, selectors, FundConstants.UPGRADER_ROLE));
        calls[1] = _managedCall(access, broadcaster, accountingAddress, upgrade, FundConstants.UPGRADER_ROLE);
        access.multicall(calls);
    }

    function _requireReady(Snapshot memory csp, Snapshot memory cc) private view {
        require(csp.allocation != 0 && cc.allocation != 0, "B1N394: active principal");
        require(csp.componentHash != CspFundAdapter(CSP_ADAPTER).positionStateHash(), "B1N394: CSP already migrated");
        require(
            cc.componentHash != CoveredCallFundAdapter(CC_ADAPTER).positionStateHash(), "B1N394: CC already migrated"
        );
        _requirePaused(FundVault(CSP_VAULT), StrategyManager(CSP_MANAGER), CSP_ADAPTER);
        _requirePaused(FundVault(CC_VAULT), StrategyManager(CC_MANAGER), CC_ADAPTER);
        require(FundVault(CSP_VAULT).executionLockOwner() == address(0), "B1N394: CSP lock");
        require(FundVault(CC_VAULT).executionLockOwner() == address(0), "B1N394: CC lock");
    }

    function _cspSnapshot() private view returns (Snapshot memory snapshot) {
        CspFundAdapter adapter = CspFundAdapter(CSP_ADAPTER);
        StrategyManager manager = StrategyManager(CSP_MANAGER);
        FundAccounting accounting = FundAccounting(CSP_ACCOUNTING);
        FundVault vault = FundVault(CSP_VAULT);
        bytes32 componentId = accounting.strategyComponentId(CSP_ADAPTER);
        FundAccountingStorage.ComponentState memory component = accounting.componentState(componentId);
        snapshot.valuator = component.valuator;
        snapshot.interfaceVersion = component.interfaceVersion;
        snapshot.componentNonce = component.nonce;
        snapshot.componentHash = component.positionStateHash;
        snapshot.adapterState = keccak256(abi.encode(adapter.adapterState()));
        snapshot.managerPositions = manager.positionsHash();
        snapshot.allocation = manager.allocatedToAdapter(CSP_ADAPTER, adapter.accountingAsset());
        snapshot.idle = vault.accountedIdleAssets();
        snapshot.nav = vault.committedNav();
        snapshot.supply = vault.shareSupply();
        snapshot.highWaterMark = accounting.feeState().highWaterMark;
    }

    function _ccSnapshot() private view returns (Snapshot memory snapshot) {
        CoveredCallFundAdapter adapter = CoveredCallFundAdapter(CC_ADAPTER);
        StrategyManager manager = StrategyManager(CC_MANAGER);
        FundAccounting accounting = FundAccounting(CC_ACCOUNTING);
        FundVault vault = FundVault(CC_VAULT);
        bytes32 componentId = accounting.strategyComponentId(CC_ADAPTER);
        FundAccountingStorage.ComponentState memory component = accounting.componentState(componentId);
        snapshot.valuator = component.valuator;
        snapshot.interfaceVersion = component.interfaceVersion;
        snapshot.componentNonce = component.nonce;
        snapshot.componentHash = component.positionStateHash;
        snapshot.adapterState = keccak256(abi.encode(adapter.adapterState()));
        snapshot.managerPositions = manager.positionsHash();
        snapshot.allocation = manager.allocatedToAdapter(CC_ADAPTER, adapter.accountingAsset());
        snapshot.idle = vault.accountedIdleAssets();
        snapshot.nav = vault.committedNav();
        snapshot.supply = vault.shareSupply();
        snapshot.highWaterMark = accounting.feeState().highWaterMark;
    }

    function _requireCspAfter(Snapshot memory before_) private view {
        CspFundAdapter adapter = CspFundAdapter(CSP_ADAPTER);
        _requireAfter(
            before_,
            FundAccounting(CSP_ACCOUNTING),
            FundVault(CSP_VAULT),
            StrategyManager(CSP_MANAGER),
            CSP_ADAPTER,
            adapter.accountingAsset(),
            keccak256(abi.encode(adapter.adapterState())),
            adapter.positionStateHash()
        );
    }

    function _requireCcAfter(Snapshot memory before_) private view {
        CoveredCallFundAdapter adapter = CoveredCallFundAdapter(CC_ADAPTER);
        _requireAfter(
            before_,
            FundAccounting(CC_ACCOUNTING),
            FundVault(CC_VAULT),
            StrategyManager(CC_MANAGER),
            CC_ADAPTER,
            adapter.accountingAsset(),
            keccak256(abi.encode(adapter.adapterState())),
            adapter.positionStateHash()
        );
    }

    function _requireAfter(
        Snapshot memory before_,
        FundAccounting accounting,
        FundVault vault,
        StrategyManager manager,
        address adapter,
        address accountingAsset,
        bytes32 adapterState,
        bytes32 migratedHash
    ) private view {
        bytes32 componentId = accounting.strategyComponentId(adapter);
        FundAccountingStorage.ComponentState memory component = accounting.componentState(componentId);
        require(component.active, "B1N394: component inactive");
        require(
            component.valuator == before_.valuator && component.interfaceVersion == before_.interfaceVersion,
            "B1N394: component config"
        );
        require(component.nonce == before_.componentNonce, "B1N394: component nonce");
        require(
            component.positionStateHash == migratedHash && component.positionStateHash != before_.componentHash,
            "B1N394: component hash"
        );
        require(adapterState == before_.adapterState, "B1N394: adapter state");
        require(manager.positionsHash() == before_.managerPositions, "B1N394: manager positions");
        require(manager.allocatedToAdapter(adapter, accountingAsset) == before_.allocation, "B1N394: allocation");
        require(vault.accountedIdleAssets() == before_.idle, "B1N394: idle");
        require(vault.committedNav() == before_.nav, "B1N394: NAV");
        require(vault.shareSupply() == before_.supply, "B1N394: supply");
        require(accounting.feeState().highWaterMark == before_.highWaterMark, "B1N394: HWM");
        _requirePaused(vault, manager, adapter);
    }
}
