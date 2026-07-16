// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC7540Operator, IERC7540Redeem} from "./IERC7540.sol";
import {IERC7575} from "./IERC7575.sol";
import {FundTypes} from "../FundTypes.sol";

interface IFundVault is IERC165, IERC20Permit, IERC7540Operator, IERC7540Redeem, IERC7575 {
    error FundExecutionLocked(address lockOwner);
    error InactiveNavWindow();
    error InvalidModule(address caller);
    error IncompatibleModuleVersion(uint64 expected, uint64 actual);
    error MinimumSharesNotMet(uint256 minimum, uint256 actual);
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
