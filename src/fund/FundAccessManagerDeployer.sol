// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundAccessManager} from "./FundAccessManager.sol";

/// @notice Isolates FundAccessManager creation code from FundFactory's EIP-170 runtime budget.
contract FundAccessManagerDeployer {
    error OnlyFundFactory();

    address public immutable FUND_FACTORY;

    constructor() {
        FUND_FACTORY = msg.sender;
    }

    function deploy() external returns (FundAccessManager manager) {
        if (msg.sender != FUND_FACTORY) revert OnlyFundFactory();
        manager = new FundAccessManager(msg.sender);
    }
}
