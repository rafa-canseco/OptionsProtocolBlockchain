// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FundUpgradeable} from "./FundUpgradeable.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {FundMath} from "./libraries/FundMath.sol";
import {FundAccountingStorage} from "./storage/FundAccountingStorage.sol";
import {IFundAccounting} from "./interfaces/IFundAccounting.sol";
import {IFundVault} from "./interfaces/IFundVault.sol";
import {IFundVaultModuleCallbacks} from "./interfaces/IFundModuleCallbacks.sol";
import {IPositionValuator} from "./interfaces/IPositionValuator.sol";
import {INavReportVerifier} from "./interfaces/INavReportVerifier.sol";

interface IFundVaultAccounting is IFundVault {
    function shareSupply() external view returns (uint256);
    function asset() external view returns (address);
    function strategyManager() external view returns (address);
    function accountedIdleAssets() external view returns (uint256);
}

interface IFlowProcessingState {
    function hasActiveProcessing() external view returns (bool);
}

/// @notice Component NAV verification, reporter quorum, and fee crystallization.
contract FundAccounting is FundUpgradeable, FundAccountingStorage, IFundAccounting {
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAV_NAME_HASH = keccak256("b1nary Fund NAV");
    bytes32 private constant NAV_VERSION_HASH = keccak256("1");
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
    error UnauthorizedFeeAccrual(address caller);

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
        address navVerifier_,
        address authority_,
        uint64 compatibilityVersion_,
        uint64 activationDelay_,
        uint64 maxSnapshotAge_,
        uint64 maxWindowLength_,
        FundTypes.FeeConfig calldata feeConfig_
    ) external initializer {
        if (
            fund_ == address(0) || navVerifier_ == address(0) || compatibilityVersion_ == 0 || activationDelay_ == 0
                || maxSnapshotAge_ == 0 || maxWindowLength_ == 0 || maxSnapshotAge_ > 255
        ) revert InvalidAddress();
        uint64 verifierVersion = INavReportVerifier(navVerifier_).interfaceVersion();
        if (navVerifier_.code.length == 0 || verifierVersion == 0) revert InvalidAddress();
        __FundUpgradeable_init(authority_);

        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        $.fund = fund_;
        $.navVerifier = navVerifier_;
        $.compatibilityVersion = compatibilityVersion_;
        $.navVerifierVersion = verifierVersion;
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

    function navVerifier() external view returns (address) {
        return _getFundAccountingStorage().navVerifier;
    }

    function navVerifierVersion() external view returns (uint64) {
        return _getFundAccountingStorage().navVerifierVersion;
    }

    function reporterSetVersion() external view returns (uint64) {
        return _getFundAccountingStorage().reporterSetVersion;
    }

    function reporterThreshold() external view returns (uint16) {
        return _getFundAccountingStorage().reporterThreshold;
    }

    function isReporter(address reporter) external view returns (bool) {
        return _getFundAccountingStorage().reporters[reporter];
    }

    function activeReporterCount() external view returns (uint256) {
        return _getFundAccountingStorage().activeReporters.length;
    }

    function activeReporterAt(uint256 index) external view returns (address) {
        return _getFundAccountingStorage().activeReporters[index];
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

    function navPolicy() external view returns (uint64 activationDelay, uint64 maxSnapshotAge, uint64 maxWindowLength) {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        return ($.activationDelay, $.maxSnapshotAge, $.maxWindowLength);
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

        bytes32 acceptedReportHash = reportHash(reportNonce, reports);
        bytes32 digest = _hashTypedDataV4(acceptedReportHash);
        nav = INavReportVerifier($.navVerifier)
            .verifyNavReport(
                INavReportVerifier.VerifyNavReportParams({
                    fund: $.fund,
                    reportNonce: reportNonce,
                    reporterSetVersion: $.reporterSetVersion,
                    reporterThreshold: $.reporterThreshold,
                    activationDelay: $.activationDelay,
                    maxSnapshotAge: $.maxSnapshotAge,
                    maxWindowLength: $.maxWindowLength,
                    reportHash: acceptedReportHash,
                    digest: digest
                }),
                reports,
                reporters,
                signatures
            );

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
        _checkpointManagementFee($);
        _setFeeConfig($, config);
    }

    function accrueManagementFee() external returns (uint256 feeShares) {
        FundAccountingStorageLayout storage $ = _getFundAccountingStorage();
        IFundVaultAccounting vault = IFundVaultAccounting($.fund);
        if (msg.sender != $.fund && msg.sender != vault.flowManager()) revert UnauthorizedFeeAccrual(msg.sender);
        feeShares = _accrueManagementFee($, vault.totalAssets(), vault.shareSupply(), true);
        _mintCheckpointShares($, feeShares);
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
        uint256 supply = vault.shareSupply();
        FundTypes.FeeConfig storage config = $.feeConfig;
        FundTypes.FeeState storage state = $.feeState;

        feeShares = _accrueManagementFee($, preFeeNav, supply, true);

        if (supply != 0 && preFeeNav != 0) {
            (, uint256 performanceShares, uint256 preFeePps) = FundMath.performanceFeeShares(
                preFeeNav, supply + feeShares, FundConstants.SHARE_SCALE, state.highWaterMark, config.performanceFeeBps
            );
            feeShares += performanceShares;
            if (preFeePps > state.highWaterMark) {
                state.highWaterMark = Math.mulDiv(preFeeNav, FundConstants.SHARE_SCALE, supply + feeShares);
            }
        }
        state.lastCrystallization = uint48(block.timestamp);
    }

    function _checkpointManagementFee(FundAccountingStorageLayout storage $) private {
        IFundVaultAccounting vault = IFundVaultAccounting($.fund);
        if (IFlowProcessingState(vault.flowManager()).hasActiveProcessing()) revert InvalidReportWindow();
        uint256 feeShares = _accrueManagementFee($, vault.totalAssets(), vault.shareSupply(), false);
        _mintCheckpointShares($, feeShares);
    }

    function _mintCheckpointShares(FundAccountingStorageLayout storage $, uint256 feeShares) private {
        if (feeShares == 0) return;
        IFundVaultAccounting vault = IFundVaultAccounting($.fund);
        uint256 lockId = vault.beginModuleExecution($.compatibilityVersion);
        IFundVaultModuleCallbacks($.fund).mintFeeShares(feeShares, $.feeConfig.feeRecipient);
        vault.endModuleExecution(lockId);
    }

    function _accrueManagementFee(
        FundAccountingStorageLayout storage $,
        uint256 preFeeNav,
        uint256 supply,
        bool capElapsed
    ) private returns (uint256 feeShares) {
        FundTypes.FeeConfig storage config = $.feeConfig;
        FundTypes.FeeState storage state = $.feeState;
        if (config.managementFeeWad == 0 || supply == 0 || preFeeNav == 0) {
            state.lastManagementAccrual = uint48(block.timestamp);
            return 0;
        }

        uint256 elapsed = block.timestamp - state.lastManagementAccrual;
        if (capElapsed && elapsed > config.maxAccrualInterval) elapsed = config.maxAccrualInterval;
        if (elapsed == 0) return 0;
        (, feeShares) = FundMath.managementFeeShares(preFeeNav, supply, config.managementFeeWad, elapsed);
        state.lastManagementAccrual += uint48(elapsed);
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

    function _hashTypedDataV4(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    function _domainSeparatorV4() private view returns (bytes32) {
        return
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAV_NAME_HASH, NAV_VERSION_HASH, block.chainid, address(this)));
    }
}
