// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {B1N394Base} from "./B1N394Base.sol";

/// @notice Pauses each V2 fund and performs its incompatible module transition in one AccessManager multicall.
/// @dev Leaves deposits, redemptions, and allocation paused until FinalizeB1N394Upgrade observes post-upgrade NAVs.
contract ExecuteB1N394Upgrade is B1N394Base {
    struct Snapshot {
        bytes32 position;
        bytes32 adapterState;
        bytes32 adapterConfig;
        bytes32 positionStateHash;
        uint256 allocation;
        uint256 idle;
        uint256 nav;
        uint256 supply;
        uint256 pending;
        uint256 claimable;
        uint256 highWaterMark;
        uint64 reportNonce;
        uint64 allocationPauseNonce;
    }

    function run() external {
        _requireBaseSepolia();
        Implementations memory implementations = _loadImplementations();
        _requireImplementations(implementations);
        _requireMatchingPolicy(CSP_CURRENT_VALUATOR, implementations.cspValuator);
        _requireMatchingPolicy(CC_CURRENT_VALUATOR, implementations.ccValuator);

        address broadcaster = vm.envAddress("B1N394_BROADCASTER");
        require(BatchSettler(BATCH_SETTLER).owner() == broadcaster, "B1N394: settler owner");

        Snapshot memory cspBefore = _cspSnapshot();
        Snapshot memory ccBefore = _ccSnapshot();
        _requireReady(cspBefore, ccBefore);

        vm.startBroadcast(broadcaster);
        _upgradeCsp(broadcaster, implementations);
        _upgradeCoveredCall(broadcaster, implementations);
        BatchSettler(BATCH_SETTLER).setProtocolFeeBps(PREMIUM_FEE_BPS);
        vm.stopBroadcast();

        _requireCspAfter(cspBefore, implementations);
        _requireCcAfter(ccBefore, implementations);
        require(BatchSettler(BATCH_SETTLER).protocolFeeBps() == PREMIUM_FEE_BPS, "B1N394: premium fee");
        console2.log("B1N394_UPGRADE_SIMULATION_BLOCK", block.number);
        console2.log("B1N394_CSP_PRE_UPGRADE_NAV_NONCE", cspBefore.reportNonce);
        console2.log("B1N394_CC_PRE_UPGRADE_NAV_NONCE", ccBefore.reportNonce);
    }

    function _upgradeCsp(address broadcaster, Implementations memory implementations) private {
        AccessManager access = AccessManager(CSP_ACCESS);
        FundVault vault = FundVault(CSP_VAULT);
        FundAccounting accounting = FundAccounting(CSP_ACCOUNTING);
        StrategyManager manager = StrategyManager(CSP_MANAGER);
        FundTypes.StrategyConfig memory replacement = manager.strategyConfig(CSP_ADAPTER);
        replacement.active = false;
        replacement.valuator = implementations.cspValuator;
        bytes32 componentId = accounting.strategyComponentId(CSP_ADAPTER);

        bytes[] memory calls = new bytes[](10);
        calls[0] = _managedCall(
            access, broadcaster, CSP_VAULT, abi.encodeCall(vault.pauseDeposits, ()), FundConstants.GUARDIAN_ROLE
        );
        calls[1] = _managedCall(
            access, broadcaster, CSP_VAULT, abi.encodeCall(vault.pauseRedemptions, ()), FundConstants.GUARDIAN_ROLE
        );
        calls[2] = _managedCall(
            access,
            broadcaster,
            CSP_MANAGER,
            abi.encodeCall(manager.pauseAllocation, (CSP_ADAPTER)),
            FundConstants.GUARDIAN_ROLE
        );
        calls[3] = _managedCall(
            access,
            broadcaster,
            CSP_ADAPTER,
            abi.encodeCall(CspFundAdapter(CSP_ADAPTER).upgradeToAndCall, (implementations.cspAdapter, bytes(""))),
            FundConstants.ADAPTER_UPGRADER_ROLE
        );
        calls[4] = _managedCall(
            access,
            broadcaster,
            CSP_ACCOUNTING,
            abi.encodeCall(accounting.upgradeToAndCall, (implementations.accounting, bytes(""))),
            FundConstants.UPGRADER_ROLE
        );
        calls[5] = _managedCall(
            access,
            broadcaster,
            CSP_FLOW,
            abi.encodeCall(FundFlowManager(CSP_FLOW).upgradeToAndCall, (implementations.flow, bytes(""))),
            FundConstants.UPGRADER_ROLE
        );
        calls[6] = _managedCall(
            access,
            broadcaster,
            CSP_MANAGER,
            abi.encodeCall(manager.upgradeToAndCall, (implementations.manager, bytes(""))),
            FundConstants.UPGRADER_ROLE
        );
        calls[7] = _managedCall(
            access,
            broadcaster,
            CSP_ACCOUNTING,
            abi.encodeCall(accounting.setComponent, (componentId, implementations.cspValuator, uint64(1), true)),
            FundConstants.CURATOR_ROLE
        );
        calls[8] = _managedCall(
            access,
            broadcaster,
            CSP_MANAGER,
            abi.encodeCall(manager.setStrategyConfig, (CSP_ADAPTER, replacement)),
            FundConstants.CURATOR_ROLE
        );
        calls[9] = _managedCall(
            access,
            broadcaster,
            CSP_ACCOUNTING,
            abi.encodeCall(accounting.setFeeConfig, (_feeConfig(accounting.feeConfig().feeRecipient))),
            FundConstants.CURATOR_ROLE
        );
        access.multicall(calls);
    }

    function _upgradeCoveredCall(address broadcaster, Implementations memory implementations) private {
        AccessManager access = AccessManager(CC_ACCESS);
        FundVault vault = FundVault(CC_VAULT);
        FundAccounting accounting = FundAccounting(CC_ACCOUNTING);
        StrategyManager manager = StrategyManager(CC_MANAGER);
        FundTypes.StrategyConfig memory replacement = manager.strategyConfig(CC_ADAPTER);
        replacement.active = false;
        replacement.valuator = implementations.ccValuator;
        bytes32 componentId = accounting.strategyComponentId(CC_ADAPTER);

        bytes[] memory calls = new bytes[](10);
        calls[0] = _managedCall(
            access, broadcaster, CC_VAULT, abi.encodeCall(vault.pauseDeposits, ()), FundConstants.GUARDIAN_ROLE
        );
        calls[1] = _managedCall(
            access, broadcaster, CC_VAULT, abi.encodeCall(vault.pauseRedemptions, ()), FundConstants.GUARDIAN_ROLE
        );
        calls[2] = _managedCall(
            access,
            broadcaster,
            CC_MANAGER,
            abi.encodeCall(manager.pauseAllocation, (CC_ADAPTER)),
            FundConstants.GUARDIAN_ROLE
        );
        calls[3] = _managedCall(
            access,
            broadcaster,
            CC_ADAPTER,
            abi.encodeCall(CoveredCallFundAdapter(CC_ADAPTER).upgradeToAndCall, (implementations.ccAdapter, bytes(""))),
            FundConstants.ADAPTER_UPGRADER_ROLE
        );
        calls[4] = _managedCall(
            access,
            broadcaster,
            CC_ACCOUNTING,
            abi.encodeCall(accounting.upgradeToAndCall, (implementations.accounting, bytes(""))),
            FundConstants.UPGRADER_ROLE
        );
        calls[5] = _managedCall(
            access,
            broadcaster,
            CC_FLOW,
            abi.encodeCall(FundFlowManager(CC_FLOW).upgradeToAndCall, (implementations.flow, bytes(""))),
            FundConstants.UPGRADER_ROLE
        );
        calls[6] = _managedCall(
            access,
            broadcaster,
            CC_MANAGER,
            abi.encodeCall(manager.upgradeToAndCall, (implementations.manager, bytes(""))),
            FundConstants.UPGRADER_ROLE
        );
        calls[7] = _managedCall(
            access,
            broadcaster,
            CC_ACCOUNTING,
            abi.encodeCall(accounting.setComponent, (componentId, implementations.ccValuator, uint64(1), true)),
            FundConstants.CURATOR_ROLE
        );
        calls[8] = _managedCall(
            access,
            broadcaster,
            CC_MANAGER,
            abi.encodeCall(manager.setStrategyConfig, (CC_ADAPTER, replacement)),
            FundConstants.CURATOR_ROLE
        );
        calls[9] = _managedCall(
            access,
            broadcaster,
            CC_ACCOUNTING,
            abi.encodeCall(accounting.setFeeConfig, (_feeConfig(accounting.feeConfig().feeRecipient))),
            FundConstants.CURATOR_ROLE
        );
        access.multicall(calls);
    }

    function _requireImplementations(Implementations memory implementations) private view {
        require(
            implementations.accounting.codehash == vm.envBytes32("B1N394_FUND_ACCOUNTING_IMPLEMENTATION_CODEHASH"),
            "B1N394: accounting bytecode"
        );
        require(
            implementations.flow.codehash == vm.envBytes32("B1N394_FUND_FLOW_IMPLEMENTATION_CODEHASH"),
            "B1N394: flow bytecode"
        );
        require(
            implementations.manager.codehash == vm.envBytes32("B1N394_STRATEGY_MANAGER_IMPLEMENTATION_CODEHASH"),
            "B1N394: manager bytecode"
        );
        require(
            implementations.cspAdapter.codehash == vm.envBytes32("B1N394_CSP_ADAPTER_IMPLEMENTATION_CODEHASH"),
            "B1N394: CSP bytecode"
        );
        require(
            implementations.ccAdapter.codehash == vm.envBytes32("B1N394_CC_ADAPTER_IMPLEMENTATION_CODEHASH"),
            "B1N394: CC bytecode"
        );
        require(
            implementations.cspValuator.codehash == vm.envBytes32("B1N394_CSP_VALUATOR_CODEHASH"),
            "B1N394: CSP valuator bytecode"
        );
        require(
            implementations.ccValuator.codehash == vm.envBytes32("B1N394_CC_VALUATOR_CODEHASH"),
            "B1N394: CC valuator bytecode"
        );
    }

    function _requireReady(Snapshot memory csp, Snapshot memory cc) private view {
        require(csp.allocation != 0 && cc.allocation != 0, "B1N394: active principal");
        require(csp.pending == 0 && csp.claimable == 0, "B1N394: CSP redemptions");
        require(cc.pending == 0 && cc.claimable == 0, "B1N394: CC redemptions");
        require(FundVault(CSP_VAULT).executionLockOwner() == address(0), "B1N394: CSP lock");
        require(FundVault(CC_VAULT).executionLockOwner() == address(0), "B1N394: CC lock");
        require(!FundFlowManager(CSP_FLOW).hasActiveProcessing(), "B1N394: CSP processing");
        require(!FundFlowManager(CC_FLOW).hasActiveProcessing(), "B1N394: CC processing");
        require(!FundVault(CSP_VAULT).depositsPaused(), "B1N394: CSP deposits already paused");
        require(!FundVault(CC_VAULT).depositsPaused(), "B1N394: CC deposits already paused");
        require(!FundVault(CSP_VAULT).redemptionsPaused(), "B1N394: CSP redemptions already paused");
        require(!FundVault(CC_VAULT).redemptionsPaused(), "B1N394: CC redemptions already paused");
        require(StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER).active, "B1N394: CSP allocation paused");
        require(StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER).active, "B1N394: CC allocation paused");
    }

    function _cspSnapshot() private view returns (Snapshot memory snapshot) {
        CspFundAdapter adapter = CspFundAdapter(CSP_ADAPTER);
        StrategyManager manager = StrategyManager(CSP_MANAGER);
        FundVault vault = FundVault(CSP_VAULT);
        FundAccounting accounting = FundAccounting(CSP_ACCOUNTING);
        FundFlowManager flow = FundFlowManager(CSP_FLOW);
        ICspFundAdapter.AdapterState memory state = adapter.adapterState();
        require(state.activePositionCount == 1, "B1N394: CSP active positions");
        require(
            adapter.position(state.positionCount).lifecycle == ICspFundAdapter.Lifecycle.Open, "B1N394: CSP lifecycle"
        );
        snapshot.position = keccak256(abi.encode(adapter.position(state.positionCount)));
        snapshot.adapterState = keccak256(abi.encode(state));
        snapshot.adapterConfig = keccak256(abi.encode(adapter.adapterConfig()));
        snapshot.positionStateHash = adapter.positionStateHash();
        snapshot.allocation = manager.allocatedToAdapter(CSP_ADAPTER, adapter.accountingAsset());
        snapshot.idle = vault.accountedIdleAssets();
        snapshot.nav = vault.committedNav();
        snapshot.supply = vault.shareSupply();
        snapshot.pending = flow.totalPendingShares();
        snapshot.claimable = flow.totalClaimableShares();
        snapshot.highWaterMark = accounting.feeState().highWaterMark;
        snapshot.reportNonce = accounting.lastReportNonce();
        snapshot.allocationPauseNonce = manager.allocationPauseNonce(CSP_ADAPTER);
    }

    function _ccSnapshot() private view returns (Snapshot memory snapshot) {
        CoveredCallFundAdapter adapter = CoveredCallFundAdapter(CC_ADAPTER);
        StrategyManager manager = StrategyManager(CC_MANAGER);
        FundVault vault = FundVault(CC_VAULT);
        FundAccounting accounting = FundAccounting(CC_ACCOUNTING);
        FundFlowManager flow = FundFlowManager(CC_FLOW);
        ICoveredCallFundAdapter.AdapterState memory state = adapter.adapterState();
        require(state.activePositionCount == 1, "B1N394: CC active positions");
        require(
            adapter.position(state.positionCount).lifecycle == ICoveredCallFundAdapter.Lifecycle.Open,
            "B1N394: CC lifecycle"
        );
        snapshot.position = keccak256(abi.encode(adapter.position(state.positionCount)));
        snapshot.adapterState = keccak256(abi.encode(state));
        snapshot.adapterConfig = keccak256(abi.encode(adapter.adapterConfig()));
        snapshot.positionStateHash = adapter.positionStateHash();
        snapshot.allocation = manager.allocatedToAdapter(CC_ADAPTER, adapter.accountingAsset());
        snapshot.idle = vault.accountedIdleAssets();
        snapshot.nav = vault.committedNav();
        snapshot.supply = vault.shareSupply();
        snapshot.pending = flow.totalPendingShares();
        snapshot.claimable = flow.totalClaimableShares();
        snapshot.highWaterMark = accounting.feeState().highWaterMark;
        snapshot.reportNonce = accounting.lastReportNonce();
        snapshot.allocationPauseNonce = manager.allocationPauseNonce(CC_ADAPTER);
    }

    function _requireCspAfter(Snapshot memory before_, Implementations memory implementations) private view {
        CspFundAdapter adapter = CspFundAdapter(CSP_ADAPTER);
        StrategyManager manager = StrategyManager(CSP_MANAGER);
        FundAccounting accounting = FundAccounting(CSP_ACCOUNTING);
        FundTypes.StrategyConfig memory config = manager.strategyConfig(CSP_ADAPTER);
        _requireCommonAfter(
            before_,
            keccak256(abi.encode(adapter.position(adapter.adapterState().positionCount))),
            keccak256(abi.encode(adapter.adapterState())),
            keccak256(abi.encode(adapter.adapterConfig())),
            manager.allocatedToAdapter(CSP_ADAPTER, adapter.accountingAsset()),
            CSP_VAULT,
            CSP_FLOW,
            CSP_ACCOUNTING
        );
        require(adapter.deallocationInterfaceVersion() == 2, "B1N394: CSP deallocation interface");
        require(adapter.positionStateHash() != before_.positionStateHash, "B1N394: CSP hash domain");
        require(config.valuator == implementations.cspValuator && !config.active, "B1N394: CSP strategy config");
        require(manager.allocationPauseNonce(CSP_ADAPTER) == before_.allocationPauseNonce + 1, "B1N394: CSP pause");
        require(
            accounting.componentState(accounting.strategyComponentId(CSP_ADAPTER)).valuator
                == implementations.cspValuator,
            "B1N394: CSP component"
        );
        _requireFeeConfig(accounting, accounting.feeConfig().feeRecipient);
    }

    function _requireCcAfter(Snapshot memory before_, Implementations memory implementations) private view {
        CoveredCallFundAdapter adapter = CoveredCallFundAdapter(CC_ADAPTER);
        StrategyManager manager = StrategyManager(CC_MANAGER);
        FundAccounting accounting = FundAccounting(CC_ACCOUNTING);
        FundTypes.StrategyConfig memory config = manager.strategyConfig(CC_ADAPTER);
        _requireCommonAfter(
            before_,
            keccak256(abi.encode(adapter.position(adapter.adapterState().positionCount))),
            keccak256(abi.encode(adapter.adapterState())),
            keccak256(abi.encode(adapter.adapterConfig())),
            manager.allocatedToAdapter(CC_ADAPTER, adapter.accountingAsset()),
            CC_VAULT,
            CC_FLOW,
            CC_ACCOUNTING
        );
        require(adapter.deallocationInterfaceVersion() == 2, "B1N394: CC deallocation interface");
        require(adapter.positionStateHash() != before_.positionStateHash, "B1N394: CC hash domain");
        require(config.valuator == implementations.ccValuator && !config.active, "B1N394: CC strategy config");
        require(manager.allocationPauseNonce(CC_ADAPTER) == before_.allocationPauseNonce + 1, "B1N394: CC pause");
        require(
            accounting.componentState(accounting.strategyComponentId(CC_ADAPTER)).valuator
                == implementations.ccValuator,
            "B1N394: CC component"
        );
        _requireFeeConfig(accounting, accounting.feeConfig().feeRecipient);
    }

    function _requireCommonAfter(
        Snapshot memory before_,
        bytes32 position,
        bytes32 adapterState,
        bytes32 adapterConfig,
        uint256 allocation,
        address vaultAddress,
        address flowAddress,
        address accountingAddress
    ) private view {
        FundVault vault = FundVault(vaultAddress);
        FundFlowManager flow = FundFlowManager(flowAddress);
        FundAccounting accounting = FundAccounting(accountingAddress);
        require(position == before_.position, "B1N394: position mutated");
        require(adapterState == before_.adapterState, "B1N394: adapter state mutated");
        require(adapterConfig == before_.adapterConfig, "B1N394: adapter config mutated");
        require(allocation == before_.allocation, "B1N394: allocation mutated");
        require(vault.accountedIdleAssets() == before_.idle, "B1N394: idle mutated");
        require(vault.committedNav() == before_.nav, "B1N394: NAV mutated");
        require(vault.shareSupply() == before_.supply, "B1N394: supply mutated");
        require(flow.totalPendingShares() == before_.pending, "B1N394: pending mutated");
        require(flow.totalClaimableShares() == before_.claimable, "B1N394: claimable mutated");
        require(accounting.feeState().highWaterMark == before_.highWaterMark, "B1N394: HWM reset");
        require(accounting.lastReportNonce() == before_.reportNonce, "B1N394: NAV nonce mutated");
        require(vault.depositsPaused() && vault.redemptionsPaused(), "B1N394: flows not paused");
        require(vault.executionLockOwner() == address(0), "B1N394: lock left open");
    }
}
