// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundFactory} from "../../src/fund/FundFactory.sol";
import {B1N352ZeroDelayFundFactory} from "../../src/fund/B1N352ZeroDelayFundFactory.sol";
import {B1N352V2Profile} from "./B1N352V2Profile.sol";
import {DeployTokenizedCspFundBaseSepolia} from "./DeployTokenizedCspFundBaseSepolia.s.sol";

/// @notice B1N-352 v2 deployment using the approved-input, codehash-pinned Base Sepolia path.
/// @dev Inherits the complete B1N-336 baseline and approved artifact checks from the canonical deploy script.
contract DeployTokenizedCspFundBaseSepoliaV2 is DeployTokenizedCspFundBaseSepolia {
    function _newFactory(address deployer) internal override returns (FundFactory) {
        return new B1N352ZeroDelayFundFactory(deployer);
    }

    function _validateDeploymentProfile(DeployConfig memory config) internal view override {
        address authority = _approvedAddress("FUND_PHASE_SCHEDULER");
        require(config.factoryOwner == authority, "B1N352V2: factory owner");
        require(
            config.roles.admin == authority && config.roles.upgrader == authority
                && config.roles.accounting == authority && config.roles.allocator == authority
                && config.roles.processor == authority && config.roles.curator == authority
                && config.roles.guardian == authority,
            "B1N352V2: role authority"
        );
        require(config.navActivationDelay == B1N352V2Profile.NAV_ACTIVATION_BLOCKS, "B1N352V2: NAV delay");
        require(config.adapterRiskConfig.minExpiryDelay == B1N352V2Profile.MIN_EXPIRY_SECONDS, "B1N352V2: min expiry");
        require(
            config.adapterRiskConfig.settlementDefaultDelay == B1N352V2Profile.FALLBACK_DELAY_SECONDS,
            "B1N352V2: fallback delay"
        );
        require(config.adapterRiskConfig.maxOpenPositions == B1N352V2Profile.MAX_POSITIONS, "B1N352V2: max positions");
        require(
            config.adapterRiskConfig.maxCollateralPerPosition == B1N352V2Profile.COLLATERAL_CAP,
            "B1N352V2: collateral cap"
        );
        require(
            config.feeConfig.managementFeeWad == 0 && config.feeConfig.performanceFeeBps == 0
                && config.feeConfig.maxManagementFeeBps == 0 && config.feeConfig.maxPerformanceFeeBps == 0
                && config.feeConfig.maxAccrualInterval == 0 && config.feeConfig.crystallizationPeriod == 0,
            "B1N352V2: nonzero fee"
        );
    }
}
