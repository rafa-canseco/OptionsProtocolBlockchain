// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundTypes} from "../FundTypes.sol";

interface INavReportVerifier {
    struct VerifyNavReportParams {
        address fund;
        uint64 reportNonce;
        uint64 reporterSetVersion;
        uint16 reporterThreshold;
        uint64 activationDelay;
        uint64 maxSnapshotAge;
        uint64 maxWindowLength;
        bytes32 reportHash;
        bytes32 digest;
    }

    function interfaceVersion() external pure returns (uint64);

    function verifyNavReport(
        VerifyNavReportParams calldata params,
        FundTypes.ComponentReport[] calldata reports,
        address[] calldata reporters,
        bytes[] calldata signatures
    ) external view returns (FundTypes.NavCommit memory nav);
}
