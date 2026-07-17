// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";

contract FundCoreProductionHandler is Test {
    bytes32 internal constant IDLE_COMPONENT = keccak256("IDLE_ACCOUNTING_ASSET");
    uint256 internal constant REPORTER_ONE_KEY = 0xA11CE;
    uint256 internal constant REPORTER_TWO_KEY = 0xB0B;

    MockERC20 public immutable asset;
    FundVault public immutable vault;
    FundAccounting public immutable accounting;
    FundFlowManager public immutable flow;
    address public immutable alice;
    address public immutable bob;

    constructor(
        MockERC20 asset_,
        FundVault vault_,
        FundAccounting accounting_,
        FundFlowManager flow_,
        address alice_,
        address bob_
    ) {
        asset = asset_;
        vault = vault_;
        accounting = accounting_;
        flow = flow_;
        alice = alice_;
        bob = bob_;
    }

    function request(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = _actor(actorSeed);
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0 || vault.pendingRedeemRequest(0, actor) != 0) return;

        vm.prank(actor);
        vault.requestRedeem(bound(sharesSeed, 1, balance), actor, actor);
    }

    function process(uint256 sharesSeed) external {
        uint64 batchId = flow.nextProcessBatchId();
        FundTypes.RedemptionBatch memory redeemBatch = flow.batch(batchId);
        if (!redeemBatch.isSealed) {
            if (batchId != flow.openBatchId() || redeemBatch.totalPendingShares == 0) return;
            flow.sealRedeemBatch(batchId);
            redeemBatch = flow.batch(batchId);
        }
        if (redeemBatch.isReleased) return;

        if (!redeemBatch.processing) {
            _synchronizeNav();
            redeemBatch = flow.batch(batchId);
            uint256 shares = bound(sharesSeed, 1, redeemBatch.totalPendingShares);
            flow.startRedeemBatch(batchId, shares, 0);
        }
        flow.processRedeemBatch(batchId, FundConstants.MAX_PROCESSING_PAGE);
    }

    function claim(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = _actor(actorSeed);
        uint256 claimable = vault.maxRedeem(actor);
        if (claimable == 0) return;

        vm.prank(actor);
        vault.redeem(bound(sharesSeed, 1, claimable), actor, actor);
    }

    function cancel(uint256 actorSeed, uint256 sharesSeed) external {
        address actor = _actor(actorSeed);
        uint256 pending = vault.pendingRedeemRequest(0, actor);
        if (pending == 0 || !flow.isCancellationAvailable(actor)) return;

        vm.prank(actor);
        vault.cancelPending(bound(sharesSeed, 1, pending));
    }

    function transferShares(uint256 actorSeed, uint256 sharesSeed) external {
        address from = _actor(actorSeed);
        address to = from == alice ? bob : alice;
        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;

        vm.prank(from);
        vault.transfer(to, bound(sharesSeed, 1, balance));
    }

    function deposit(uint256 actorSeed, uint96 assetsSeed) external {
        address actor = _actor(actorSeed);
        if (vault.maxDeposit(actor) == 0) return;
        uint256 assets = bound(uint256(assetsSeed), 1, 10e6);
        asset.mint(actor, assets);
        vm.prank(actor);
        vault.deposit(assets, actor);
    }

    function donate(uint96 assetsSeed) external {
        asset.mint(address(vault), bound(uint256(assetsSeed), 1, 10e6));
    }

    function synchronizeDonation() external {
        if (vault.unaccountedBalance(address(asset)) == 0) return;
        _synchronizeNav();
    }

    function expireNav() external {
        FundTypes.NavCommit memory nav = vault.activeNavWindow();
        if (block.number <= nav.validUntilBlock) vm.roll(nav.validUntilBlock + 1);
    }

    function _synchronizeNav() private {
        vm.roll(block.number + 2);
        uint64 snapshotBlock = uint64(block.number - 1);
        bytes32 snapshotHash = keccak256(abi.encode("invariant-snapshot", snapshotBlock));
        vm.setBlockhash(snapshotBlock, snapshotHash);
        uint64 validAfterBlock = uint64(block.number + 1);
        uint64 reportNonce = accounting.lastReportNonce() + 1;
        uint256 rawAssets = asset.balanceOf(address(vault));

        FundTypes.ComponentReport[] memory reports = new FundTypes.ComponentReport[](1);
        reports[0] = FundTypes.ComponentReport({
            fund: address(vault),
            componentId: IDLE_COMPONENT,
            chainId: block.chainid,
            snapshotBlock: snapshotBlock,
            snapshotBlockHash: snapshotHash,
            validAfterBlock: validAfterBlock,
            validUntilBlock: validAfterBlock + 10,
            reporterSetVersion: 1,
            componentNonce: vault.fundFlowNonce(),
            positionStateHash: vault.idleStateHash(),
            grossAssets: rawAssets,
            liabilities: 0,
            liquidAccountingAssets: rawAssets,
            baseExitCost: 0,
            dataHash: keccak256(abi.encode(rawAssets))
        });

        bytes32 digest = accounting.signatureDigest(reportNonce, reports);
        address[] memory reporters = new address[](2);
        bytes[] memory signatures = new bytes[](2);
        reporters[0] = vm.addr(REPORTER_ONE_KEY);
        reporters[1] = vm.addr(REPORTER_TWO_KEY);
        signatures[0] = _signature(REPORTER_ONE_KEY, digest);
        signatures[1] = _signature(REPORTER_TWO_KEY, digest);
        accounting.submitNav(reportNonce, reports, reporters, signatures);
        vm.roll(validAfterBlock);
    }

    function _actor(uint256 actorSeed) private view returns (address) {
        return actorSeed % 2 == 0 ? alice : bob;
    }

    function _signature(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract FundCoreProductionInvariantTest is StdInvariant, Test {
    bytes32 internal constant IDLE_COMPONENT = keccak256("IDLE_ACCOUNTING_ASSET");
    uint256 internal constant REPORTER_ONE_KEY = 0xA11CE;
    uint256 internal constant REPORTER_TWO_KEY = 0xB0B;

    MockERC20 internal asset;
    FundVault internal vault;
    FundAccounting internal accounting;
    FundFlowManager internal flow;
    AccessManager internal manager;
    FundCoreProductionHandler internal handler;
    address internal alice = makeAddr("invariant-alice");
    address internal bob = makeAddr("invariant-bob");

    function setUp() public {
        asset = new MockERC20("Invariant USDC", "iUSDC", 6);
        FundFactory factory = new FundFactory(address(this));
        factory.registerImplementationVersion(
            1,
            FundFactory.ImplementationSet({
                vault: address(new FundVault()),
                accounting: address(new FundAccounting()),
                flowManager: address(new FundFlowManager()),
                strategyManager: address(new StrategyManager()),
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
            maxManagementFeeBps: 0,
            maxPerformanceFeeBps: 0,
            maxAccrualInterval: 0,
            crystallizationPeriod: 0,
            feeRecipient: address(0)
        });
        FundFactory.FundDeployment memory deployed = factory.createFund(
            FundFactory.CreateFundParams({
                implementationVersion: 1,
                salt: keccak256("production-invariant"),
                name: "Invariant Fund",
                symbol: "IFUND",
                asset: asset,
                minimumIdleBps: 0,
                navActivationDelay: 1,
                maxSnapshotAge: 20,
                maxNavWindowLength: 20,
                feeConfig: feeConfig,
                roles: roles
            })
        );
        vault = FundVault(deployed.vault);
        accounting = FundAccounting(deployed.accounting);
        flow = FundFlowManager(deployed.flowManager);
        manager = AccessManager(deployed.accessManager);

        _configureNavSources();
        _submitInitialNav();
        _seedHolder(alice);
        _seedHolder(bob);

        handler = new FundCoreProductionHandler(asset, vault, accounting, flow, alice, bob);
        bytes memory accountingGrant =
            abi.encodeCall(manager.grantRole, (FundConstants.ACCOUNTING_ROLE, address(handler), uint32(0)));
        bytes memory processorGrant =
            abi.encodeCall(manager.grantRole, (FundConstants.PROCESSOR_ROLE, address(handler), uint32(0)));
        manager.schedule(address(manager), accountingGrant, 0);
        manager.schedule(address(manager), processorGrant, 0);
        vm.warp(block.timestamp + FundConstants.CORE_UPGRADE_DELAY);
        manager.grantRole(FundConstants.ACCOUNTING_ROLE, address(handler), 0);
        manager.grantRole(FundConstants.PROCESSOR_ROLE, address(handler), 0);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.process.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.transferShares.selector;
        selectors[5] = handler.deposit.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.synchronizeDonation.selector;
        selectors[8] = handler.expireNav.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_shareSupplyAndPendingEscrowReconcile() public view {
        assertEq(vault.totalSupply(), vault.balanceOf(alice) + vault.balanceOf(bob) + vault.balanceOf(address(vault)));
        assertEq(vault.balanceOf(address(vault)), flow.totalPendingShares());
        assertEq(flow.totalPendingShares(), vault.pendingRedeemRequest(0, alice) + vault.pendingRedeemRequest(0, bob));
    }

    function invariant_claimSharesAndAssetsReconcile() public view {
        assertEq(
            flow.totalClaimableShares(), vault.claimableRedeemRequest(0, alice) + vault.claimableRedeemRequest(0, bob)
        );
        uint256 controllerAssets = flow.claimableAssets(alice) + flow.claimableAssets(bob);
        assertEq(flow.totalReservedAssets(), controllerAssets);
        assertEq(vault.reservedClaimAssets(), controllerAssets);
        assertEq(asset.balanceOf(vault.claimEscrow()), controllerAssets);
    }

    function invariant_navExcludesClaimsAndUnsynchronizedDonations() public view {
        uint256 unaccounted = vault.unaccountedBalance(address(asset));
        assertEq(asset.balanceOf(address(vault)), vault.accountedIdleAssets() + unaccounted);
        assertEq(vault.totalAssets(), vault.accountedIdleAssets());
        assertEq(
            asset.balanceOf(address(vault)) + asset.balanceOf(vault.claimEscrow()),
            vault.totalAssets() + vault.reservedClaimAssets() + unaccounted
        );
    }

    function invariant_crossProxyLockIsAlwaysReleased() public view {
        assertEq(vault.executionLockOwner(), address(0));
    }

    function _configureNavSources() private {
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

    function _submitInitialNav() private {
        vm.roll(100);
        bytes32 snapshotHash = keccak256("invariant-initial-snapshot");
        vm.setBlockhash(99, snapshotHash);
        FundTypes.ComponentReport[] memory reports = new FundTypes.ComponentReport[](1);
        reports[0] = FundTypes.ComponentReport({
            fund: address(vault),
            componentId: IDLE_COMPONENT,
            chainId: block.chainid,
            snapshotBlock: 99,
            snapshotBlockHash: snapshotHash,
            validAfterBlock: 101,
            validUntilBlock: 111,
            reporterSetVersion: 1,
            componentNonce: vault.fundFlowNonce(),
            positionStateHash: vault.idleStateHash(),
            grossAssets: 0,
            liabilities: 0,
            liquidAccountingAssets: 0,
            baseExitCost: 0,
            dataHash: keccak256("initial-nav")
        });
        bytes32 digest = accounting.signatureDigest(1, reports);
        address[] memory reporters = new address[](2);
        bytes[] memory signatures = new bytes[](2);
        reporters[0] = vm.addr(REPORTER_ONE_KEY);
        reporters[1] = vm.addr(REPORTER_TWO_KEY);
        signatures[0] = _signature(REPORTER_ONE_KEY, digest);
        signatures[1] = _signature(REPORTER_TWO_KEY, digest);
        accounting.submitNav(1, reports, reporters, signatures);
        vm.roll(101);
    }

    function _seedHolder(address holder) private {
        asset.mint(holder, 1_000e6);
        vm.startPrank(holder);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, holder);
        vm.stopPrank();
    }

    function _signature(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
