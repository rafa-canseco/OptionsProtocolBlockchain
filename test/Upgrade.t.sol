// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/core/Whitelist.sol";
import "../src/core/BatchSettler.sol";
import "../src/mocks/MockERC20.sol";
import "../src/mocks/MockChainlinkFeed.sol";

// V2 stubs for upgrade testing — add a version() getter to prove upgrade worked
contract AddressBookV2 is AddressBook {
    function version() external pure returns (uint256) { return 2; }
}
contract ControllerV2 is Controller {
    function version() external pure returns (uint256) { return 2; }
}
contract MarginPoolV2 is MarginPool {
    function version() external pure returns (uint256) { return 2; }
}
contract OTokenFactoryV2 is OTokenFactory {
    function version() external pure returns (uint256) { return 2; }
}
contract OracleV2 is Oracle {
    function version() external pure returns (uint256) { return 2; }
}
contract WhitelistV2 is Whitelist {
    function version() external pure returns (uint256) { return 2; }
}
contract BatchSettlerV2 is BatchSettler {
    function version() external pure returns (uint256) { return 2; }
}

contract UpgradeTest is Test {
    AddressBook addressBook;
    Controller controller;
    MarginPool pool;
    OTokenFactory factory;
    Oracle oracle;
    Whitelist whitelist;
    BatchSettler settler;

    MockERC20 weth;
    MockERC20 usdc;
    MockChainlinkFeed feed;

    address owner = address(this);
    address operator = address(0xBEEF);

    function setUp() public {
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        feed = new MockChainlinkFeed(2500e8);

        // Deploy all contracts behind proxies
        addressBook = AddressBook(address(new ERC1967Proxy(
            address(new AddressBook()),
            abi.encodeCall(AddressBook.initialize, (owner))
        )));
        controller = Controller(address(new ERC1967Proxy(
            address(new Controller()),
            abi.encodeCall(Controller.initialize, (address(addressBook), owner))
        )));
        pool = MarginPool(address(new ERC1967Proxy(
            address(new MarginPool()),
            abi.encodeCall(MarginPool.initialize, (address(addressBook)))
        )));
        factory = OTokenFactory(address(new ERC1967Proxy(
            address(new OTokenFactory()),
            abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
        )));
        oracle = Oracle(address(new ERC1967Proxy(
            address(new Oracle()),
            abi.encodeCall(Oracle.initialize, (address(addressBook), owner))
        )));
        whitelist = Whitelist(address(new ERC1967Proxy(
            address(new Whitelist()),
            abi.encodeCall(Whitelist.initialize, (address(addressBook), owner))
        )));
        settler = BatchSettler(address(new ERC1967Proxy(
            address(new BatchSettler()),
            abi.encodeCall(BatchSettler.initialize, (address(addressBook), operator))
        )));

        // Wire AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    // ===== Double-initialization prevention =====

    function test_cannotReinitializeAddressBook() public {
        vm.expectRevert();
        addressBook.initialize(address(0xDEAD));
    }

    function test_cannotReinitializeController() public {
        vm.expectRevert();
        controller.initialize(address(addressBook), address(0xDEAD));
    }

    function test_cannotReinitializeMarginPool() public {
        vm.expectRevert();
        pool.initialize(address(addressBook));
    }

    function test_cannotReinitializeOTokenFactory() public {
        vm.expectRevert();
        factory.initialize(address(addressBook));
    }

    function test_cannotReinitializeOracle() public {
        vm.expectRevert();
        oracle.initialize(address(addressBook), address(0xDEAD));
    }

    function test_cannotReinitializeWhitelist() public {
        vm.expectRevert();
        whitelist.initialize(address(addressBook), address(0xDEAD));
    }

    function test_cannotReinitializeBatchSettler() public {
        vm.expectRevert();
        settler.initialize(address(addressBook), address(0xDEAD));
    }

    // ===== Implementation cannot be initialized =====

    function test_implementationLockedAddressBook() public {
        AddressBook impl = new AddressBook();
        vm.expectRevert();
        impl.initialize(owner);
    }

    function test_implementationLockedController() public {
        Controller impl = new Controller();
        vm.expectRevert();
        impl.initialize(address(addressBook), owner);
    }

    function test_implementationLockedBatchSettler() public {
        BatchSettler impl = new BatchSettler();
        vm.expectRevert();
        impl.initialize(address(addressBook), operator);
    }

    // ===== Upgrade: state preserved =====

    function test_upgradeAddressBook_preservesState() public {
        // Set some state
        address testAddr = address(0x1234);
        addressBook.setController(testAddr);
        assertEq(addressBook.controller(), testAddr);
        assertEq(addressBook.owner(), owner);

        // Upgrade
        AddressBookV2 v2Impl = new AddressBookV2();
        addressBook.upgradeToAndCall(address(v2Impl), "");

        // State preserved
        assertEq(addressBook.controller(), testAddr);
        assertEq(addressBook.owner(), owner);

        // New functionality available
        assertEq(AddressBookV2(address(addressBook)).version(), 2);
    }

    function test_upgradeController_preservesState() public {
        controller.setBetaMode(true);
        assertTrue(controller.betaMode());

        ControllerV2 v2Impl = new ControllerV2();
        controller.upgradeToAndCall(address(v2Impl), "");

        assertTrue(controller.betaMode());
        assertEq(controller.owner(), owner);
        assertEq(ControllerV2(address(controller)).version(), 2);
    }

    function test_upgradeMarginPool_preservesState() public {
        assertEq(address(pool.addressBook()), address(addressBook));

        MarginPoolV2 v2Impl = new MarginPoolV2();
        // MarginPool upgrade authorized by AddressBook owner
        pool.upgradeToAndCall(address(v2Impl), "");

        assertEq(address(pool.addressBook()), address(addressBook));
        assertEq(MarginPoolV2(address(pool)).version(), 2);
    }

    function test_upgradeOTokenFactory_preservesState() public {
        assertEq(address(factory.addressBook()), address(addressBook));

        OTokenFactoryV2 v2Impl = new OTokenFactoryV2();
        // OTokenFactory upgrade authorized by AddressBook owner
        factory.upgradeToAndCall(address(v2Impl), "");

        assertEq(address(factory.addressBook()), address(addressBook));
        assertEq(OTokenFactoryV2(address(factory)).version(), 2);
    }

    function test_upgradeOracle_preservesState() public {
        oracle.setPriceFeed(address(weth), address(feed));
        assertEq(oracle.priceFeed(address(weth)), address(feed));

        OracleV2 v2Impl = new OracleV2();
        oracle.upgradeToAndCall(address(v2Impl), "");

        assertEq(oracle.priceFeed(address(weth)), address(feed));
        assertEq(oracle.owner(), owner);
        assertEq(OracleV2(address(oracle)).version(), 2);
    }

    function test_upgradeWhitelist_preservesState() public {
        whitelist.whitelistUnderlying(address(weth));
        assertTrue(whitelist.isWhitelistedUnderlying(address(weth)));

        WhitelistV2 v2Impl = new WhitelistV2();
        whitelist.upgradeToAndCall(address(v2Impl), "");

        assertTrue(whitelist.isWhitelistedUnderlying(address(weth)));
        assertEq(whitelist.owner(), owner);
        assertEq(WhitelistV2(address(whitelist)).version(), 2);
    }

    function test_upgradeBatchSettler_preservesState() public {
        settler.setWhitelistedMM(operator, true);
        assertTrue(settler.whitelistedMMs(operator));

        BatchSettlerV2 v2Impl = new BatchSettlerV2();
        settler.upgradeToAndCall(address(v2Impl), "");

        assertTrue(settler.whitelistedMMs(operator));
        assertEq(settler.owner(), owner);
        assertEq(settler.operator(), operator);
        assertEq(BatchSettlerV2(address(settler)).version(), 2);
    }

    // ===== Upgrade authorization =====

    function test_upgradeRevertsForNonOwner_AddressBook() public {
        AddressBookV2 v2Impl = new AddressBookV2();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        addressBook.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_Controller() public {
        ControllerV2 v2Impl = new ControllerV2();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        controller.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_MarginPool() public {
        MarginPoolV2 v2Impl = new MarginPoolV2();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        pool.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_OTokenFactory() public {
        OTokenFactoryV2 v2Impl = new OTokenFactoryV2();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        factory.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_Oracle() public {
        OracleV2 v2Impl = new OracleV2();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        oracle.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_Whitelist() public {
        WhitelistV2 v2Impl = new WhitelistV2();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        whitelist.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_BatchSettler() public {
        BatchSettlerV2 v2Impl = new BatchSettlerV2();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        settler.upgradeToAndCall(address(v2Impl), "");
    }
}
