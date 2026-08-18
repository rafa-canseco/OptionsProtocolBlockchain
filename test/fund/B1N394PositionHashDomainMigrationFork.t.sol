// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {FundAccountingStorage} from "../../src/fund/storage/FundAccountingStorage.sol";
import {RepairB1N394PositionHashDomain} from "../../script/fund/RepairB1N394PositionHashDomain.s.sol";

contract B1N394PositionHashDomainMigrationForkTest is Test {
    uint256 private constant POST_UPGRADE_BLOCK = 44_840_105;
    address private constant ADMIN = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;

    address private constant CSP_VAULT = 0x53e38Baf2fC55259729085b7542BFF066F6a509e;
    address private constant CSP_ACCOUNTING = 0x21d3acc5a2c64666dA93ABC8c77AB483b96836a3;
    address private constant CSP_MANAGER = 0xfC28237145596D4E1dfD28B80e186EFC09A1F988;
    address private constant CSP_ADAPTER = 0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3;

    address private constant CC_VAULT = 0x9060946E6ACC4E430A823E90120743c7305EE2CA;
    address private constant CC_ACCOUNTING = 0x9a112A65FE8510bCf5DC894fFBf06aEa8d12d311;
    address private constant CC_MANAGER = 0x745422dd14E84ee27C2E56D2845C3BB1658027d9;
    address private constant CC_ADAPTER = 0x0BF96C5cE0D637d4D686d342aE42Bc00fDa19De9;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")), POST_UPGRADE_BLOCK);
        vm.setEnv("B1N394_BROADCASTER", vm.toString(ADMIN));
    }

    function test_migratesOnlyTheAccountingHashDomainWhileVaultsRemainPaused() public {
        bytes32 cspPosition = keccak256(abi.encode(CspFundAdapter(CSP_ADAPTER).position(3)));
        bytes32 ccPosition = keccak256(abi.encode(CoveredCallFundAdapter(CC_ADAPTER).position(1)));
        bytes32 cspManagerPositions = StrategyManager(CSP_MANAGER).positionsHash();
        bytes32 ccManagerPositions = StrategyManager(CC_MANAGER).positionsHash();
        uint256 cspIdle = FundVault(CSP_VAULT).accountedIdleAssets();
        uint256 ccIdle = FundVault(CC_VAULT).accountedIdleAssets();

        FundAccounting implementation = new FundAccounting();
        vm.setEnv("B1N394_HASH_DOMAIN_ACCOUNTING_IMPLEMENTATION", vm.toString(address(implementation)));
        vm.setEnv(
            "B1N394_HASH_DOMAIN_ACCOUNTING_IMPLEMENTATION_CODEHASH", vm.toString(address(implementation).codehash)
        );

        new RepairB1N394PositionHashDomain().run();

        _assertMigrated(CSP_ACCOUNTING, CSP_MANAGER, CSP_ADAPTER, CspFundAdapter(CSP_ADAPTER).positionStateHash());
        _assertMigrated(CC_ACCOUNTING, CC_MANAGER, CC_ADAPTER, CoveredCallFundAdapter(CC_ADAPTER).positionStateHash());
        assertEq(keccak256(abi.encode(CspFundAdapter(CSP_ADAPTER).position(3))), cspPosition);
        assertEq(keccak256(abi.encode(CoveredCallFundAdapter(CC_ADAPTER).position(1))), ccPosition);
        assertEq(StrategyManager(CSP_MANAGER).positionsHash(), cspManagerPositions);
        assertEq(StrategyManager(CC_MANAGER).positionsHash(), ccManagerPositions);
        assertEq(FundVault(CSP_VAULT).accountedIdleAssets(), cspIdle);
        assertEq(FundVault(CC_VAULT).accountedIdleAssets(), ccIdle);
        assertTrue(FundVault(CSP_VAULT).depositsPaused());
        assertTrue(FundVault(CC_VAULT).depositsPaused());
        assertTrue(FundVault(CSP_VAULT).redemptionsPaused());
        assertTrue(FundVault(CC_VAULT).redemptionsPaused());
    }

    function _assertMigrated(address accountingAddress, address managerAddress, address adapter, bytes32 expectedHash)
        private
        view
    {
        FundAccounting accounting = FundAccounting(accountingAddress);
        bytes32 componentId = accounting.strategyComponentId(adapter);
        FundAccountingStorage.ComponentState memory component = accounting.componentState(componentId);
        assertTrue(component.active);
        assertEq(component.nonce, StrategyManager(managerAddress).positionNonce(adapter));
        assertEq(component.positionStateHash, expectedHash);
    }
}
