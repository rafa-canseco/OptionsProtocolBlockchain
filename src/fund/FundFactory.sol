// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FundVault} from "./FundVault.sol";
import {FundShare} from "./FundShare.sol";
import {FundAccounting} from "./FundAccounting.sol";
import {FundFlowManager} from "./FundFlowManager.sol";
import {StrategyManager} from "./StrategyManager.sol";
import {ClaimEscrow} from "./ClaimEscrow.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {FundAccessPolicy} from "./libraries/FundAccessPolicy.sol";

/// @notice Versioned deployer for isolated modular fund stacks.
/// @dev The factory never receives authority over deployed fund assets.
contract FundFactory is Ownable {
    error InvalidImplementationSet(uint64 version);
    error InvalidRoleAccount();
    error VersionAlreadyRegistered(uint64 version);

    struct ImplementationSet {
        address vault;
        address share;
        address accounting;
        address navVerifier;
        address flowManager;
        address strategyManager;
        uint64 compatibilityVersion;
        bool active;
    }

    struct RoleAccounts {
        address admin;
        address upgrader;
        address accounting;
        address allocator;
        address processor;
        address curator;
        address guardian;
    }

    struct CreateFundParams {
        uint64 implementationVersion;
        bytes32 salt;
        string name;
        string symbol;
        IERC20 asset;
        uint16 minimumIdleBps;
        uint64 navActivationDelay;
        uint64 maxSnapshotAge;
        uint64 maxNavWindowLength;
        FundTypes.FeeConfig feeConfig;
        RoleAccounts roles;
    }

    struct FundDeployment {
        address vault;
        address share;
        address accounting;
        address navVerifier;
        address flowManager;
        address strategyManager;
        address claimEscrow;
        address accessManager;
        uint64 implementationVersion;
    }

    mapping(uint64 version => ImplementationSet implementations) public implementationSets;
    mapping(bytes32 deploymentId => FundDeployment deployment) private _deployments;

    event ImplementationVersionRegistered(uint64 indexed version, uint64 compatibilityVersion);
    event ImplementationVersionStatusChanged(uint64 indexed version, bool active);
    event FundCreated(
        bytes32 indexed deploymentId,
        address indexed vault,
        address indexed asset,
        address share,
        address accounting,
        address navVerifier,
        address flowManager,
        address strategyManager,
        address claimEscrow,
        address accessManager,
        uint64 implementationVersion
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    function registerImplementationVersion(uint64 version, ImplementationSet calldata implementationSet)
        external
        onlyOwner
    {
        if (implementationSets[version].compatibilityVersion != 0) revert VersionAlreadyRegistered(version);
        if (
            version == 0 || implementationSet.compatibilityVersion == 0 || implementationSet.vault.code.length == 0
                || implementationSet.share.code.length == 0 || implementationSet.accounting.code.length == 0
                || implementationSet.navVerifier.code.length == 0 || implementationSet.flowManager.code.length == 0
                || implementationSet.strategyManager.code.length == 0
        ) revert InvalidImplementationSet(version);
        implementationSets[version] = implementationSet;
        emit ImplementationVersionRegistered(version, implementationSet.compatibilityVersion);
    }

    function setImplementationVersionActive(uint64 version, bool active) external onlyOwner {
        ImplementationSet storage implementationSet = implementationSets[version];
        if (implementationSet.compatibilityVersion == 0) revert InvalidImplementationSet(version);
        implementationSet.active = active;
        emit ImplementationVersionStatusChanged(version, active);
    }

    function deployment(bytes32 deploymentId) external view returns (FundDeployment memory) {
        return _deployments[deploymentId];
    }

    function computeDeploymentId(CreateFundParams calldata params, address creator) external view returns (bytes32) {
        return _computeDeploymentId(params, creator);
    }

    function createFund(CreateFundParams calldata params) external returns (FundDeployment memory deployed) {
        ImplementationSet memory implementationSet = implementationSets[params.implementationVersion];
        if (!implementationSet.active || address(params.asset) == address(0)) {
            revert InvalidImplementationSet(params.implementationVersion);
        }
        _validateRoles(params.roles);
        bytes32 deploymentId = _computeDeploymentId(params, msg.sender);
        if (_deployments[deploymentId].vault != address(0)) {
            revert InvalidImplementationSet(params.implementationVersion);
        }

        AccessManager manager = new AccessManager(address(this));
        address vaultProxy =
            address(new ERC1967Proxy{salt: keccak256(abi.encode(deploymentId, "VAULT"))}(implementationSet.vault, ""));
        address shareProxy =
            address(new ERC1967Proxy{salt: keccak256(abi.encode(deploymentId, "SHARE"))}(implementationSet.share, ""));
        address accountingProxy = address(
            new ERC1967Proxy{salt: keccak256(abi.encode(deploymentId, "ACCOUNTING"))}(implementationSet.accounting, "")
        );
        address flowProxy = address(
            new ERC1967Proxy{salt: keccak256(abi.encode(deploymentId, "FLOW"))}(implementationSet.flowManager, "")
        );
        address strategyProxy = address(
            new ERC1967Proxy{salt: keccak256(abi.encode(deploymentId, "STRATEGY"))}(
                implementationSet.strategyManager, ""
            )
        );
        ClaimEscrow escrow =
            new ClaimEscrow{salt: keccak256(abi.encode(deploymentId, "CLAIM_ESCROW"))}(params.asset, vaultProxy);

        FundShare(shareProxy)
            .initialize(
                params.name,
                params.symbol,
                address(params.asset),
                vaultProxy,
                address(manager),
                implementationSet.compatibilityVersion
            );
        FundVault(vaultProxy)
            .initialize(
                params.name,
                params.symbol,
                params.asset,
                shareProxy,
                accountingProxy,
                flowProxy,
                strategyProxy,
                address(escrow),
                address(0),
                address(manager),
                implementationSet.compatibilityVersion
            );
        FundAccounting(accountingProxy)
            .initialize(
                vaultProxy,
                implementationSet.navVerifier,
                address(manager),
                implementationSet.compatibilityVersion,
                params.navActivationDelay,
                params.maxSnapshotAge,
                params.maxNavWindowLength,
                params.feeConfig
            );
        FundFlowManager(flowProxy)
            .initialize(vaultProxy, address(escrow), address(manager), implementationSet.compatibilityVersion);
        StrategyManager(strategyProxy)
            .initialize(vaultProxy, address(manager), implementationSet.compatibilityVersion, params.minimumIdleBps);

        _configureRules(manager, shareProxy, FundAccessPolicy.shareRules());
        _configureRules(manager, vaultProxy, FundAccessPolicy.vaultRules());
        _configureRules(manager, accountingProxy, FundAccessPolicy.accountingRules());
        _configureRules(manager, flowProxy, FundAccessPolicy.flowRules());
        _configureRules(manager, strategyProxy, FundAccessPolicy.strategyRules());
        _setSingleRule(manager, accountingProxy, FundAccounting.setComponentState.selector, FundConstants.CURATOR_ROLE);
        manager.setRoleGuardian(FundConstants.CURATOR_ROLE, FundConstants.GUARDIAN_ROLE);
        manager.setGrantDelay(manager.ADMIN_ROLE(), FundConstants.CORE_UPGRADE_DELAY);
        manager.setGrantDelay(FundConstants.UPGRADER_ROLE, FundConstants.CORE_UPGRADE_DELAY);
        manager.setGrantDelay(FundConstants.CURATOR_ROLE, FundConstants.CURATOR_DELAY);
        manager.setTargetAdminDelay(shareProxy, FundConstants.CORE_UPGRADE_DELAY);
        manager.setTargetAdminDelay(vaultProxy, FundConstants.CORE_UPGRADE_DELAY);
        manager.setTargetAdminDelay(accountingProxy, FundConstants.CORE_UPGRADE_DELAY);
        manager.setTargetAdminDelay(flowProxy, FundConstants.CORE_UPGRADE_DELAY);
        manager.setTargetAdminDelay(strategyProxy, FundConstants.CORE_UPGRADE_DELAY);

        manager.grantRole(FundConstants.UPGRADER_ROLE, params.roles.upgrader, FundConstants.CORE_UPGRADE_DELAY);
        manager.grantRole(FundConstants.ACCOUNTING_ROLE, params.roles.accounting, 0);
        manager.grantRole(FundConstants.ALLOCATOR_ROLE, params.roles.allocator, 0);
        manager.grantRole(FundConstants.PROCESSOR_ROLE, params.roles.processor, 0);
        manager.grantRole(FundConstants.CURATOR_ROLE, params.roles.curator, FundConstants.CURATOR_DELAY);
        manager.grantRole(FundConstants.GUARDIAN_ROLE, params.roles.guardian, 0);
        manager.grantRole(manager.ADMIN_ROLE(), params.roles.admin, FundConstants.CORE_UPGRADE_DELAY);
        manager.renounceRole(manager.ADMIN_ROLE(), address(this));

        deployed = FundDeployment({
            vault: vaultProxy,
            share: shareProxy,
            accounting: accountingProxy,
            navVerifier: implementationSet.navVerifier,
            flowManager: flowProxy,
            strategyManager: strategyProxy,
            claimEscrow: address(escrow),
            accessManager: address(manager),
            implementationVersion: params.implementationVersion
        });
        _deployments[deploymentId] = deployed;
        emit FundCreated(
            deploymentId,
            vaultProxy,
            address(params.asset),
            shareProxy,
            accountingProxy,
            implementationSet.navVerifier,
            flowProxy,
            strategyProxy,
            address(escrow),
            address(manager),
            params.implementationVersion
        );
    }

    function _configureRules(AccessManager manager, address target, FundAccessPolicy.Rule[] memory rules) private {
        for (uint256 i; i < rules.length; ++i) {
            _setSingleRule(manager, target, rules[i].selector, rules[i].role);
        }
    }

    function _setSingleRule(AccessManager manager, address target, bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    function _validateRoles(RoleAccounts calldata roles) private pure {
        if (
            roles.admin == address(0) || roles.upgrader == address(0) || roles.accounting == address(0)
                || roles.allocator == address(0) || roles.processor == address(0) || roles.curator == address(0)
                || roles.guardian == address(0)
        ) revert InvalidRoleAccount();
    }

    function _computeDeploymentId(CreateFundParams calldata params, address creator) private view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, creator, params.roles.admin, params.salt, params));
    }
}
