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
import {ClaimEscrow} from "../../src/fund/ClaimEscrow.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract RuntimeBudgetTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;

    function test_allProductionContractsRetainEip170OperationalMargin() public {
        assertLt(address(new FundVault()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundShare()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundAccounting()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new NavReportVerifier()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundFlowManager()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new StrategyManager()).code.length, EIP170_RUNTIME_LIMIT);
        assertLt(address(new FundFactory(address(this))).code.length, EIP170_RUNTIME_LIMIT);
        MockERC20 asset = new MockERC20("Budget Asset", "BUD", 6);
        assertLt(address(new ClaimEscrow(asset, address(this))).code.length, EIP170_RUNTIME_LIMIT);
    }

    function test_fundVaultMeetsArchitecturalDesignTarget() public {
        assertLt(address(new FundVault()).code.length, 18 * 1024);
    }

    function test_fundAccountingMeetsArchitecturalDesignTarget() public {
        assertLt(address(new FundAccounting()).code.length, 16 * 1024);
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
        assertLt(address(new StrategyManager()).code.length, 14 * 1024);
    }
}
