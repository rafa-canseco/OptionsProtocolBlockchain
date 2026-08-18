// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {B1N394Base} from "./B1N394Base.sol";

/// @notice Reopens normal V2 operation only after both reporters have committed post-upgrade active NAV windows.
contract FinalizeB1N394Upgrade is B1N394Base {
    function run() external {
        _requireBaseSepolia();
        Implementations memory implementations = _loadImplementations();
        uint64 upgradeBlock = uint64(vm.envUint("B1N394_UPGRADE_BLOCK"));
        uint64 cspPriorNonce = uint64(vm.envUint("B1N394_CSP_PRE_UPGRADE_NAV_NONCE"));
        uint64 ccPriorNonce = uint64(vm.envUint("B1N394_CC_PRE_UPGRADE_NAV_NONCE"));
        _requirePostUpgradeState(implementations, upgradeBlock, cspPriorNonce, ccPriorNonce);

        address broadcaster = vm.envAddress("B1N394_BROADCASTER");

        vm.startBroadcast(broadcaster);
        _resume(AccessManager(CSP_ACCESS), broadcaster, FundVault(CSP_VAULT), StrategyManager(CSP_MANAGER), CSP_ADAPTER);
        _resume(AccessManager(CC_ACCESS), broadcaster, FundVault(CC_VAULT), StrategyManager(CC_MANAGER), CC_ADAPTER);
        vm.stopBroadcast();

        _requireOperational(FundVault(CSP_VAULT), StrategyManager(CSP_MANAGER), CSP_ADAPTER);
        _requireOperational(FundVault(CC_VAULT), StrategyManager(CC_MANAGER), CC_ADAPTER);
    }

    function _resume(
        AccessManager access,
        address broadcaster,
        FundVault vault,
        StrategyManager manager,
        address adapter
    ) private {
        uint64 pauseNonce = manager.allocationPauseNonce(adapter);
        bytes[] memory calls = new bytes[](3);
        calls[0] = _managedCall(
            access, broadcaster, address(vault), abi.encodeCall(vault.resumeDeposits, ()), FundConstants.CURATOR_ROLE
        );
        calls[1] = _managedCall(
            access, broadcaster, address(vault), abi.encodeCall(vault.resumeRedemptions, ()), FundConstants.CURATOR_ROLE
        );
        calls[2] = _managedCall(
            access,
            broadcaster,
            address(manager),
            abi.encodeCall(manager.resumeAllocation, (adapter, pauseNonce)),
            FundConstants.CURATOR_ROLE
        );
        access.multicall(calls);
    }

    function _requirePostUpgradeState(
        Implementations memory implementations,
        uint64 upgradeBlock,
        uint64 cspPriorNonce,
        uint64 ccPriorNonce
    ) private view {
        require(upgradeBlock != 0 && upgradeBlock < block.number, "B1N394: upgrade block");
        require(CspFundAdapter(CSP_ADAPTER).deallocationInterfaceVersion() == 2, "B1N394: CSP adapter");
        require(CoveredCallFundAdapter(CC_ADAPTER).deallocationInterfaceVersion() == 2, "B1N394: CC adapter");
        require(
            StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER).valuator == implementations.cspValuator,
            "B1N394: CSP valuator"
        );
        require(
            StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER).valuator == implementations.ccValuator,
            "B1N394: CC valuator"
        );
        _requireFreshNav(FundVault(CSP_VAULT), FundAccounting(CSP_ACCOUNTING), upgradeBlock, cspPriorNonce, CSP_MANAGER);
        _requireFreshNav(FundVault(CC_VAULT), FundAccounting(CC_ACCOUNTING), upgradeBlock, ccPriorNonce, CC_MANAGER);
        _requireFeeConfig(FundAccounting(CSP_ACCOUNTING), FundAccounting(CSP_ACCOUNTING).feeConfig().feeRecipient);
        _requireFeeConfig(FundAccounting(CC_ACCOUNTING), FundAccounting(CC_ACCOUNTING).feeConfig().feeRecipient);
        require(BatchSettler(BATCH_SETTLER).protocolFeeBps() == PREMIUM_FEE_BPS, "B1N394: premium fee");
        _requirePaused(FundVault(CSP_VAULT), StrategyManager(CSP_MANAGER), CSP_ADAPTER);
        _requirePaused(FundVault(CC_VAULT), StrategyManager(CC_MANAGER), CC_ADAPTER);
    }

    function _requireFreshNav(
        FundVault vault,
        FundAccounting accounting,
        uint64 upgradeBlock,
        uint64 priorNonce,
        address strategyManager
    ) private view {
        FundTypes.NavCommit memory nav = vault.activeNavWindow();
        require(accounting.lastReportNonce() > priorNonce, "B1N394: NAV nonce not advanced");
        require(nav.reportNonce == accounting.lastReportNonce(), "B1N394: NAV nonce mismatch");
        require(nav.snapshotBlock >= upgradeBlock, "B1N394: pre-upgrade NAV");
        require(nav.validAfterBlock <= block.number && block.number <= nav.validUntilBlock, "B1N394: inactive NAV");
        require(nav.positionsHash == StrategyManager(strategyManager).positionsHash(), "B1N394: positions hash");
        require(nav.fundFlowNonce + 1 == vault.fundFlowNonce(), "B1N394: flow nonce");
        bytes32 expectedIdleHash = keccak256(
            abi.encode(
                address(vault),
                block.chainid,
                nav.fundFlowNonce,
                vault.accountedIdleAssets(),
                IERC20(vault.asset()).balanceOf(address(vault))
            )
        );
        require(nav.idleStateHash == expectedIdleHash, "B1N394: idle hash");
    }

    function _requireOperational(FundVault vault, StrategyManager manager, address adapter) private view {
        require(!vault.depositsPaused(), "B1N394: deposits paused");
        require(!vault.redemptionsPaused(), "B1N394: redemptions paused");
        require(manager.strategyConfig(adapter).active, "B1N394: allocation paused");
        require(vault.executionLockOwner() == address(0), "B1N394: execution lock");
    }
}
