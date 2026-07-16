// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {IFundAccounting} from "../../src/fund/interfaces/IFundAccounting.sol";

contract NavReportHarness {
    using MessageHashUtils for bytes32;

    error DuplicateReporter(address reporter);
    error InvalidChain(uint256 chainId);
    error InvalidFund(address fund);
    error InvalidReportWindow();
    error InvalidReporter(address reporter);
    error InvalidSignatureCount();
    error LiabilityExceedsAssets(bytes32 componentId);

    struct ComponentConfig {
        bool active;
        uint64 nonce;
        bytes32 positionStateHash;
    }

    address public immutable expectedFund;
    uint64 public immutable activationDelay;
    uint64 public immutable maxSnapshotAge;
    uint64 public immutable maxWindowLength;

    uint64 public reporterSetVersion;
    uint16 public reporterThreshold;
    bytes32[] public activeComponents;
    mapping(bytes32 componentId => ComponentConfig config) public componentConfig;
    mapping(address reporter => bool active) public isReporter;

    constructor(address fund_, uint64 activationDelay_, uint64 maxSnapshotAge_, uint64 maxWindowLength_) {
        expectedFund = fund_;
        activationDelay = activationDelay_;
        maxSnapshotAge = maxSnapshotAge_;
        maxWindowLength = maxWindowLength_;
    }

    function configureComponent(bytes32 componentId, uint64 nonce, bytes32 positionStateHash) external {
        if (!componentConfig[componentId].active) activeComponents.push(componentId);
        componentConfig[componentId] =
            ComponentConfig({active: true, nonce: nonce, positionStateHash: positionStateHash});
    }

    function configureReporters(address[] calldata reporters, uint16 threshold, uint64 version) external {
        for (uint256 i; i < reporters.length; ++i) {
            isReporter[reporters[i]] = true;
        }
        reporterThreshold = threshold;
        reporterSetVersion = version;
    }

    function reportHash(FundTypes.ComponentReport[] calldata reports) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, reporterSetVersion, reports));
    }

    function signatureDigest(FundTypes.ComponentReport[] calldata reports) external view returns (bytes32) {
        return reportHash(reports).toEthSignedMessageHash();
    }

    function submitNav(
        FundTypes.ComponentReport[] calldata reports,
        address[] calldata reporters,
        bytes[] calldata signatures
    ) external view returns (FundTypes.NavCommit memory nav) {
        if (reports.length != activeComponents.length) {
            revert IFundAccounting.IncompleteComponentSet();
        }
        if (reporters.length != signatures.length || reporters.length < reporterThreshold) {
            revert InvalidSignatureCount();
        }

        bytes32 acceptedReportHash = reportHash(reports);
        bytes32 digest = acceptedReportHash.toEthSignedMessageHash();
        _validateReporters(reporters, signatures, digest);

        uint64 snapshotBlock = reports[0].snapshotBlock;
        uint64 validAfterBlock = reports[0].validAfterBlock;
        uint64 validUntilBlock = reports[0].validUntilBlock;
        bytes32 snapshotBlockHash = reports[0].snapshotBlockHash;

        if (
            snapshotBlock >= block.number || block.number - snapshotBlock > maxSnapshotAge
                || blockhash(snapshotBlock) != snapshotBlockHash
        ) revert IFundAccounting.InvalidSnapshotBlock(snapshotBlock);
        if (
            validAfterBlock < block.number + 1 || validAfterBlock < snapshotBlock + activationDelay
                || validUntilBlock <= validAfterBlock || validUntilBlock - validAfterBlock > maxWindowLength
        ) revert InvalidReportWindow();

        bytes32 aggregatePositionsHash;
        for (uint256 i; i < reports.length; ++i) {
            FundTypes.ComponentReport calldata report = reports[i];
            _validateComponent(report, reports, i, snapshotBlock, snapshotBlockHash, validAfterBlock, validUntilBlock);

            if (report.liabilities > report.grossAssets) revert LiabilityExceedsAssets(report.componentId);
            nav.grossAssets += report.grossAssets;
            nav.liabilities += report.liabilities;
            nav.liquidAccountingAssets += report.liquidAccountingAssets;
            nav.baseExitCost += report.baseExitCost;
            aggregatePositionsHash = keccak256(
                abi.encode(aggregatePositionsHash, report.componentId, report.componentNonce, report.positionStateHash)
            );
        }

        nav.netAssets = nav.grossAssets - nav.liabilities;
        nav.snapshotBlock = snapshotBlock;
        nav.validAfterBlock = validAfterBlock;
        nav.validUntilBlock = validUntilBlock;
        nav.reporterSetVersion = reporterSetVersion;
        nav.positionsHash = aggregatePositionsHash;
        nav.reportHash = acceptedReportHash;
    }

    function isActive(FundTypes.NavCommit calldata nav) external view returns (bool) {
        return block.number >= nav.validAfterBlock && block.number <= nav.validUntilBlock;
    }

    function _validateReporters(address[] calldata reporters, bytes[] calldata signatures, bytes32 digest)
        private
        view
    {
        for (uint256 i; i < reporters.length; ++i) {
            address recovered = ECDSA.recover(digest, signatures[i]);
            if (recovered != reporters[i] || !isReporter[recovered]) revert InvalidReporter(recovered);
            for (uint256 j; j < i; ++j) {
                if (reporters[j] == recovered) revert DuplicateReporter(recovered);
            }
        }
    }

    function _validateComponent(
        FundTypes.ComponentReport calldata report,
        FundTypes.ComponentReport[] calldata reports,
        uint256 index,
        uint64 snapshotBlock,
        bytes32 snapshotBlockHash,
        uint64 validAfterBlock,
        uint64 validUntilBlock
    ) private view {
        if (report.fund != expectedFund) revert InvalidFund(report.fund);
        if (report.chainId != block.chainid) revert InvalidChain(report.chainId);
        if (report.reporterSetVersion != reporterSetVersion) {
            revert IFundAccounting.InvalidReporterSet(report.reporterSetVersion);
        }
        if (
            report.snapshotBlock != snapshotBlock || report.snapshotBlockHash != snapshotBlockHash
                || report.validAfterBlock != validAfterBlock || report.validUntilBlock != validUntilBlock
        ) revert IFundAccounting.StaleComponent(report.componentId);

        ComponentConfig memory config = componentConfig[report.componentId];
        if (!config.active) revert IFundAccounting.IncompleteComponentSet();
        if (report.componentNonce != config.nonce || report.positionStateHash != config.positionStateHash) {
            revert IFundAccounting.InvalidPositionState(report.componentId);
        }
        for (uint256 j; j < index; ++j) {
            if (reports[j].componentId == report.componentId) {
                revert IFundAccounting.DuplicateComponent(report.componentId);
            }
        }
    }
}

