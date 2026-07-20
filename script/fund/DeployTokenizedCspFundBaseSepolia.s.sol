// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {NavReportVerifier} from "../../src/fund/NavReportVerifier.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CspFundValuator} from "../../src/fund/CspFundValuator.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {CspFundAdapterOperations} from "../../src/fund/libraries/CspFundAdapterOperations.sol";
import {B1N352Base} from "./B1N352Base.sol";

/// @notice Deployment phase only. It does not configure delayed roles, onboard V1, or activate the strategy.
contract DeployTokenizedCspFundBaseSepolia is B1N352Base {
    function run() external returns (DeploymentAddresses memory deployed) {
        _requireBaseSepolia();
        DeployConfig memory config = _loadDeployConfig();
        _validateExternalConfig(config);
        _requireExpectedV1Baseline(config.addressBook);
        _logV1Baseline(config.addressBook);

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);
        deployed = _deploy(config, deployer);
        vm.stopBroadcast();

        _logDeployment(deployed);
    }

    function _deploy(DeployConfig memory config, address deployer)
        internal
        returns (DeploymentAddresses memory deployed)
    {
        deployed.fundVaultImplementation = address(new FundVault());
        deployed.fundShareImplementation = address(new FundShare());
        deployed.fundAccountingImplementation = address(new FundAccounting());
        deployed.fundFlowManagerImplementation = address(new FundFlowManager());
        deployed.strategyManagerImplementation = address(new StrategyManager());
        deployed.navReportVerifier = address(new NavReportVerifier());

        FundFactory factory = new FundFactory(deployer);
        deployed.fundFactory = address(factory);
        deployed.fundAccessManagerDeployer = address(factory.accessManagerDeployer());
        factory.registerImplementationVersion(
            config.implementationVersion,
            FundFactory.ImplementationSet({
                vault: deployed.fundVaultImplementation,
                share: deployed.fundShareImplementation,
                accounting: deployed.fundAccountingImplementation,
                navVerifier: deployed.navReportVerifier,
                flowManager: deployed.fundFlowManagerImplementation,
                strategyManager: deployed.strategyManagerImplementation,
                compatibilityVersion: config.compatibilityVersion,
                active: true
            })
        );

        FundFactory.CreateFundParams memory createParams = FundFactory.CreateFundParams({
            implementationVersion: config.implementationVersion,
            salt: config.fundSalt,
            name: config.fundName,
            symbol: config.fundSymbol,
            asset: IERC20(config.accountingAsset),
            minimumIdleBps: config.minimumIdleBps,
            navActivationDelay: config.navActivationDelay,
            maxSnapshotAge: config.maxSnapshotAge,
            maxNavWindowLength: config.maxNavWindowLength,
            feeConfig: config.feeConfig,
            roles: config.roles
        });
        deployed.deploymentId = factory.computeDeploymentId(createParams, deployer);
        FundFactory.FundDeployment memory fund = factory.createFund(createParams);
        deployed.fundVaultProxy = fund.vault;
        deployed.fundShareProxy = fund.share;
        deployed.fundAccountingProxy = fund.accounting;
        deployed.fundFlowManagerProxy = fund.flowManager;
        deployed.strategyManagerProxy = fund.strategyManager;
        deployed.claimEscrow = fund.claimEscrow;
        deployed.accessManager = fund.accessManager;

        deployed.cspAdapterOperations = address(CspFundAdapterOperations);
        deployed.cspFundAdapterImplementation = address(new CspFundAdapter());
        CspFundAdapter.InitializeParams memory adapterParams = CspFundAdapter.InitializeParams({
            fund: fund.vault,
            strategyManager: fund.strategyManager,
            addressBook: config.addressBook,
            accountingAsset: config.accountingAsset,
            weth: config.weth,
            swapRouter: config.adapterSwapRouter,
            swapFeeTier: config.adapterSwapFeeTier,
            authority: fund.accessManager,
            riskConfig: config.adapterRiskConfig
        });
        deployed.cspFundAdapterProxy = address(
            new ERC1967Proxy(
                deployed.cspFundAdapterImplementation, abi.encodeCall(CspFundAdapter.initialize, (adapterParams))
            )
        );
        deployed.cspFundValuator = address(
            new CspFundValuator(
                config.spotFeed,
                config.spotFeedDecimals,
                config.maxSpotStaleness,
                config.maxObservationWindow,
                config.observationQuorum,
                config.liabilityBufferBps,
                config.approvedObservers
            )
        );
        deployed.inKindStrategyEscrow =
            address(new StrategyAssetEscrow(fund.vault, fund.accessManager, IN_KIND_ESCROW_PURPOSE));
        deployed.emergencyStrategyEscrow =
            address(new StrategyAssetEscrow(fund.vault, fund.accessManager, EMERGENCY_ESCROW_PURPOSE));

        factory.transferOwnership(config.factoryOwner);
    }

    function _logDeployment(DeploymentAddresses memory deployed) private view {
        console2.log("FUND_FACTORY", deployed.fundFactory);
        console2.log("FUND_ACCESS_MANAGER_DEPLOYER", deployed.fundAccessManagerDeployer);
        console2.log("FUND_ACCESS_MANAGER_DEPLOYER_CODEHASH");
        console2.logBytes32(deployed.fundAccessManagerDeployer.codehash);
        console2.log("FUND_DEPLOYMENT_ID");
        console2.logBytes32(deployed.deploymentId);
        console2.log("FUND_VAULT_IMPLEMENTATION", deployed.fundVaultImplementation);
        console2.log("FUND_SHARE_IMPLEMENTATION", deployed.fundShareImplementation);
        console2.log("FUND_ACCOUNTING_IMPLEMENTATION", deployed.fundAccountingImplementation);
        console2.log("FUND_FLOW_MANAGER_IMPLEMENTATION", deployed.fundFlowManagerImplementation);
        console2.log("FUND_STRATEGY_MANAGER_IMPLEMENTATION", deployed.strategyManagerImplementation);
        console2.log("FUND_NAV_REPORT_VERIFIER", deployed.navReportVerifier);
        console2.log("FUND_NAV_REPORT_VERIFIER_CODEHASH");
        console2.logBytes32(deployed.navReportVerifier.codehash);
        console2.log("FUND_VAULT_PROXY", deployed.fundVaultProxy);
        console2.log("FUND_SHARE_PROXY", deployed.fundShareProxy);
        console2.log("FUND_ACCOUNTING_PROXY", deployed.fundAccountingProxy);
        console2.log("FUND_FLOW_MANAGER_PROXY", deployed.fundFlowManagerProxy);
        console2.log("FUND_STRATEGY_MANAGER_PROXY", deployed.strategyManagerProxy);
        console2.log("FUND_CLAIM_ESCROW", deployed.claimEscrow);
        console2.log("FUND_CLAIM_ESCROW_CODEHASH");
        console2.logBytes32(deployed.claimEscrow.codehash);
        console2.log("FUND_ACCESS_MANAGER", deployed.accessManager);
        console2.log("FUND_ACCESS_MANAGER_CODEHASH");
        console2.logBytes32(deployed.accessManager.codehash);
        console2.log("FUND_CSP_ADAPTER_OPERATIONS", deployed.cspAdapterOperations);
        console2.log("FUND_CSP_ADAPTER_OPERATIONS_CODEHASH");
        console2.logBytes32(deployed.cspAdapterOperations.codehash);
        console2.log("FUND_CSP_ADAPTER_IMPLEMENTATION", deployed.cspFundAdapterImplementation);
        console2.log("FUND_CSP_ADAPTER_IMPLEMENTATION_CODEHASH");
        console2.logBytes32(deployed.cspFundAdapterImplementation.codehash);
        console2.log("FUND_CSP_ADAPTER_PROXY", deployed.cspFundAdapterProxy);
        console2.log("FUND_CSP_VALUATOR", deployed.cspFundValuator);
        console2.log("FUND_IN_KIND_STRATEGY_ESCROW", deployed.inKindStrategyEscrow);
        console2.log("FUND_EMERGENCY_STRATEGY_ESCROW", deployed.emergencyStrategyEscrow);
    }
}
