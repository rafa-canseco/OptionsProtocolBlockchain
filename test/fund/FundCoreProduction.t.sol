// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {NavReportVerifier} from "../../src/fund/NavReportVerifier.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {IFundAccounting} from "../../src/fund/interfaces/IFundAccounting.sol";
import {IFundFlowManager} from "../../src/fund/interfaces/IFundFlowManager.sol";
import {IStrategyManager} from "../../src/fund/interfaces/IStrategyManager.sol";
import {IFundStrategyAdapter} from "../../src/fund/interfaces/IFundStrategyAdapter.sol";
import {IPositionValuator} from "../../src/fund/interfaces/IPositionValuator.sol";

contract ProductionStrategyAdapter is IFundStrategyAdapter {
    address public immutable override fund;
    address public immutable override accountingAsset;
    uint64 public positionNonce;

    constructor(address fund_, address accountingAsset_) {
        fund = fund_;
        accountingAsset = accountingAsset_;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function positionStateHash() external view returns (bytes32) {
        return keccak256(abi.encode(IERC20(accountingAsset).balanceOf(address(this)), positionNonce));
    }

    function freeAssets(address asset_) external view returns (uint256) {
        return IERC20(asset_).balanceOf(address(this));
    }

    function allocate(address asset_, uint256 amount, bytes calldata) external {
        require(msg.sender == FundVault(fund).strategyManager(), "ONLY_MANAGER");
        require(asset_ == accountingAsset && IERC20(asset_).balanceOf(address(this)) >= amount, "INVALID_ALLOCATION");
        ++positionNonce;
    }

    function deallocate(uint256 targetValue, uint256 minAccountingAssetsOut, bytes calldata)
        external
        returns (uint256 accountingAssetsOut)
    {
        require(msg.sender == FundVault(fund).strategyManager(), "ONLY_MANAGER");
        accountingAssetsOut = targetValue;
        require(accountingAssetsOut >= minAccountingAssetsOut, "MIN_OUT");
        IERC20(accountingAsset).transfer(fund, accountingAssetsOut);
        ++positionNonce;
    }

    function deallocateInKind(uint256 fractionWad, address escrow, bytes calldata)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        require(msg.sender == FundVault(fund).strategyManager(), "ONLY_MANAGER");
        assets = new address[](1);
        amounts = new uint256[](1);
        assets[0] = accountingAsset;
        amounts[0] = Math.mulDiv(IERC20(accountingAsset).balanceOf(address(this)), fractionWad, FundConstants.WAD);
        IERC20(accountingAsset).transfer(escrow, amounts[0]);
        ++positionNonce;
    }

    function emergencyExit(address escrow, bytes calldata)
        external
        returns (address[] memory assets, uint256[] memory amounts)
    {
        require(msg.sender == FundVault(fund).strategyManager(), "ONLY_MANAGER");
        assets = new address[](1);
        amounts = new uint256[](1);
        assets[0] = accountingAsset;
        amounts[0] = IERC20(accountingAsset).balanceOf(address(this));
        IERC20(accountingAsset).transfer(escrow, amounts[0]);
        ++positionNonce;
    }
}

    contract ProductionAssetEscrow {}

    contract ProductionPositionValuator is IPositionValuator {
        function interfaceVersion() external pure returns (uint64) {
            return 1;
        }

        function value(address adapter, uint64, bytes calldata)
            external
            view
            returns (FundTypes.PositionValue memory positionValue)
        {
            uint256 assets = IERC20(IFundStrategyAdapter(adapter).accountingAsset()).balanceOf(adapter);
            positionValue.grossAssets = assets;
            positionValue.liquidAccountingAssets = assets;
            positionValue.dataHash = keccak256(abi.encode(adapter, assets));
        }
    }

    contract FundCoreProductionTest is Test {
        bytes32 internal constant IDLE_COMPONENT = keccak256("IDLE_ACCOUNTING_ASSET");
        bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
            0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 internal constant PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        uint256 internal constant REPORTER_ONE_KEY = 0xA11CE;
        uint256 internal constant REPORTER_TWO_KEY = 0xB0B;

        MockERC20 internal asset;
        FundFactory internal factory;
        FundVault internal vault;
        FundShare internal share;
        FundAccounting internal accounting;
        FundFlowManager internal flow;
        StrategyManager internal strategy;
        AccessManager internal manager;

        FundVault internal vaultImplementation;
        FundShare internal shareImplementation;
        FundAccounting internal accountingImplementation;
        NavReportVerifier internal navVerifier;
        FundFlowManager internal flowImplementation;
        StrategyManager internal strategyImplementation;

        address internal alice = makeAddr("alice");
        address internal bob = makeAddr("bob");
        address internal operator = makeAddr("operator");
        address internal feeRecipient = makeAddr("feeRecipient");

        function setUp() public {
            asset = new MockERC20("Mock USDC", "USDC", 6);
            vaultImplementation = new FundVault();
            shareImplementation = new FundShare();
            accountingImplementation = new FundAccounting();
            navVerifier = new NavReportVerifier();
            flowImplementation = new FundFlowManager();
            strategyImplementation = new StrategyManager();

            factory = new FundFactory(address(this));
            factory.registerImplementationVersion(
                1,
                FundFactory.ImplementationSet({
                    vault: address(vaultImplementation),
                    share: address(shareImplementation),
                    accounting: address(accountingImplementation),
                    navVerifier: address(navVerifier),
                    flowManager: address(flowImplementation),
                    strategyManager: address(strategyImplementation),
                    compatibilityVersion: 1,
                    active: true
                })
            );

            FundFactory.RoleAccounts memory roles = FundFactory.RoleAccounts({
                admin: address(this),
                upgrader: address(this),
                accounting: address(this),
                allocator: address(this),
                processor: address(this),
                curator: address(this),
                guardian: address(this)
            });
            FundTypes.FeeConfig memory feeConfig = FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 0,
                maxManagementFeeBps: 200,
                maxPerformanceFeeBps: 2_000,
                maxAccrualInterval: 30 days,
                crystallizationPeriod: 1 days,
                feeRecipient: feeRecipient
            });
            FundFactory.FundDeployment memory deployed = factory.createFund(
                FundFactory.CreateFundParams({
                    implementationVersion: 1,
                    salt: keccak256("production-fund"),
                    name: "b1nary Fund",
                    symbol: "B1F",
                    asset: asset,
                    minimumIdleBps: 1_000,
                    navActivationDelay: 1,
                    maxSnapshotAge: 20,
                    maxNavWindowLength: 20,
                    feeConfig: feeConfig,
                    roles: roles
                })
            );

            vault = FundVault(deployed.vault);
            share = FundShare(deployed.share);
            accounting = FundAccounting(deployed.accounting);
            flow = FundFlowManager(deployed.flowManager);
            strategy = StrategyManager(deployed.strategyManager);
            manager = AccessManager(deployed.accessManager);

            _scheduleAndConfigureNavSources();
            _submitNav(0, 0);
        }

        function test_factoryDeploysIsolatedModularTopologyAndPolicy() public view {
            assertEq(vault.accounting(), address(accounting));
            assertEq(vault.share(), address(share));
            assertEq(share.vault(address(asset)), address(vault));
            assertEq(share.asset(), address(asset));
            assertEq(vault.flowManager(), address(flow));
            assertEq(vault.strategyManager(), address(strategy));
            assertEq(accounting.fund(), address(vault));
            assertEq(accounting.navVerifier(), address(navVerifier));
            assertEq(accounting.navVerifierVersion(), 1);
            assertEq(flow.fund(), address(vault));
            assertEq(strategy.fund(), address(vault));
            assertEq(vault.compatibilityVersion(), 1);
            assertEq(vault.decimals(), 18);

            assertEq(
                manager.getTargetFunctionRole(address(vault), FundVault.pauseDeposits.selector),
                FundConstants.GUARDIAN_ROLE
            );
            assertEq(
                manager.getTargetFunctionRole(address(vault), bytes4(keccak256("upgradeToAndCall(address,bytes)"))),
                FundConstants.UPGRADER_ROLE
            );
            assertEq(
                manager.getTargetFunctionRole(address(accounting), FundAccounting.submitNav.selector),
                FundConstants.ACCOUNTING_ROLE
            );
            assertEq(
                manager.getTargetFunctionRole(address(flow), FundFlowManager.processRedeemBatch.selector),
                FundConstants.PROCESSOR_ROLE
            );

            (bool factoryIsAdmin,) = manager.hasRole(manager.ADMIN_ROLE(), address(factory));
            (bool fundAdmin, uint32 adminDelay) = manager.hasRole(manager.ADMIN_ROLE(), address(this));
            (bool upgrader, uint32 upgraderDelay) = manager.hasRole(FundConstants.UPGRADER_ROLE, address(this));
            assertFalse(factoryIsAdmin);
            assertTrue(fundAdmin);
            assertEq(adminDelay, FundConstants.CORE_UPGRADE_DELAY);
            assertTrue(upgrader);
            assertEq(upgraderDelay, FundConstants.CORE_UPGRADE_DELAY);
            assertEq(manager.getRoleGrantDelay(manager.ADMIN_ROLE()), FundConstants.CORE_UPGRADE_DELAY);
            assertEq(manager.getRoleGrantDelay(FundConstants.UPGRADER_ROLE), FundConstants.CORE_UPGRADE_DELAY);
            assertEq(manager.getRoleGrantDelay(FundConstants.CURATOR_ROLE), FundConstants.CURATOR_DELAY);
            assertEq(manager.getTargetAdminDelay(address(share)), FundConstants.CORE_UPGRADE_DELAY);
            assertEq(manager.getTargetAdminDelay(address(vault)), FundConstants.CORE_UPGRADE_DELAY);
        }

        function test_factoryEmitsErc7575VaultUpdateWithNonIndexedVault() public {
            FundFactory.CreateFundParams memory params = _defaultCreateParams(keccak256("erc7575-vault-update"));

            vm.recordLogs();
            FundFactory.FundDeployment memory deployed = factory.createFund(params);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            bytes32 eventSignature = keccak256("VaultUpdate(address,address)");
            bool found;
            for (uint256 i; i < logs.length; ++i) {
                if (
                    logs[i].emitter != deployed.share || logs[i].topics.length == 0
                        || logs[i].topics[0] != eventSignature
                ) continue;

                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(asset)))));
                assertEq(abi.decode(logs[i].data, (address)), deployed.vault);
                found = true;
                break;
            }

            assertTrue(found);
            assertEq(FundShare(deployed.share).vault(address(asset)), deployed.vault);
        }

        function test_productionFundShareSupportsErc7575ShareInterface() public view {
            assertTrue(share.supportsInterface(FundConstants.ERC7575_SHARE_INTERFACE_ID));
            assertTrue(share.supportsInterface(FundConstants.ERC165_INTERFACE_ID));
            assertFalse(share.supportsInterface(0xffffffff));
        }

        function test_productionFundSharePermitSetsAllowance() public {
            uint256 ownerKey = 0xC0FFEE;
            address owner = vm.addr(ownerKey);
            uint256 value = 25e18;
            uint256 deadline = block.timestamp + 1 days;

            asset.mint(owner, 100e6);
            vm.startPrank(owner);
            asset.approve(address(vault), 100e6);
            vault.deposit(100e6, owner);
            vm.stopPrank();

            bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, operator, value, 0, deadline));
            bytes32 digest = keccak256(abi.encodePacked("\x19\x01", share.DOMAIN_SEPARATOR(), structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

            share.permit(owner, operator, value, deadline, v, r, s);

            assertEq(share.allowance(owner, operator), value);
            assertEq(share.nonces(owner), 1);
        }

        function test_productionFundShareRejectsUnauthorizedVaultOperations() public {
            bytes memory unauthorized = abi.encodeWithSelector(FundShare.UnauthorizedVault.selector, address(this));

            vm.expectRevert(unauthorized);
            share.mint(alice, 1);

            vm.expectRevert(unauthorized);
            share.burn(alice, 1);

            vm.expectRevert(unauthorized);
            share.escrowShares(alice, alice, 1);

            vm.expectRevert(unauthorized);
            share.returnEscrowedShares(alice, 1);
        }

        function test_adminCannotImmediatelyCreateUpgraderOrRewriteTargetPolicy() public {
            address newUpgrader = makeAddr("new-upgrader");
            bytes memory grantData =
                abi.encodeCall(manager.grantRole, (FundConstants.UPGRADER_ROLE, newUpgrader, uint32(0)));
            vm.expectRevert();
            manager.grantRole(FundConstants.UPGRADER_ROLE, newUpgrader, 0);

            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
            uint64 publicRole = manager.PUBLIC_ROLE();
            vm.expectRevert();
            manager.setTargetFunctionRole(address(vault), selectors, publicRole);

            manager.schedule(address(manager), grantData, 0);
            vm.warp(block.timestamp + FundConstants.CORE_UPGRADE_DELAY);
            manager.grantRole(FundConstants.UPGRADER_ROLE, newUpgrader, 0);
            (bool activeBeforeGrantDelay,) = manager.hasRole(FundConstants.UPGRADER_ROLE, newUpgrader);
            assertFalse(activeBeforeGrantDelay);

            vm.warp(block.timestamp + FundConstants.CORE_UPGRADE_DELAY);
            (bool activeAfterGrantDelay, uint32 executionDelay) =
                manager.hasRole(FundConstants.UPGRADER_ROLE, newUpgrader);
            assertTrue(activeAfterGrantDelay);
            assertEq(executionDelay, 0);
        }

        function test_create2DeploymentIdBindsCreatorAdminAndConfiguration() public view {
            FundFactory.CreateFundParams memory params = _defaultCreateParams(keccak256("front-run-resistant"));
            bytes32 aliceId = factory.computeDeploymentId(params, alice);
            bytes32 bobId = factory.computeDeploymentId(params, bob);
            assertNotEq(aliceId, bobId);

            params.roles.admin = bob;
            bytes32 differentAdminId = factory.computeDeploymentId(params, alice);
            assertNotEq(aliceId, differentAdminId);

            params.minimumIdleBps = 2_000;
            bytes32 differentConfigId = factory.computeDeploymentId(params, alice);
            assertNotEq(differentAdminId, differentConfigId);
        }

        function test_activeNavEnablesDepositsAndStaleNavDoesNotFreezeTransfers() public {
            _depositForAlice(100e6);
            assertEq(share.balanceOf(alice), 100e18);
            assertEq(vault.totalAssets(), 100e6);
            assertEq(vault.accountedIdleAssets(), 100e6);

            vm.roll(vault.activeNavWindow().validUntilBlock + 1);
            assertEq(vault.maxDeposit(alice), 0);

            vm.prank(alice);
            share.transfer(bob, 25e18);
            assertEq(share.balanceOf(bob), 25e18);
            assertEq(share.balanceOf(alice), 75e18);
        }

        function test_donationIsQuarantinedWithoutClosingEntry() public {
            _depositForAlice(100e6);
            asset.mint(address(this), 10e6);
            asset.transfer(address(vault), 10e6);

            assertEq(vault.unaccountedBalance(address(asset)), 10e6);
            assertEq(vault.maxDeposit(bob), type(uint256).max);

            asset.mint(bob, 100e6);
            vm.startPrank(bob);
            asset.approve(address(vault), 100e6);
            vault.deposit(100e6, bob);
            vm.stopPrank();

            assertEq(share.balanceOf(bob), 100e18);
            assertEq(vault.unaccountedBalance(address(asset)), 10e6);
            assertEq(vault.totalAssets(), 200e6);

            _submitNav(210e6, 210e6);
            assertEq(vault.unaccountedBalance(address(asset)), 0);
            assertEq(vault.totalAssets(), 210e6);
            assertEq(vault.accountedIdleAssets(), 210e6);
            assertEq(vault.maxDeposit(alice), type(uint256).max);
        }

        function test_navCommitRejectsPostSnapshotDonation() public {
            _depositForAlice(100e6);
            (
                uint64 reportNonce,
                FundTypes.ComponentReport[] memory reports,
                address[] memory reporters,
                bytes[] memory signatures,
                uint64 ignoredValidAfterBlock
            ) = _buildSignedNav(100e6, 100e6, 0);
            ignoredValidAfterBlock;

            asset.mint(address(vault), 1);
            vm.expectRevert(abi.encodeWithSelector(IFundAccounting.InvalidPositionState.selector, IDLE_COMPONENT));
            accounting.submitNav(reportNonce, reports, reporters, signatures);
        }

        function test_navCommitRejectsPostSnapshotDepositFlowNonce() public {
            _depositForAlice(100e6);
            (
                uint64 reportNonce,
                FundTypes.ComponentReport[] memory reports,
                address[] memory reporters,
                bytes[] memory signatures,
                uint64 ignoredValidAfterBlock
            ) = _buildSignedNav(100e6, 100e6, 0);
            ignoredValidAfterBlock;

            asset.mint(bob, 10e6);
            vm.startPrank(bob);
            asset.approve(address(vault), 10e6);
            vault.deposit(10e6, bob);
            vm.stopPrank();

            vm.expectRevert(abi.encodeWithSelector(IFundAccounting.InvalidPositionState.selector, IDLE_COMPONENT));
            accounting.submitNav(reportNonce, reports, reporters, signatures);
        }

        function test_unsignedBootstrapIsRejectedAfterIdleComponentActivation() public {
            FundFactory.RoleAccounts memory roles = FundFactory.RoleAccounts({
                admin: address(this),
                upgrader: address(this),
                accounting: address(this),
                allocator: address(this),
                processor: address(this),
                curator: address(this),
                guardian: address(this)
            });
            FundTypes.FeeConfig memory feeConfig = FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 0,
                maxManagementFeeBps: 0,
                maxPerformanceFeeBps: 0,
                maxAccrualInterval: 0,
                crystallizationPeriod: 0,
                feeRecipient: address(0)
            });
            FundFactory.FundDeployment memory deployed = factory.createFund(
                FundFactory.CreateFundParams({
                    implementationVersion: 1,
                    salt: keccak256("unsigned-bootstrap"),
                    name: "Bootstrap Fund",
                    symbol: "BOOT",
                    asset: asset,
                    minimumIdleBps: 0,
                    navActivationDelay: 1,
                    maxSnapshotAge: 20,
                    maxNavWindowLength: 20,
                    feeConfig: feeConfig,
                    roles: roles
                })
            );
            FundVault bootstrapVault = FundVault(deployed.vault);
            FundAccounting bootstrapAccounting = FundAccounting(deployed.accounting);
            AccessManager bootstrapManager = AccessManager(deployed.accessManager);

            vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
            bytes memory componentData =
                abi.encodeCall(bootstrapAccounting.setComponent, (IDLE_COMPONENT, address(0), uint64(1), true));
            bootstrapManager.schedule(address(bootstrapAccounting), componentData, 0);
            vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
            bootstrapAccounting.setComponent(IDLE_COMPONENT, address(0), 1, true);

            vm.roll(block.number + 2);
            uint64 snapshotBlock = uint64(block.number - 1);
            bytes32 snapshotHash = keccak256("unsigned-bootstrap-snapshot");
            vm.setBlockhash(snapshotBlock, snapshotHash);
            FundTypes.ComponentReport[] memory reports = new FundTypes.ComponentReport[](1);
            reports[0] = FundTypes.ComponentReport({
                fund: address(bootstrapVault),
                componentId: IDLE_COMPONENT,
                chainId: block.chainid,
                snapshotBlock: snapshotBlock,
                snapshotBlockHash: snapshotHash,
                validAfterBlock: uint64(block.number + 1),
                validUntilBlock: uint64(block.number + 11),
                reporterSetVersion: 0,
                componentNonce: bootstrapVault.fundFlowNonce(),
                positionStateHash: bootstrapVault.idleStateHash(),
                grossAssets: 0,
                liabilities: 0,
                liquidAccountingAssets: 0,
                baseExitCost: 0,
                dataHash: bytes32(0)
            });

            vm.expectRevert(abi.encodeWithSelector(IFundAccounting.InvalidReporterSet.selector, uint64(0)));
            bootstrapAccounting.submitNav(1, reports, new address[](0), new bytes[](0));
        }

        function test_donationDoesNotBlockRedemptionProcessing() public {
            _depositForAlice(100e6);
            asset.mint(address(vault), 1);
            vm.prank(alice);
            vault.requestRedeem(40e18, alice, alice);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 40e18, 0);
            flow.processRedeemBatch(1, 16);

            assertEq(vault.unaccountedBalance(address(asset)), 1);
            assertEq(vault.claimableRedeemRequest(0, alice), 40e18);
        }

        function test_requestBecomesClaimableOnlyAfterBoundedProcessing() public {
            _depositForAlice(100e6);

            vm.prank(alice);
            assertEq(vault.requestRedeem(40e18, alice, alice), FundConstants.ERC7540_REQUEST_ID);
            assertEq(share.balanceOf(address(vault)), 40e18);
            assertEq(vault.pendingRedeemRequest(0, alice), 40e18);
            assertEq(vault.maxRedeem(alice), 0);

            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 40e18, 0);
            assertEq(asset.balanceOf(vault.claimEscrow()), 40e6);
            assertEq(vault.reservedClaimAssets(), 40e6);
            assertEq(vault.totalAssets(), 60e6);

            (uint16 processed, bool complete) = flow.processRedeemBatch(1, 16);
            assertEq(processed, 1);
            assertTrue(complete);
            assertEq(share.totalSupply(), 60e18);
            assertEq(vault.pendingRedeemRequest(0, alice), 0);
            assertEq(vault.claimableRedeemRequest(0, alice), 40e18);
            assertEq(vault.maxDeposit(alice), type(uint256).max);

            uint256 aliceAssetsBefore = asset.balanceOf(alice);
            vm.prank(alice);
            assertEq(vault.withdraw(13e6, alice, alice), 13e18);
            assertEq(asset.balanceOf(alice) - aliceAssetsBefore, 13e6);
            assertEq(vault.maxWithdraw(alice), 27e6);
            assertEq(vault.maxRedeem(alice), 27e18);

            vm.prank(alice);
            assertEq(vault.redeem(27e18, alice, alice), 27e6);
            assertEq(asset.balanceOf(alice) - aliceAssetsBefore, 40e6);
            assertEq(asset.balanceOf(vault.claimEscrow()), 0);
            assertEq(vault.reservedClaimAssets(), 0);
            assertEq(vault.maxRedeem(alice), 0);
        }

        function test_operatorCannotRedirectOrCancelOwnerSharesToItself() public {
            _depositForAlice(100e6);
            vm.prank(alice);
            vault.setOperator(operator, true);

            vm.prank(operator);
            vm.expectRevert();
            vault.requestRedeem(40e18, operator, alice);

            vm.prank(operator);
            vault.requestRedeem(40e18, alice, alice);
            vm.prank(operator);
            vault.cancelRedeemRequest(alice, 40e18);

            assertEq(share.balanceOf(alice), 100e18);
            assertEq(share.balanceOf(operator), 0);
            assertEq(share.balanceOf(address(vault)), 0);
        }

        function test_allowanceRequesterCannotReceiveOwnersCancelledShares() public {
            _depositForAlice(100e6);
            vm.prank(alice);
            share.approve(operator, 40e18);

            vm.prank(operator);
            vault.requestRedeem(40e18, operator, alice);
            vm.prank(operator);
            vault.cancelPending(40e18);

            assertEq(share.balanceOf(alice), 100e18);
            assertEq(share.balanceOf(operator), 0);
        }

        function test_processorCannotChooseMarginalExitCost() public {
            _depositForAlice(100e6);
            _submitNavWithExitCost(100e6, 100e6, 10e6);
            vm.prank(alice);
            vault.requestRedeem(40e18, alice, alice);
            flow.sealRedeemBatch(1);

            vm.expectRevert(
                abi.encodeWithSelector(IFundFlowManager.InvalidMarginalExitCost.selector, uint256(4e6), uint256(40e6))
            );
            flow.startRedeemBatch(1, 40e18, 40e6);

            flow.startRedeemBatch(1, 40e18, 4e6);
            assertEq(asset.balanceOf(vault.claimEscrow()), 36e6);
        }

        function test_partialBatchRequiresFreshNavBeforeItsNextRound() public {
            _depositForAlice(100e6);
            vm.prank(alice);
            vault.requestRedeem(40e18, alice, alice);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 20e18, 0);
            flow.processRedeemBatch(1, 16);

            assertEq(vault.maxDeposit(alice), type(uint256).max);
            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchNotProcessable.selector, uint64(1)));
            flow.startRedeemBatch(1, 20e18, 0);

            _submitNav(80e6, 80e6);
            flow.startRedeemBatch(1, 20e18, 0);
            flow.processRedeemBatch(1, 16);
            assertEq(vault.claimableRedeemRequest(0, alice), 40e18);
            assertEq(vault.pendingRedeemRequest(0, alice), 0);
        }

        function test_partialBatchRemainderCanBeReleasedAndCancelled() public {
            _depositForAlice(100e6);
            vm.prank(alice);
            vault.requestRedeemWithMinAssets(40e18, alice, alice, 40e6);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 20e18, 0);
            flow.processRedeemBatch(1, 16);

            vm.prank(alice);
            vault.redeem(20e18, alice, alice);
            _submitNav(20e6, 80e6);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IFundFlowManager.MinimumAssetsNotMet.selector, alice, uint256(20e6), uint256(5e6)
                )
            );
            flow.startRedeemBatch(1, 20e18, 0);

            flow.releaseRedeemBatch(1);
            vm.prank(alice);
            vault.cancelPending(20e18);

            assertEq(flow.nextProcessBatchId(), 2);
            assertEq(vault.pendingRedeemRequest(0, alice), 0);
            assertEq(share.balanceOf(alice), 80e18);
        }

        function test_windowOutflowAccumulatesAcrossSuccessiveBatches() public {
            _scheduleAndCall(address(flow), abi.encodeCall(flow.setExitPolicy, (uint16(0), uint16(5_000))));
            _depositForAlice(100e6);
            uint64 reportNonce = vault.activeNavWindow().reportNonce;

            vm.prank(alice);
            vault.requestRedeem(30e18, alice, alice);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 30e18, 0);
            flow.processRedeemBatch(1, 16);

            (uint256 eligibleSupply, uint256 processedShares) = flow.windowOutflow(reportNonce);
            assertEq(eligibleSupply, 100e18);
            assertEq(processedShares, 30e18);

            vm.prank(alice);
            vault.requestRedeem(20e18, alice, alice);
            flow.sealRedeemBatch(2);
            flow.startRedeemBatch(2, 20e18, 0);
            flow.processRedeemBatch(2, 16);

            (eligibleSupply, processedShares) = flow.windowOutflow(reportNonce);
            assertEq(eligibleSupply, 100e18);
            assertEq(processedShares, 50e18);

            vm.prank(alice);
            vault.requestRedeem(1e18, alice, alice);
            flow.sealRedeemBatch(3);
            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchNotProcessable.selector, uint64(3)));
            flow.startRedeemBatch(3, 1e18, 0);
        }

        function test_windowOutflowCountsOnlyAfterPartialRoundCompletes() public {
            _scheduleAndCall(address(flow), abi.encodeCall(flow.setExitPolicy, (uint16(0), uint16(5_000))));
            _depositForAlice(60e6);
            _depositForBob(40e6);
            uint64 reportNonce = vault.activeNavWindow().reportNonce;

            vm.prank(alice);
            vault.requestRedeem(20e18, alice, alice);
            vm.prank(bob);
            vault.requestRedeem(20e18, bob, bob);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 40e18, 0);

            (, bool roundComplete) = flow.processRedeemBatch(1, 1);
            assertFalse(roundComplete);
            (uint256 eligibleSupply, uint256 processedShares) = flow.windowOutflow(reportNonce);
            assertEq(eligibleSupply, 100e18);
            assertEq(processedShares, 0);

            (, roundComplete) = flow.processRedeemBatch(1, 1);
            assertTrue(roundComplete);
            (eligibleSupply, processedShares) = flow.windowOutflow(reportNonce);
            assertEq(eligibleSupply, 100e18);
            assertEq(processedShares, 40e18);
        }

        function test_releaseAndCancelDoNotResetWindowOutflow() public {
            _scheduleAndCall(address(flow), abi.encodeCall(flow.setExitPolicy, (uint16(0), uint16(5_000))));
            _depositForAlice(100e6);
            uint64 reportNonce = vault.activeNavWindow().reportNonce;

            vm.prank(alice);
            vault.requestRedeem(40e18, alice, alice);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 20e18, 0);
            flow.processRedeemBatch(1, 16);
            vm.prank(alice);
            vault.redeem(20e18, alice, alice);

            flow.releaseRedeemBatch(1);
            vm.prank(alice);
            vault.cancelPending(20e18);

            (uint256 eligibleSupply, uint256 processedShares) = flow.windowOutflow(reportNonce);
            assertEq(eligibleSupply, 100e18);
            assertEq(processedShares, 20e18);

            vm.prank(alice);
            vault.requestRedeem(31e18, alice, alice);
            flow.sealRedeemBatch(2);
            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchNotProcessable.selector, uint64(2)));
            flow.startRedeemBatch(2, 31e18, 0);
        }

        function test_newNavReportResetsWindowOutflowWithNewEligibleSupply() public {
            _scheduleAndCall(address(flow), abi.encodeCall(flow.setExitPolicy, (uint16(0), uint16(5_000))));
            _depositForAlice(100e6);
            uint64 firstReportNonce = vault.activeNavWindow().reportNonce;

            vm.prank(alice);
            vault.requestRedeem(50e18, alice, alice);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 50e18, 0);
            flow.processRedeemBatch(1, 16);

            vm.prank(alice);
            vault.requestRedeem(1e18, alice, alice);
            flow.sealRedeemBatch(2);
            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchNotProcessable.selector, uint64(2)));
            flow.startRedeemBatch(2, 1e18, 0);

            _submitNav(50e6, 50e6);
            uint64 secondReportNonce = vault.activeNavWindow().reportNonce;
            assertGt(secondReportNonce, firstReportNonce);
            flow.startRedeemBatch(2, 1e18, 0);
            flow.processRedeemBatch(2, 16);

            (uint256 firstEligibleSupply, uint256 firstProcessedShares) = flow.windowOutflow(firstReportNonce);
            assertEq(firstEligibleSupply, 100e18);
            assertEq(firstProcessedShares, 50e18);
            (uint256 secondEligibleSupply, uint256 secondProcessedShares) = flow.windowOutflow(secondReportNonce);
            assertEq(secondEligibleSupply, 50e18);
            assertEq(secondProcessedShares, 1e18);
        }

        function test_minimumAssetsIsValidatedBeforeFundsAreCommitted() public {
            _depositForAlice(100e6);
            vm.prank(alice);
            vault.requestRedeemWithMinAssets(40e18, alice, alice, 41e6);
            flow.sealRedeemBatch(1);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IFundFlowManager.MinimumAssetsNotMet.selector, alice, uint256(41e6), uint256(40e6)
                )
            );
            flow.startRedeemBatch(1, 40e18, 0);

            assertEq(asset.balanceOf(vault.claimEscrow()), 0);
            assertEq(vault.reservedClaimAssets(), 0);
            assertEq(vault.totalAssets(), 100e6);
            assertEq(vault.pendingRedeemRequest(0, alice), 40e18);
        }

        function test_strategyCapsIdleFloorAndRoundTripAreEnforced() public {
            _depositForAlice(100e6);
            ProductionStrategyAdapter adapter = new ProductionStrategyAdapter(address(vault), address(asset));
            ProductionPositionValuator valuator = new ProductionPositionValuator();
            _scheduleAndCall(
                address(accounting),
                abi.encodeCall(
                    accounting.setComponent,
                    (accounting.strategyComponentId(address(adapter)), address(valuator), uint64(1), true)
                )
            );
            FundTypes.StrategyConfig memory config = FundTypes.StrategyConfig({
                active: true,
                maxAllocationBps: 5_000,
                maxLossBps: 100,
                cooldown: 0,
                interfaceVersion: 1,
                valuator: address(valuator),
                absoluteCap: 50e6
            });
            _scheduleAndCall(address(strategy), abi.encodeCall(strategy.setStrategyConfig, (address(adapter), config)));

            strategy.allocate(address(adapter), address(asset), 40e6, "");
            assertEq(asset.balanceOf(address(adapter)), 40e6);
            assertEq(vault.accountedIdleAssets(), 60e6);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 40e6);
            assertEq(vault.maxDeposit(alice), 0);

            vm.expectRevert(abi.encodeWithSelector(IStrategyManager.AllocationCapExceeded.selector, address(adapter)));
            strategy.allocate(address(adapter), address(asset), 11e6, "");

            asset.mint(address(vault), 1);
            strategy.allocate(address(adapter), address(asset), 1, "");
            assertEq(vault.unaccountedBalance(address(asset)), 1);

            assertEq(strategy.deallocate(address(adapter), 15e6, 15e6, ""), 15e6);
            assertEq(asset.balanceOf(address(adapter)), 25e6 + 1);
            assertEq(vault.accountedIdleAssets(), 75e6 - 1);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 25e6 + 1);
        }

        function test_strategyInKindExitSynchronizesNonceAndAccountingHash() public {
            _depositForAlice(100e6);
            (ProductionStrategyAdapter adapter,) = _configureProductionStrategy(50e6, 10_000);
            strategy.allocate(address(adapter), address(asset), 40e6, "");
            bytes32 componentId = accounting.strategyComponentId(address(adapter));

            FundAccounting.ComponentState memory afterAllocation = accounting.componentState(componentId);
            assertEq(afterAllocation.nonce, 1);
            assertEq(afterAllocation.positionStateHash, adapter.positionStateHash());
            bytes32 positionsBefore = strategy.positionsHash();

            address rawEscrow = address(new ProductionAssetEscrow());
            address emergencyEscrow = address(new ProductionAssetEscrow());
            _scheduleAndCall(address(flow), abi.encodeCall(flow.setStrategyExitEscrows, (rawEscrow, emergencyEscrow)));
            bytes32 batchId = keccak256("production-in-kind-batch");

            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.StrategyExitBatchInvalid.selector, batchId));
            strategy.deallocateInKind(batchId, address(adapter), 0.5e18, "");

            _scheduleAndCall(
                address(flow),
                abi.encodeCall(
                    flow.authorizeStrategyInKindBatch,
                    (batchId, address(adapter), 0.5e18, uint64(block.timestamp + 7 days))
                )
            );
            vm.expectRevert(FundFlowManager.InvalidAddress.selector);
            flow.consumeStrategyInKindBatch(batchId, address(adapter), 0.5e18);
            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.StrategyExitBatchInvalid.selector, batchId));
            strategy.deallocateInKind(batchId, address(adapter), 0.4e18, "");

            (address[] memory assets, uint256[] memory amounts) =
                strategy.deallocateInKind(batchId, address(adapter), 0.5e18, "");

            assertEq(assets.length, 1);
            assertEq(assets[0], address(asset));
            assertEq(amounts[0], 20e6);
            assertEq(asset.balanceOf(rawEscrow), 20e6);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 20e6);
            assertEq(strategy.positionNonce(address(adapter)), 2);
            assertNotEq(strategy.positionsHash(), positionsBefore);
            FundAccounting.ComponentState memory afterExit = accounting.componentState(componentId);
            assertEq(afterExit.nonce, 2);
            assertEq(afterExit.positionStateHash, adapter.positionStateHash());
            assertEq(vault.maxDeposit(alice), 0);

            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.StrategyExitBatchInvalid.selector, batchId));
            strategy.deallocateInKind(batchId, address(adapter), 0.5e18, "");

            bytes32 expiredBatchId = keccak256("expired-production-in-kind-batch");
            _scheduleAndCall(
                address(flow),
                abi.encodeCall(
                    flow.authorizeStrategyInKindBatch,
                    (expiredBatchId, address(adapter), 0.5e18, uint64(block.timestamp + 3 days))
                )
            );
            vm.warp(block.timestamp + 2 days + 1);
            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.StrategyExitBatchInvalid.selector, expiredBatchId));
            strategy.deallocateInKind(expiredBatchId, address(adapter), 0.5e18, "");
        }

        function test_strategyEmergencyExitSynchronizesHashAndDisablesAllocation() public {
            _depositForAlice(100e6);
            (ProductionStrategyAdapter adapter,) = _configureProductionStrategy(50e6, 10_000);
            strategy.allocate(address(adapter), address(asset), 40e6, "");
            bytes32 componentId = accounting.strategyComponentId(address(adapter));
            address inKindEscrow = address(new ProductionAssetEscrow());
            address emergencyEscrow = address(new ProductionAssetEscrow());
            _scheduleAndCall(
                address(flow), abi.encodeCall(flow.setStrategyExitEscrows, (inKindEscrow, emergencyEscrow))
            );

            (address[] memory assets, uint256[] memory amounts) = strategy.emergencyExit(address(adapter), "");

            assertEq(assets.length, 1);
            assertEq(assets[0], address(asset));
            assertEq(amounts[0], 40e6);
            assertEq(asset.balanceOf(emergencyEscrow), 40e6);
            assertEq(asset.balanceOf(inKindEscrow), 0);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 0);
            assertFalse(strategy.strategyConfig(address(adapter)).active);
            assertEq(strategy.positionNonce(address(adapter)), 2);
            FundAccounting.ComponentState memory afterExit = accounting.componentState(componentId);
            assertEq(afterExit.nonce, 2);
            assertEq(afterExit.positionStateHash, adapter.positionStateHash());

            vm.expectRevert(abi.encodeWithSelector(IStrategyManager.AdapterNotActive.selector, address(adapter)));
            strategy.allocate(address(adapter), address(asset), 1, "");
        }

        function test_performanceFeeMintsSharesWithoutMovingAssets() public {
            _depositForAlice(100e6);
            FundTypes.FeeConfig memory config = FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 1_000,
                maxManagementFeeBps: 200,
                maxPerformanceFeeBps: 2_000,
                maxAccrualInterval: 30 days,
                crystallizationPeriod: 1 days,
                feeRecipient: feeRecipient
            });
            _scheduleAndCall(address(accounting), abi.encodeCall(accounting.setFeeConfig, (config)));
            uint256 rawAssetsBefore = asset.balanceOf(address(vault));

            _submitNav(110e6, 100e6);

            assertGt(share.balanceOf(feeRecipient), 0);
            assertEq(asset.balanceOf(address(vault)), rawAssetsBefore);
            assertEq(vault.totalAssets(), 110e6);
            uint256 postFeePps = Math.mulDiv(110e6, FundConstants.SHARE_SCALE, share.totalSupply());
            assertEq(accounting.feeState().highWaterMark, postFeePps);
            assertLt(postFeePps, 1.1e6);
        }

        function test_managementFeeCrystallizesBeforeRedemptionProcessing() public {
            _depositForAlice(100e6);
            FundTypes.FeeConfig memory config = FundTypes.FeeConfig({
                managementFeeWad: uint64(0.02e18),
                performanceFeeBps: 0,
                maxManagementFeeBps: 200,
                maxPerformanceFeeBps: 0,
                maxAccrualInterval: 365 days,
                crystallizationPeriod: 0,
                feeRecipient: feeRecipient
            });
            _scheduleAndCall(address(accounting), abi.encodeCall(accounting.setFeeConfig, (config)));
            vm.warp(block.timestamp + 365 days);

            vm.prank(alice);
            vault.requestRedeem(40e18, alice, alice);
            flow.sealRedeemBatch(1);
            flow.startRedeemBatch(1, 40e18, 0);

            assertGt(share.balanceOf(feeRecipient), 0);
            assertLt(asset.balanceOf(vault.claimEscrow()), 40e6);
        }

        function test_feeConfigCheckpointsOldRateAndRecipient() public {
            _depositForAlice(100e6);
            FundTypes.FeeConfig memory oldConfig = FundTypes.FeeConfig({
                managementFeeWad: uint64(0.01e18),
                performanceFeeBps: 0,
                maxManagementFeeBps: 200,
                maxPerformanceFeeBps: 0,
                maxAccrualInterval: 365 days,
                crystallizationPeriod: 0,
                feeRecipient: feeRecipient
            });
            _scheduleAndCall(address(accounting), abi.encodeCall(accounting.setFeeConfig, (oldConfig)));
            vm.warp(block.timestamp + 100 days);

            address newRecipient = makeAddr("new-fee-recipient");
            FundTypes.FeeConfig memory newConfig = oldConfig;
            newConfig.managementFeeWad = uint64(0.02e18);
            newConfig.feeRecipient = newRecipient;
            _scheduleAndCall(address(accounting), abi.encodeCall(accounting.setFeeConfig, (newConfig)));

            assertGt(share.balanceOf(feeRecipient), 0);
            assertEq(share.balanceOf(newRecipient), 0);

            vm.warp(block.timestamp + 30 days);
            asset.mint(bob, 1e6);
            vm.startPrank(bob);
            asset.approve(address(vault), 1e6);
            vault.deposit(1e6, bob);
            vm.stopPrank();
            assertGt(share.balanceOf(newRecipient), 0);
        }

        function test_depositRejectsPositiveAssetsWhenVirtualConversionRoundsToZero() public {
            _depositForAlice(1e6);
            _submitNav(2e18, 1e6);
            asset.mint(bob, 1);
            vm.startPrank(bob);
            asset.approve(address(vault), 1);
            vm.expectRevert(abi.encodeWithSelector(FundVault.ZeroSharesDeposit.selector, uint256(1)));
            vault.deposit(1, bob);
            vm.stopPrank();
        }

        function test_highWaterMarkDoesNotResetAfterAReportedLoss() public {
            _depositForAlice(100e6);
            FundTypes.FeeConfig memory config = FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 1_000,
                maxManagementFeeBps: 200,
                maxPerformanceFeeBps: 2_000,
                maxAccrualInterval: 30 days,
                crystallizationPeriod: 1 days,
                feeRecipient: feeRecipient
            });
            _scheduleAndCall(address(accounting), abi.encodeCall(accounting.setFeeConfig, (config)));

            _submitNav(90e6, 100e6);
            assertEq(accounting.feeState().highWaterMark, 1e6);
            _submitNav(100e6, 100e6);

            assertEq(share.balanceOf(feeRecipient), 0);
            assertEq(accounting.feeState().highWaterMark, 1e6);
        }

        function test_zeroNavClosesEntryAndProcessingButSharesRemainTransferable() public {
            _depositForAlice(100e6);
            _submitNav(0, 100e6);
            assertEq(vault.maxDeposit(alice), 0);

            vm.prank(alice);
            share.transfer(bob, 10e18);
            assertEq(share.balanceOf(bob), 10e18);

            vm.prank(alice);
            vault.requestRedeem(40e18, alice, alice);
            flow.sealRedeemBatch(1);
            vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchNotProcessable.selector, uint64(1)));
            flow.startRedeemBatch(1, 40e18, 0);
        }

        function test_guardianPauseIsImmediateAndCuratorResumeRequiresDelay() public {
            vault.pauseDeposits();
            assertTrue(vault.depositsPaused());

            bytes memory data = abi.encodeCall(vault.resumeDeposits, ());
            vm.expectRevert();
            vault.resumeDeposits();

            manager.schedule(address(vault), data, 0);
            vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
            vault.resumeDeposits();
            assertFalse(vault.depositsPaused());
        }

        function test_scheduledUupsUpgradePreservesProductionProxyState() public {
            _depositForAlice(100e6);
            FundVault nextImplementation = new FundVault();
            bytes memory data = abi.encodeWithSelector(
                bytes4(keccak256("upgradeToAndCall(address,bytes)")), address(nextImplementation), bytes("")
            );

            vm.expectRevert();
            vault.upgradeToAndCall(address(nextImplementation), "");

            manager.schedule(address(vault), data, 0);
            vm.warp(block.timestamp + FundConstants.CORE_UPGRADE_DELAY);
            vault.upgradeToAndCall(address(nextImplementation), "");

            assertEq(
                address(uint160(uint256(vm.load(address(vault), ERC1967_IMPLEMENTATION_SLOT)))),
                address(nextImplementation)
            );
            assertEq(share.balanceOf(alice), 100e18);
            assertEq(vault.totalAssets(), 100e6);
            assertEq(vault.accounting(), address(accounting));
            assertEq(vault.flowManager(), address(flow));
            assertEq(vault.strategyManager(), address(strategy));
        }

        function _scheduleAndConfigureNavSources() private {
            vm.warp(block.timestamp + FundConstants.CORE_UPGRADE_DELAY);
            address[] memory reporters = new address[](2);
            reporters[0] = vm.addr(REPORTER_ONE_KEY);
            reporters[1] = vm.addr(REPORTER_TWO_KEY);
            bytes memory reporterData = abi.encodeCall(accounting.setReporterSet, (reporters, uint16(2), uint64(1)));
            bytes memory componentData =
                abi.encodeCall(accounting.setComponent, (IDLE_COMPONENT, address(0), uint64(1), true));
            manager.schedule(address(accounting), reporterData, 0);
            manager.schedule(address(accounting), componentData, 0);
            vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
            accounting.setReporterSet(reporters, 2, 1);
            accounting.setComponent(IDLE_COMPONENT, address(0), 1, true);
            vm.warp(block.timestamp + 1 days);
        }

        function _configureProductionStrategy(uint256 absoluteCap, uint16 maxLossBps)
            private
            returns (ProductionStrategyAdapter adapter, ProductionPositionValuator valuator)
        {
            adapter = new ProductionStrategyAdapter(address(vault), address(asset));
            valuator = new ProductionPositionValuator();
            _scheduleAndCall(
                address(accounting),
                abi.encodeCall(
                    accounting.setComponent,
                    (accounting.strategyComponentId(address(adapter)), address(valuator), uint64(1), true)
                )
            );
            FundTypes.StrategyConfig memory config = FundTypes.StrategyConfig({
                active: true,
                maxAllocationBps: 5_000,
                maxLossBps: maxLossBps,
                cooldown: 0,
                interfaceVersion: 1,
                valuator: address(valuator),
                absoluteCap: absoluteCap
            });
            _scheduleAndCall(address(strategy), abi.encodeCall(strategy.setStrategyConfig, (address(adapter), config)));
        }

        function _scheduleAndCall(address target, bytes memory data) private {
            manager.schedule(target, data, 0);
            vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
            (bool success, bytes memory result) = target.call(data);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }

        function _depositForAlice(uint256 assets) private {
            asset.mint(alice, assets);
            vm.startPrank(alice);
            asset.approve(address(vault), assets);
            vault.deposit(assets, alice);
            vm.stopPrank();
        }

        function _depositForBob(uint256 assets) private {
            asset.mint(bob, assets);
            vm.startPrank(bob);
            asset.approve(address(vault), assets);
            vault.deposit(assets, bob);
            vm.stopPrank();
        }

        function _submitNav(uint256 grossAssets, uint256 liquidAssets) private {
            _submitNavWithExitCost(grossAssets, liquidAssets, 0);
        }

        function _submitNavWithExitCost(uint256 grossAssets, uint256 liquidAssets, uint256 baseExitCost) private {
            (
                uint64 reportNonce,
                FundTypes.ComponentReport[] memory reports,
                address[] memory reporters,
                bytes[] memory signatures,
                uint64 validAfterBlock
            ) = _buildSignedNav(grossAssets, liquidAssets, baseExitCost);
            accounting.submitNav(reportNonce, reports, reporters, signatures);
            vm.roll(validAfterBlock);
        }

        function _buildSignedNav(uint256 grossAssets, uint256 liquidAssets, uint256 baseExitCost)
            private
            returns (
                uint64 reportNonce,
                FundTypes.ComponentReport[] memory reports,
                address[] memory reporters,
                bytes[] memory signatures,
                uint64 validAfterBlock
            )
        {
            vm.roll(block.number + 2);
            uint64 snapshotBlock = uint64(block.number - 1);
            bytes32 snapshotHash = keccak256(abi.encode("snapshot", snapshotBlock));
            vm.setBlockhash(snapshotBlock, snapshotHash);
            validAfterBlock = uint64(block.number + 1);
            uint64 validUntilBlock = validAfterBlock + 10;
            reportNonce = accounting.lastReportNonce() + 1;

            reports = new FundTypes.ComponentReport[](1);
            reports[0] = FundTypes.ComponentReport({
                fund: address(vault),
                componentId: IDLE_COMPONENT,
                chainId: block.chainid,
                snapshotBlock: snapshotBlock,
                snapshotBlockHash: snapshotHash,
                validAfterBlock: validAfterBlock,
                validUntilBlock: validUntilBlock,
                reporterSetVersion: 1,
                componentNonce: vault.fundFlowNonce(),
                positionStateHash: vault.idleStateHash(),
                grossAssets: grossAssets,
                liabilities: 0,
                liquidAccountingAssets: liquidAssets,
                baseExitCost: baseExitCost,
                dataHash: keccak256(abi.encode(grossAssets, liquidAssets))
            });

            bytes32 digest = accounting.signatureDigest(reportNonce, reports);
            reporters = new address[](2);
            signatures = new bytes[](2);
            reporters[0] = vm.addr(REPORTER_ONE_KEY);
            reporters[1] = vm.addr(REPORTER_TWO_KEY);
            signatures[0] = _signature(REPORTER_ONE_KEY, digest);
            signatures[1] = _signature(REPORTER_TWO_KEY, digest);
        }

        function _signature(uint256 key, bytes32 digest) private pure returns (bytes memory) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
            return abi.encodePacked(r, s, v);
        }

        function _defaultCreateParams(bytes32 salt) private view returns (FundFactory.CreateFundParams memory params) {
            params.implementationVersion = 1;
            params.salt = salt;
            params.name = "Predictable Fund";
            params.symbol = "PRED";
            params.asset = asset;
            params.minimumIdleBps = 1_000;
            params.navActivationDelay = 1;
            params.maxSnapshotAge = 20;
            params.maxNavWindowLength = 20;
            params.feeConfig = FundTypes.FeeConfig({
                managementFeeWad: 0,
                performanceFeeBps: 0,
                maxManagementFeeBps: 0,
                maxPerformanceFeeBps: 0,
                maxAccrualInterval: 0,
                crystallizationPeriod: 0,
                feeRecipient: address(0)
            });
            params.roles = FundFactory.RoleAccounts({
                admin: address(this),
                upgrader: address(this),
                accounting: address(this),
                allocator: address(this),
                processor: address(this),
                curator: address(this),
                guardian: address(this)
            });
        }
    }
