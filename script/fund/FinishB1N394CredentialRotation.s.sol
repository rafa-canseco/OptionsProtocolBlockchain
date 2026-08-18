// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {B1N394Base} from "./B1N394Base.sol";

/// @notice Removes every remaining V2 AccessManager role from the retired Base Sepolia signer.
contract FinishB1N394CredentialRotation is B1N394Base {
    address private constant RETIRING_SIGNER = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;

    function run() external {
        _requireBaseSepolia();
        address governance = vm.envAddress("B1N394_NEW_GOVERNANCE");
        _requireImmediateRole(AccessManager(CSP_ACCESS), 0, governance);
        _requireImmediateRole(AccessManager(CC_ACCESS), 0, governance);

        vm.startBroadcast(governance);
        _revokeCsp(AccessManager(CSP_ACCESS));
        _revokeCc(AccessManager(CC_ACCESS));
        vm.stopBroadcast();

        for (uint64 role; role <= FundConstants.ADAPTER_UPGRADER_ROLE; ++role) {
            (bool active,) = AccessManager(CSP_ACCESS).hasRole(role, RETIRING_SIGNER);
            require(!active, "B1N394: CSP retired role");
            (active,) = AccessManager(CC_ACCESS).hasRole(role, RETIRING_SIGNER);
            require(!active, "B1N394: CC retired role");
        }
    }

    function _revokeCsp(AccessManager access) private {
        access.revokeRole(FundConstants.UPGRADER_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.ACCOUNTING_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.ALLOCATOR_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.PROCESSOR_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.CURATOR_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.GUARDIAN_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.REPORTER_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.ADAPTER_UPGRADER_ROLE, RETIRING_SIGNER);
        access.revokeRole(0, RETIRING_SIGNER);
    }

    function _revokeCc(AccessManager access) private {
        access.revokeRole(FundConstants.UPGRADER_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.ACCOUNTING_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.ALLOCATOR_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.PROCESSOR_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.CURATOR_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.GUARDIAN_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.REPORTER_ROLE, RETIRING_SIGNER);
        access.revokeRole(FundConstants.ADAPTER_UPGRADER_ROLE, RETIRING_SIGNER);
        access.revokeRole(0, RETIRING_SIGNER);
    }
}
