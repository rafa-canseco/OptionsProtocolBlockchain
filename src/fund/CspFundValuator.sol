// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AddressBook} from "../core/AddressBook.sol";
import {BatchSettler} from "../core/BatchSettler.sol";
import {Controller} from "../core/Controller.sol";
import {OToken} from "../core/OToken.sol";
import {MarginVault} from "../interfaces/IMarginVault.sol";
import {FundConstants} from "./FundConstants.sol";
import {FundTypes} from "./FundTypes.sol";
import {IPositionValuator} from "./interfaces/IPositionValuator.sol";
import {ICspFundAdapter} from "./interfaces/ICspFundAdapter.sol";
import {ICspFundValuator} from "./interfaces/ICspFundValuator.sol";

interface IChainlinkSpotFeed {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Deterministic, read-only valuation policy for one CSP adapter implementation version.
/// @dev Pre-expiry option liabilities require unique approved signed observations and fail closed without quorum.
contract CspFundValuator is IPositionValuator, ICspFundValuator {
    using ECDSA for bytes32;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("b1nary CSP Valuator");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 public constant OPTION_OBSERVATION_TYPEHASH = keccak256(
        "OptionObservation(address adapter,bytes32 positionStateHash,uint256 positionId,uint256 protocolVaultId,address oToken,uint256 optionAmount,uint256 liability,uint256 baseExitCost,uint64 snapshotBlock,uint64 validUntilBlock,uint256 nonce)"
    );

    address public immutable spotFeed;
    uint8 public immutable spotFeedDecimals;
    uint64 public immutable maxSpotStaleness;
    uint64 public immutable maxObservationWindow;
    uint8 public immutable observationQuorum;
    uint16 public immutable liabilityBufferBps;
    mapping(address observer => bool approved) public isApprovedObserver;
    address[] private _approvedObservers;

    constructor(
        address spotFeed_,
        uint8 spotFeedDecimals_,
        uint64 maxSpotStaleness_,
        uint64 maxObservationWindow_,
        uint8 observationQuorum_,
        uint16 liabilityBufferBps_,
        address[] memory approvedObservers_
    ) {
        if (
            spotFeed_ == address(0) || spotFeed_.code.length == 0 || spotFeedDecimals_ > 18 || maxSpotStaleness_ == 0
                || maxObservationWindow_ == 0 || observationQuorum_ < 2
                || observationQuorum_ > approvedObservers_.length || liabilityBufferBps_ > FundConstants.BPS
        ) revert InvalidSpotObservation();
        if (IChainlinkSpotFeed(spotFeed_).decimals() != spotFeedDecimals_) revert InvalidSpotObservation();
        spotFeed = spotFeed_;
        spotFeedDecimals = spotFeedDecimals_;
        maxSpotStaleness = maxSpotStaleness_;
        maxObservationWindow = maxObservationWindow_;
        observationQuorum = observationQuorum_;
        liabilityBufferBps = liabilityBufferBps_;
        for (uint256 i; i < approvedObservers_.length; ++i) {
            address observer = approvedObservers_[i];
            if (observer == address(0) || isApprovedObserver[observer]) revert DuplicateObserver(observer);
            isApprovedObserver[observer] = true;
            _approvedObservers.push(observer);
        }
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function approvedObserverCount() external view returns (uint256) {
        return _approvedObservers.length;
    }

    function approvedObserverAt(uint256 index) external view returns (address) {
        return _approvedObservers[index];
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function observationDigest(
        address adapter,
        uint256 positionId,
        uint64 snapshotBlock,
        uint64 validUntilBlock,
        uint256 liability,
        uint256 baseExitCost,
        uint256 nonce
    ) public view returns (bytes32) {
        ICspFundAdapter csp = ICspFundAdapter(adapter);
        ICspFundAdapter.Position memory strategyPosition = csp.position(positionId);
        bytes32 structHash = keccak256(
            abi.encode(
                OPTION_OBSERVATION_TYPEHASH,
                adapter,
                csp.positionStateHash(),
                positionId,
                strategyPosition.protocolVaultId,
                strategyPosition.oToken,
                strategyPosition.optionAmount,
                liability,
                baseExitCost,
                snapshotBlock,
                validUntilBlock,
                nonce
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    function value(address adapter, uint64 snapshotBlock, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory positionValue)
    {
        if (adapter == address(0) || adapter.code.length == 0) revert InvalidAdapter(adapter);
        ICspFundAdapter csp = ICspFundAdapter(adapter);
        if (csp.interfaceVersion() != 1 || !csp.isOnboarded()) revert InvalidAdapter(adapter);
        if (snapshotBlock != block.number) revert InvalidSnapshotBlock(uint64(block.number), snapshotBlock);

        ValuationData memory valuationData = abi.decode(data, (ValuationData));
        (uint80 spotRoundId, uint256 spotPrice, uint256 spotUpdatedAt) = _readSpot();
        ICspFundAdapter.AdapterState memory adapterState_ = csp.adapterState();
        address usdcAddress = csp.accountingAsset();
        address wethAddress = csp.weth();
        uint256 accountedUsdcValue = adapterState_.accountedUsdc;
        uint256 accountedWethValue = adapterState_.accountedWeth;
        uint256 rawUsdc = IERC20(usdcAddress).balanceOf(adapter);
        uint256 rawWeth = IERC20(wethAddress).balanceOf(adapter);
        if (rawUsdc < accountedUsdcValue) {
            revert AccountingDeficit(usdcAddress, accountedUsdcValue, rawUsdc);
        }
        if (rawWeth < accountedWethValue) {
            revert AccountingDeficit(wethAddress, accountedWethValue, rawWeth);
        }

        positionValue.grossAssets = accountedUsdcValue + _wethValue(accountedWethValue, spotPrice, usdcAddress);
        positionValue.liquidAccountingAssets = accountedUsdcValue;
        uint256 usedObservations;
        uint256 count = adapterState_.positionCount;
        for (uint256 positionId = 1; positionId <= count; ++positionId) {
            ICspFundAdapter.Position memory strategyPosition = csp.position(positionId);
            if (strategyPosition.lifecycle == ICspFundAdapter.Lifecycle.None) revert InvalidObservation(positionId);
            if (strategyPosition.lifecycle == ICspFundAdapter.Lifecycle.Open) {
                _validateOpenProtocolState(adapter, positionId, strategyPosition, csp);
                positionValue.grossAssets += strategyPosition.collateral;
                if (block.timestamp >= OToken(strategyPosition.oToken).expiry()) {
                    positionValue.liabilities += strategyPosition.collateral;
                } else {
                    (uint256 liability, uint256 exitCost, uint256 used) = _preExpiryLiability(
                        adapter, positionId, snapshotBlock, strategyPosition, valuationData.optionObservations
                    );
                    positionValue.liabilities += liability;
                    positionValue.baseExitCost += exitCost;
                    usedObservations += used;
                }
            } else if (strategyPosition.lifecycle == ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery) {
                _validateAwaitingDelivery(adapter, positionId, strategyPosition, csp);
            } else {
                _validateTerminalProtocolState(adapter, positionId, strategyPosition, csp);
            }
        }
        if (usedObservations != valuationData.optionObservations.length) revert InvalidObservation(0);

        positionValue.dataHash = keccak256(
            abi.encode(
                adapter,
                csp.positionStateHash(),
                snapshotBlock,
                spotRoundId,
                spotPrice,
                spotUpdatedAt,
                keccak256(data),
                positionValue.grossAssets,
                positionValue.liabilities,
                positionValue.liquidAccountingAssets,
                positionValue.baseExitCost
            )
        );
    }

    function _preExpiryLiability(
        address adapter,
        uint256 positionId,
        uint64 snapshotBlock,
        ICspFundAdapter.Position memory strategyPosition,
        OptionObservation[] memory observations
    ) private view returns (uint256 liability, uint256 baseExitCost, uint256 used) {
        address[] memory seen = new address[](observationQuorum);
        bool hasIndependentObserver;
        for (uint256 i; i < observations.length; ++i) {
            OptionObservation memory observation = observations[i];
            if (observation.positionId != positionId) continue;
            if (
                observation.snapshotBlock != snapshotBlock || observation.validUntilBlock < block.number
                    || observation.validUntilBlock > snapshotBlock + maxObservationWindow
            ) revert InvalidObservation(positionId);
            bytes32 digest = observationDigest(
                adapter,
                positionId,
                observation.snapshotBlock,
                observation.validUntilBlock,
                observation.liability,
                observation.baseExitCost,
                observation.nonce
            );
            address observer = digest.recover(observation.signature);
            if (!isApprovedObserver[observer]) revert UnapprovedObserver(observer);
            for (uint256 j; j < used; ++j) {
                if (seen[j] == observer) revert DuplicateObserver(observer);
            }
            if (used >= observationQuorum) revert InvalidObservation(positionId);
            seen[used] = observer;
            ++used;
            if (observer != strategyPosition.marketMaker) hasIndependentObserver = true;
            liability = Math.max(liability, observation.liability);
            baseExitCost = Math.max(baseExitCost, observation.baseExitCost);
        }
        if (used != observationQuorum || !hasIndependentObserver) {
            revert InsufficientObservationQuorum(positionId, observationQuorum, used);
        }
        liability =
            Math.mulDiv(liability, FundConstants.BPS + liabilityBufferBps, FundConstants.BPS, Math.Rounding.Ceil);
    }

    function _validateOpenProtocolState(
        address adapter,
        uint256 positionId,
        ICspFundAdapter.Position memory strategyPosition,
        ICspFundAdapter csp
    ) private view {
        AddressBook book = AddressBook(csp.addressBook());
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        MarginVault.Vault memory vault = controller.getVault(adapter, strategyPosition.protocolVaultId);
        if (
            controller.vaultSettled(adapter, strategyPosition.protocolVaultId)
                || vault.shortOtoken != strategyPosition.oToken || vault.shortAmount != strategyPosition.optionAmount
                || vault.collateralAsset != csp.accountingAsset()
                || vault.collateralAmount != strategyPosition.collateral
                || settler.vaultOTokenBalance(adapter, strategyPosition.protocolVaultId)
                    != strategyPosition.optionAmount
                || !settler.physicalDeliveryReservedVault(adapter, strategyPosition.protocolVaultId)
                || settler.physicalDeliveryReservedAmount(adapter, strategyPosition.protocolVaultId)
                    != strategyPosition.optionAmount
        ) revert LedgerMismatch(positionId);
    }

    function _validateAwaitingDelivery(
        address adapter,
        uint256 positionId,
        ICspFundAdapter.Position memory strategyPosition,
        ICspFundAdapter csp
    ) private view {
        AddressBook book = AddressBook(csp.addressBook());
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        if (
            !controller.vaultSettled(adapter, strategyPosition.protocolVaultId)
                || settler.vaultOTokenBalance(adapter, strategyPosition.protocolVaultId)
                    != strategyPosition.optionAmount
                || settler.physicalDeliveryReservedVault(adapter, strategyPosition.protocolVaultId)
        ) revert LedgerMismatch(positionId);
        revert PendingPhysicalDelivery(positionId);
    }

    function _validateTerminalProtocolState(
        address adapter,
        uint256 positionId,
        ICspFundAdapter.Position memory strategyPosition,
        ICspFundAdapter csp
    ) private view {
        AddressBook book = AddressBook(csp.addressBook());
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        if (
            !controller.vaultSettled(adapter, strategyPosition.protocolVaultId)
                || settler.vaultOTokenBalance(adapter, strategyPosition.protocolVaultId) != 0
                || settler.physicalDeliveryReservedVault(adapter, strategyPosition.protocolVaultId)
        ) revert LedgerMismatch(positionId);
    }

    function _readSpot() private view returns (uint80 roundId, uint256 price, uint256 updatedAt) {
        int256 answer;
        uint80 answeredInRound;
        (roundId, answer,, updatedAt, answeredInRound) = IChainlinkSpotFeed(spotFeed).latestRoundData();
        if (
            answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp
                || block.timestamp - updatedAt > maxSpotStaleness || answeredInRound < roundId
        ) revert InvalidSpotObservation();
        price = uint256(answer);
    }

    function _wethValue(uint256 wethAmount, uint256 spotPrice, address usdcAddress) private view returns (uint256) {
        uint256 valueAtWad = Math.mulDiv(wethAmount, spotPrice, 10 ** spotFeedDecimals);
        uint8 usdcDecimals = IERC20Metadata(usdcAddress).decimals();
        if (usdcDecimals > 18) revert InvalidSpotObservation();
        return valueAtWad / (10 ** (18 - usdcDecimals));
    }
}
