// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint amount,
        uint premium,
        address initiator,
        bytes calldata params
    )
        external
        returns (bool);
}
