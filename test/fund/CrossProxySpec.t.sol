// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IFundVault} from "../../src/fund/interfaces/IFundVault.sol";

interface IFundCallback {
    function onCallback() external;
}

contract FundLockVaultHarness {
    mapping(address module => uint64 version) public moduleVersion;
    address public lockOwner;
    uint256 public lockNonce;
    uint256 public value;
    uint256 public deposits;

    function registerModule(address module, uint64 version) external {
        moduleVersion[module] = version;
    }

    function beginModuleExecution(uint64 version) external returns (uint256 lockId) {
        uint64 expected = moduleVersion[msg.sender];
        if (expected == 0) revert IFundVault.InvalidModule(msg.sender);
        if (expected != version) revert IFundVault.IncompatibleModuleVersion(expected, version);
        if (lockOwner != address(0)) revert IFundVault.FundExecutionLocked(lockOwner);

        lockOwner = msg.sender;
        lockId = ++lockNonce;
    }

    function moduleWrite(uint256 lockId, uint256 newValue) external {
        if (moduleVersion[msg.sender] == 0 || lockOwner != msg.sender || lockId != lockNonce) {
            revert IFundVault.InvalidModule(msg.sender);
        }
        value = newValue;
    }

    function endModuleExecution(uint256 lockId) external {
        if (lockOwner != msg.sender || lockId != lockNonce) revert IFundVault.InvalidModule(msg.sender);
        lockOwner = address(0);
    }

    function deposit() external {
        if (lockOwner != address(0)) revert IFundVault.FundExecutionLocked(lockOwner);
        ++deposits;
    }
}

contract TypedModuleHarness {
    FundLockVaultHarness public immutable fund;
    uint64 public immutable version;
    bool public callbackSucceeded;

    constructor(FundLockVaultHarness fund_, uint64 version_) {
        fund = fund_;
        version = version_;
    }

    function execute(uint256 newValue, IFundCallback callback) external {
        uint256 lockId = fund.beginModuleExecution(version);
        fund.moduleWrite(lockId, newValue);
        if (address(callback) != address(0)) {
            (callbackSucceeded,) = address(callback).call(abi.encodeCall(IFundCallback.onCallback, ()));
        }
        fund.endModuleExecution(lockId);
    }

    function executeAndBubble(IFundCallback callback) external {
        uint256 lockId = fund.beginModuleExecution(version);
        callback.onCallback();
        fund.endModuleExecution(lockId);
    }
}

contract DepositReentrantCallback is IFundCallback {
    FundLockVaultHarness public immutable fund;

    constructor(FundLockVaultHarness fund_) {
        fund = fund_;
    }

    function onCallback() external {
        fund.deposit();
    }
}

contract ModuleReentrantCallback is IFundCallback {
    TypedModuleHarness public immutable module;

    constructor(TypedModuleHarness module_) {
        module = module_;
    }

    function onCallback() external {
        module.execute(999, IFundCallback(address(0)));
    }
}

contract AlwaysRevertCallback is IFundCallback {
    error CallbackReverted();

    function onCallback() external pure {
        revert CallbackReverted();
    }
}

contract CrossProxySpecTest is Test {
    FundLockVaultHarness internal fund;
    TypedModuleHarness internal flowModule;
    TypedModuleHarness internal strategyModule;

    function setUp() public {
        fund = new FundLockVaultHarness();
        flowModule = new TypedModuleHarness(fund, 1);
        strategyModule = new TypedModuleHarness(fund, 1);
        fund.registerModule(address(flowModule), 1);
        fund.registerModule(address(strategyModule), 1);
    }

    function test_registeredCompatibleModuleCanWriteInsideLock() public {
        flowModule.execute(42, IFundCallback(address(0)));

        assertEq(fund.value(), 42);
        assertEq(fund.lockOwner(), address(0));
    }

    function test_unregisteredCallerCannotAcquireOrWrite() public {
        vm.expectRevert(abi.encodeWithSelector(IFundVault.InvalidModule.selector, address(this)));
        fund.beginModuleExecution(1);

        vm.expectRevert(abi.encodeWithSelector(IFundVault.InvalidModule.selector, address(this)));
        fund.moduleWrite(1, 1);
    }

    function test_incompatibleModuleVersionFailsBeforeLock() public {
        fund.registerModule(address(flowModule), 2);

        vm.expectRevert(abi.encodeWithSelector(IFundVault.IncompatibleModuleVersion.selector, 2, 1));
        flowModule.execute(42, IFundCallback(address(0)));

        assertEq(fund.lockOwner(), address(0));
        assertEq(fund.value(), 0);
    }

    function test_callbackCannotReenterDeposit() public {
        DepositReentrantCallback callback = new DepositReentrantCallback(fund);

        flowModule.execute(42, callback);

        assertFalse(flowModule.callbackSucceeded());
        assertEq(fund.deposits(), 0);
        assertEq(fund.lockOwner(), address(0));
    }

    function test_callbackCannotEnterSecondModule() public {
        ModuleReentrantCallback callback = new ModuleReentrantCallback(strategyModule);

        flowModule.execute(42, callback);

        assertFalse(flowModule.callbackSucceeded());
        assertEq(fund.value(), 42);
        assertEq(fund.lockOwner(), address(0));
    }

    function test_bubbledExternalRevertRollsBackLockAcquisition() public {
        AlwaysRevertCallback callback = new AlwaysRevertCallback();

        vm.expectRevert(AlwaysRevertCallback.CallbackReverted.selector);
        flowModule.executeAndBubble(callback);

        assertEq(fund.lockOwner(), address(0));
        assertEq(fund.lockNonce(), 0);
    }
}
