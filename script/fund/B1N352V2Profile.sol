// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library B1N352V2Profile {
    uint256 internal constant CHAIN_ID = 84_532;
    uint64 internal constant NAV_ACTIVATION_BLOCKS = 1;
    uint64 internal constant MIN_EXPIRY_SECONDS = 1;
    uint64 internal constant FALLBACK_DELAY_SECONDS = 1;
    uint32 internal constant STRATEGY_COOLDOWN_SECONDS = 0;
    uint16 internal constant MINIMUM_IDLE_BPS = 7_500;
    uint16 internal constant MAX_ALLOCATION_BPS = 2_500;
    uint16 internal constant MAX_EXIT_FEE_BPS = 0;
    uint256 internal constant FUND_CAP = 25e6;
    uint256 internal constant COLLATERAL_CAP = 25e6;
    uint16 internal constant MAX_POSITIONS = 3;
}
