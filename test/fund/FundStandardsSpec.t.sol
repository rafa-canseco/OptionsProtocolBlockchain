// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundMath} from "../../src/fund/libraries/FundMath.sol";
import {IERC7540Operator, IERC7540Redeem} from "../../src/fund/interfaces/IERC7540.sol";
import {IERC7575} from "../../src/fund/interfaces/IERC7575.sol";

contract AsyncRedeemVaultHarness is ERC4626, ERC20Permit, ERC165, IERC7540Operator, IERC7540Redeem, IERC7575 {
    using SafeERC20 for IERC20;

    error AsyncPreviewUnsupported();
    error InvalidRequestId(uint256 requestId);
    error RequestNotCancelable();
    error UnauthorizedOperator(address controller, address caller);

    mapping(address controller => mapping(address operator => bool approved)) private _operators;
    mapping(address controller => uint256 shares) private _pending;
    mapping(address controller => uint256 shares) private _claimableShares;
    mapping(address controller => uint256 assets) private _claimableAssets;
    mapping(address controller => bool committed) private _unwindCommitted;
    mapping(address controller => bool seen) private _seenController;
    address[] private _controllers;

    uint256 public totalPendingShares;
    uint256 public totalReservedAssets;
    uint256 public accountedGrossAssets;
    bool public immediateClaimable;

    constructor(IERC20 asset_) ERC20("b1nary Fund Share", "bFUND") ERC4626(asset_) ERC20Permit("b1nary Fund Share") {}

    function share() external view returns (address) {
        return address(this);
    }

    function decimals() public view override(ERC20, ERC4626, IERC20Metadata) returns (uint8) {
        return ERC4626.decimals();
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return accountedGrossAssets - totalReservedAssets;
    }

    function unaccountedBalance() public view returns (uint256) {
        uint256 rawBalance = IERC20(asset()).balanceOf(address(this));
        return rawBalance > accountedGrossAssets ? rawBalance - accountedGrossAssets : 0;
    }

    function syncDonation() external {
        accountedGrossAssets += unaccountedBalance();
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165) returns (bool) {
        return interfaceId == FundConstants.ERC7540_OPERATOR_INTERFACE_ID
            || interfaceId == FundConstants.ERC7540_REDEEM_INTERFACE_ID
            || interfaceId == FundConstants.ERC7575_VAULT_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    function setImmediateClaimable(bool enabled) external {
        immediateClaimable = enabled;
    }

    function isOperator(address controller, address operator) public view returns (bool) {
        return _operators[controller][operator];
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        _operators[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId) {
        if (controller == address(0) || owner == address(0) || shares == 0) {
            revert UnauthorizedOperator(owner, msg.sender);
        }

        if (msg.sender != owner && !isOperator(owner, msg.sender)) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _transfer(owner, address(this), shares);
        if (!_seenController[controller]) {
            _seenController[controller] = true;
            _controllers.push(controller);
        }

        _pending[controller] += shares;
        totalPendingShares += shares;
        emit RedeemRequest(controller, owner, FundConstants.ERC7540_REQUEST_ID, msg.sender, shares);

        if (immediateClaimable) {
            uint256 nav = totalAssets();
            uint256 supply = totalSupply();
            _makeClaimable(controller, shares, Math.mulDiv(shares, nav, supply));
        }
        return FundConstants.ERC7540_REQUEST_ID;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        _requireRequestId(requestId);
        return _pending[controller];
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        _requireRequestId(requestId);
        return _claimableShares[controller];
    }

    function claimableAssets(address controller) external view returns (uint256) {
        return _claimableAssets[controller];
    }

    function markUnwindCommitted(address controller) external {
        _unwindCommitted[controller] = true;
    }

    function cancelPending(uint256 shares) external {
        if (_claimableShares[msg.sender] != 0 || _unwindCommitted[msg.sender] || shares > _pending[msg.sender]) {
            revert RequestNotCancelable();
        }
        _pending[msg.sender] -= shares;
        totalPendingShares -= shares;
        _transfer(address(this), msg.sender, shares);
    }

    function processBatch(uint256 requestedProcessedShares) external returns (uint256 actualProcessedShares) {
        uint256 batchShares = totalPendingShares;
        if (requestedProcessedShares > batchShares || batchShares == 0) revert RequestNotCancelable();

        uint256 nav = totalAssets();
        uint256 supply = totalSupply();
        uint256 length = _controllers.length;
        for (uint256 i; i < length; ++i) {
            address controller = _controllers[i];
            uint256 controllerShares = FundMath.proRata(_pending[controller], requestedProcessedShares, batchShares);
            if (controllerShares == 0) continue;

            uint256 assets = Math.mulDiv(controllerShares, nav, supply);
            actualProcessedShares += controllerShares;
            _makeClaimable(controller, controllerShares, assets);
        }
    }

    function maxRedeem(address controller) public view override(ERC4626, IERC4626) returns (uint256) {
        return _claimableShares[controller];
    }

    function maxWithdraw(address controller) public view override(ERC4626, IERC4626) returns (uint256) {
        return _claimableAssets[controller];
    }

    function previewRedeem(uint256) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function previewWithdraw(uint256) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert AsyncPreviewUnsupported();
    }

    function redeem(uint256 shares, address receiver, address controller)
        public
        override(ERC4626, IERC4626)
        returns (uint256 assets)
    {
        _requireController(controller);
        uint256 availableShares = _claimableShares[controller];
        if (shares == 0 || shares > availableShares) {
            revert ERC4626ExceededMaxRedeem(controller, shares, availableShares);
        }

        assets = Math.mulDiv(_claimableAssets[controller], shares, availableShares);
        _consumeClaim(controller, receiver, shares, assets);
    }

    function withdraw(uint256 assets, address receiver, address controller)
        public
        override(ERC4626, IERC4626)
        returns (uint256 shares)
    {
        _requireController(controller);
        uint256 availableAssets = _claimableAssets[controller];
        if (assets == 0 || assets > availableAssets) {
            revert ERC4626ExceededMaxWithdraw(controller, assets, availableAssets);
        }

        shares = Math.mulDiv(_claimableShares[controller], assets, availableAssets, Math.Rounding.Ceil);
        _consumeClaim(controller, receiver, shares, assets);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        accountedGrossAssets += assets;
    }

    function _makeClaimable(address controller, uint256 shares, uint256 assets) private {
        _pending[controller] -= shares;
        totalPendingShares -= shares;
        _claimableShares[controller] += shares;
        _claimableAssets[controller] += assets;
        totalReservedAssets += assets;
        _burn(address(this), shares);
    }

    function _consumeClaim(address controller, address receiver, uint256 shares, uint256 assets) private {
        _claimableShares[controller] -= shares;
        _claimableAssets[controller] -= assets;
        totalReservedAssets -= assets;
        accountedGrossAssets -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function _requireController(address controller) private view {
        if (msg.sender != controller && !isOperator(controller, msg.sender)) {
            revert UnauthorizedOperator(controller, msg.sender);
        }
    }

    function _requireRequestId(uint256 requestId) private pure {
        if (requestId != FundConstants.ERC7540_REQUEST_ID) revert InvalidRequestId(requestId);
    }
}

contract FundStandardsSpecTest is Test {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    MockERC20 internal asset;
    AsyncRedeemVaultHarness internal vault;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob = address(0xB0B);
    address internal operator = address(0x0B01);

    function setUp() public {
        aliceKey = 0xA11CE;
        alice = vm.addr(aliceKey);
        asset = new MockERC20("Mock USDC", "mUSDC", 6);
        vault = new AsyncRedeemVaultHarness(asset);

        asset.mint(alice, 2_000e6);
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_interfaceIdsMatchFinalStandards() public view {
        assertEq(type(IERC7540Operator).interfaceId, FundConstants.ERC7540_OPERATOR_INTERFACE_ID);
        assertEq(type(IERC7540Redeem).interfaceId, FundConstants.ERC7540_REDEEM_INTERFACE_ID);
        assertTrue(vault.supportsInterface(FundConstants.ERC165_INTERFACE_ID));
        assertTrue(vault.supportsInterface(FundConstants.ERC7540_OPERATOR_INTERFACE_ID));
        assertTrue(vault.supportsInterface(FundConstants.ERC7540_REDEEM_INTERFACE_ID));
        assertTrue(vault.supportsInterface(FundConstants.ERC7575_VAULT_INTERFACE_ID));
        assertFalse(vault.supportsInterface(0xffffffff));
        assertEq(vault.share(), address(vault));
    }

    function test_erc20SharesAreTransferable() public {
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 100e6));
        assertEq(vault.balanceOf(bob), 100e6);
    }

    function test_erc4626DepositsAndMintsRemainSynchronous() public {
        asset.mint(bob, 300e6);
        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, bob);
        uint256 assets = vault.mint(50e6, bob);
        vm.stopPrank();

        assertEq(shares, 100e6);
        assertEq(assets, 50e6);
        assertEq(vault.balanceOf(bob), 150e6);
    }

    function test_erc2612PermitSetsShareAllowance() public {
        uint256 value = 250e6;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, alice, operator, value, 0, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        vault.permit(alice, operator, value, deadline, v, r, s);

        assertEq(vault.allowance(alice, operator), value);
        assertEq(vault.nonces(alice), 1);
    }

    function test_requestMovesSharesToPendingEscrowWithoutBurning() public {
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(400e6, alice, alice);

        assertEq(requestId, 0);
        assertEq(vault.pendingRedeemRequest(0, alice), 400e6);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);
        assertEq(vault.balanceOf(address(vault)), 400e6);
        assertEq(vault.totalSupply(), 1_000e6);
    }

    function test_pendingSharesRemainYieldBearingAfterDonationIsSynchronized() public {
        vm.prank(alice);
        vault.requestRedeem(400e6, alice, alice);
        asset.mint(address(vault), 100e6);
        vault.syncDonation();

        vault.processBatch(400e6);

        assertEq(vault.claimableAssets(alice), 440e6);
        assertEq(vault.totalReservedAssets(), 440e6);
        assertEq(vault.totalAssets(), 660e6);
        assertEq(vault.totalSupply(), 600e6);
    }

    function test_donationDoesNotChangeNavUntilSynchronized() public {
        asset.mint(address(vault), 100e6);

        assertEq(vault.totalAssets(), 1_000e6);
        assertEq(vault.unaccountedBalance(), 100e6);

        vault.syncDonation();
        assertEq(vault.totalAssets(), 1_100e6);
        assertEq(vault.unaccountedBalance(), 0);
    }

    function test_partialProcessingIsProRataAndClaimIsPullBased() public {
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 200e6));
        vm.prank(alice);
        vault.requestRedeem(400e6, alice, alice);
        vm.prank(bob);
        vault.requestRedeem(200e6, bob, bob);

        uint256 processed = vault.processBatch(300e6);

        assertEq(processed, 300e6);
        assertEq(vault.pendingRedeemRequest(0, alice), 200e6);
        assertEq(vault.pendingRedeemRequest(0, bob), 100e6);
        assertEq(vault.claimableRedeemRequest(0, alice), 200e6);
        assertEq(vault.claimableRedeemRequest(0, bob), 100e6);
        assertEq(asset.balanceOf(alice), 1_000e6);

        vm.prank(alice);
        uint256 assets = vault.redeem(200e6, alice, alice);
        assertEq(assets, 200e6);
        assertEq(asset.balanceOf(alice), 1_200e6);
    }

    function test_immediateClaimableStillRequiresSeparateClaim() public {
        vault.setImmediateClaimable(true);
        uint256 beforeAssets = asset.balanceOf(alice);

        vm.prank(alice);
        vault.requestRedeem(100e6, alice, alice);

        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.claimableRedeemRequest(0, alice), 100e6);
        assertEq(asset.balanceOf(alice), beforeAssets);

        vm.prank(alice);
        vault.withdraw(100e6, alice, alice);
        assertEq(asset.balanceOf(alice), beforeAssets + 100e6);
    }

    function test_operatorCanRequestAndClaimWithoutShareAllowance() public {
        vm.prank(alice);
        vault.setOperator(operator, true);

        vm.prank(operator);
        vault.requestRedeem(100e6, alice, alice);
        vault.processBatch(100e6);
        vm.prank(operator);
        vault.redeem(100e6, alice, alice);

        assertEq(vault.allowance(alice, operator), 0);
        assertEq(asset.balanceOf(alice), 1_100e6);
    }

    function test_shareAllowanceCanAuthorizeRequestWithoutOperatorPermission() public {
        vm.prank(alice);
        vault.approve(operator, 100e6);

        vm.prank(operator);
        vault.requestRedeem(100e6, operator, alice);

        assertEq(vault.allowance(alice, operator), 0);
        assertEq(vault.pendingRedeemRequest(0, operator), 100e6);
    }

    function test_asyncPreviewFunctionsAlwaysRevertAndMaxUsesClaimable() public {
        vm.prank(alice);
        vault.requestRedeem(200e6, alice, alice);
        vault.processBatch(100e6);

        vm.expectRevert(AsyncRedeemVaultHarness.AsyncPreviewUnsupported.selector);
        vault.previewRedeem(1);
        vm.expectRevert(AsyncRedeemVaultHarness.AsyncPreviewUnsupported.selector);
        vault.previewWithdraw(1);

        assertEq(vault.maxRedeem(alice), 100e6);
        assertEq(vault.maxWithdraw(alice), 100e6);
    }

    function test_pendingCancellationStopsAfterAnyClaimableTransition() public {
        vm.prank(alice);
        vault.requestRedeem(200e6, alice, alice);
        vault.processBatch(100e6);

        vm.prank(alice);
        vm.expectRevert(AsyncRedeemVaultHarness.RequestNotCancelable.selector);
        vault.cancelPending(100e6);
    }

    function test_pendingCancellationReturnsEscrowedSharesBeforeUnwind() public {
        vm.prank(alice);
        vault.requestRedeem(200e6, alice, alice);

        vm.prank(alice);
        vault.cancelPending(200e6);

        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.balanceOf(alice), 1_000e6);
    }

    function test_nonZeroRequestIdAlwaysReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AsyncRedeemVaultHarness.InvalidRequestId.selector, 1));
        vault.pendingRedeemRequest(1, alice);
    }
}
