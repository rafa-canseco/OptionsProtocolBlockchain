// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IFundFlowManager {
    error BatchCapacityExceeded(uint64 batchId);
    error BatchNotProcessable(uint64 batchId);
    error BatchNotReleasable(uint64 batchId);
    error ClaimExceedsAvailable();
    error InvalidProcessingPage(uint16 requested, uint16 maximum);
    error InvalidMarginalExitCost(uint256 expected, uint256 actual);
    error MinimumAssetsNotMet(address controller, uint256 minimum, uint256 actual);
    error PendingRequestInSealedBatch(address controller, uint64 batchId);
    error RequestOwnerMismatch(address controller, address expectedOwner, address actualOwner);
    error RequestNotCancelable();
    error StrategyExitBatchInvalid(bytes32 batchId);
    error UnauthorizedOperator(address controller, address caller);

    event RedeemBatchReleased(uint64 indexed batchId);
    event StrategyExitEscrowsUpdated(address indexed inKindEscrow, address indexed emergencyEscrow);
    event StrategyInKindBatchAuthorized(
        bytes32 indexed batchId, address indexed adapter, address indexed escrow, uint256 fractionWad, uint64 validUntil
    );
    event StrategyInKindBatchConsumed(bytes32 indexed batchId, address indexed adapter);

    function fund() external view returns (address);
    function compatibilityVersion() external view returns (uint64);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function isOperator(address controller, address operator) external view returns (bool);
    function windowOutflow(uint64 reportNonce) external view returns (uint256 eligibleSupply, uint256 processedShares);
    function strategyExitEscrows() external view returns (address inKindEscrow, address emergencyEscrow);
    function claimEscrow() external view returns (address);
    function strategyInKindBatch(bytes32 batchId)
        external
        view
        returns (address adapter, address escrow, uint64 validUntil, bool consumed, uint256 fractionWad);

    function recordRedeemRequest(
        address caller,
        address shareSpender,
        uint256 shares,
        address controller,
        address owner,
        uint256 minAssetsOut
    ) external returns (uint256 requestId);
    function sealRedeemBatch(uint64 batchId) external;
    function releaseRedeemBatch(uint64 batchId) external;
    function startRedeemBatch(uint64 batchId, uint256 shares, uint256 marginalExitCost) external;
    function processRedeemBatch(uint64 batchId, uint16 maxControllers)
        external
        returns (uint16 processedControllers, bool roundComplete);
    function consumeClaim(address caller, address controller, uint256 shares) external returns (uint256 assets);
    function cancelPending(address caller, address controller, uint256 shares) external;
    function setExitPolicy(uint16 maxExitFeeBps, uint16 maxWindowOutflowBps) external;
    function setStrategyExitEscrows(address inKindEscrow, address emergencyEscrow) external;
    function authorizeStrategyInKindBatch(bytes32 batchId, address adapter, uint256 fractionWad, uint64 validUntil)
        external;
    function consumeStrategyInKindBatch(bytes32 batchId, address adapter, uint256 fractionWad)
        external
        returns (address escrow);
}
