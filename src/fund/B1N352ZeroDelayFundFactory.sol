// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FundFactory} from "./FundFactory.sol";
import {FundAccessManager} from "./FundAccessManager.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundVault} from "./FundVault.sol";

/// @notice One-shot B1N-352 v2 Fund factory restricted to Base Sepolia.
/// @dev The production FundFactory keeps its governance delays. This deployment-only
///      specialization creates one supervised testnet Fund with zero AccessManager delays.
contract B1N352ZeroDelayFundFactory is FundFactory {
    uint256 public constant DEPLOYMENT_CHAIN_ID = 84_532;

    error WrongDeploymentChain(uint256 actualChainId);
    error FundAlreadyCreated();

    constructor(address initialOwner) FundFactory(initialOwner) {
        _requireDeploymentChain();
    }

    function createFund(CreateFundParams calldata params)
        public
        override
        onlyOwner
        returns (FundDeployment memory deployed)
    {
        _requireDeploymentChain();
        if (fundCreated) revert FundAlreadyCreated();
        fundCreated = true;
        return super.createFund(params);
    }

    bool public fundCreated;

    function _configureAuthority(FundAccessManager manager, RoleAccounts calldata roles, FundDeployment memory)
        internal
        override
    {
        manager.setRoleGuardian(FundConstants.CURATOR_ROLE, FundConstants.GUARDIAN_ROLE);
        manager.grantRole(FundConstants.UPGRADER_ROLE, roles.upgrader, 0);
        manager.grantRole(FundConstants.ADAPTER_UPGRADER_ROLE, roles.upgrader, 0);
        manager.grantRole(FundConstants.ACCOUNTING_ROLE, roles.accounting, 0);
        manager.grantRole(FundConstants.ALLOCATOR_ROLE, roles.allocator, 0);
        manager.grantRole(FundConstants.PROCESSOR_ROLE, roles.processor, 0);
        manager.grantRole(FundConstants.CURATOR_ROLE, roles.curator, 0);
        manager.grantRole(FundConstants.GUARDIAN_ROLE, roles.guardian, 0);
        manager.grantRole(manager.ADMIN_ROLE(), roles.admin, 0);
        manager.renounceRole(manager.ADMIN_ROLE(), address(this));
    }

    function _beforeRulesConfigured(address vault) internal override {
        FundVault(vault).pauseDeposits();
    }

    function _requireDeploymentChain() private view {
        if (block.chainid != DEPLOYMENT_CHAIN_ID) revert WrongDeploymentChain(block.chainid);
    }
}
