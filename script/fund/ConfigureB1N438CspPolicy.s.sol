// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {EthCspOptionSelector} from "../../src/vaults/EthCspOptionSelector.sol";
import {EthCspVault} from "../../src/vaults/EthCspVault.sol";
import {IEthCspOptionSelector} from "../../src/vaults/interfaces/IEthCspOptionSelector.sol";

/// @notice Preflights the Base Sepolia B1N-438 CSP objective policy without mutating runtime state.
/// @dev Execution is rejected; delayed AccessManager operations require a separately reviewed phase script.
contract ConfigureB1N438CspPolicy is Script {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant TARGET_UTILIZATION_BPS = 8_000;
    uint256 private constant TARGET_MIN_PREMIUM_BPS = 20;
    uint256 private constant TARGET_MIN_EXPIRY = 36 hours;
    uint256 private constant TARGET_MAX_EXPIRY = 60 hours;
    uint16 private constant TARGET_MINIMUM_IDLE_BPS = 2_000;
    bytes32 private constant PREVIOUS_META_WHEEL_POLICY_HASH =
        0xdb47fcd1f4f96b656fe462956c85194b1f5e25d0c1d8c8862864b256d38fa93c;
    bytes32 private constant TARGET_META_WHEEL_POLICY_HASH =
        0x22e43a8c3c59627c5d08271585b0cf88f80f915d45f0360f71e5d84127172bf1;

    struct StandaloneState {
        EthCspVault vault;
        EthCspOptionSelector selector;
        EthCspVault.StrategyConfig vaultConfig;
        IEthCspOptionSelector.StrategyConfig selectorConfig;
        uint256 performanceFeeBps;
        uint256 protocolFeeBps;
    }

    struct FundState {
        StrategyManager manager;
        address adapter;
        FundTypes.StrategyConfig strategyConfig;
        ICspFundAdapter.AdapterConfig adapterConfig;
        FundTypes.FeeConfig feeConfig;
        uint16 minimumIdleBps;
        uint256 protocolFeeBps;
    }

    struct MetaWheelState {
        StrategyManager manager;
        WheelCoordinatorAdapter coordinator;
        bytes32 policyHash;
    }

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "B1N438: Base Sepolia only");
        StandaloneState memory standalone = _preflightStandalone();
        FundState memory fund = _preflightFund();
        MetaWheelState memory metaWheel = _preflightMetaWheel();

        bool execute = vm.envOr("B1N438_EXECUTE", false);
        require(!execute, "B1N438: preflight only; use reviewed AccessManager schedule/execute phases");

        console2.log("B1N438_EXECUTE", execute);
        console2.log("B1N438_STANDALONE_NEEDS_UPDATE", _standaloneNeedsUpdate(standalone));
        console2.log("B1N438_FUND_NEEDS_UPDATE", _fundNeedsUpdate(fund));
        console2.log("B1N438_META_WHEEL_NEEDS_UPDATE", _metaWheelNeedsUpdate(metaWheel));
        console2.log("B1N438_TARGET_UTILIZATION_BPS", TARGET_UTILIZATION_BPS);
        console2.log("B1N438_TARGET_MIN_PREMIUM_BPS", TARGET_MIN_PREMIUM_BPS);
        console2.log("B1N438_TARGET_MIN_EXPIRY", TARGET_MIN_EXPIRY);
        console2.log("B1N438_TARGET_MAX_EXPIRY", TARGET_MAX_EXPIRY);
        console2.logBytes32(TARGET_META_WHEEL_POLICY_HASH);
    }

    function _preflightStandalone() private view returns (StandaloneState memory state) {
        state.vault = EthCspVault(vm.envAddress("B1N438_STANDALONE_CSP_VAULT"));
        state.selector = EthCspOptionSelector(vm.envAddress("B1N438_STANDALONE_CSP_SELECTOR"));
        require(
            address(state.vault).code.length != 0 && address(state.selector).code.length != 0, "B1N438: standalone code"
        );
        require(state.vault.optionSelector() == address(state.selector), "B1N438: selector binding");
        require(
            address(state.vault.underlying()) != address(0) && address(state.vault.usdc()) != address(0),
            "B1N438: standalone assets"
        );

        state.vaultConfig = _readVaultConfig(state.vault);
        state.selectorConfig = _readSelectorConfig(state.selector);
        _requireRecognizedStandalone(state.vaultConfig);
        _requireRecognizedStandaloneSelector(state.selectorConfig);
        state.performanceFeeBps = state.vault.performanceFeeBps();
        state.protocolFeeBps = BatchSettler(state.vault.addressBook().batchSettler()).protocolFeeBps();
    }

    function _preflightFund() private view returns (FundState memory state) {
        state.manager = StrategyManager(vm.envAddress("B1N438_CSP_STRATEGY_MANAGER"));
        state.adapter = vm.envAddress("B1N438_CSP_FUND_ADAPTER");
        require(address(state.manager).code.length != 0 && state.adapter.code.length != 0, "B1N438: fund code");
        require(ICspFundAdapter(state.adapter).strategyManager() == address(state.manager), "B1N438: manager binding");

        state.strategyConfig = state.manager.strategyConfig(state.adapter);
        state.adapterConfig = ICspFundAdapter(state.adapter).adapterConfig();
        state.minimumIdleBps = state.manager.minimumIdleBps();
        require(
            state.strategyConfig.maxAllocationBps == 2_500
                || state.strategyConfig.maxAllocationBps == TARGET_UTILIZATION_BPS,
            "B1N438: unexpected fund utilization"
        );
        require(
            state.minimumIdleBps == 7_500 || state.minimumIdleBps == TARGET_MINIMUM_IDLE_BPS,
            "B1N438: unexpected fund idle policy"
        );
        _requireRecognizedFundRisk(state.adapterConfig.riskConfig);

        FundVault vault = FundVault(state.manager.fund());
        state.feeConfig = FundAccounting(vault.accounting()).feeConfig();
        state.protocolFeeBps =
            BatchSettler(AddressBook(ICspFundAdapter(state.adapter).addressBook()).batchSettler()).protocolFeeBps();
    }

    function _preflightMetaWheel() private view returns (MetaWheelState memory state) {
        state.manager = StrategyManager(vm.envAddress("B1N438_META_STRATEGY_MANAGER"));
        state.coordinator = WheelCoordinatorAdapter(vm.envAddress("B1N438_META_COORDINATOR"));
        require(
            address(state.manager).code.length != 0 && address(state.coordinator).code.length != 0,
            "B1N438: meta wheel code"
        );
        require(state.coordinator.fund() == state.manager.fund(), "B1N438: meta wheel manager binding");
        require(
            state.manager.strategyConfig(address(state.coordinator)).interfaceVersion == 1,
            "B1N438: meta wheel strategy"
        );
        state.policyHash = state.coordinator.policyHash();
        require(
            state.policyHash == PREVIOUS_META_WHEEL_POLICY_HASH || state.policyHash == TARGET_META_WHEEL_POLICY_HASH,
            "B1N438: unexpected meta wheel policy"
        );
    }

    function _standaloneNeedsUpdate(StandaloneState memory state) private pure returns (bool) {
        return !_isTarget(state.vaultConfig) || !_isTarget(state.selectorConfig);
    }

    function _fundNeedsUpdate(FundState memory state) private pure returns (bool) {
        return state.strategyConfig.maxAllocationBps != TARGET_UTILIZATION_BPS
            || state.minimumIdleBps != TARGET_MINIMUM_IDLE_BPS || !_isTarget(state.adapterConfig.riskConfig);
    }

    function _metaWheelNeedsUpdate(MetaWheelState memory state) private pure returns (bool) {
        return state.policyHash != TARGET_META_WHEEL_POLICY_HASH;
    }

    function _requireRecognizedStandalone(EthCspVault.StrategyConfig memory config) private pure {
        if (_isTarget(config)) return;
        require(
            config.maxUtilizationBps == 2_500 && config.minPremiumBps == 1 && config.minExpiryDelay == 1 hours
                && config.maxExpiryDelay == 30 days,
            "B1N438: unexpected vault policy"
        );
    }

    function _requireRecognizedStandaloneSelector(IEthCspOptionSelector.StrategyConfig memory config) private pure {
        if (_isTarget(config)) return;
        require(
            config.maxUtilizationBps == 2_500 && config.minPremiumBps == 1 && config.minExpiryDelay == 1 hours
                && config.maxExpiryDelay == 30 days,
            "B1N438: unexpected selector policy"
        );
    }

    function _requireRecognizedFundRisk(ICspFundAdapter.RiskConfig memory risk) private pure {
        if (_isTarget(risk)) return;
        require(
            risk.minPremiumBps == 1 && (risk.minExpiryDelay == 1 || risk.minExpiryDelay == 1 hours)
                && risk.maxExpiryDelay == 7 days,
            "B1N438: unexpected fund risk"
        );
    }

    function _isTarget(EthCspVault.StrategyConfig memory config) private pure returns (bool) {
        return config.maxUtilizationBps == TARGET_UTILIZATION_BPS && config.minPremiumBps == TARGET_MIN_PREMIUM_BPS
            && config.minExpiryDelay == TARGET_MIN_EXPIRY && config.maxExpiryDelay == TARGET_MAX_EXPIRY;
    }

    function _isTarget(IEthCspOptionSelector.StrategyConfig memory config) private pure returns (bool) {
        return config.maxUtilizationBps == TARGET_UTILIZATION_BPS && config.minPremiumBps == TARGET_MIN_PREMIUM_BPS
            && config.minExpiryDelay == TARGET_MIN_EXPIRY && config.maxExpiryDelay == TARGET_MAX_EXPIRY;
    }

    function _isTarget(ICspFundAdapter.RiskConfig memory risk) private pure returns (bool) {
        return risk.minPremiumBps == TARGET_MIN_PREMIUM_BPS && risk.minExpiryDelay == TARGET_MIN_EXPIRY
            && risk.maxExpiryDelay == TARGET_MAX_EXPIRY;
    }

    function _readVaultConfig(EthCspVault vault) private view returns (EthCspVault.StrategyConfig memory config) {
        (
            config.maxCollateralPerBatch,
            config.maxUtilizationBps,
            config.minPremiumBps,
            config.minExpiryDelay,
            config.maxExpiryDelay,
            config.minStrike,
            config.maxStrike
        ) = vault.strategyConfig();
    }

    function _readSelectorConfig(EthCspOptionSelector selector)
        private
        view
        returns (IEthCspOptionSelector.StrategyConfig memory config)
    {
        (
            config.maxCollateralPerBatch,
            config.maxUtilizationBps,
            config.minPremiumBps,
            config.minExpiryDelay,
            config.maxExpiryDelay,
            config.minStrike,
            config.maxStrike
        ) = selector.strategyConfig();
    }
}
