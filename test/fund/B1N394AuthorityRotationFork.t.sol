// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {IB1N394ValuatorPolicy} from "../../script/fund/B1N394Base.sol";
import {CompleteB1N394AuthorityRotation} from "../../script/fund/CompleteB1N394AuthorityRotation.s.sol";

interface IOwnedDependency {
    function owner() external view returns (address);
}

contract B1N394AuthorityRotationForkTest is Test {
    address private constant RETIRED = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant GOVERNANCE = 0x376a4c54623fe24D0Ffc1032D0b6CcC03A32fd7D;
    address private constant OPERATOR = 0xEa99E3C48D68D1614d6454643135FD93e5cD18cE;
    address private constant ADDRESS_BOOK = 0x033d9d37Baf83dBc71935239b6fA22a6905dbaa0;
    address private constant CONTROLLER = 0xD52EFbBaA1b02BA65A7f0A1604A5dFb4C4dB1572;
    address private constant OTOKEN_FACTORY = 0x193ED89eB64d0179b4dB08E87E541b7b3c30002A;
    address private constant WHITELIST = 0xe0Ca66a93341eB0af0C136651c8B57C187aa60Ab;
    address private constant CSP_FACTORY = 0xf8b508271F92eE5DC81a9Bc8E569C7Ff458E517C;
    address private constant CC_FACTORY = 0x6F5b59047629730f973c75c8941d88Ed526946b8;
    address private constant CSP_ACCESS = 0x729d5076C1C59a7C2676Faf3fB9133Ff80cDaB12;
    address private constant CSP_ACCOUNTING = 0x21d3acc5a2c64666dA93ABC8c77AB483b96836a3;
    address private constant CSP_MANAGER = 0xfC28237145596D4E1dfD28B80e186EFC09A1F988;
    address private constant CSP_ADAPTER = 0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3;
    address private constant CC_ACCESS = 0x5AfD3d840ec2f7fE078b44b75462C2dCD3DC3F6D;
    address private constant CC_ACCOUNTING = 0x9a112A65FE8510bCf5DC894fFBf06aEa8d12d311;
    address private constant CC_MANAGER = 0x745422dd14E84ee27C2E56D2845C3BB1658027d9;
    address private constant CC_ADAPTER = 0x0BF96C5cE0D637d4D686d342aE42Bc00fDa19De9;
    address private constant ORACLE = 0xF95CC4aED4a0bD68e0F1BE7c779BC281189F8187;
    address private constant SETTLER = 0xb94D6270B336dca566C2077d50c2C50F06398cB8;
    address private constant ROUTER = 0x0Cd738d1F80FaDBbF6171280eD01Cfa33F8E17b3;
    address private constant WETH = 0x8A6Aa2304797898d46eC1d342Fedc817D3a973B6;

    function test_rotationRemovesRetiredAuthorityAcrossSharedDependencies() external {
        vm.createSelectFork(vm.envString("BASE_SEPOLIA_RPC_URL"));
        vm.setEnv("B1N394_NEW_GOVERNANCE", vm.toString(GOVERNANCE));
        vm.deal(GOVERNANCE, 1 ether);

        bytes32 cspAdapterHash = CspFundAdapter(CSP_ADAPTER).positionStateHash();
        bytes32 ccAdapterHash = CoveredCallFundAdapter(CC_ADAPTER).positionStateHash();
        bytes32 cspManagerHash = StrategyManager(CSP_MANAGER).positionsHash();
        bytes32 ccManagerHash = StrategyManager(CC_MANAGER).positionsHash();

        new CompleteB1N394AuthorityRotation().run();

        BatchSettler settler = BatchSettler(SETTLER);
        Oracle oracle = Oracle(ORACLE);
        MockSwapRouter router = MockSwapRouter(ROUTER);
        address feed = oracle.priceFeed(WETH);

        assertEq(settler.owner(), GOVERNANCE);
        assertEq(settler.operator(), OPERATOR);
        assertEq(settler.treasury(), GOVERNANCE);
        assertEq(settler.swapRouter(), ROUTER);
        assertFalse(settler.whitelistedMMs(RETIRED));
        assertEq(router.owner(), GOVERNANCE);
        assertEq(router.priceFeeds(WETH), feed);
        assertEq(oracle.owner(), GOVERNANCE);
        assertEq(oracle.operator(), OPERATOR);
        assertNotEq(IOwnedDependency(feed).owner(), RETIRED);
        assertEq(AddressBook(ADDRESS_BOOK).owner(), GOVERNANCE);
        assertEq(Controller(CONTROLLER).owner(), GOVERNANCE);
        assertEq(Controller(CONTROLLER).partialPauser(), OPERATOR);
        assertEq(OTokenFactory(OTOKEN_FACTORY).operator(), OPERATOR);
        assertEq(IOwnedDependency(WHITELIST).owner(), GOVERNANCE);
        assertEq(IOwnedDependency(CSP_FACTORY).owner(), GOVERNANCE);
        assertEq(IOwnedDependency(CC_FACTORY).owner(), GOVERNANCE);
        assertEq(FundAccounting(CSP_ACCOUNTING).feeConfig().feeRecipient, GOVERNANCE);
        assertEq(FundAccounting(CC_ACCOUNTING).feeConfig().feeRecipient, GOVERNANCE);
        assertFalse(FundAccounting(CSP_ACCOUNTING).isReporter(RETIRED));
        assertFalse(FundAccounting(CC_ACCOUNTING).isReporter(RETIRED));
        assertEq(CspFundAdapter(CSP_ADAPTER).adapterConfig().swapRouter, ROUTER);
        assertEq(CoveredCallFundAdapter(CC_ADAPTER).adapterConfig().swapRouter, ROUTER);
        assertEq(
            IB1N394ValuatorPolicy(StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER).valuator).spotFeed(), feed
        );
        assertEq(
            IB1N394ValuatorPolicy(StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER).valuator).spotFeed(), feed
        );
        assertEq(CspFundAdapter(CSP_ADAPTER).positionStateHash(), cspAdapterHash);
        assertEq(CoveredCallFundAdapter(CC_ADAPTER).positionStateHash(), ccAdapterHash);
        assertEq(StrategyManager(CSP_MANAGER).positionsHash(), cspManagerHash);
        assertEq(StrategyManager(CC_MANAGER).positionsHash(), ccManagerHash);

        _assertNoRetiredRoles(AccessManager(CSP_ACCESS));
        _assertNoRetiredRoles(AccessManager(CC_ACCESS));
    }

    function _assertNoRetiredRoles(AccessManager access) private view {
        for (uint64 role; role <= FundConstants.ADAPTER_UPGRADER_ROLE; ++role) {
            (bool active,) = access.hasRole(role, RETIRED);
            assertFalse(active);
        }
    }
}
