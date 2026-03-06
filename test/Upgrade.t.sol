// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
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
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ControllerV2 is Controller {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MarginPoolV2 is MarginPool {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract OTokenFactoryV2 is OTokenFactory {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract OracleV2 is Oracle {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract WhitelistV2 is Whitelist {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract BatchSettlerV2 is BatchSettler {
    function version() external pure returns (uint256) {
        return 2;
    }
}

// V2 stub with reinitializer(2) for reinitializer upgrade test
contract AddressBookV2Reinit is AddressBook {
    uint256 public v2Value;

    function initializeV2(uint256 _val) external reinitializer(2) {
        v2Value = _val;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
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
        addressBook = AddressBook(
            address(new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (owner))))
        );
        controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()), abi.encodeCall(Controller.initialize, (address(addressBook), owner))
                )
            )
        );
        pool = MarginPool(
            address(
                new ERC1967Proxy(
                    address(new MarginPool()), abi.encodeCall(MarginPool.initialize, (address(addressBook)))
                )
            )
        );
        factory = OTokenFactory(
            address(
                new ERC1967Proxy(
                    address(new OTokenFactory()), abi.encodeCall(OTokenFactory.initialize, (address(addressBook)))
                )
            )
        );
        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), owner))
                )
            )
        );
        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()), abi.encodeCall(Whitelist.initialize, (address(addressBook), owner))
                )
            )
        );
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operator, owner))
                )
            )
        );

        // Wire AddressBook
        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    // ===== Double-initialization prevention (Suggestion #9: specific revert selectors) =====

    function test_cannotReinitializeAddressBook() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        addressBook.initialize(address(0xDEAD));
    }

    function test_cannotReinitializeController() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        controller.initialize(address(addressBook), address(0xDEAD));
    }

    function test_cannotReinitializeMarginPool() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pool.initialize(address(addressBook));
    }

    function test_cannotReinitializeOTokenFactory() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(address(addressBook));
    }

    function test_cannotReinitializeOracle() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(address(addressBook), address(0xDEAD));
    }

    function test_cannotReinitializeWhitelist() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        whitelist.initialize(address(addressBook), address(0xDEAD));
    }

    function test_cannotReinitializeBatchSettler() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        settler.initialize(address(addressBook), address(0xDEAD), owner);
    }

    // ===== Implementation cannot be initialized (Important #5: all 7 contracts) =====

    function test_implementationLockedAddressBook() public {
        AddressBook impl = new AddressBook();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner);
    }

    function test_implementationLockedController() public {
        Controller impl = new Controller();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(addressBook), owner);
    }

    function test_implementationLockedMarginPool() public {
        MarginPool impl = new MarginPool();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(addressBook));
    }

    function test_implementationLockedOTokenFactory() public {
        OTokenFactory impl = new OTokenFactory();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(addressBook));
    }

    function test_implementationLockedOracle() public {
        Oracle impl = new Oracle();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(addressBook), owner);
    }

    function test_implementationLockedWhitelist() public {
        Whitelist impl = new Whitelist();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(addressBook), owner);
    }

    function test_implementationLockedBatchSettler() public {
        BatchSettler impl = new BatchSettler();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(addressBook), operator, owner);
    }

    // ===== Zero-address initialization tests (Suggestion #11) =====

    function test_initializeAddressBook_revertsOnZeroOwner() public {
        address impl = address(new AddressBook());
        vm.expectRevert(AddressBook.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(AddressBook.initialize, (address(0))));
    }

    function test_initializeController_revertsOnZeroAddress() public {
        address impl = address(new Controller());
        vm.expectRevert(Controller.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(Controller.initialize, (address(0), owner)));

        vm.expectRevert(Controller.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(Controller.initialize, (address(addressBook), address(0))));
    }

    function test_initializeOracle_revertsOnZeroAddress() public {
        address impl = address(new Oracle());
        vm.expectRevert(Oracle.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(Oracle.initialize, (address(0), owner)));

        vm.expectRevert(Oracle.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(Oracle.initialize, (address(addressBook), address(0))));
    }

    function test_initializeWhitelist_revertsOnZeroAddress() public {
        address impl = address(new Whitelist());
        vm.expectRevert(Whitelist.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(Whitelist.initialize, (address(0), owner)));

        vm.expectRevert(Whitelist.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(Whitelist.initialize, (address(addressBook), address(0))));
    }

    function test_initializeMarginPool_revertsOnZeroAddress() public {
        address impl = address(new MarginPool());
        vm.expectRevert(MarginPool.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(MarginPool.initialize, (address(0))));
    }

    function test_initializeOTokenFactory_revertsOnZeroAddress() public {
        address impl = address(new OTokenFactory());
        vm.expectRevert(OTokenFactory.InvalidAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(OTokenFactory.initialize, (address(0))));
    }

    // ===== Upgrade: state preserved =====

    function test_upgradeAddressBook_preservesState() public {
        address testAddr = address(0x1234);
        addressBook.setController(testAddr);
        assertEq(addressBook.controller(), testAddr);
        assertEq(addressBook.owner(), owner);

        AddressBookV2 v2Impl = new AddressBookV2();
        addressBook.upgradeToAndCall(address(v2Impl), "");

        assertEq(addressBook.controller(), testAddr);
        assertEq(addressBook.owner(), owner);
        assertEq(AddressBookV2(address(addressBook)).version(), 2);
    }

    function test_upgradeController_preservesState() public {
        assertEq(controller.owner(), owner);

        // Set pause state before upgrade
        address testPauser = address(0x9999);
        controller.setPartialPauser(testPauser);
        controller.setSystemFullyPaused(true);
        vm.prank(testPauser);
        controller.setSystemPartiallyPaused(true);

        ControllerV2 v2Impl = new ControllerV2();
        controller.upgradeToAndCall(address(v2Impl), "");

        assertEq(controller.owner(), owner);
        assertTrue(controller.systemPartiallyPaused());
        assertTrue(controller.systemFullyPaused());
        assertEq(controller.partialPauser(), testPauser);
        assertEq(ControllerV2(address(controller)).version(), 2);
    }

    function test_upgradeMarginPool_preservesState() public {
        assertEq(address(pool.addressBook()), address(addressBook));

        MarginPoolV2 v2Impl = new MarginPoolV2();
        pool.upgradeToAndCall(address(v2Impl), "");

        assertEq(address(pool.addressBook()), address(addressBook));
        assertEq(MarginPoolV2(address(pool)).version(), 2);
    }

    function test_upgradeOTokenFactory_preservesState() public {
        assertEq(address(factory.addressBook()), address(addressBook));

        OTokenFactoryV2 v2Impl = new OTokenFactoryV2();
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
        vm.expectRevert(AddressBook.OnlyOwner.selector);
        addressBook.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_Controller() public {
        ControllerV2 v2Impl = new ControllerV2();
        vm.prank(address(0xBAD));
        vm.expectRevert(Controller.OnlyOwner.selector);
        controller.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_MarginPool() public {
        MarginPoolV2 v2Impl = new MarginPoolV2();
        vm.prank(address(0xBAD));
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_OTokenFactory() public {
        OTokenFactoryV2 v2Impl = new OTokenFactoryV2();
        vm.prank(address(0xBAD));
        vm.expectRevert(OTokenFactory.Unauthorized.selector);
        factory.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_Oracle() public {
        OracleV2 v2Impl = new OracleV2();
        vm.prank(address(0xBAD));
        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_Whitelist() public {
        WhitelistV2 v2Impl = new WhitelistV2();
        vm.prank(address(0xBAD));
        vm.expectRevert(Whitelist.OnlyOwner.selector);
        whitelist.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeRevertsForNonOwner_BatchSettler() public {
        BatchSettlerV2 v2Impl = new BatchSettlerV2();
        vm.prank(address(0xBAD));
        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.upgradeToAndCall(address(v2Impl), "");
    }

    // ===== Delegated upgrade auth with AddressBook owner change (Important #6) =====

    function test_upgradeMarginPool_onlyAddressBookOwner() public {
        address newOwner = address(0xCAFE);

        // Transfer AddressBook ownership (two-step)
        addressBook.transferOwnership(newOwner);
        vm.prank(newOwner);
        addressBook.acceptOwnership();
        assertEq(addressBook.owner(), newOwner);

        // Old owner (this) can no longer upgrade MarginPool
        MarginPoolV2 v2Impl = new MarginPoolV2();
        vm.expectRevert(MarginPool.Unauthorized.selector);
        pool.upgradeToAndCall(address(v2Impl), "");

        // New owner can upgrade
        vm.prank(newOwner);
        pool.upgradeToAndCall(address(v2Impl), "");
        assertEq(MarginPoolV2(address(pool)).version(), 2);
    }

    function test_upgradeOTokenFactory_onlyAddressBookOwner() public {
        address newOwner = address(0xCAFE);

        // Transfer AddressBook ownership (two-step)
        addressBook.transferOwnership(newOwner);
        vm.prank(newOwner);
        addressBook.acceptOwnership();
        assertEq(addressBook.owner(), newOwner);

        // Old owner (this) can no longer upgrade OTokenFactory
        OTokenFactoryV2 v2Impl = new OTokenFactoryV2();
        vm.expectRevert(OTokenFactory.Unauthorized.selector);
        factory.upgradeToAndCall(address(v2Impl), "");

        // New owner can upgrade
        vm.prank(newOwner);
        factory.upgradeToAndCall(address(v2Impl), "");
        assertEq(OTokenFactoryV2(address(factory)).version(), 2);
    }

    // ===== BatchSettler domain separator proxy correctness (Important #7) =====

    function test_domainSeparator_usesProxyAddress() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("b1nary"),
                keccak256("1"),
                block.chainid,
                address(settler) // proxy address, not implementation
            )
        );
        assertEq(settler.DOMAIN_SEPARATOR(), expected);
    }

    function test_upgradeBatchSettler_domainSeparatorPreserved() public {
        bytes32 domainBefore = settler.DOMAIN_SEPARATOR();

        BatchSettlerV2 v2Impl = new BatchSettlerV2();
        settler.upgradeToAndCall(address(v2Impl), "");

        // Domain separator should remain the same after upgrade (same proxy address)
        assertEq(settler.DOMAIN_SEPARATOR(), domainBefore);
    }

    // ===== Two-step ownership on AddressBook (Important #4) =====

    function test_addressBook_twoStepOwnership() public {
        address newOwner = address(0x1234);

        // Step 1: transferOwnership sets pendingOwner
        addressBook.transferOwnership(newOwner);
        assertEq(addressBook.pendingOwner(), newOwner);
        assertEq(addressBook.owner(), owner); // still the old owner

        // Step 2: acceptOwnership completes transfer
        vm.prank(newOwner);
        addressBook.acceptOwnership();
        assertEq(addressBook.owner(), newOwner);
        assertEq(addressBook.pendingOwner(), address(0));
    }

    function test_addressBook_onlyPendingOwnerCanAccept() public {
        address newOwner = address(0x1234);
        addressBook.transferOwnership(newOwner);

        // Random address cannot accept
        vm.prank(address(0xBAD));
        vm.expectRevert(AddressBook.OnlyPendingOwner.selector);
        addressBook.acceptOwnership();

        // Old owner cannot accept
        vm.expectRevert(AddressBook.OnlyPendingOwner.selector);
        addressBook.acceptOwnership();
    }

    function test_addressBook_transferOwnershipRevertsOnZero() public {
        vm.expectRevert(AddressBook.InvalidAddress.selector);
        addressBook.transferOwnership(address(0));
    }

    // ===== transferOwnership tests for Controller, Oracle, Whitelist, BatchSettler =====

    function test_transferOwnership_Controller() public {
        address newOwner = address(0x1234);
        controller.transferOwnership(newOwner);
        // Two-step: owner unchanged until accepted
        assertEq(controller.owner(), owner);
        assertEq(controller.pendingOwner(), newOwner);

        // Non-pending cannot accept
        vm.prank(address(0x9999));
        vm.expectRevert(Controller.OnlyPendingOwner.selector);
        controller.acceptOwnership();

        // Pending owner accepts
        vm.prank(newOwner);
        controller.acceptOwnership();
        assertEq(controller.owner(), newOwner);
        assertEq(controller.pendingOwner(), address(0));

        // Old owner can no longer call owner-only functions
        vm.expectRevert(Controller.OnlyOwner.selector);
        controller.transferOwnership(address(0x5678));

        // New owner can
        vm.prank(newOwner);
        controller.transferOwnership(owner);
        vm.prank(owner);
        controller.acceptOwnership();
        assertEq(controller.owner(), owner);
    }

    function test_transferOwnership_Oracle() public {
        address newOwner = address(0x1234);
        oracle.transferOwnership(newOwner);
        assertEq(oracle.owner(), owner);
        assertEq(oracle.pendingOwner(), newOwner);

        vm.prank(newOwner);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), newOwner);

        vm.expectRevert(Oracle.OnlyOwner.selector);
        oracle.setPriceFeed(address(weth), address(feed));

        vm.prank(newOwner);
        oracle.setPriceFeed(address(weth), address(feed));
        assertEq(oracle.priceFeed(address(weth)), address(feed));
    }

    function test_transferOwnership_Whitelist() public {
        address newOwner = address(0x1234);
        whitelist.transferOwnership(newOwner);
        assertEq(whitelist.owner(), owner);
        assertEq(whitelist.pendingOwner(), newOwner);

        vm.prank(newOwner);
        whitelist.acceptOwnership();
        assertEq(whitelist.owner(), newOwner);

        vm.expectRevert(Whitelist.OnlyOwner.selector);
        whitelist.whitelistUnderlying(address(weth));

        vm.prank(newOwner);
        whitelist.whitelistUnderlying(address(weth));
        assertTrue(whitelist.isWhitelistedUnderlying(address(weth)));
    }

    function test_transferOwnership_BatchSettler() public {
        address newOwner = address(0x1234);
        settler.transferOwnership(newOwner);
        assertEq(settler.owner(), owner);
        assertEq(settler.pendingOwner(), newOwner);

        vm.prank(newOwner);
        settler.acceptOwnership();
        assertEq(settler.owner(), newOwner);

        vm.expectRevert(BatchSettler.OnlyOwner.selector);
        settler.setOperator(address(0xDEAD));

        vm.prank(newOwner);
        settler.setOperator(address(0xDEAD));
        assertEq(settler.operator(), address(0xDEAD));
    }

    function test_transferOwnership_revertsOnZero_Controller() public {
        vm.expectRevert(Controller.InvalidAddress.selector);
        controller.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsOnZero_Oracle() public {
        vm.expectRevert(Oracle.InvalidAddress.selector);
        oracle.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsOnZero_Whitelist() public {
        vm.expectRevert(Whitelist.InvalidAddress.selector);
        whitelist.transferOwnership(address(0));
    }

    function test_transferOwnership_revertsOnZero_BatchSettler() public {
        vm.expectRevert(BatchSettler.InvalidAddress.selector);
        settler.transferOwnership(address(0));
    }

    // ===== Reinitializer upgrade test (Suggestion #12) =====

    function test_upgradeToAndCall_withReinitializer() public {
        AddressBookV2Reinit v2Impl = new AddressBookV2Reinit();

        // Upgrade and call reinitializer(2) in one step
        addressBook.upgradeToAndCall(address(v2Impl), abi.encodeCall(AddressBookV2Reinit.initializeV2, (42)));

        assertEq(AddressBookV2Reinit(address(addressBook)).v2Value(), 42);
        assertEq(AddressBookV2Reinit(address(addressBook)).version(), 2);
        // Original state preserved
        assertEq(addressBook.owner(), owner);
    }
}
