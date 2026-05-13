// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressBook} from "../src/core/AddressBook.sol";
import {BatchSettler} from "../src/core/BatchSettler.sol";
import {Controller} from "../src/core/Controller.sol";
import {MarginPool} from "../src/core/MarginPool.sol";
import {OTokenFactory} from "../src/core/OTokenFactory.sol";
import {Oracle} from "../src/core/Oracle.sol";
import {Whitelist} from "../src/core/Whitelist.sol";
import {BaseVaultAdapter} from "../src/adapters/BaseVaultAdapter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract BaseVaultAdapterTest is Test {
    AddressBook public addressBook;
    Controller public controller;
    MarginPool public pool;
    OTokenFactory public factory;
    Oracle public oracle;
    Whitelist public whitelist;
    BatchSettler public settler;
    BaseVaultAdapter public adapter;

    MockERC20 public weth;
    MockERC20 public usdc;

    address public owner = address(this);
    address public operator = address(0x0B0B);
    address public agent = address(0xA6E17);
    uint256 public mmKey = 0xAA01;
    address public mm;

    uint256 public strikePrice = 2000e8;
    uint256 public expiry;
    uint256 public nextQuoteId = 1;

    event PositionOpened(
        bytes32 indexed intentId,
        uint256 indexed vaultId,
        address indexed oToken,
        BaseVaultAdapter.PositionMode mode,
        uint256 amount,
        uint256 premium,
        uint256 collateral,
        uint256 expiry
    );

    function setUp() public {
        vm.warp(1_700_000_000);
        mm = vm.addr(mmKey);

        _deployProtocol();
        _deployAdapter();

        settler.setWhitelistedMM(mm, true);

        whitelist.whitelistUnderlying(address(weth));
        whitelist.whitelistCollateral(address(usdc));
        whitelist.whitelistCollateral(address(weth));
        whitelist.whitelistProduct(address(weth), address(usdc), address(usdc), true);
        whitelist.whitelistProduct(address(weth), address(usdc), address(weth), false);

        _computeExpiry();

        usdc.mint(mm, 1_000_000e6);
        vm.prank(mm);
        usdc.approve(address(settler), type(uint256).max);

        usdc.mint(address(adapter), 100_000e6);
        weth.mint(address(adapter), 100e18);
    }

    function test_executePosition_recordsCspPosition() public {
        address oToken = _createPut(strikePrice);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        bytes32 intentId = keccak256("csp-intent");
        uint256 amount = 1e8;
        uint256 collateral = 2000e6;
        uint256 premium = 70e6;

        vm.expectEmit(true, true, true, true);
        emit PositionOpened(intentId, 1, oToken, BaseVaultAdapter.PositionMode.CSP, amount, premium, collateral, expiry);

        vm.prank(agent);
        uint256 vaultId =
            adapter.executePosition(intentId, quote, sig, amount, collateral, BaseVaultAdapter.PositionMode.CSP);

        assertEq(vaultId, 1);
        assertTrue(adapter.processedIntent(intentId));
        assertEq(controller.vaultCount(address(adapter)), 1);
        assertEq(usdc.balanceOf(address(adapter)), 100_000e6 - collateral + premium);

        (
            bool exists,
            BaseVaultAdapter.PositionMode mode,
            BaseVaultAdapter.PositionStatus status,
            address recordedOToken,
            address underlying,
            address strikeAsset,
            address collateralAsset,
            uint256 recordedExpiry,
            uint256 recordedAmount,
            uint256 recordedCollateral,
            uint256 recordedPremium,
            uint256 recordedVaultId,
        ) = adapter.positions(intentId);

        assertTrue(exists);
        assertEq(uint256(mode), uint256(BaseVaultAdapter.PositionMode.CSP));
        assertEq(uint256(status), uint256(BaseVaultAdapter.PositionStatus.Opened));
        assertEq(recordedOToken, oToken);
        assertEq(underlying, address(weth));
        assertEq(strikeAsset, address(usdc));
        assertEq(collateralAsset, address(usdc));
        assertEq(recordedExpiry, expiry);
        assertEq(recordedAmount, amount);
        assertEq(recordedCollateral, collateral);
        assertEq(recordedPremium, premium);
        assertEq(recordedVaultId, vaultId);
    }

    function test_executePosition_recordsCcPosition() public {
        address oToken = _createCall(strikePrice);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 50e6, block.timestamp + 1 hours, 100e8);

        bytes32 intentId = keccak256("cc-intent");

        vm.prank(operator);
        adapter.executePosition(intentId, quote, sig, 1e8, 1e18, BaseVaultAdapter.PositionMode.CC);

        (,, BaseVaultAdapter.PositionStatus status,,,, address collateralAsset,,,,,,) = adapter.positions(intentId);
        assertEq(uint256(status), uint256(BaseVaultAdapter.PositionStatus.Opened));
        assertEq(collateralAsset, address(weth));
        assertTrue(adapter.processedIntent(intentId));
    }

    function test_executePosition_revertsOnModeMismatch() public {
        address oToken = _createPut(strikePrice);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(agent);
        vm.expectRevert(BaseVaultAdapter.InvalidMode.selector);
        adapter.executePosition(keccak256("bad-mode"), quote, sig, 1e8, 2000e6, BaseVaultAdapter.PositionMode.CC);
    }

    function test_executePosition_rejectsDuplicateIntent() public {
        address oToken = _createPut(strikePrice);
        bytes32 intentId = keccak256("duplicate-intent");

        (BatchSettler.Quote memory quote1, bytes memory sig1) =
            _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);
        vm.prank(agent);
        adapter.executePosition(intentId, quote1, sig1, 1e8, 2000e6, BaseVaultAdapter.PositionMode.CSP);

        (BatchSettler.Quote memory quote2, bytes memory sig2) =
            _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);
        vm.prank(agent);
        vm.expectRevert(BaseVaultAdapter.IntentAlreadyProcessed.selector);
        adapter.executePosition(intentId, quote2, sig2, 1e8, 2000e6, BaseVaultAdapter.PositionMode.CSP);
    }

    function test_executePosition_onlyAgentOrOperator() public {
        address oToken = _createPut(strikePrice);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        vm.prank(address(0xBAD));
        vm.expectRevert(BaseVaultAdapter.OnlyAgentOrOperator.selector);
        adapter.executePosition(keccak256("unauthorized"), quote, sig, 1e8, 2000e6, BaseVaultAdapter.PositionMode.CSP);
    }

    function test_pauseBlocksExecutionAndStatusUpdates() public {
        address oToken = _createPut(strikePrice);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        adapter.pause();

        vm.prank(agent);
        vm.expectRevert();
        adapter.executePosition(keccak256("paused"), quote, sig, 1e8, 2000e6, BaseVaultAdapter.PositionMode.CSP);

        adapter.unpause();
        vm.prank(agent);
        adapter.executePosition(keccak256("opened"), quote, sig, 1e8, 2000e6, BaseVaultAdapter.PositionMode.CSP);

        adapter.pause();
        vm.prank(agent);
        vm.expectRevert();
        adapter.updatePositionStatus(keccak256("opened"), BaseVaultAdapter.PositionStatus.NoAssignment);
    }

    function test_updatePositionStatus_recordsLifecycle() public {
        address oToken = _createPut(strikePrice);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);

        bytes32 intentId = keccak256("lifecycle");
        vm.prank(agent);
        adapter.executePosition(intentId, quote, sig, 1e8, 2000e6, BaseVaultAdapter.PositionMode.CSP);

        vm.prank(operator);
        adapter.updatePositionStatus(intentId, BaseVaultAdapter.PositionStatus.NoAssignment);
        (,, BaseVaultAdapter.PositionStatus status,,,,,,,,,,) = adapter.positions(intentId);
        assertEq(uint256(status), uint256(BaseVaultAdapter.PositionStatus.NoAssignment));

        vm.prank(agent);
        adapter.updatePositionStatus(intentId, BaseVaultAdapter.PositionStatus.Closed);
        (,, status,,,,,,,,,,) = adapter.positions(intentId);
        assertEq(uint256(status), uint256(BaseVaultAdapter.PositionStatus.Closed));
    }

    function test_recordAssetReceipt_supportsBridgedUsdcAndHeldAssets() public {
        bytes32 receiptId = keccak256("bridge-usdc");

        vm.prank(agent);
        adapter.recordAssetReceipt(receiptId, address(usdc), 100e6);

        assertTrue(adapter.processedAssetReceipt(receiptId));

        weth.mint(address(adapter), 2e18);
        vm.prank(operator);
        adapter.recordAssetReceipt(keccak256("assigned-weth"), address(weth), 2e18);

        assertEq(weth.balanceOf(address(adapter)), 102e18);
    }

    function test_failedExecutionDoesNotMarkIntent() public {
        address oToken = _createPut(strikePrice);
        (BatchSettler.Quote memory quote, bytes memory sig) = _signQuote(oToken, 70e6, block.timestamp + 1 hours, 100e8);
        bytes32 intentId = keccak256("failed-execution");

        vm.prank(agent);
        vm.expectRevert(BatchSettler.CapacityExceeded.selector);
        adapter.executePosition(intentId, quote, sig, 101e8, 202_000e6, BaseVaultAdapter.PositionMode.CSP);

        assertFalse(adapter.processedIntent(intentId));
        (bool exists,,,,,,,,,,,,) = adapter.positions(intentId);
        assertFalse(exists);
    }

    function _deployProtocol() internal {
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        addressBook = AddressBook(
            address(
                new ERC1967Proxy(address(new AddressBook()), abi.encodeCall(AddressBook.initialize, (address(this))))
            )
        );
        controller = Controller(
            address(
                new ERC1967Proxy(
                    address(new Controller()),
                    abi.encodeCall(Controller.initialize, (address(addressBook), address(this)))
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
                    address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(addressBook), address(this)))
                )
            )
        );
        whitelist = Whitelist(
            address(
                new ERC1967Proxy(
                    address(new Whitelist()),
                    abi.encodeCall(Whitelist.initialize, (address(addressBook), address(this)))
                )
            )
        );
        settler = BatchSettler(
            address(
                new ERC1967Proxy(
                    address(new BatchSettler()),
                    abi.encodeCall(BatchSettler.initialize, (address(addressBook), operator, address(this)))
                )
            )
        );

        addressBook.setController(address(controller));
        addressBook.setMarginPool(address(pool));
        addressBook.setOTokenFactory(address(factory));
        factory.setOperator(address(this));
        addressBook.setOracle(address(oracle));
        addressBook.setWhitelist(address(whitelist));
        addressBook.setBatchSettler(address(settler));
    }

    function _deployAdapter() internal {
        adapter = BaseVaultAdapter(
            address(
                new ERC1967Proxy(
                    address(new BaseVaultAdapter()),
                    abi.encodeCall(
                        BaseVaultAdapter.initialize,
                        (address(addressBook), address(settler), address(usdc), owner, operator, agent)
                    )
                )
            )
        );
    }

    function _computeExpiry() internal {
        uint256 today8am = (block.timestamp / 1 days) * 1 days + 8 hours;
        expiry = today8am > block.timestamp ? today8am : today8am + 1 days;
    }

    function _createPut(uint256 strike) internal returns (address) {
        address oToken = factory.createOToken(address(weth), address(usdc), address(usdc), strike, expiry, true);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _createCall(uint256 strike) internal returns (address) {
        address oToken = factory.createOToken(address(weth), address(usdc), address(weth), strike, expiry, false);
        whitelist.whitelistOToken(oToken);
        return oToken;
    }

    function _signQuote(address oToken, uint256 bidPrice, uint256 deadline, uint256 maxAmount)
        internal
        returns (BatchSettler.Quote memory quote, bytes memory sig)
    {
        quote = BatchSettler.Quote({
            oToken: oToken,
            bidPrice: bidPrice,
            deadline: deadline,
            quoteId: nextQuoteId++,
            maxAmount: maxAmount,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mmKey, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
