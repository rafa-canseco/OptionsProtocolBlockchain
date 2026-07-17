// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {FundMath} from "./libraries/FundMath.sol";
import {FundAccountingStorage} from "./storage/FundAccountingStorage.sol";
import {IFundAccounting} from "./interfaces/IFundAccounting.sol";
import {IFundVault} from "./interfaces/IFundVault.sol";
import {IPositionValuator} from "./interfaces/IPositionValuator.sol";

interface IFundVaultAccounting is IFundVault {
    function totalSupply() external view returns (uint256);
    function asset() external view returns (address);
    function strategyManager() external view returns (address);
}

interface IStrategyPositions {
    function positionsHash() external view returns (bytes32);
}

interface IFlowProcessingState {
    function hasActiveProcessing() external view returns (bool);
}

/// @notice Component NAV verification, reporter quorum, and fee crystallization.
contract FundAccounting is FundUpgradeable, EIP712Upgradeable, FundAccountingStorage, IFundAccounting {
    bytes32 public constant NAV_REPORT_TYPEHASH =
        keccak256("NavReport(address fund,uint64 reporterSetVersion,uint64 reportNonce,bytes32 reportsHash)");

    error InvalidAddress();
    error InvalidChain(uint256 chainId);
    error InvalidFund(address fund);
    error InvalidReportWindow();
    error InvalidSignatureCount();
    error LiabilityExceedsAssets(bytes32 componentId);
    error InvalidFeeConfig();
    error InvalidValuator(address valuator);
    error UnauthorizedStrategyManager(address caller);

    event ReporterSetUpdated(uint64 indexed version, uint16 threshold, address[] reporters);
    event ComponentUpdated(bytes32 indexed componentId, address valuator, uint64 interfaceVersion, bool active);
    event ComponentStateUpdated(bytes32 indexed componentId, uint64 nonce, bytes32 positionStateHash);
    event FeeConfigUpdated(address indexed recipient, uint64 managementFeeWad, uint16 performanceFeeBps);
    event NavSubmitted(uint64 indexed reportNonce, bytes32 indexed reportHash, uint256 netAssets, uint256 feeShares);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address fund_,
        address authority_,
        uint64 compatibilityVersion_,
        uint64 activationDelay_,
        uint64 maxSnapshotAge_,
        uint64 maxWindowLength_,
        FundTypes.FeeConfig calldata feeConfig_
    ) external initializer {
        if (
            fund_ == address(0) || compatibilityVersion_ == 0 || activationDelay_ == 0 || maxSnapshotAge_ == 0
                || maxWindowLength_ == 0 || maxSnapshotAge_ > 255
        ) revert InvalidAddress();
        __FundUpgradeable_init(authority_);
        __EIP712_init("b1nary Fund NAV", "1");

        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        $.fund = fund_;
        $.compatibilityVersion = compatibilityVersion_;
        $.activationDelay = activationDelay_;
        $.maxSnapshotAge = maxSnapshotAge_;
        $.maxWindowLength = maxWindowLength_;
        $.feeState.lastManagementAccrual = uint48(block.timestamp);
        $.feeState.lastCrystallization = uint48(block.timestamp);
        uint8 assetDecimals = IERC20Metadata(IFundVaultAccounting(fund_).asset()).decimals();
        $.feeState.highWaterMark = 10 ** assetDecimals;
        _setFeeConfig($, feeConfig_);
    }

    function fund() external view returns (address) {
        return _getFundAccountingStorage().fund;
    }

    function compatibilityVersion() external view returns (uint64) {
        return _getFundAccountingStorage().compatibilityVersion;
    }

    function reporterSetVersion() external view returns (uint64) {
        return _getFundAccountingStorage().reporterSetVersion;
    }

    function lastReportNonce() external view returns (uint64) {
        return _getFundAccountingStorage().lastReportNonce;
    }

    function componentNonce(bytes32 componentId) external view returns (uint64) {
        return _getFundAccountingStorage().components[componentId].nonce;
    }

    function componentState(bytes32 componentId) external view returns (ComponentState memory) {
        return _getFundAccountingStorage().components[componentId];
    }

    function activeComponentCount() external view returns (uint256) {
        return _getFundAccountingStorage().activeComponentIds.length;
    }

    function activeComponentAt(uint256 index) external view returns (bytes32) {
        return _getFundAccountingStorage().activeComponentIds[index];
    }

    function feeConfig() external view returns (FundTypes.FeeConfig memory) {
        return _getFundAccountingStorage().feeConfig;
    }

    function feeState() external view returns (FundTypes.FeeState memory) {
        return _getFundAccountingStorage().feeState;
    }

    function reportHash(uint64 reportNonce, FundTypes.ComponentReport[] calldata reports)
        public
        view
        returns (bytes32)
    {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        return keccak256(
            abi.encode(NAV_REPORT_TYPEHASH, $.fund, $.reporterSetVersion, reportNonce, keccak256(abi.encode(reports)))
        );
    }

    function signatureDigest(uint64 reportNonce, FundTypes.ComponentReport[] calldata reports)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(reportHash(reportNonce, reports));
    }

    function submitNav(
        uint64 reportNonce,
        FundTypes.ComponentReport[] calldata reports,
        address[] calldata reporters,
        bytes[] calldata signatures
    ) external restricted returns (FundTypes.NavCommit memory nav) {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        IFundVaultAccounting vault = IFundVaultAccounting($.fund);
        if (IFlowProcessingState(vault.flowManager()).hasActiveProcessing()) revert InvalidReportWindow();
        uint64 expectedNonce = $.lastReportNonce + 1;
        if (reportNonce != expectedNonce) revert InvalidReportNonce(expectedNonce, reportNonce);
        if (reports.length == 0 || reports.length != $.activeComponentIds.length) {
            revert IncompleteComponentSet();
        }
        if (reporters.length != signatures.length || reporters.length < $.reporterThreshold) {
            revert InvalidSignatureCount();
        }

        bytes32 acceptedReportHash = reportHash(reportNonce, reports);
        bytes32 digest = _hashTypedDataV4(acceptedReportHash);
        _validateReporters($, reporters, signatures, digest);

        uint64 snapshotBlock = reports[0].snapshotBlock;
        uint64 validAfterBlock = reports[0].validAfterBlock;
        uint64 validUntilBlock = reports[0].validUntilBlock;
        bytes32 snapshotBlockHash = reports[0].snapshotBlockHash;
        if (
            snapshotBlock >= block.number || block.number - snapshotBlock > $.maxSnapshotAge
                || blockhash(snapshotBlock) != snapshotBlockHash
        ) revert InvalidSnapshotBlock(snapshotBlock);
        if (
            validAfterBlock < block.number + 1 || validAfterBlock < snapshotBlock + $.activationDelay
                || validUntilBlock <= validAfterBlock || validUntilBlock - validAfterBlock > $.maxWindowLength
        ) revert InvalidReportWindow();

        for (uint256 i; i < reports.length; ++i) {
            FundTypes.ComponentReport calldata report = reports[i];
            _validateComponent(
                $, report, reports, i, snapshotBlock, snapshotBlockHash, validAfterBlock, validUntilBlock
            );
            if (report.liabilities > report.grossAssets) revert LiabilityExceedsAssets(report.componentId);
            nav.grossAssets += report.grossAssets;
            nav.liabilities += report.liabilities;
            nav.liquidAccountingAssets += report.liquidAccountingAssets;
            nav.baseExitCost += report.baseExitCost;
        }

        nav.netAssets = nav.grossAssets - nav.liabilities;
        nav.snapshotBlock = snapshotBlock;
        nav.validAfterBlock = validAfterBlock;
        nav.validUntilBlock = validUntilBlock;
        nav.reporterSetVersion = $.reporterSetVersion;
        nav.reportNonce = reportNonce;
        nav.positionsHash = IStrategyPositions(IFundVaultAccounting($.fund).strategyManager()).positionsHash();
        nav.reportHash = acceptedReportHash;
        nav.signaturesHash = keccak256(abi.encode(reporters, signatures));

        uint256 feeShares = _crystallizeFees($, nav.netAssets);
        $.lastReportNonce = reportNonce;
        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        vault.commitNav(nav, feeShares, $.feeConfig.feeRecipient);
        vault.endModuleExecution(lockId);
        emit NavSubmitted(reportNonce, acceptedReportHash, nav.netAssets, feeShares);
    }

    function setReporterSet(address[] calldata reporters, uint16 threshold, uint64 version) external restricted {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        if (version <= $.reporterSetVersion) revert InvalidReporterSet(version);
        if (threshold == 0 || threshold > reporters.length) {
            revert InvalidReporterThreshold(threshold, reporters.length);
        }
        for (uint256 i; i < $.activeReporters.length; ++i) {
            $.reporters[$.activeReporters[i]] = false;
        }
        delete $.activeReporters;
        for (uint256 i; i < reporters.length; ++i) {
            address reporter = reporters[i];
            if (reporter == address(0)) revert InvalidReporter(reporter);
            for (uint256 j; j < i; ++j) {
                if (reporters[j] == reporter) revert DuplicateReporter(reporter);
            }
            $.reporters[reporter] = true;
            $.activeReporters.push(reporter);
        }
        $.reporterThreshold = threshold;
        $.reporterSetVersion = version;
        emit ReporterSetUpdated(version, threshold, reporters);
    }

    function setComponent(bytes32 componentId, address valuator, uint64 interfaceVersion, bool active)
        external
        restricted
    {
        if (componentId == bytes32(0) || (active && interfaceVersion == 0)) revert InvalidValuator(valuator);
        if (active && valuator != address(0)) {
            if (valuator.code.length == 0 || IPositionValuator(valuator).interfaceVersion() != interfaceVersion) {
                revert InvalidValuator(valuator);
            }
        }
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        ComponentState storage state = $.components[componentId];
        if (active && !state.active) {
            $.activeComponentIds.push(componentId);
        } else if (!active && state.active) {
            _removeComponent($, componentId);
        }
        state.valuator = valuator;
        state.interfaceVersion = interfaceVersion;
        state.active = active;
        emit ComponentUpdated(componentId, valuator, interfaceVersion, active);
    }

    function setComponentState(bytes32 componentId, uint64 nonce, bytes32 positionStateHash) external restricted {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        ComponentState storage state = $.components[componentId];
        if (!state.active || nonce <= state.nonce) revert InvalidPositionState(componentId);
        state.nonce = nonce;
        state.positionStateHash = positionStateHash;
        emit ComponentStateUpdated(componentId, nonce, positionStateHash);
    }

    function syncStrategyComponent(address adapter, uint64 nonce, bytes32 positionStateHash) external {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        if (msg.sender != IFundVaultAccounting($.fund).strategyManager()) {
            revert UnauthorizedStrategyManager(msg.sender);
        }
        bytes32 componentId = strategyComponentId(adapter);
        ComponentState storage state = $.components[componentId];
        if (!state.active) return;
        if (nonce <= state.nonce) revert InvalidPositionState(componentId);
        state.nonce = nonce;
        state.positionStateHash = positionStateHash;
        emit ComponentStateUpdated(componentId, nonce, positionStateHash);
    }

    function strategyComponentId(address adapter) public pure returns (bytes32) {
        return keccak256(abi.encodePacked("STRATEGY", adapter));
    }

    function setFeeConfig(FundTypes.FeeConfig calldata config) external restricted {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        _setFeeConfig($, config);
    }

    function _setFeeConfig(FundAccountingStorageLayout storage $, FundTypes.FeeConfig calldata config) private {
        if (
            config.maxManagementFeeBps > FundConstants.BPS || config.maxPerformanceFeeBps > FundConstants.BPS
                || config.performanceFeeBps > config.maxPerformanceFeeBps
                || config.managementFeeWad > uint256(config.maxManagementFeeBps) * 1e14
                || (config.managementFeeWad != 0 && config.maxAccrualInterval == 0)
                || ((config.managementFeeWad != 0 || config.performanceFeeBps != 0)
                    && config.feeRecipient == address(0))
        ) revert InvalidFeeConfig();
        $.feeConfig = config;
        emit FeeConfigUpdated(config.feeRecipient, config.managementFeeWad, config.performanceFeeBps);
    }

    function _crystallizeFees(FundAccountingStorageLayout storage $, uint256 preFeeNav)
        private
        returns (uint256 feeShares)
    {
        IFundVaultAccounting vault = IFundVaultAccounting($.fund);
        uint256 supply = vault.totalSupply();
        FundTypes.FeeConfig storage config = $.feeConfig;
        FundTypes.FeeState storage state = $.feeState;

        if (config.managementFeeWad != 0 && supply != 0 && preFeeNav != 0) {
            uint256 elapsed = block.timestamp - state.lastManagementAccrual;
            if (elapsed > config.maxAccrualInterval) elapsed = config.maxAccrualInterval;
            if (elapsed != 0) {
                (, uint256 managementShares) =
                    FundMath.managementFeeShares(preFeeNav, supply, config.managementFeeWad, elapsed);
                feeShares += managementShares;
                state.lastManagementAccrual += uint48(elapsed);
            }
        } else {
            state.lastManagementAccrual = uint48(block.timestamp);
        }

        if (supply != 0 && preFeeNav != 0) {
            (, uint256 performanceShares, uint256 preFeePps) = FundMath.performanceFeeShares(
                preFeeNav, supply + feeShares, FundConstants.SHARE_SCALE, state.highWaterMark, config.performanceFeeBps
            );
            feeShares += performanceShares;
            if (preFeePps > state.highWaterMark) state.highWaterMark = preFeePps;
        }
        state.lastCrystallization = uint48(block.timestamp);
    }

    function _validateReporters(
        FundAccountingStorageLayout storage $,
        address[] calldata reporters,
        bytes[] calldata signatures,
        bytes32 digest
    ) private view {
        for (uint256 i; i < reporters.length; ++i) {
            address recovered = ECDSA.recover(digest, signatures[i]);
            if (recovered != reporters[i] || !$.reporters[recovered]) revert InvalidReporter(recovered);
            for (uint256 j; j < i; ++j) {
                if (reporters[j] == recovered) revert DuplicateReporter(recovered);
            }
        }
    }

    function _validateComponent(
        FundAccountingStorageLayout storage $,
        FundTypes.ComponentReport calldata report,
        FundTypes.ComponentReport[] calldata reports,
        uint256 index,
        uint64 snapshotBlock,
        bytes32 snapshotBlockHash,
        uint64 validAfterBlock,
        uint64 validUntilBlock
    ) private view {
        if (report.fund != $.fund) revert InvalidFund(report.fund);
        if (report.chainId != block.chainid) revert InvalidChain(report.chainId);
        if (report.reporterSetVersion != $.reporterSetVersion) revert InvalidReporterSet(report.reporterSetVersion);
        if (
            report.snapshotBlock != snapshotBlock || report.snapshotBlockHash != snapshotBlockHash
                || report.validAfterBlock != validAfterBlock || report.validUntilBlock != validUntilBlock
        ) revert StaleComponent(report.componentId);

        ComponentState storage state = $.components[report.componentId];
        if (!state.active) revert IncompleteComponentSet();
        if (report.componentNonce != state.nonce || report.positionStateHash != state.positionStateHash) {
            revert InvalidPositionState(report.componentId);
        }
        for (uint256 j; j < index; ++j) {
            if (reports[j].componentId == report.componentId) revert DuplicateComponent(report.componentId);
        }
    }

    function _removeComponent(FundAccountingStorageLayout storage $, bytes32 componentId) private {
        uint256 length = $.activeComponentIds.length;
        for (uint256 i; i < length; ++i) {
            if ($.activeComponentIds[i] == componentId) {
                if (i != length - 1) $.activeComponentIds[i] = $.activeComponentIds[length - 1];
                $.activeComponentIds.pop();
                return;
            }
        }
    }
}
