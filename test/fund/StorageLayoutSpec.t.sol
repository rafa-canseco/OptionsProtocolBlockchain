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
    CspFundAdapterStorageHarnessV1
} from "./harness/StorageLayoutHarnesses.sol";

contract StorageLayoutSpecTest is Test {
    string internal constant HARNESS_PATH = "test/fund/harness/StorageLayoutHarnesses.sol:";

    function test_productionFundUupsImplementationsPassUpgradeSafetyValidation() public {
        Options memory options;
        Upgrades.validateImplementation("src/fund/FundVault.sol:FundVault", options);
        Upgrades.validateImplementation("src/fund/FundShare.sol:FundShare", options);
        Upgrades.validateImplementation("src/fund/FundAccounting.sol:FundAccounting", options);
        Upgrades.validateImplementation("src/fund/FundFlowManager.sol:FundFlowManager", options);
        Upgrades.validateImplementation("src/fund/StrategyManager.sol:StrategyManager", options);
        options.unsafeAllow = "external-library-linking";
        Upgrades.validateImplementation("src/fund/CspFundAdapter.sol:CspFundAdapter", options);
    }

    function test_storageHarnessImplementationsPassUpgradeSafetyValidation() public {
        Options memory options;
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundVaultStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundAccountingStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV2"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV1"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV2"), options);
        Upgrades.validateImplementation(string.concat(HARNESS_PATH, "CspFundAdapterStorageHarnessV1"), options);
    }

    function test_appendToNamespaceIsCompatible() public {
        Options memory options;
        options.referenceContract = string.concat(HARNESS_PATH, "FundVaultStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "FundVaultStorageHarnessV2"), options);
        options.referenceContract = string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "FundFlowManagerStorageHarnessV2"), options);
        options.referenceContract = string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV1");
        Upgrades.validateUpgrade(string.concat(HARNESS_PATH, "StrategyManagerStorageHarnessV2"), options);
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
    }

    function test_namespaceLocationsMatchErc7201Derivations() public {
        FundVaultStorageHarnessV1 vault = new FundVaultStorageHarnessV1();
        FundAccountingStorageHarnessV1 accounting = new FundAccountingStorageHarnessV1();
        FundFlowManagerStorageHarnessV1 flow = new FundFlowManagerStorageHarnessV1();
        StrategyManagerStorageHarnessV1 strategy = new StrategyManagerStorageHarnessV1();
        CspFundAdapterStorageHarnessV1 cspAdapter = new CspFundAdapterStorageHarnessV1();

        assertEq(vault.storageLocation(), _erc7201("b1nary.storage.FundVault"));
        assertEq(accounting.storageLocation(), _erc7201("b1nary.storage.FundAccounting"));
        assertEq(flow.storageLocation(), _erc7201("b1nary.storage.FundFlowManager"));
        assertEq(strategy.storageLocation(), _erc7201("b1nary.storage.StrategyManager"));
        assertEq(cspAdapter.storageLocation(), _erc7201("b1nary.storage.CspFundAdapter"));
    }

    function _erc7201(string memory namespace) private pure returns (bytes32) {
        uint256 inner = uint256(keccak256(bytes(namespace))) - 1;
        return bytes32(uint256(keccak256(abi.encode(inner))) & ~uint256(0xff));
    }
}
