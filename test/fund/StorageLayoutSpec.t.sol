// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {
    FundVaultStorageHarnessV1,
    FundVaultStorageHarnessV2,
    FundAccountingStorageHarnessV1,
    FundFlowManagerStorageHarnessV1,
    FundFlowManagerStorageHarnessV2,
    StrategyManagerStorageHarnessV1,
    StrategyManagerStorageHarnessV2,
    CspFundAdapterStorageHarnessV1,
    CspFundAdapterStorageHarnessV2,
    CoveredCallFundAdapterStorageHarnessV1,
    CoveredCallFundAdapterStorageHarnessV2
} from "./harness/StorageLayoutHarnesses.sol";

contract StorageLayoutSpecTest is Test {
    string internal constant HARNESS_PATH = "test/fund/harness/StorageLayoutHarnesses.sol:";

    function test_productionFundUupsImplementationsPassUpgradeSafetyValidation() public {
        Options memory options;
        Upgrades.validateImplementation("src/fund/FundVault.sol:FundVault", options);
        Upgrades.validateImplementation("src/fund/FundShare.sol:FundShare", options);
        Upgrades.validateImplementation("src/fund/FundAccounting.sol:FundAccounting", options);
        Upgrades.validateImplementation("src/fund/FundFlowManager.sol:FundFlowManager", options);
        options.unsafeAllow = "external-library-linking";
        Upgrades.validateImplementation("src/fund/StrategyManager.sol:StrategyManager", options);
    }

    function test_productionAdapterUupsImplementationsPassUpgradeSafetyValidation() public {
        Options memory options;
        options.unsafeAllow = "external-library-linking";
        Upgrades.validateImplementation("src/fund/CspFundAdapter.sol:CspFundAdapter", options);
        Upgrades.validateImplementation("src/fund/CoveredCallFundAdapter.sol:CoveredCallFundAdapter", options);
    }

    function test_storageHarnessImplementationsPassUpgradeSafetyValidation() public {
        Options memory options;
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundVaultStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundAccountingStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV2"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV2"), options);
    }

    function test_adapterStorageHarnessImplementationsPassUpgradeSafetyValidation() public {
        Options memory options;
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV2"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "CoveredCallFundAdapterStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "CoveredCallFundAdapterStorageHarnessV2"), options);
    }

    function test_appendToNamespaceIsCompatible() public {
        Options memory options;
        options.referenceContract = string.concat(HARNESS_PATH, "FundVaultStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "FundVaultStorageHarnessV2"), options);
        options.referenceContract = string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV2"), options);
        options.referenceContract = string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV2"), options);
        options.referenceContract = string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV2"), options);
        options.referenceContract = string.concat(HARNESS_PATH, "CoveredCallFundAdapterStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "CoveredCallFundAdapterStorageHarnessV2"), options);
    }

    function test_compatibleUupsUpgradePreservesNamespacedState() public {
        address proxy = Upgrades.deployUUPSProxy(
            string.concat(HARNESS_PATH, "FundVaultStorageHarnessV1"),
            abi.encodeCall(FundVaultStorageHarnessV1.initialize, (address(this)))
        );
        FundVaultStorageHarnessV1(proxy).setCommittedNav(42);

        Options memory options;
        options.referenceContract = string.concat(HARNESS_PATH, "FundVaultStorageHarnessV1");
        Upgrades.upgradeProxy(proxy, string.concat(HARNESS_PATH, "FundVaultStorageHarnessV2"), "", options);

        FundVaultStorageHarnessV2 upgraded = FundVaultStorageHarnessV2(proxy);
        assertEq(upgraded.committedNav(), 42);
        upgraded.setAppendedField(99);
        assertEq(upgraded.appendedField(), 99);

        address strategyProxy = Upgrades.deployUUPSProxy(
            string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV1"),
            abi.encodeCall(StrategyManagerStorageHarnessV1.initialize, (address(this)))
        );
        StrategyManagerStorageHarnessV1(strategyProxy).setFund(address(0xB1A352));
        options.referenceContract = string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV1");
        Upgrades.upgradeProxy(
            strategyProxy, string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV2"), "", options
        );
        StrategyManagerStorageHarnessV2 upgradedStrategy = StrategyManagerStorageHarnessV2(strategyProxy);
        assertEq(upgradedStrategy.fund(), address(0xB1A352));
        upgradedStrategy.setAllocationPauseNonce(address(0xA11CE), 7);
        assertEq(upgradedStrategy.allocationPauseNonce(address(0xA11CE)), 7);

        address flowProxy = Upgrades.deployUUPSProxy(
            string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV1"),
            abi.encodeCall(FundFlowManagerStorageHarnessV1.initialize, (address(this)))
        );
        address controller = address(0xC011EC70);
        FundFlowManagerStorageHarnessV1(flowProxy).setRedemptionAccount(7, controller, 11, 22, 3, address(0xA11CE));
        options.referenceContract = string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV1");
        Upgrades.upgradeProxy(flowProxy, string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV2"), "", options);
        (
            uint256 pendingShares,
            uint256 pendingMinAssetsOut,
            uint16 indexPlusOne,
            address refundOwner,
            uint256 roundProcessableShares,
            uint256 roundProcessableAssets
        ) = FundFlowManagerStorageHarnessV2(flowProxy).redemptionAccount(7, controller);
        assertEq(pendingShares, 11);
        assertEq(pendingMinAssetsOut, 22);
        assertEq(indexPlusOne, 3);
        assertEq(refundOwner, address(0xA11CE));
        assertEq(roundProcessableShares, 0);
        assertEq(roundProcessableAssets, 0);
    }

    function test_cspCompatibleUupsUpgradePreservesNamespacedState() public {
        address cspProxy = Upgrades.deployUUPSProxy(
            string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV1"),
            abi.encodeCall(CspFundAdapterStorageHarnessV1.initialize, (address(this)))
        );
        Options memory options;
        CspFundAdapterStorageHarnessV1(cspProxy).setFund(address(0xC5F));
        options.referenceContract = string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV1");
        Upgrades.upgradeProxy(cspProxy, string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV2"), "", options);
        CspFundAdapterStorageHarnessV2 upgradedCsp = CspFundAdapterStorageHarnessV2(cspProxy);
        assertEq(upgradedCsp.fund(), address(0xC5F));
        assertEq(upgradedCsp.releasablePrincipal(), 0);
        upgradedCsp.setReleasablePrincipal(123);
        assertEq(upgradedCsp.releasablePrincipal(), 123);
    }

    function test_coveredCallCompatibleUupsUpgradePreservesNamespacedState() public {
        address coveredCallProxy = Upgrades.deployUUPSProxy(
            string.concat(HARNESS_PATH, "CoveredCallFundAdapterStorageHarnessV1"),
            abi.encodeCall(CoveredCallFundAdapterStorageHarnessV1.initialize, (address(this)))
        );
        Options memory options;
        CoveredCallFundAdapterStorageHarnessV1(coveredCallProxy).setFund(address(0xCC));
        options.referenceContract = string.concat(HARNESS_PATH, "CoveredCallFundAdapterStorageHarnessV1");
        Upgrades.upgradeProxy(
            coveredCallProxy, string.concat(HARNESS_PATH, "CoveredCallFundAdapterStorageHarnessV2"), "", options
        );
        CoveredCallFundAdapterStorageHarnessV2 upgradedCoveredCall =
            CoveredCallFundAdapterStorageHarnessV2(coveredCallProxy);
        assertEq(upgradedCoveredCall.fund(), address(0xCC));
        assertEq(upgradedCoveredCall.releasablePrincipal(), 0);
        upgradedCoveredCall.setReleasablePrincipal(456);
        assertEq(upgradedCoveredCall.releasablePrincipal(), 456);
    }

    function test_namespaceLocationsMatchErc7201Derivations() public {
        FundVaultStorageHarnessV1 vault = new FundVaultStorageHarnessV1();
        FundAccountingStorageHarnessV1 accounting = new FundAccountingStorageHarnessV1();
        FundFlowManagerStorageHarnessV1 flow = new FundFlowManagerStorageHarnessV1();
        StrategyManagerStorageHarnessV1 strategy = new StrategyManagerStorageHarnessV1();
        CspFundAdapterStorageHarnessV1 cspAdapter = new CspFundAdapterStorageHarnessV1();
        CoveredCallFundAdapterStorageHarnessV1 coveredCallAdapter = new CoveredCallFundAdapterStorageHarnessV1();

        assertEq(vault.storageLocation(), _erc7201("b1nary.storage.FundVault"));
        assertEq(accounting.storageLocation(), _erc7201("b1nary.storage.FundAccounting"));
        assertEq(flow.storageLocation(), _erc7201("b1nary.storage.FundFlowManager"));
        assertEq(strategy.storageLocation(), _erc7201("b1nary.storage.StrategyManager"));
        assertEq(cspAdapter.storageLocation(), _erc7201("b1nary.storage.CspFundAdapter"));
        assertEq(coveredCallAdapter.storageLocation(), _erc7201("b1nary.storage.CoveredCallFundAdapter"));
    }

    function _erc7201(string memory namespace) private pure returns (bytes32) {
        uint256 inner = uint256(keccak256(bytes(namespace))) - 1;
        return bytes32(uint256(keccak256(abi.encode(inner))) & ~uint256(0xff));
    }
}
