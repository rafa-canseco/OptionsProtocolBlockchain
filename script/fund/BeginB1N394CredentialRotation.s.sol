// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {B1N394Base} from "./B1N394Base.sol";

interface IB1N394TwoStepOwner {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IB1N394Owner {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice Starts the Base Sepolia credential rotation while the retiring signer is still authorized.
contract BeginB1N394CredentialRotation is B1N394Base {
    address private constant RETIRING_SIGNER = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant SECONDARY_REPORTER = 0xE02458C6575bA6dF2449809660D46444281F4aff;
    address private constant ADDRESS_BOOK = 0x033d9d37Baf83dBc71935239b6fA22a6905dbaa0;
    address private constant CONTROLLER = 0xD52EFbBaA1b02BA65A7f0A1604A5dFb4C4dB1572;
    address private constant ORACLE = 0xF95CC4aED4a0bD68e0F1BE7c779BC281189F8187;
    address private constant WHITELIST = 0xe0Ca66a93341eB0af0C136651c8B57C187aa60Ab;
    address private constant CSP_FACTORY = 0xf8b508271F92eE5DC81a9Bc8E569C7Ff458E517C;
    address private constant CC_FACTORY = 0x6F5b59047629730f973c75c8941d88Ed526946b8;
    address private constant CSP_SHARE = 0x07Db1F574ecCFD15c4A8bd4582e5d25baA84De7d;
    address private constant CC_SHARE = 0xaA1070adb74C5455320285618BF1ED804d3745C3;

    function run() external {
        _requireBaseSepolia();
        address broadcaster = vm.envAddress("B1N394_BROADCASTER");
        address governance = vm.envAddress("B1N394_NEW_GOVERNANCE");
        address navReporter = vm.envAddress("B1N394_NEW_NAV_REPORTER");
        address operator = vm.envAddress("B1N394_NEW_OPERATOR");
        require(
            broadcaster == RETIRING_SIGNER && governance != address(0) && navReporter != address(0)
                && operator != address(0) && governance != navReporter && governance != operator
                && navReporter != operator,
            "B1N394: rotation identities"
        );

        _requireReporterSet(FundAccounting(CSP_ACCOUNTING));
        _requireReporterSet(FundAccounting(CC_ACCOUNTING));
        _requireOwnedByRetiringSigner();

        vm.startBroadcast(broadcaster);
        _grantGovernance(AccessManager(CSP_ACCESS), governance);
        _grantGovernance(AccessManager(CC_ACCESS), governance);
        _grantCspOperations(AccessManager(CSP_ACCESS), operator);
        _rotateFund(AccessManager(CSP_ACCESS), FundAccounting(CSP_ACCOUNTING), navReporter, governance);
        _rotateFund(AccessManager(CC_ACCESS), FundAccounting(CC_ACCOUNTING), navReporter, governance);
        _startOwnershipTransfers(governance);
        IB1N394Owner(CSP_FACTORY).transferOwnership(governance);
        IB1N394Owner(CC_FACTORY).transferOwnership(governance);
        _transferBalance(CSP_SHARE, governance);
        _transferBalance(CC_SHARE, governance);
        vm.stopBroadcast();

        _requireGovernanceRoles(AccessManager(CSP_ACCESS), governance);
        _requireGovernanceRoles(AccessManager(CC_ACCESS), governance);
        _requireImmediateRole(AccessManager(CSP_ACCESS), FundConstants.ACCOUNTING_ROLE, operator);
        _requireImmediateRole(AccessManager(CSP_ACCESS), FundConstants.ALLOCATOR_ROLE, operator);
        _requireImmediateRole(AccessManager(CSP_ACCESS), FundConstants.PROCESSOR_ROLE, operator);
        _requireRotatedFund(FundAccounting(CSP_ACCOUNTING), navReporter, governance);
        _requireRotatedFund(FundAccounting(CC_ACCOUNTING), navReporter, governance);
        _requirePendingGovernance(governance);
        require(IB1N394Owner(CSP_FACTORY).owner() == governance, "B1N394: CSP factory owner");
        require(IB1N394Owner(CC_FACTORY).owner() == governance, "B1N394: CC factory owner");
        require(IERC20(CSP_SHARE).balanceOf(RETIRING_SIGNER) == 0, "B1N394: CSP shares");
        require(IERC20(CC_SHARE).balanceOf(RETIRING_SIGNER) == 0, "B1N394: CC shares");
    }

    function _grantGovernance(AccessManager access, address governance) private {
        access.grantRole(0, governance, 0);
        access.grantRole(FundConstants.UPGRADER_ROLE, governance, 0);
        access.grantRole(FundConstants.CURATOR_ROLE, governance, 0);
        access.grantRole(FundConstants.GUARDIAN_ROLE, governance, 0);
        access.grantRole(FundConstants.ADAPTER_UPGRADER_ROLE, governance, 0);
    }

    function _grantCspOperations(AccessManager access, address operator) private {
        access.grantRole(FundConstants.ACCOUNTING_ROLE, operator, 0);
        access.grantRole(FundConstants.ALLOCATOR_ROLE, operator, 0);
        access.grantRole(FundConstants.PROCESSOR_ROLE, operator, 0);
    }

    function _rotateFund(AccessManager access, FundAccounting accounting, address navReporter, address governance)
        private
    {
        address[] memory reporters = new address[](2);
        reporters[0] = navReporter;
        reporters[1] = SECONDARY_REPORTER;
        FundTypes.FeeConfig memory fees = accounting.feeConfig();
        fees.feeRecipient = governance;
        bytes[] memory calls = new bytes[](2);
        calls[0] = _managedCall(
            access,
            RETIRING_SIGNER,
            address(accounting),
            abi.encodeCall(accounting.setReporterSet, (reporters, uint16(1), uint64(2))),
            FundConstants.CURATOR_ROLE
        );
        calls[1] = _managedCall(
            access,
            RETIRING_SIGNER,
            address(accounting),
            abi.encodeCall(accounting.setFeeConfig, (fees)),
            FundConstants.CURATOR_ROLE
        );
        access.multicall(calls);
    }

    function _startOwnershipTransfers(address governance) private {
        IB1N394TwoStepOwner(ADDRESS_BOOK).transferOwnership(governance);
        IB1N394TwoStepOwner(CONTROLLER).transferOwnership(governance);
        IB1N394TwoStepOwner(ORACLE).transferOwnership(governance);
        IB1N394TwoStepOwner(WHITELIST).transferOwnership(governance);
        IB1N394TwoStepOwner(BATCH_SETTLER).transferOwnership(governance);
    }

    function _transferBalance(address token, address governance) private {
        uint256 balance = IERC20(token).balanceOf(RETIRING_SIGNER);
        if (balance != 0) require(IERC20(token).transfer(governance, balance), "B1N394: share transfer");
    }

    function _requireReporterSet(FundAccounting accounting) private view {
        require(
            accounting.reporterSetVersion() == 1 && accounting.reporterThreshold() == 1
                && accounting.activeReporterCount() == 2 && accounting.activeReporterAt(0) == RETIRING_SIGNER
                && accounting.activeReporterAt(1) == SECONDARY_REPORTER,
            "B1N394: prior reporter set"
        );
    }

    function _requireOwnedByRetiringSigner() private view {
        require(IB1N394TwoStepOwner(ADDRESS_BOOK).owner() == RETIRING_SIGNER, "B1N394: address book owner");
        require(IB1N394TwoStepOwner(CONTROLLER).owner() == RETIRING_SIGNER, "B1N394: controller owner");
        require(IB1N394TwoStepOwner(ORACLE).owner() == RETIRING_SIGNER, "B1N394: oracle owner");
        require(IB1N394TwoStepOwner(WHITELIST).owner() == RETIRING_SIGNER, "B1N394: whitelist owner");
        require(IB1N394TwoStepOwner(BATCH_SETTLER).owner() == RETIRING_SIGNER, "B1N394: settler owner");
        require(IB1N394Owner(CSP_FACTORY).owner() == RETIRING_SIGNER, "B1N394: CSP factory owner");
        require(IB1N394Owner(CC_FACTORY).owner() == RETIRING_SIGNER, "B1N394: CC factory owner");
    }

    function _requireGovernanceRoles(AccessManager access, address governance) private view {
        _requireImmediateRole(access, 0, governance);
        _requireImmediateRole(access, FundConstants.UPGRADER_ROLE, governance);
        _requireImmediateRole(access, FundConstants.CURATOR_ROLE, governance);
        _requireImmediateRole(access, FundConstants.GUARDIAN_ROLE, governance);
        _requireImmediateRole(access, FundConstants.ADAPTER_UPGRADER_ROLE, governance);
    }

    function _requireRotatedFund(FundAccounting accounting, address navReporter, address governance) private view {
        require(
            accounting.reporterSetVersion() == 2 && accounting.reporterThreshold() == 1
                && accounting.activeReporterCount() == 2 && accounting.activeReporterAt(0) == navReporter
                && accounting.activeReporterAt(1) == SECONDARY_REPORTER && !accounting.isReporter(RETIRING_SIGNER)
                && accounting.feeConfig().feeRecipient == governance,
            "B1N394: rotated fund"
        );
    }

    function _requirePendingGovernance(address governance) private view {
        require(IB1N394TwoStepOwner(ADDRESS_BOOK).pendingOwner() == governance, "B1N394: address book pending");
        require(IB1N394TwoStepOwner(CONTROLLER).pendingOwner() == governance, "B1N394: controller pending");
        require(IB1N394TwoStepOwner(ORACLE).pendingOwner() == governance, "B1N394: oracle pending");
        require(IB1N394TwoStepOwner(WHITELIST).pendingOwner() == governance, "B1N394: whitelist pending");
        require(IB1N394TwoStepOwner(BATCH_SETTLER).pendingOwner() == governance, "B1N394: settler pending");
    }
}