contract NavReportSpecTest is Test {
    bytes32 internal constant IDLE_COMPONENT = keccak256("IDLE");
    bytes32 internal constant STRATEGY_COMPONENT = keccak256("STRATEGY");
    bytes32 internal constant IDLE_HASH = keccak256("idle-state");
    bytes32 internal constant STRATEGY_HASH = keccak256("strategy-state");

    NavReportHarness internal harness;
    address internal fund = address(0xF00D);
    uint256 internal reporterOneKey = 0xA11CE;
    uint256 internal reporterTwoKey = 0xB0B;
    address internal reporterOne;
    address internal reporterTwo;

    function setUp() public {
        reporterOne = vm.addr(reporterOneKey);
        reporterTwo = vm.addr(reporterTwoKey);
        harness = new NavReportHarness(fund, 2, 20, 20);
        harness.configureComponent(IDLE_COMPONENT, 3, IDLE_HASH);
        harness.configureComponent(STRATEGY_COMPONENT, 7, STRATEGY_HASH);

        address[] memory reporters = new address[](2);
        reporters[0] = reporterOne;
        reporters[1] = reporterTwo;
        harness.configureReporters(reporters, 2, 1);

        vm.roll(100);
        vm.setBlockhash(99, keccak256("block-99"));
    }

    function test_validComponentReportsProduceDelayedNavCommit() public {
        FundTypes.ComponentReport[] memory reports = _validReports();
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        FundTypes.NavCommit memory nav = harness.submitNav(reports, reporters, signatures);

        assertEq(nav.grossAssets, 1_100e6);
        assertEq(nav.liabilities, 100e6);
        assertEq(nav.netAssets, 1_000e6);
        assertEq(nav.liquidAccountingAssets, 600e6);
        assertFalse(harness.isActive(nav));
        vm.roll(101);
        assertTrue(harness.isActive(nav));
        vm.roll(111);
        assertFalse(harness.isActive(nav));
    }

    function test_rejectsMissingComponent() public {
        FundTypes.ComponentReport[] memory reports = new FundTypes.ComponentReport[](1);
        reports[0] = _validReports()[0];
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        vm.expectRevert(IFundAccounting.IncompleteComponentSet.selector);
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsDuplicateComponent() public {
        FundTypes.ComponentReport[] memory reports = _validReports();
        reports[1].componentId = IDLE_COMPONENT;
        reports[1].componentNonce = 3;
        reports[1].positionStateHash = IDLE_HASH;
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        vm.expectRevert(abi.encodeWithSelector(IFundAccounting.DuplicateComponent.selector, IDLE_COMPONENT));
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsMismatchedPositionHash() public {
        FundTypes.ComponentReport[] memory reports = _validReports();
        reports[1].positionStateHash = keccak256("changed-after-snapshot");
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        vm.expectRevert(abi.encodeWithSelector(IFundAccounting.InvalidPositionState.selector, STRATEGY_COMPONENT));
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsStaleSnapshot() public {
        vm.setBlockhash(70, keccak256("block-70"));
        FundTypes.ComponentReport[] memory reports = _validReports();
        for (uint256 i; i < reports.length; ++i) {
            reports[i].snapshotBlock = 70;
            reports[i].snapshotBlockHash = keccak256("block-70");
        }
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        vm.expectRevert(abi.encodeWithSelector(IFundAccounting.InvalidSnapshotBlock.selector, 70));
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsWrongBlockHash() public {
        FundTypes.ComponentReport[] memory reports = _validReports();
        for (uint256 i; i < reports.length; ++i) {
            reports[i].snapshotBlockHash = keccak256("wrong");
        }
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        vm.expectRevert(abi.encodeWithSelector(IFundAccounting.InvalidSnapshotBlock.selector, 99));
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsSameBlockActivation() public {
        FundTypes.ComponentReport[] memory reports = _validReports();
        for (uint256 i; i < reports.length; ++i) {
            reports[i].validAfterBlock = 100;
        }
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        vm.expectRevert(NavReportHarness.InvalidReportWindow.selector);
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsWrongReporterSetVersion() public {
        FundTypes.ComponentReport[] memory reports = _validReports();
        for (uint256 i; i < reports.length; ++i) {
            reports[i].reporterSetVersion = 2;
        }
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterTwoKey);

        vm.expectRevert(abi.encodeWithSelector(IFundAccounting.InvalidReporterSet.selector, 2));
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsUnapprovedReporter() public {
        uint256 attackerKey = 0xBAD;
        FundTypes.ComponentReport[] memory reports = _validReports();
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, attackerKey);

        vm.expectRevert(abi.encodeWithSelector(NavReportHarness.InvalidReporter.selector, vm.addr(attackerKey)));
        harness.submitNav(reports, reporters, signatures);
    }

    function test_rejectsDuplicateReporterForQuorum() public {
        FundTypes.ComponentReport[] memory reports = _validReports();
        (address[] memory reporters, bytes[] memory signatures) = _sign(reports, reporterOneKey, reporterOneKey);

        vm.expectRevert(abi.encodeWithSelector(NavReportHarness.DuplicateReporter.selector, reporterOne));
        harness.submitNav(reports, reporters, signatures);
    }

    function _validReports() private view returns (FundTypes.ComponentReport[] memory reports) {
        reports = new FundTypes.ComponentReport[](2);
        reports[0] = FundTypes.ComponentReport({
            fund: fund,
            componentId: IDLE_COMPONENT,
            chainId: block.chainid,
            snapshotBlock: 99,
            snapshotBlockHash: keccak256("block-99"),
            validAfterBlock: 101,
            validUntilBlock: 110,
            reporterSetVersion: 1,
            componentNonce: 3,
            positionStateHash: IDLE_HASH,
            grossAssets: 600e6,
            liabilities: 0,
            liquidAccountingAssets: 600e6,
            baseExitCost: 0,
            dataHash: keccak256("idle-data")
        });
        reports[1] = FundTypes.ComponentReport({
            fund: fund,
            componentId: STRATEGY_COMPONENT,
            chainId: block.chainid,
            snapshotBlock: 99,
            snapshotBlockHash: keccak256("block-99"),
            validAfterBlock: 101,
            validUntilBlock: 110,
            reporterSetVersion: 1,
            componentNonce: 7,
            positionStateHash: STRATEGY_HASH,
            grossAssets: 500e6,
            liabilities: 100e6,
            liquidAccountingAssets: 0,
            baseExitCost: 5e6,
            dataHash: keccak256("strategy-data")
        });
    }

    function _sign(FundTypes.ComponentReport[] memory reports, uint256 firstKey, uint256 secondKey)
        private
        view
        returns (address[] memory reporters, bytes[] memory signatures)
    {
        bytes32 digest = harness.signatureDigest(reports);
        reporters = new address[](2);
        signatures = new bytes[](2);
        reporters[0] = vm.addr(firstKey);
        reporters[1] = vm.addr(secondKey);
        signatures[0] = _signature(firstKey, digest);
        signatures[1] = _signature(secondKey, digest);
    }

    function _signature(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
