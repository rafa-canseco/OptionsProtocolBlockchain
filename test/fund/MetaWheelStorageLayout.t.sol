// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCoordinatorAdapterStorage} from "../../src/fund/storage/WheelCoordinatorAdapterStorage.sol";
import {WheelCoveredCallChildLaneStorage} from "../../src/fund/storage/WheelCoveredCallChildLaneStorage.sol";
import {WheelCoveredCallFundAdapterStorage} from "../../src/fund/storage/WheelCoveredCallFundAdapterStorage.sol";
import {WheelCspChildLaneStorage} from "../../src/fund/storage/WheelCspChildLaneStorage.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MetaWheelStorageLocationHarness is
    WheelCoordinatorAdapterStorage,
    WheelCspChildLaneStorage,
    WheelCoveredCallChildLaneStorage,
    WheelCoveredCallFundAdapterStorage
{
    function locations() external pure returns (bytes32, bytes32, bytes32, bytes32) {
        return (
            WHEEL_COORDINATOR_ADAPTER_STORAGE_LOCATION,
            WHEEL_CSP_CHILD_LANE_STORAGE_LOCATION,
            WHEEL_COVERED_CALL_CHILD_LANE_STORAGE_LOCATION,
            WHEEL_COVERED_CALL_FUND_ADAPTER_STORAGE_LOCATION
        );
    }
}

contract MetaWheelCoordinatorV2Harness is WheelCoordinatorAdapter {
    function version2Marker() external pure returns (bytes32) {
        return keccak256("META_WHEEL_V2_HARNESS");
    }
}

contract MetaWheelCodeAddress {}

contract MetaWheelStorageLayoutTest is Test {
    function test_newUupsImplementationsPassUpgradeSafetyValidation() public {
        Options memory options;
        Upgrades.validateImplementation("src/fund/WheelCoordinatorAdapter.sol:WheelCoordinatorAdapter", options);
        Upgrades.validateImplementation("src/fund/WheelCspChildLane.sol:WheelCspChildLane", options);
        Upgrades.validateImplementation("src/fund/WheelCoveredCallChildLane.sol:WheelCoveredCallChildLane", options);
        // The Wheel subtype intentionally reuses the inherited adapter initializer;
        // its added namespace contains only an empty-by-default replay-protection mapping.
        options.unsafeAllow = "external-library-linking,missing-initializer";
        Upgrades.validateImplementation("src/fund/WheelCoveredCallFundAdapter.sol:WheelCoveredCallFundAdapter", options);
    }

    function test_namespacesMatchErc7201DerivationAndDoNotCollide() public {
        (bytes32 coordinator, bytes32 cspLane, bytes32 callLane, bytes32 callAdapter) =
            new MetaWheelStorageLocationHarness().locations();
        assertEq(coordinator, _erc7201("b1nary.storage.WheelCoordinatorAdapter"));
        assertEq(cspLane, _erc7201("b1nary.storage.WheelCspChildLane"));
        assertEq(callLane, _erc7201("b1nary.storage.WheelCoveredCallChildLane"));
        assertEq(callAdapter, _erc7201("b1nary.storage.WheelCoveredCallFundAdapter"));
        assertTrue(coordinator != cspLane && coordinator != callLane && coordinator != callAdapter);
        assertTrue(cspLane != callLane && cspLane != callAdapter && callLane != callAdapter);
    }

    function test_uupsUpgradePreservesCoordinatorState() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        MetaWheelCodeAddress fund = new MetaWheelCodeAddress();
        MetaWheelCodeAddress strategy = new MetaWheelCodeAddress();
        FundAccessManager accessManager = new FundAccessManager(address(this));
        bytes32 configuredPolicyHash = keccak256("policy-v1");
        WheelCoordinatorAdapter implementation = new WheelCoordinatorAdapter();
        WheelCoordinatorAdapter coordinator = WheelCoordinatorAdapter(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        WheelCoordinatorAdapter.initialize,
                        (WheelCoordinatorAdapter.InitializeParams({
                                fund: address(fund),
                                strategyManager: address(strategy),
                                usdc: address(usdc),
                                weth: address(weth),
                                authority: address(accessManager),
                                maxCspLanes: 4,
                                maxCoveredCallLanes: 4,
                                floorBufferUsd8: 10e8,
                                policyHash: configuredPolicyHash
                            }))
                    )
                )
            )
        );

        coordinator.upgradeToAndCall(address(new MetaWheelCoordinatorV2Harness()), "");
        MetaWheelCoordinatorV2Harness upgraded = MetaWheelCoordinatorV2Harness(address(coordinator));
        assertEq(upgraded.fund(), address(fund));
        assertEq(upgraded.accountingAsset(), address(usdc));
        assertEq(upgraded.weth(), address(weth));
        assertEq(upgraded.floorBufferUsd8(), 10e8);
        assertEq(upgraded.policyHash(), configuredPolicyHash);
        assertEq(upgraded.version2Marker(), keccak256("META_WHEEL_V2_HARNESS"));
    }

    function _erc7201(string memory namespace) private pure returns (bytes32) {
        uint256 namespaceHash = uint256(keccak256(bytes(namespace)));
        return bytes32(uint256(keccak256(abi.encode(namespaceHash - 1))) & ~uint256(0xff));
    }
}
