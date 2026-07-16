// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IFundFlowManager {
    error BatchCapacityExceeded(uint64 batchId);
    error BatchNotProcessable(uint64 batchId);
    error ClaimExceedsAvailable();
    error InvalidProcessingPage(uint16 requested, uint16 maximum);
    error MinimumAssetsNotMet(address controller, uint256 minimum, uint256 actual);
    error PendingRequestInSealedBatch(address controller, uint64 batchId);
    error RequestNotCancelable();
    error UnauthorizedOperator(address controller, address caller);

    function fund() external view returns (address);
    function compatibilityVersion() external view returns (uint64);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function isOperator(address controller, address operator) external view returns (bool);

    function recordRedeemRequest(
        address caller,
        uint256 shares,
        address controller,
        address owner,
        uint256 minAssetsOut
    ) external returns (uint256 requestId);
    function sealRedeemBatch(uint64 batchId) external;
    function startRedeemBatch(uint64 batchId, uint256 shares, uint256 marginalExitCost) external;
    function processRedeemBatch(uint64 batchId, uint16 maxControllers)
        external
        returns (uint16 processedControllers, bool roundComplete);
    function consumeClaim(address caller, address controller, uint256 shares) external returns (uint256 assets);
    function cancelPending(address caller, address controller, uint256 shares) external;
    function setExitPolicy(uint16 maxExitFeeBps, uint16 maxWindowOutflowBps) external;
}
