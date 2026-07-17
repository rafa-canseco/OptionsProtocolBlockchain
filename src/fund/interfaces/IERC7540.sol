// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.24;

interface IERC7540Operator {
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function isOperator(address controller, address operator) external view returns (bool status);
    function setOperator(address operator, bool approved) external returns (bool success);
}

interface IERC7540Redeem {
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
}
