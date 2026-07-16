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
import {IERC7540Operator, IERC7540Redeem} from "../../src/fund/interfaces/IERC7540.sol";
import {IERC7575} from "../../src/fund/interfaces/IERC7575.sol";
import {IFundFlowManager} from "../../src/fund/interfaces/IFundFlowManager.sol";
import {IFundVault} from "../../src/fund/interfaces/IFundVault.sol";

contract AsyncRedeemVaultHarness is ERC4626, ERC20Permit, ERC165, IERC7540Operator, IERC7540Redeem, IERC7575 {
    using SafeERC20 for IERC20;

    error AsyncPreviewUnsupported();
    error RequestNotCancelable();
    error InvalidDonationReportNonce(uint64 expected, uint64 actual);
    error UnauthorizedAccounting(address caller);
    error UnauthorizedOperator(address controller, address caller);

    struct BatchAccount {
        uint256 pendingShares;
        uint256 pendingMinAssetsOut;
        uint16 indexPlusOne;
    }

    struct Batch {
        uint256 totalPendingShares;
        uint256 processedShares;
        uint256 marginalExitCost;
        uint256 processingNav;
        uint256 eligibleSupply;
        uint256 roundPendingShares;
        uint256 roundTargetShares;
        uint256 roundCumulativeShares;
        uint256 roundAllocatedShares;
        uint256 roundAssetBudget;
        uint256 roundAllocatedAssets;
        uint16 processingCursor;
        bool isSealed;
        bool processing;
        bool unwindCommitted;
    }

    mapping(address controller => mapping(address operator => bool approved)) private _operators;
    mapping(address controller => uint256 shares) private _pending;
    mapping(address controller => uint256 shares) private _claimableShares;
    mapping(address controller => uint256 assets) private _claimableAssets;
    mapping(address controller => uint256 assets) private _pendingMinAssetsOut;
    mapping(address controller => bool committed) private _unwindCommitted;
    mapping(address controller => uint64 batchId) private _pendingBatchId;
    mapping(uint64 batchId => Batch batch) private _batches;
    mapping(uint64 batchId => address[] controllers) private _batchControllers;
    mapping(uint64 batchId => mapping(address controller => BatchAccount account)) private _batchAccounts;

    uint256 public totalPendingShares;
    uint256 public totalReservedAssets;
    uint256 public accountedGrossAssets;
    uint256 public activeProcessingRounds;
    uint64 public openBatchId = 1;
    uint64 public nextProcessBatchId = 1;
    uint64 public lastDonationReportNonce;
    bool public immediateClaimable;
    address public immutable accounting;
    uint8 private immutable _shareDecimalsOffsetValue;

    constructor(IERC20 asset_) ERC20("b1nary Fund Share", "bFUND") ERC4626(asset_) ERC20Permit("b1nary Fund Share") {
        accounting = msg.sender;
        uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
        if (assetDecimals > FundConstants.SHARE_DECIMALS) {
            revert IFundVault.UnsupportedAccountingAssetDecimals(assetDecimals);
        }
        _shareDecimalsOffsetValue = FundConstants.SHARE_DECIMALS - assetDecimals;
    }

    function share() external view returns (address) {
        return address(this);
    }

    function decimals() public view override(ERC20, ERC4626, IERC20Metadata) returns (uint8) {
        return ERC4626.decimals();
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return _shareDecimalsOffsetValue;
    }

    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return accountedGrossAssets - totalReservedAssets;
    }

    function unaccountedBalance() public view returns (uint256) {
        uint256 rawBalance = IERC20(asset()).balanceOf(address(this));
        return rawBalance > accountedGrossAssets ? rawBalance - accountedGrossAssets : 0;
    }

    function syncDonation(uint64 reportNonce) external {
        if (msg.sender != accounting) revert UnauthorizedAccounting(msg.sender);
        if (activeProcessingRounds != 0) revert IFundFlowManager.BatchNotProcessable(nextProcessBatchId);
        uint64 expectedNonce = lastDonationReportNonce + 1;
        if (reportNonce != expectedNonce) revert InvalidDonationReportNonce(expectedNonce, reportNonce);
        lastDonationReportNonce = reportNonce;
        accountedGrossAssets += unaccountedBalance();
    }

    function maxDeposit(address) public view override(ERC4626, IERC4626) returns (uint256) {
        return unaccountedBalance() == 0 && activeProcessingRounds == 0 ? type(uint256).max : 0;
    }

    function maxMint(address) public view override(ERC4626, IERC4626) returns (uint256) {
        return unaccountedBalance() == 0 && activeProcessingRounds == 0 ? type(uint256).max : 0;
    }

    function depositWithMinShares(uint256 assets, address receiver, uint256 minSharesOut)
        external
        returns (uint256 shares)
    {
        shares = deposit(assets, receiver);
        if (shares < minSharesOut) revert IFundVault.MinimumSharesNotMet(minSharesOut, shares);
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
        return _requestRedeem(shares, controller, owner, 0);
    }

    function requestRedeemWithMinAssets(uint256 shares, address controller, address owner, uint256 minAssetsOut)
        external
        returns (uint256 requestId)
    {
        return _requestRedeem(shares, controller, owner, minAssetsOut);
    }

    function _requestRedeem(uint256 shares, address controller, address owner, uint256 minAssetsOut)
        private
        returns (uint256 requestId)
    {
        if (controller == address(0) || owner == address(0) || shares == 0) {
            revert UnauthorizedOperator(owner, msg.sender);
        }

        if (msg.sender != owner && !isOperator(owner, msg.sender)) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _transfer(owner, address(this), shares);
        _pending[controller] += shares;
        _pendingMinAssetsOut[controller] += minAssetsOut;
        totalPendingShares += shares;
        emit RedeemRequest(controller, owner, FundConstants.ERC7540_REQUEST_ID, msg.sender, shares);

        if (immediateClaimable && unaccountedBalance() == 0 && activeProcessingRounds == 0) {
            uint256 nav = totalAssets();
            uint256 supply = totalSupply();
            uint256 assets = Math.mulDiv(shares, nav, supply);
            if (assets < minAssetsOut) {
                revert IFundFlowManager.MinimumAssetsNotMet(controller, minAssetsOut, assets);
            }
            _pendingMinAssetsOut[controller] -= minAssetsOut;
            _makeClaimable(controller, shares, assets);
        } else {
            _addToOpenBatch(controller, shares, minAssetsOut);
        }
        return FundConstants.ERC7540_REQUEST_ID;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return requestId == FundConstants.ERC7540_REQUEST_ID ? _pending[controller] : 0;
    }

    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        return requestId == FundConstants.ERC7540_REQUEST_ID ? _claimableShares[controller] : 0;
    }

    function claimableAssets(address controller) external view returns (uint256) {
        return _claimableAssets[controller];
    }

    function markUnwindCommitted(address controller) external {
        _unwindCommitted[controller] = true;
        _batches[_pendingBatchId[controller]].unwindCommitted = true;
    }

    function cancelPending(uint256 shares) external {
        uint64 batchId = _pendingBatchId[msg.sender];
        Batch storage batch = _batches[batchId];
        BatchAccount storage account = _batchAccounts[batchId][msg.sender];
        if (
            _claimableShares[msg.sender] != 0 || _unwindCommitted[msg.sender] || batch.processing
                || batch.unwindCommitted || shares == 0 || shares > account.pendingShares
        ) {
            revert RequestNotCancelable();
        }

        uint256 minReduction = Math.mulDiv(account.pendingMinAssetsOut, shares, account.pendingShares);
        account.pendingShares -= shares;
        account.pendingMinAssetsOut -= minReduction;
        batch.totalPendingShares -= shares;
        _pending[msg.sender] -= shares;
        _pendingMinAssetsOut[msg.sender] -= minReduction;
        totalPendingShares -= shares;
        if (account.pendingShares == 0) {
            _removeOpenBatchController(batchId, msg.sender);
            _pendingBatchId[msg.sender] = 0;
        }
        _transfer(address(this), msg.sender, shares);
    }

    function sealOpenBatch() external returns (uint64 batchId) {
        batchId = openBatchId;
        _sealRedeemBatch(batchId);
    }

    function sealRedeemBatch(uint64 batchId) external {
        _sealRedeemBatch(batchId);
    }

    function startRedeemBatch(uint64 batchId, uint256 shares, uint256 marginalExitCost) public {
        Batch storage batch = _batches[batchId];
        if (
            batchId != nextProcessBatchId || !batch.isSealed || batch.processing || shares == 0
                || shares > batch.totalPendingShares || unaccountedBalance() != 0 || activeProcessingRounds != 0
        ) revert IFundFlowManager.BatchNotProcessable(batchId);

        batch.processing = true;
        batch.unwindCommitted = true;
        batch.processingNav = totalAssets();
        batch.eligibleSupply = totalSupply();
        batch.roundPendingShares = batch.totalPendingShares;
        batch.roundTargetShares = shares;
        batch.roundCumulativeShares = 0;
        batch.roundAllocatedShares = 0;
        batch.processingCursor = 0;
        batch.marginalExitCost = marginalExitCost;

        _validateBatchMinimums(batchId);
        uint256 grossAssetBudget = Math.mulDiv(shares, batch.processingNav, batch.eligibleSupply);
        if (marginalExitCost > grossAssetBudget) revert IFundFlowManager.BatchNotProcessable(batchId);
        batch.roundAssetBudget = grossAssetBudget - marginalExitCost;
        batch.roundAllocatedAssets = 0;
        totalReservedAssets += batch.roundAssetBudget;
        activeProcessingRounds = 1;
    }

    function processRedeemBatch(uint64 batchId, uint16 maxControllers)
        public
        returns (uint16 processedControllers, bool roundComplete)
    {
        if (maxControllers == 0 || maxControllers > FundConstants.MAX_PROCESSING_PAGE) {
            revert IFundFlowManager.InvalidProcessingPage(maxControllers, FundConstants.MAX_PROCESSING_PAGE);
        }
        Batch storage batch = _batches[batchId];
        if (!batch.processing) revert IFundFlowManager.BatchNotProcessable(batchId);

        address[] storage controllers = _batchControllers[batchId];
        uint256 end = Math.min(uint256(batch.processingCursor) + maxControllers, controllers.length);
        for (uint256 i = batch.processingCursor; i < end; ++i) {
            address controller = controllers[i];
            BatchAccount storage account = _batchAccounts[batchId][controller];
            uint256 accountShares = account.pendingShares;
            uint256 newCumulativeShares = batch.roundCumulativeShares + accountShares;
            uint256 newAllocatedShares =
                Math.mulDiv(newCumulativeShares, batch.roundTargetShares, batch.roundPendingShares);
            uint256 allocatedShares = newAllocatedShares - batch.roundAllocatedShares;

            if (allocatedShares != 0) {
                uint256 minimumAssets =
                    Math.mulDiv(account.pendingMinAssetsOut, allocatedShares, accountShares, Math.Rounding.Ceil);
                uint256 assets =
                    _processedAssets(batch, allocatedShares, batch.roundAllocatedShares, newAllocatedShares);
                account.pendingShares -= allocatedShares;
                account.pendingMinAssetsOut -= minimumAssets;
                _pendingMinAssetsOut[controller] -= minimumAssets;
                _makeBatchClaimable(batch, controller, allocatedShares, assets);
                if (account.pendingShares == 0) _pendingBatchId[controller] = 0;
            }

            batch.roundCumulativeShares = newCumulativeShares;
            batch.roundAllocatedShares = newAllocatedShares;
            processedControllers += 1;
        }

        batch.processingCursor = uint16(end);
        if (end == controllers.length) {
            assert(batch.roundAllocatedShares == batch.roundTargetShares);
            batch.totalPendingShares -= batch.roundTargetShares;
            batch.processedShares += batch.roundTargetShares;
            totalReservedAssets -= batch.roundAssetBudget - batch.roundAllocatedAssets;
            activeProcessingRounds = 0;
            batch.processing = false;
            if (batch.totalPendingShares == 0 && batchId == nextProcessBatchId) {
                nextProcessBatchId = batchId + 1;
            }
            roundComplete = true;
        }
    }

    function processBatch(uint256 requestedProcessedShares) external returns (uint256 actualProcessedShares) {
        uint64 batchId = nextProcessBatchId;
        if (!_batches[batchId].isSealed) _sealRedeemBatch(batchId);
        startRedeemBatch(batchId, requestedProcessedShares, 0);
        while (_batches[batchId].processing) {
            processRedeemBatch(batchId, FundConstants.MAX_PROCESSING_PAGE);
        }
        return requestedProcessedShares;
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
        uint256 surplus = unaccountedBalance();
        if (surplus != 0) revert IFundVault.UnaccountedBalance(asset(), surplus);
        if (activeProcessingRounds != 0) revert IFundFlowManager.BatchNotProcessable(nextProcessBatchId);
        super._deposit(caller, receiver, assets, shares);
        accountedGrossAssets += assets;
    }

    function batchParticipantCount(uint64 batchId) external view returns (uint256) {
        return _batchControllers[batchId].length;
    }

    function batchProcessingCursor(uint64 batchId) external view returns (uint16) {
        return _batches[batchId].processingCursor;
    }

    function batchPendingShares(uint64 batchId) external view returns (uint256) {
        return _batches[batchId].totalPendingShares;
    }

    function pendingMinimumAssets(address controller) external view returns (uint256) {
        return _pendingMinAssetsOut[controller];
    }

    function isCancellationAvailable(address controller) external view returns (bool) {
        Batch storage batch = _batches[_pendingBatchId[controller]];
        return _pending[controller] != 0 && _claimableShares[controller] == 0 && !_unwindCommitted[controller]
            && !batch.processing && !batch.unwindCommitted;
    }

    function _addToOpenBatch(address controller, uint256 shares, uint256 minAssetsOut) private {
        uint64 existingBatchId = _pendingBatchId[controller];
        if (existingBatchId != 0 && existingBatchId != openBatchId) {
            revert IFundFlowManager.PendingRequestInSealedBatch(controller, existingBatchId);
        }

        Batch storage batch = _batches[openBatchId];
        BatchAccount storage account = _batchAccounts[openBatchId][controller];
        if (account.indexPlusOne == 0) {
            address[] storage controllers = _batchControllers[openBatchId];
            if (controllers.length == FundConstants.MAX_BATCH_CONTROLLERS) {
                revert IFundFlowManager.BatchCapacityExceeded(openBatchId);
            }
            controllers.push(controller);
            account.indexPlusOne = uint16(controllers.length);
            _pendingBatchId[controller] = openBatchId;
        }
        account.pendingShares += shares;
        account.pendingMinAssetsOut += minAssetsOut;
        batch.totalPendingShares += shares;
    }

    function _removeOpenBatchController(uint64 batchId, address controller) private {
        Batch storage batch = _batches[batchId];
        if (batch.isSealed) return;

        BatchAccount storage account = _batchAccounts[batchId][controller];
        uint256 index = account.indexPlusOne - 1;
        address[] storage controllers = _batchControllers[batchId];
        uint256 lastIndex = controllers.length - 1;
        if (index != lastIndex) {
            address moved = controllers[lastIndex];
            controllers[index] = moved;
            _batchAccounts[batchId][moved].indexPlusOne = uint16(index + 1);
        }
        controllers.pop();
        delete _batchAccounts[batchId][controller];
    }

    function _sealRedeemBatch(uint64 batchId) private {
        Batch storage batch = _batches[batchId];
        if (batchId != openBatchId || batch.isSealed || batch.totalPendingShares == 0) {
            revert IFundFlowManager.BatchNotProcessable(batchId);
        }
        batch.isSealed = true;
        batch.unwindCommitted = true;
        openBatchId = batchId + 1;
    }

    function _validateBatchMinimums(uint64 batchId) private view {
        Batch storage batch = _batches[batchId];
        address[] storage controllers = _batchControllers[batchId];
        uint256 cumulativeShares;
        uint256 allocatedShares;
        for (uint256 i; i < controllers.length; ++i) {
            address controller = controllers[i];
            BatchAccount storage account = _batchAccounts[batchId][controller];
            cumulativeShares += account.pendingShares;
            uint256 newAllocatedShares =
                Math.mulDiv(cumulativeShares, batch.roundTargetShares, batch.roundPendingShares);
            uint256 controllerShares = newAllocatedShares - allocatedShares;
            if (controllerShares != 0) {
                uint256 minimumAssets = Math.mulDiv(
                    account.pendingMinAssetsOut, controllerShares, account.pendingShares, Math.Rounding.Ceil
                );
                uint256 assets = _processedAssets(batch, controllerShares, allocatedShares, newAllocatedShares);
                if (assets < minimumAssets) {
                    revert IFundFlowManager.MinimumAssetsNotMet(controller, minimumAssets, assets);
                }
            }
            allocatedShares = newAllocatedShares;
        }
    }

    function _processedAssets(
        Batch storage batch,
        uint256 shares,
        uint256 priorAllocatedShares,
        uint256 newAllocatedShares
    ) private view returns (uint256) {
        uint256 grossAssets = Math.mulDiv(shares, batch.processingNav, batch.eligibleSupply);
        uint256 newAllocatedCost = Math.mulDiv(newAllocatedShares, batch.marginalExitCost, batch.roundTargetShares);
        uint256 priorAllocatedCost = Math.mulDiv(priorAllocatedShares, batch.marginalExitCost, batch.roundTargetShares);
        uint256 allocatedCost = newAllocatedCost - priorAllocatedCost;
        if (allocatedCost > grossAssets) revert IFundFlowManager.BatchNotProcessable(0);
        return grossAssets - allocatedCost;
    }

    function _makeClaimable(address controller, uint256 shares, uint256 assets) private {
        _pending[controller] -= shares;
        totalPendingShares -= shares;
        _claimableShares[controller] += shares;
        _claimableAssets[controller] += assets;
        totalReservedAssets += assets;
        _burn(address(this), shares);
    }

    function _makeBatchClaimable(Batch storage batch, address controller, uint256 shares, uint256 assets) private {
        _pending[controller] -= shares;
        totalPendingShares -= shares;
        _claimableShares[controller] += shares;
        _claimableAssets[controller] += assets;
        batch.roundAllocatedAssets += assets;
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
        assertEq(vault.decimals(), FundConstants.SHARE_DECIMALS);
    }

    function test_erc20SharesAreTransferable() public {
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 100e18));
        assertEq(vault.balanceOf(bob), 100e18);
    }

    function test_erc4626DepositsAndMintsRemainSynchronous() public {
        asset.mint(bob, 300e6);
        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e6, bob);
        uint256 assets = vault.mint(50e18, bob);
        vm.stopPrank();

        assertEq(shares, 100e18);
        assertEq(assets, 50e6);
        assertEq(vault.balanceOf(bob), 150e18);
    }

    function test_erc2612PermitSetsShareAllowance() public {
        uint256 value = 250e18;
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
        uint256 requestId = vault.requestRedeem(400e18, alice, alice);

        assertEq(requestId, 0);
        assertEq(vault.pendingRedeemRequest(0, alice), 400e18);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);
        assertEq(vault.balanceOf(address(vault)), 400e18);
        assertEq(vault.totalSupply(), 1_000e18);
    }

    function test_pendingSharesRemainYieldBearingAfterDonationIsSynchronized() public {
        vm.prank(alice);
        vault.requestRedeem(400e18, alice, alice);
        asset.mint(address(vault), 100e6);
        vault.syncDonation(1);

        vault.processBatch(400e18);

        assertEq(vault.claimableAssets(alice), 440e6);
        assertEq(vault.totalReservedAssets(), 440e6);
        assertEq(vault.totalAssets(), 660e6);
        assertEq(vault.totalSupply(), 600e18);
        assertEq(vault.nextProcessBatchId(), 2);
    }

    function test_donationDoesNotChangeNavUntilSynchronized() public {
        asset.mint(address(vault), 100e6);

        assertEq(vault.totalAssets(), 1_000e6);
        assertEq(vault.unaccountedBalance(), 100e6);

        vault.syncDonation(1);
        assertEq(vault.totalAssets(), 1_100e6);
        assertEq(vault.unaccountedBalance(), 0);
    }

    function test_unaccountedDonationClosesEntryAndNavPricedProcessing() public {
        vm.prank(alice);
        vault.requestRedeem(100e18, alice, alice);
        asset.mint(address(vault), 100e6);
        asset.mint(bob, 100e6);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);

        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, 100e6, 0));
        vault.deposit(100e6, bob);

        vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchNotProcessable.selector, 1));
        vault.processBatch(100e18);
    }

    function test_freshNavSynchronizationPreventsDonationCapture() public {
        asset.mint(address(vault), 100e6);
        asset.mint(bob, 100e6);
        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vault.syncDonation(1);
        vm.prank(bob);
        uint256 shares = vault.depositWithMinShares(100e6, bob, 90e18);

        assertGt(shares, 90e18);
        assertLt(shares, 100e18);
    }

    function test_onlyAccountingCanSynchronizeDonation() public {
        asset.mint(address(vault), 1e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AsyncRedeemVaultHarness.UnauthorizedAccounting.selector, bob));
        vault.syncDonation(1);
    }

    function test_donationSynchronizationConsumesFreshNavNonce() public {
        asset.mint(address(vault), 1e6);
        vault.syncDonation(1);

        vm.expectRevert(abi.encodeWithSelector(AsyncRedeemVaultHarness.InvalidDonationReportNonce.selector, 2, 1));
        vault.syncDonation(1);
    }

    function test_depositWithMinSharesRevertsAtomicallyBelowMinimum() public {
        asset.mint(bob, 100e6);
        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IFundVault.MinimumSharesNotMet.selector, 101e18, 100e18));
        vault.depositWithMinShares(100e6, bob, 101e18);
        vm.stopPrank();

        assertEq(asset.balanceOf(bob), 100e6);
        assertEq(vault.balanceOf(bob), 0);
    }

    function test_redemptionMinimumIsPersistedAndCheckedBeforePagination() public {
        vm.prank(alice);
        vault.requestRedeemWithMinAssets(100e18, alice, alice, 101e6);
        assertEq(vault.pendingMinimumAssets(alice), 101e6);

        vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.MinimumAssetsNotMet.selector, alice, 101e6, 100e6));
        vault.processBatch(100e18);
    }

    function test_partialProcessingConsumesMinimumProRata() public {
        vm.prank(alice);
        vault.requestRedeemWithMinAssets(200e18, alice, alice, 180e6);

        vault.processBatch(50e18);

        assertEq(vault.claimableRedeemRequest(0, alice), 50e18);
        assertEq(vault.claimableAssets(alice), 50e6);
        assertEq(vault.pendingMinimumAssets(alice), 135e6);
    }

    function test_partialProcessingIsProRataAndClaimIsPullBased() public {
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 200e18));
        vm.prank(alice);
        vault.requestRedeem(400e18, alice, alice);
        vm.prank(bob);
        vault.requestRedeem(200e18, bob, bob);

        uint256 processed = vault.processBatch(300e18);

        assertEq(processed, 300e18);
        assertEq(vault.pendingRedeemRequest(0, alice), 200e18);
        assertEq(vault.pendingRedeemRequest(0, bob), 100e18);
        assertEq(vault.claimableRedeemRequest(0, alice), 200e18);
        assertEq(vault.claimableRedeemRequest(0, bob), 100e18);
        assertEq(asset.balanceOf(alice), 1_000e6);

        vm.prank(alice);
        uint256 assets = vault.redeem(200e18, alice, alice);
        assertEq(assets, 200e6);
        assertEq(asset.balanceOf(alice), 1_200e6);
    }

    function test_immediateClaimableStillRequiresSeparateClaim() public {
        vault.setImmediateClaimable(true);
        uint256 beforeAssets = asset.balanceOf(alice);

        vm.prank(alice);
        vault.requestRedeem(100e18, alice, alice);

        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.claimableRedeemRequest(0, alice), 100e18);
        assertEq(asset.balanceOf(alice), beforeAssets);

        vm.prank(alice);
        vault.withdraw(100e6, alice, alice);
        assertEq(asset.balanceOf(alice), beforeAssets + 100e6);
    }

    function test_operatorCanRequestAndClaimWithoutShareAllowance() public {
        vm.prank(alice);
        vault.setOperator(operator, true);

        vm.prank(operator);
        vault.requestRedeem(100e18, alice, alice);
        vault.processBatch(100e18);
        vm.prank(operator);
        vault.redeem(100e18, alice, alice);

        assertEq(vault.allowance(alice, operator), 0);
        assertEq(asset.balanceOf(alice), 1_100e6);
    }

    function test_shareAllowanceCanAuthorizeRequestWithoutOperatorPermission() public {
        vm.prank(alice);
        vault.approve(operator, 100e18);

        vm.prank(operator);
        vault.requestRedeem(100e18, operator, alice);

        assertEq(vault.allowance(alice, operator), 0);
        assertEq(vault.pendingRedeemRequest(0, operator), 100e18);
    }

    function test_asyncPreviewFunctionsAlwaysRevertAndMaxUsesClaimable() public {
        vm.prank(alice);
        vault.requestRedeem(200e18, alice, alice);
        vault.processBatch(100e18);

        vm.expectRevert(AsyncRedeemVaultHarness.AsyncPreviewUnsupported.selector);
        vault.previewRedeem(1);
        vm.expectRevert(AsyncRedeemVaultHarness.AsyncPreviewUnsupported.selector);
        vault.previewWithdraw(1);

        assertEq(vault.maxRedeem(alice), 100e18);
        assertEq(vault.maxWithdraw(alice), 100e6);
    }

    function test_pendingCancellationStopsAfterAnyClaimableTransition() public {
        vm.prank(alice);
        vault.requestRedeem(200e18, alice, alice);
        vault.processBatch(100e18);

        vm.prank(alice);
        vm.expectRevert(AsyncRedeemVaultHarness.RequestNotCancelable.selector);
        vault.cancelPending(100e18);
    }

    function test_pendingCancellationReturnsEscrowedSharesBeforeUnwind() public {
        vm.prank(alice);
        vault.requestRedeem(200e18, alice, alice);

        vm.prank(alice);
        vault.cancelPending(200e18);

        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.balanceOf(alice), 1_000e18);
    }

    function test_sealingCommitsUnwindAndDisablesCancellation() public {
        vm.prank(alice);
        vault.requestRedeem(200e18, alice, alice);
        vault.sealOpenBatch();

        vm.prank(alice);
        vm.expectRevert(AsyncRedeemVaultHarness.RequestNotCancelable.selector);
        vault.cancelPending(200e18);
    }

    function test_sealedBatchesCannotProcessOutOfOrder() public {
        vm.prank(alice);
        assertTrue(vault.transfer(bob, 100e18));
        vm.prank(alice);
        vault.requestRedeem(100e18, alice, alice);
        vault.sealOpenBatch();
        vm.prank(bob);
        vault.requestRedeem(100e18, bob, bob);
        uint64 secondBatchId = vault.sealOpenBatch();

        vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchNotProcessable.selector, secondBatchId));
        vault.startRedeemBatch(secondBatchId, 100e18, 0);
    }

    function test_fullCancellationRemovesOpenBatchMemberAndPreventsListGrowth() public {
        for (uint256 i; i < 80; ++i) {
            address controller = address(uint160(0x1000 + i));
            vm.prank(alice);
            assertTrue(vault.transfer(controller, 1e18));
            vm.prank(controller);
            vault.requestRedeem(1e18, controller, controller);
            vm.prank(controller);
            vault.cancelPending(1e18);
            vm.prank(controller);
            assertTrue(vault.transfer(alice, 1e18));
        }

        assertEq(vault.batchParticipantCount(vault.openBatchId()), 0);
    }

    function test_batchCapacityIsExplicitlyBounded() public {
        uint64 batchId = vault.openBatchId();
        for (uint256 i; i < FundConstants.MAX_BATCH_CONTROLLERS; ++i) {
            address controller = address(uint160(0x2000 + i));
            vm.prank(alice);
            assertTrue(vault.transfer(controller, 1e18));
            vm.prank(controller);
            vault.requestRedeem(1e18, controller, controller);
        }

        address overflowController = address(0x3000);
        vm.prank(alice);
        assertTrue(vault.transfer(overflowController, 1e18));
        vm.prank(overflowController);
        vm.expectRevert(abi.encodeWithSelector(IFundFlowManager.BatchCapacityExceeded.selector, batchId));
        vault.requestRedeem(1e18, overflowController, overflowController);
    }

    function test_sealedBatchProcessesWithFixedSnapshotAcrossBoundedPages() public {
        uint256 controllerCount = 20;
        for (uint256 i; i < controllerCount; ++i) {
            address controller = address(uint160(0x4000 + i));
            vm.prank(alice);
            assertTrue(vault.transfer(controller, 1e18));
            vm.prank(controller);
            vault.requestRedeem(1e18, controller, controller);
        }

        uint64 batchId = vault.sealOpenBatch();
        vault.startRedeemBatch(batchId, 10e18, 0);
        assertEq(vault.totalReservedAssets(), 10e6);
        (uint16 firstPage, bool firstComplete) = vault.processRedeemBatch(batchId, 8);
        assertEq(firstPage, 8);
        assertFalse(firstComplete);
        assertEq(vault.batchProcessingCursor(batchId), 8);
        assertEq(vault.totalReservedAssets(), 10e6);

        (uint16 secondPage, bool secondComplete) = vault.processRedeemBatch(batchId, 16);
        assertEq(secondPage, 12);
        assertTrue(secondComplete);
        assertEq(vault.batchPendingShares(batchId), 10e18);

        uint256 claimable;
        for (uint256 i; i < controllerCount; ++i) {
            claimable += vault.claimableRedeemRequest(0, address(uint160(0x4000 + i)));
        }
        assertEq(claimable, 10e18);
    }

    function test_rejectsAccountingAssetWithMoreThanEighteenDecimals() public {
        MockERC20 unsupported = new MockERC20("Unsupported", "BAD", 19);
        vm.expectRevert(abi.encodeWithSelector(IFundVault.UnsupportedAccountingAssetDecimals.selector, 19));
        new AsyncRedeemVaultHarness(unsupported);
    }

    function test_arbitraryUnsupportedRequestIdsReturnZero() public view {
        assertEq(vault.pendingRedeemRequest(1, alice), 0);
        assertEq(vault.claimableRedeemRequest(type(uint256).max, alice), 0);
    }
}
