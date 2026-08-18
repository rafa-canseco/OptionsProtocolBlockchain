// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {IFundAccounting} from "./interfaces/IFundAccounting.sol";
import {INavReportVerifier} from "./interfaces/INavReportVerifier.sol";

interface INavReportAccountingView {
    function activeComponentCount() external view returns (uint256);
    function componentState(bytes32 componentId)
        external
        view
        returns (address valuator, uint64 interfaceVersion, uint64 nonce, bytes32 positionStateHash, bool active);
    function isReporter(address reporter) external view returns (bool);
}

interface INavReportVaultView {
    function asset() external view returns (address);
    function fundFlowNonce() external view returns (uint64);
    function idleStateHash() external view returns (bytes32);
    function strategyManager() external view returns (address);
}

interface INavReportStrategyPositions {
    function positionsHash() external view returns (bytes32);
}

/// @notice Stateless NAV report, reporter quorum, and component consistency verifier.
contract NavReportVerifier is INavReportVerifier {
    error InvalidAddress();
    error InvalidChain(uint256 chainId);
    error InvalidFund(address fund);
    error InvalidReportWindow();
    error InvalidSignatureCount();
    error LiabilityExceedsAssets(bytes32 componentId);

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function verifyNavReport(
        VerifyNavReportParams calldata params,
        FundTypes.ComponentReport[] calldata reports,
        address[] calldata reporters,
        bytes[] calldata signatures
    ) external view returns (FundTypes.NavCommit memory nav) {
        if (params.fund == address(0) || params.reporterSetVersion == 0 || params.reporterThreshold == 0) {
            revert IFundAccounting.InvalidReporterSet(params.reporterSetVersion);
        }
        INavReportAccountingView accounting = INavReportAccountingView(msg.sender);
        if (reports.length == 0 || reports.length != accounting.activeComponentCount()) {
            revert IFundAccounting.IncompleteComponentSet();
        }
        if (reporters.length != signatures.length || reporters.length < params.reporterThreshold) {
            revert InvalidSignatureCount();
        }

        _validateReporters(accounting, reporters, signatures, params.digest);

        uint64 snapshotBlock = reports[0].snapshotBlock;
        uint64 validAfterBlock = reports[0].validAfterBlock;
        uint64 validUntilBlock = reports[0].validUntilBlock;
        bytes32 snapshotBlockHash = reports[0].snapshotBlockHash;
        if (
            snapshotBlock >= block.number || block.number - snapshotBlock > params.maxSnapshotAge
                || blockhash(snapshotBlock) != snapshotBlockHash
        ) revert IFundAccounting.InvalidSnapshotBlock(snapshotBlock);
        if (
            validAfterBlock < block.number + 1 || validAfterBlock < snapshotBlock + params.activationDelay
                || validUntilBlock <= validAfterBlock || validUntilBlock - validAfterBlock > params.maxWindowLength
        ) revert InvalidReportWindow();

        for (uint256 i; i < reports.length; ++i) {
            FundTypes.ComponentReport calldata report = reports[i];
            _validateComponent(
                accounting,
                params,
                report,
                reports,
                i,
                snapshotBlock,
                snapshotBlockHash,
                validAfterBlock,
                validUntilBlock
            );
            if (report.liabilities > report.grossAssets) revert LiabilityExceedsAssets(report.componentId);
            nav.grossAssets += report.grossAssets;
            nav.liabilities += report.liabilities;
            nav.liquidAccountingAssets += report.liquidAccountingAssets;
            nav.baseExitCost += report.baseExitCost;
            if (report.componentId == FundConstants.IDLE_COMPONENT_ID) {
                nav.fundFlowNonce = report.componentNonce;
                nav.idleStateHash = report.positionStateHash;
            }
        }

        nav.netAssets = nav.grossAssets - nav.liabilities;
        nav.snapshotBlock = snapshotBlock;
        nav.validAfterBlock = validAfterBlock;
        nav.validUntilBlock = validUntilBlock;
        nav.reporterSetVersion = params.reporterSetVersion;
        nav.reportNonce = params.reportNonce;
        nav.positionsHash =
            INavReportStrategyPositions(INavReportVaultView(params.fund).strategyManager()).positionsHash();
        nav.reportHash = params.reportHash;
        nav.signaturesHash = keccak256(abi.encode(reporters, signatures));
    }

    function _validateReporters(
        INavReportAccountingView accounting,
        address[] calldata reporters,
        bytes[] calldata signatures,
        bytes32 digest
    ) private view {
        for (uint256 i; i < reporters.length; ++i) {
            address recovered = ECDSA.recover(digest, signatures[i]);
            if (recovered != reporters[i] || !accounting.isReporter(recovered)) {
                revert IFundAccounting.InvalidReporter(recovered);
            }
            for (uint256 j; j < i; ++j) {
                if (reporters[j] == recovered) revert IFundAccounting.DuplicateReporter(recovered);
            }
        }
    }

    function _validateComponent(
        INavReportAccountingView accounting,
        VerifyNavReportParams calldata params,
        FundTypes.ComponentReport calldata report,
        FundTypes.ComponentReport[] calldata reports,
        uint256 index,
        uint64 snapshotBlock,
        bytes32 snapshotBlockHash,
        uint64 validAfterBlock,
        uint64 validUntilBlock
    ) private view {
        if (report.fund != params.fund) revert InvalidFund(report.fund);
        if (report.chainId != block.chainid) revert InvalidChain(report.chainId);
        if (report.reporterSetVersion != params.reporterSetVersion) {
            revert IFundAccounting.InvalidReporterSet(report.reporterSetVersion);
        }
        if (
            report.snapshotBlock != snapshotBlock || report.snapshotBlockHash != snapshotBlockHash
                || report.validAfterBlock != validAfterBlock || report.validUntilBlock != validUntilBlock
        ) revert IFundAccounting.StaleComponent(report.componentId);

        (,, uint64 nonce, bytes32 positionStateHash, bool active) = accounting.componentState(report.componentId);
        if (!active) revert IFundAccounting.IncompleteComponentSet();
        if (report.componentId == FundConstants.IDLE_COMPONENT_ID) {
            INavReportVaultView vault = INavReportVaultView(params.fund);
            if (
                report.componentNonce != vault.fundFlowNonce() || report.positionStateHash != vault.idleStateHash()
                    || report.liquidAccountingAssets != IERC20Metadata(vault.asset()).balanceOf(params.fund)
            ) revert IFundAccounting.InvalidPositionState(report.componentId);
        } else if (report.componentNonce != nonce || report.positionStateHash != positionStateHash) {
            revert IFundAccounting.InvalidPositionState(report.componentId);
        }
        for (uint256 j; j < index; ++j) {
            if (reports[j].componentId == report.componentId) {
                revert IFundAccounting.DuplicateComponent(report.componentId);
            }
        }
    }
}
