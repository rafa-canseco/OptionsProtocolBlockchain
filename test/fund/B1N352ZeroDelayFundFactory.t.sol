// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {B1N352ZeroDelayFundFactory} from "../../src/fund/B1N352ZeroDelayFundFactory.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {NavReportVerifier} from "../../src/fund/NavReportVerifier.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {IStrategyAssetEscrow} from "../../src/fund/interfaces/IStrategyAssetEscrow.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {B1N352DeploymentReconciler} from "../../script/fund/ReconcileB1N352Deployment.s.sol";

contract B1N352V2AccessReconcilerHarness is B1N352DeploymentReconciler {
    address private immutable _expectedMember;

    constructor(address expectedMember_) {
        _expectedMember = expectedMember_;
    }

    function verifyZeroDelayAccess(
        FundAccessManager manager,
        FundFactory.FundDeployment memory deployed,
        address adapter,
        address inKindEscrow,
        address emergencyEscrow
    ) external view {
        _verifyAccessManager(
            manager,
            deployed.vault,
            deployed.share,
            deployed.accounting,
            deployed.flowManager,
            deployed.strategyManager,
            adapter,
            inKindEscrow,
            emergencyEscrow,
            0,
            0,
            0
        );
    }

    function _approvedAddress(string memory) internal view override returns (address) {
        return _expectedMember;
    }
}

