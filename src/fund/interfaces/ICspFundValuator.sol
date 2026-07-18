// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ICspFundValuator {
    struct OptionObservation {
        uint256 positionId;
        uint64 snapshotBlock;
        uint64 validUntilBlock;
        uint256 liability;
        uint256 baseExitCost;
        uint256 nonce;
        bytes signature;
    }

    struct ValuationData {
        OptionObservation[] optionObservations;
    }

    error AccountingDeficit(address asset, uint256 accounted, uint256 actual);
    error DuplicateObserver(address observer);
    error InsufficientObservationQuorum(uint256 positionId, uint256 required, uint256 actual);
    error InvalidAdapter(address adapter);
    error InvalidObservation(uint256 positionId);
    error InvalidSnapshotBlock(uint64 expected, uint64 actual);
    error InvalidSpotObservation();
    error LedgerMismatch(uint256 positionId);
    error PendingPhysicalDelivery(uint256 positionId);
    error UnapprovedObserver(address observer);

    function observationDigest(
        address adapter,
        uint256 positionId,
        uint64 snapshotBlock,
        uint64 validUntilBlock,
        uint256 liability,
        uint256 baseExitCost,
        uint256 nonce
    ) external view returns (bytes32);
}
