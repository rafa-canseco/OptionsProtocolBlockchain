// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {FundShare} from "../../src/fund/FundShare.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {NavReportVerifier} from "../../src/fund/NavReportVerifier.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {FundFactory} from "../../src/fund/FundFactory.sol";
import {FundAccessManagerDeployer} from "../../src/fund/FundAccessManagerDeployer.sol";
import {ClaimEscrow} from "../../src/fund/ClaimEscrow.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CspFundValuator} from "../../src/fund/CspFundValuator.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {CspFundAdapterOperations} from "../../src/fund/libraries/CspFundAdapterOperations.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {CoveredCallFundAdapterOperations} from "../../src/fund/libraries/CoveredCallFundAdapterOperations.sol";
import {ManagedStrategyOperations} from "../../src/fund/libraries/ManagedStrategyOperations.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";

contract RuntimeBudgetTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;

    function test_allProductionContractsRetainEip170OperationalMargin() public {
        assertLt(address(new FundVault()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundShare()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundAccounting()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new NavReportVerifier()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundFlowManager()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new StrategyManager()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(ManagedStrategyOperations).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundFactory(address(this))).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundAccessManagerDeployer()).code.length, EIP170_RUNTIME_LIMIT);
        MockERC20 asset = new MockERC20("Budget Asset", "BUD", 6);
        assertLt(address(new ClaimEscrow(asset, address(this))).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new CspFundAdapter()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(CspFundAdapterOperations).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new CoveredCallFundAdapter()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(CoveredCallFundAdapterOperations).code.length, EIP170_RUNTIME_LIMIT);
        MockChainlinkFeed spotFeed = new MockChainlinkFeed(2_000e8);
        address[] memory observers = new address[](2);
        observers[0] = address(0xA11CE);
        observers[1] = address(0xB0B);
        assertLt(
            address(new CspFundValuator(address(spotFeed), 8, 1 hours, 10, 2, 1_000, observers)).code.length,
            EIP170_RUNTIME_LIMIT
        );
        assertLt(
            address(new CspFundValuatorV2(address(spotFeed), 8, 1 hours, 10, 2, observers)).code.length,
            EIP170_RUNTIME_LIMIT
        );
        assertLt(
            address(new CoveredCallFundValuatorV2(address(spotFeed), 8, 1 hours, 10, 2, observers)).code.length,
            EIP170_RUNTIME_LIMIT
        );
    }

    function test_fundVaultMeetsArchitecturalDesignTarget() public {
        assertLt(address(new FundVault()).code.length, 18 * 1024);
    }

    function test_fundAccountingMeetsArchitecturalDesignTarget() public {
        // V2 fee crystallization and position-domain migration still leave more than 6 KiB below EIP-170.
        assertLt(address(new FundAccounting()).code.length, 18 * 1024);
    }

    function test_fundShareMeetsArchitecturalDesignTarget() public {
        assertLt(address(new FundShare()).code.length, 14 * 1024);
    }

    function test_navReportVerifierMeetsArchitecturalDesignTarget() public {
        assertLt(address(new NavReportVerifier()).code.length, 14 * 1024);
    }

    function test_fundFlowManagerMeetsArchitecturalDesignTarget() public {
        assertLt(address(new FundFlowManager()).code.length, 18 * 1024);
    }

    function test_strategyManagerMeetsArchitecturalDesignTarget() public {
        // Managed NAV synchronization still leaves more than 8 KiB below EIP-170.
        assertLt(address(new StrategyManager()).code.length, 16 * 1024);
    }
}