contract B1N352ZeroDelayFundFactoryTest is Test {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    MockERC20 private asset;
    FundFactory.ImplementationSet private implementations;

    function setUp() public {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        asset = new MockERC20("USD Coin", "USDC", 6);
        implementations = FundFactory.ImplementationSet({
            vault: address(new FundVault()),
            share: address(new FundShare()),
            accounting: address(new FundAccounting()),
            navVerifier: address(new NavReportVerifier()),
            flowManager: address(new FundFlowManager()),
            strategyManager: address(new StrategyManager()),
            compatibilityVersion: 1,
            active: true
        });
    }

    function test_factoryConstructorAndCreationAreLockedToBaseSepolia() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(B1N352ZeroDelayFundFactory.WrongDeploymentChain.selector, 1));
        new B1N352ZeroDelayFundFactory(address(this));

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        B1N352ZeroDelayFundFactory factory = _zeroDelayFactory();
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(B1N352ZeroDelayFundFactory.WrongDeploymentChain.selector, 1));
        factory.createFund(_params(keccak256("WRONG_CHAIN")));
    }

    function test_v2FactoryStartsPausedInactiveAndAllGovernanceDelaysAreZero() public {
        B1N352ZeroDelayFundFactory factory = _zeroDelayFactory();
        FundFactory.FundDeployment memory deployed = factory.createFund(_params(keccak256("V2")));
        FundAccessManager manager = FundAccessManager(deployed.accessManager);

        _assertRoleDelay(manager, manager.ADMIN_ROLE(), 0);
        _assertRoleDelay(manager, FundConstants.UPGRADER_ROLE, 0);
        _assertRoleDelay(manager, FundConstants.ADAPTER_UPGRADER_ROLE, 0);
        _assertRoleDelay(manager, FundConstants.ACCOUNTING_ROLE, 0);
        _assertRoleDelay(manager, FundConstants.ALLOCATOR_ROLE, 0);
        _assertRoleDelay(manager, FundConstants.PROCESSOR_ROLE, 0);
        _assertRoleDelay(manager, FundConstants.CURATOR_ROLE, 0);
        _assertRoleDelay(manager, FundConstants.GUARDIAN_ROLE, 0);
        assertEq(manager.getTargetAdminDelay(deployed.share), 0);
        assertEq(manager.getTargetAdminDelay(deployed.vault), 0);
        assertEq(manager.getTargetAdminDelay(deployed.accounting), 0);
        assertEq(manager.getTargetAdminDelay(deployed.flowManager), 0);
        assertEq(manager.getTargetAdminDelay(deployed.strategyManager), 0);
        assertTrue(FundVault(deployed.vault).depositsPaused());
        assertEq(StrategyManager(deployed.strategyManager).activeAdapterCount(), 0);
    }

    function test_curatorExecutesRestrictedCallDirectlyWithoutSchedule() public {
        B1N352ZeroDelayFundFactory factory = _zeroDelayFactory();
        FundFactory.FundDeployment memory deployed = factory.createFund(_params(keccak256("DIRECT")));
        StrategyManager strategy = StrategyManager(deployed.strategyManager);

        strategy.setMinimumIdleBps(1_234);
        assertEq(strategy.minimumIdleBps(), 1_234);
    }

    function test_onlyOwnerCanConsumeOneShotCreation() public {
        B1N352ZeroDelayFundFactory factory = _zeroDelayFactory();
        address unauthorized = address(0xBEEF);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unauthorized));
        factory.createFund(_params(keccak256("UNAUTHORIZED")));
        assertFalse(factory.fundCreated());

        factory.createFund(_params(keccak256("AUTHORIZED")));
        assertTrue(factory.fundCreated());
        vm.expectRevert(B1N352ZeroDelayFundFactory.FundAlreadyCreated.selector);
        factory.createFund(_params(keccak256("SECOND")));
    }

    function test_v2ReconcilerAcceptsExactZeroDelayAuthorityAndExternalRules() public {
        B1N352ZeroDelayFundFactory factory = _zeroDelayFactory();
        FundFactory.FundDeployment memory deployed = factory.createFund(_params(keccak256("RECONCILE")));
        FundAccessManager manager = FundAccessManager(deployed.accessManager);
        address adapter = address(0xADA7);
        address inKindEscrow = address(0x1A11);
        address emergencyEscrow = address(0xE911);

        _setRule(manager, adapter, FundAccessPolicy.UPGRADE_TO_AND_CALL_SELECTOR, FundConstants.ADAPTER_UPGRADER_ROLE);
        _setRule(manager, adapter, ICspFundAdapter.setAdapterConfig.selector, FundConstants.CURATOR_ROLE);
        _setRule(manager, inKindEscrow, IStrategyAssetEscrow.releaseToFund.selector, FundConstants.CURATOR_ROLE);
        _setRule(manager, emergencyEscrow, IStrategyAssetEscrow.releaseToFund.selector, FundConstants.CURATOR_ROLE);

        new B1N352V2AccessReconcilerHarness(address(this))
            .verifyZeroDelayAccess(manager, deployed, adapter, inKindEscrow, emergencyEscrow);
    }

    function test_productionFactoryRetainsConfiguredGovernanceDelays() public {
        FundFactory factory = new FundFactory(address(this));
        factory.registerImplementationVersion(1, implementations);
        FundFactory.FundDeployment memory deployed = factory.createFund(_params(keccak256("PRODUCTION")));
        FundAccessManager manager = FundAccessManager(deployed.accessManager);

        _assertRoleDelay(manager, manager.ADMIN_ROLE(), FundConstants.CORE_UPGRADE_DELAY);
        _assertRoleDelay(manager, FundConstants.UPGRADER_ROLE, FundConstants.CORE_UPGRADE_DELAY);
        _assertRoleDelay(manager, FundConstants.ADAPTER_UPGRADER_ROLE, FundConstants.ADAPTER_UPGRADE_DELAY);
        _assertRoleDelay(manager, FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        vm.warp(block.timestamp + manager.minSetback());
        assertEq(manager.getTargetAdminDelay(deployed.vault), FundConstants.CORE_UPGRADE_DELAY);
    }

    function _zeroDelayFactory() private returns (B1N352ZeroDelayFundFactory factory) {
        factory = new B1N352ZeroDelayFundFactory(address(this));
        factory.registerImplementationVersion(1, implementations);
    }

    function _params(bytes32 salt) private view returns (FundFactory.CreateFundParams memory) {
        return FundFactory.CreateFundParams({
            implementationVersion: 1,
            salt: salt,
            name: "B1N352 V2 CSP Fund",
            symbol: "qaCSP",
            asset: asset,
            minimumIdleBps: 2_000,
            navActivationDelay: 1,
            maxSnapshotAge: 20,
            maxNavWindowLength: 100,
            feeConfig: FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 0,
                maxManagementFeeBps: 0,
                maxPerformanceFeeBps: 0,
                maxAccrualInterval: 0,
                crystallizationPeriod: 0,
                feeRecipient: address(0)
            }),
            roles: _roles()
        });
    }

    function _roles() private view returns (FundFactory.RoleAccounts memory) {
        return FundFactory.RoleAccounts({
            admin: address(this),
            upgrader: address(this),
            accounting: address(this),
            allocator: address(this),
            processor: address(this),
            curator: address(this),
            guardian: address(this)
        });
    }

    function _assertRoleDelay(FundAccessManager manager, uint64 role, uint32 expectedExecutionDelay) private view {
        (bool member, uint32 executionDelay) = manager.hasRole(role, address(this));
        assertTrue(member);
        assertEq(executionDelay, expectedExecutionDelay);
        assertEq(manager.getRoleGrantDelay(role), 0);
    }

    function _setRule(FundAccessManager manager, address target, bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }
}
