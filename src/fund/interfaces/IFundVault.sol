// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC7540Operator, IERC7540Redeem} from "./IERC7540.sol";
import {IERC7575} from "./IERC7575.sol";
import {FundTypes} from "../FundTypes.sol";

interface IFundVault is IERC165, IERC7540Operator, IERC7540Redeem, IERC7575 {
    error FundExecutionLocked(address lockOwner);
    error InactiveNavWindow();
    error InvalidModule(address caller);
    error IncompatibleModuleVersion(uint64 expected, uint64 actual);
    error MinimumSharesNotMet(uint256 minimum, uint256 actual);
    error ZeroSharesDeposit(uint256 assets);
    error UnsupportedAccountingAssetDecimals(uint8 decimals);
    error UnaccountedBalance(address asset, uint256 amount);

    function accounting() external view returns (address);
    function flowManager() external view returns (address);
    function strategyManager() external view returns (address);
    function claimEscrow() external view returns (address);
    function distributionEscrow() external view returns (address);
    function compatibilityVersion() external view returns (uint64);
    function committedNav() external view returns (uint256);
    function reservedClaimAssets() external view returns (uint256);
    function fundFlowNonce() external view returns (uint64);
    function idleStateHash() external view returns (bytes32);
    function virtualShares() external view returns (uint256);
    function shareSupply() external view returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function maxWithdraw(address controller) external view returns (uint256 maxAssets);
    function maxRedeem(address controller) external view returns (uint256 maxShares);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address controller) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
    function activeNavWindow() external view returns (FundTypes.NavCommit memory);
    function depositWithMinShares(uint256 assets, address receiver, uint256 minSharesOut)
        external
        returns (uint256 shares);
    function requestRedeemWithMinAssets(uint256 shares, address controller, address owner, uint256 minAssetsOut)
        external
        returns (uint256 requestId);

    function commitNav(FundTypes.NavCommit calldata nav, uint256 feeShares, address feeRecipient) external;
    function processAccountingAssetClaim(address controller, uint256 shares, uint256 assets) external;
    function transferToStrategy(address asset, address adapter, uint256 amount) external;
    function beginModuleExecution(uint64 moduleVersion) external returns (uint256 lockId);
    function endModuleExecution(uint256 lockId) external;
    function pauseDeposits() external;
    function pauseRedemptions() external;
    function resumeDeposits() external;
    function resumeRedemptions() external;
}
