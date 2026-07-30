// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {CspFundValuatorV2} from "../../src/fund/CspFundValuatorV2.sol";
import {CoveredCallFundValuatorV2} from "../../src/fund/CoveredCallFundValuatorV2.sol";
import {INavReportVerifier} from "../../src/fund/interfaces/INavReportVerifier.sol";
import {B1N394Base, IB1N394ValuatorPolicy} from "../../script/fund/B1N394Base.sol";
import {ExecuteB1N394Upgrade} from "../../script/fund/ExecuteB1N394Upgrade.s.sol";
import {FinalizeB1N394Upgrade} from "../../script/fund/FinalizeB1N394Upgrade.s.sol";

/// @notice Executes the production pause/upgrade/rebind/fee/fresh-NAV/finalize scripts on an exact-state fork.
/// @dev NAV verifier calls are mocked only to avoid importing live reporter secrets into a defensive fork test.
contract B1N394ProductionRunbookForkTest is Test {
    uint256 private constant SNAPSHOT_BLOCK = 44_835_826;
    address private constant ADMIN = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant BATCH_SETTLER = 0xb94D6270B336dca566C2077d50c2C50F06398cB8;

    address private constant CSP_ACCESS = 0x729d5076C1C59a7C2676Faf3fB9133Ff80cDaB12;
    address private constant CSP_VAULT = 0x53e38Baf2fC55259729085b7542BFF066F6a509e;
    address private constant CSP_ACCOUNTING = 0x21d3acc5a2c64666dA93ABC8c77AB483b96836a3;
    address private constant CSP_MANAGER = 0xfC28237145596D4E1dfD28B80e186EFC09A1F988;
    address private constant CSP_ADAPTER = 0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3;
    address private constant CSP_CURRENT_VALUATOR = 0x63aB18b546d2b7a6e9e68eF7C784Ecfa41B76798;

    address private constant CC_ACCESS = 0x5AfD3d840ec2f7fE078b44b75462C2dCD3DC3F6D;
    address private constant CC_VAULT = 0x9060946E6ACC4E430A823E90120743c7305EE2CA;
    address private constant CC_ACCOUNTING = 0x9a112A65FE8510bCf5DC894fFBf06aEa8d12d311;
    address private constant CC_MANAGER = 0x745422dd14E84ee27C2E56D2845C3BB1658027d9;
    address private constant CC_ADAPTER = 0x0BF96C5cE0D637d4D686d342aE42Bc00fDa19De9;
    address private constant CC_CURRENT_VALUATOR = 0xA1BFC1bE3C7fCA77CA0b32d25de1Ce58A50333A0;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")), SNAPSHOT_BLOCK);
        vm.setEnv("B1N394_BROADCASTER", vm.toString(ADMIN));
    }

    function test_productionRunbookPreservesPositionsAndReopensOnlyAfterFreshNav() public {
        bytes32 cspPositionBefore = keccak256(abi.encode(CspFundAdapter(CSP_ADAPTER).position(3)));
        bytes32 ccPositionBefore = keccak256(abi.encode(CoveredCallFundAdapter(CC_ADAPTER).position(1)));
        uint256 cspHwmBefore = FundAccounting(CSP_ACCOUNTING).feeState().highWaterMark;
        uint256 ccHwmBefore = FundAccounting(CC_ACCOUNTING).feeState().highWaterMark;
        uint64 cspPriorNonce = FundAccounting(CSP_ACCOUNTING).lastReportNonce();
        uint64 ccPriorNonce = FundAccounting(CC_ACCOUNTING).lastReportNonce();

        _deployAndConfigureImplementationEnvironment();
        new ExecuteB1N394Upgrade().run();

        uint64 upgradeBlock = uint64(block.number);
        vm.setEnv("B1N394_UPGRADE_BLOCK", vm.toString(upgradeBlock));
        vm.setEnv("B1N394_CSP_PRE_UPGRADE_NAV_NONCE", vm.toString(cspPriorNonce));
        vm.setEnv("B1N394_CC_PRE_UPGRADE_NAV_NONCE", vm.toString(ccPriorNonce));
        assertTrue(FundVault(CSP_VAULT).depositsPaused());
        assertTrue(FundVault(CC_VAULT).depositsPaused());
        assertFalse(StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER).active);
        assertFalse(StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER).active);
        assertEq(keccak256(abi.encode(CspFundAdapter(CSP_ADAPTER).position(3))), cspPositionBefore);
        assertEq(keccak256(abi.encode(CoveredCallFundAdapter(CC_ADAPTER).position(1))), ccPositionBefore);
        assertEq(FundAccounting(CSP_ACCOUNTING).feeState().highWaterMark, cspHwmBefore);
        assertEq(FundAccounting(CC_ACCOUNTING).feeState().highWaterMark, ccHwmBefore);

        vm.roll(block.number + 1);
        _submitMockedFreshNav(CSP_ACCESS, CSP_VAULT, CSP_ACCOUNTING, CSP_MANAGER, upgradeBlock);
        _submitMockedFreshNav(CC_ACCESS, CC_VAULT, CC_ACCOUNTING, CC_MANAGER, upgradeBlock);
        vm.roll(block.number + 1);

        new FinalizeB1N394Upgrade().run();

        assertFalse(FundVault(CSP_VAULT).depositsPaused());
        assertFalse(FundVault(CC_VAULT).depositsPaused());
        assertFalse(FundVault(CSP_VAULT).redemptionsPaused());
        assertFalse(FundVault(CC_VAULT).redemptionsPaused());
        assertTrue(StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER).active);
        assertTrue(StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER).active);
        assertEq(CspFundAdapter(CSP_ADAPTER).deallocationInterfaceVersion(), 2);
        assertEq(CoveredCallFundAdapter(CC_ADAPTER).deallocationInterfaceVersion(), 2);
        assertEq(_protocolFeeBps(), 1_000);
        assertEq(keccak256(abi.encode(CspFundAdapter(CSP_ADAPTER).position(3))), cspPositionBefore);
        assertEq(keccak256(abi.encode(CoveredCallFundAdapter(CC_ADAPTER).position(1))), ccPositionBefore);
    }

    function _deployAndConfigureImplementationEnvironment() private {
        FundAccounting accounting = new FundAccounting();
        FundFlowManager flow = new FundFlowManager();
        StrategyManager manager = new StrategyManager();
        CspFundAdapter cspAdapter = new CspFundAdapter();
        CoveredCallFundAdapter ccAdapter = new CoveredCallFundAdapter();

        IB1N394ValuatorPolicy cspPrior = IB1N394ValuatorPolicy(CSP_CURRENT_VALUATOR);
        IB1N394ValuatorPolicy ccPrior = IB1N394ValuatorPolicy(CC_CURRENT_VALUATOR);
        CspFundValuatorV2 cspValuator = new CspFundValuatorV2(
            cspPrior.spotFeed(),
            cspPrior.spotFeedDecimals(),
            cspPrior.maxSpotStaleness(),
            cspPrior.maxObservationWindow(),
            cspPrior.observationQuorum(),
            _observers(cspPrior)
        );
        CoveredCallFundValuatorV2 ccValuator = new CoveredCallFundValuatorV2(
            ccPrior.spotFeed(),
            ccPrior.spotFeedDecimals(),
            ccPrior.maxSpotStaleness(),
            ccPrior.maxObservationWindow(),
            ccPrior.observationQuorum(),
            _observers(ccPrior)
        );

        _setImplementation("B1N394_FUND_ACCOUNTING_IMPLEMENTATION", address(accounting));
        _setImplementation("B1N394_FUND_FLOW_IMPLEMENTATION", address(flow));
        _setImplementation("B1N394_STRATEGY_MANAGER_IMPLEMENTATION", address(manager));
        _setImplementation("B1N394_CSP_ADAPTER_IMPLEMENTATION", address(cspAdapter));
        _setImplementation("B1N394_CC_ADAPTER_IMPLEMENTATION", address(ccAdapter));
        _setImplementation("B1N394_CSP_VALUATOR", address(cspValuator));
        _setImplementation("B1N394_CC_VALUATOR", address(ccValuator));
    }

    function _submitMockedFreshNav(
        address accessManager,
        address vaultAddress,
        address accountingAddress,
        address managerAddress,
        uint64 upgradeBlock
    ) private {
        FundVault vault = FundVault(vaultAddress);
        FundAccounting accounting = FundAccounting(accountingAddress);
        FundTypes.NavCommit memory prior = vault.activeNavWindow();
        FundTypes.NavCommit memory nav = FundTypes.NavCommit({
            grossAssets: vault.committedNav(),
            liabilities: 0,
            netAssets: vault.committedNav(),
            liquidAccountingAssets: vault.accountedIdleAssets(),
            baseExitCost: prior.baseExitCost,
            snapshotBlock: upgradeBlock,
            validAfterBlock: uint64(block.number + 1),
            validUntilBlock: uint64(block.number + 50),
            reporterSetVersion: accounting.reporterSetVersion(),
            reportNonce: accounting.lastReportNonce() + 1,
            positionsHash: StrategyManager(managerAddress).positionsHash(),
            reportHash: keccak256(abi.encode("B1N394", vaultAddress, block.number)),
            signaturesHash: keccak256("B1N394_FORK_SIGNATURES"),
            fundFlowNonce: vault.fundFlowNonce(),
            idleStateHash: vault.idleStateHash()
        });

        vm.mockCall(
            accounting.navVerifier(),
            abi.encodeWithSelector(INavReportVerifier.verifyNavReport.selector),
            abi.encode(nav)
        );
        FundTypes.ComponentReport[] memory reports = new FundTypes.ComponentReport[](0);
        address[] memory reporters = new address[](0);
        bytes[] memory signatures = new bytes[](0);
        vm.prank(_roleMember(accessManager, FundConstants.ACCOUNTING_ROLE));
        accounting.submitNav(nav.reportNonce, reports, reporters, signatures);
    }

    function _setImplementation(string memory name, address deployed) private {
        vm.setEnv(name, vm.toString(deployed));
        vm.setEnv(string.concat(name, "_CODEHASH"), vm.toString(deployed.codehash));
    }

    function _observers(IB1N394ValuatorPolicy policy) private view returns (address[] memory observers) {
        observers = new address[](policy.approvedObserverCount());
        for (uint256 i; i < observers.length; ++i) {
            observers[i] = policy.approvedObserverAt(i);
        }
    }

    function _roleMember(address accessManager, uint64 role) private view returns (address) {
        return FundAccessManager(accessManager).roleMemberAt(role, 0);
    }

    function _protocolFeeBps() private view returns (uint256 feeBps) {
        (bool success, bytes memory result) = BATCH_SETTLER.staticcall(abi.encodeWithSignature("protocolFeeBps()"));
        require(success);
        feeBps = abi.decode(result, (uint256));
    }
}
