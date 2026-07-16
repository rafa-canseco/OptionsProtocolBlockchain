// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IFundFlowManager {
    error ClaimExceedsAvailable();
    error InvalidRequestId(uint256 requestId);
    error RequestNotCancelable();
    error UnauthorizedOperator(address controller, address caller);

    function fund() external view returns (address);
    function compatibilityVersion() external view returns (uint64);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256);
    function isOperator(address controller, address operator) external view returns (bool);

    function recordRedeemRequest(address caller, uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);
    function processRedeemBatch(uint64 batchId, uint256 shares, uint256 assets, uint256 marginalExitCost) external;
    function consumeClaim(address caller, address controller, uint256 shares) external returns (uint256 assets);
    function cancelPending(address caller, address controller, uint256 shares) external;
    function setExitPolicy(uint16 maxExitFeeBps, uint16 maxWindowOutflowBps) external;
}
