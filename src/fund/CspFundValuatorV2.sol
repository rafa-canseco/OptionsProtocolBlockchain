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
import {Oracle} from "../core/Oracle.sol";
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
/// @dev Pre-expiry option liabilities require unique approved signed fair marks and fail closed without quorum.
contract CspFundValuatorV2 is IPositionValuator, ICspFundValuator {
    using ECDSA for bytes32;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("b1nary CSP Valuator");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 public constant OPTION_OBSERVATION_TYPEHASH = keccak256(
        "OptionObservation(address adapter,bytes32 positionStateHash,uint256 positionId,uint256 protocolVaultId,address oToken,uint256 optionAmount,uint256 liability,uint256 baseExitCost,uint64 snapshotBlock,uint64 validUntilBlock,uint256 nonce)"
    );
    uint64 public constant requiredModelVersion = 1;
    uint64 public constant valuationPolicyVersion = 2;
    uint16 public constant maxObservationDivergenceBps = 500;
    /// @notice Compatibility getter for the off-chain fair-value policy gate.
    /// @dev V2 applies the signed fair liability exactly and therefore fixes the buffer at zero.
    uint16 public constant liabilityBufferBps = 0;

    address public immutable spotFeed;
    uint8 public immutable spotFeedDecimals;
    uint64 public immutable maxSpotStaleness;
    uint64 public immutable maxObservationWindow;
    uint8 public immutable observationQuorum;
    mapping(address observer => bool approved) public isApprovedObserver;
    address[] private _approvedObservers;

    constructor(
        address spotFeed_,
        uint8 spotFeedDecimals_,
        uint64 maxSpotStaleness_,
        uint64 maxObservationWindow_,
        uint8 observationQuorum_,
        address[] memory approvedObservers_
    ) {
        if (
            spotFeed_ == address(0) || spotFeed_.code.length == 0 || spotFeedDecimals_ > 18 || maxSpotStaleness_ == 0
                || maxObservationWindow_ == 0 || observationQuorum_ < 2
                || observationQuorum_ > approvedObservers_.length
        ) revert InvalidSpotObservation();
        if (IChainlinkSpotFeed(spotFeed_).decimals() != spotFeedDecimals_) revert InvalidSpotObservation();
        spotFeed = spotFeed_;
        spotFeedDecimals = spotFeedDecimals_;
        maxSpotStaleness = maxSpotStaleness_;
        maxObservationWindow = maxObservationWindow_;
        observationQuorum = observationQuorum_;
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
        return _value(adapter, 0, snapshotBlock, data);
    }

    /// @notice Values one current position without traversing terminal adapter history.
    /// @dev Intended for dedicated Wheel lanes whose adapter policy permits at most one active position.
    function valuePosition(address adapter, uint256 positionId, uint64 snapshotBlock, bytes calldata data)
        external
        view
        returns (FundTypes.PositionValue memory positionValue)
    {
        if (positionId == 0) revert InvalidObservation(0);
        return _value(adapter, positionId, snapshotBlock, data);
    }

    function _value(address adapter, uint256 selectedPositionId, uint64 snapshotBlock, bytes calldata data)
        private
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

        uint256 accountedWethFairValue = _wethValue(accountedWethValue, spotPrice, usdcAddress);
        ICspFundAdapter.AdapterConfig memory config = csp.adapterConfig();
        positionValue.grossAssets = accountedUsdcValue + accountedWethFairValue;
        positionValue.liquidAccountingAssets = accountedUsdcValue;
        positionValue.baseExitCost = _swapExitCost(accountedWethFairValue, config.riskConfig.maxSwapSlippageBps);
        uint256 usedObservations;
        uint256 observedActivePositions;
        uint256 firstPositionId = selectedPositionId == 0 ? 1 : selectedPositionId;
        uint256 lastPositionId = selectedPositionId == 0 ? adapterState_.positionCount : selectedPositionId;
        if (
            lastPositionId > adapterState_.positionCount
                || (selectedPositionId != 0 && selectedPositionId != adapterState_.positionCount)
        ) revert InvalidObservation(lastPositionId);
        for (uint256 positionId = firstPositionId; positionId <= lastPositionId; ++positionId) {
            ICspFundAdapter.Position memory strategyPosition = csp.position(positionId);
            if (strategyPosition.lifecycle == ICspFundAdapter.Lifecycle.None) revert InvalidObservation(positionId);
            if (strategyPosition.lifecycle == ICspFundAdapter.Lifecycle.Open) {
                ++observedActivePositions;
                _validateOpenProtocolState(adapter, positionId, strategyPosition, csp);
                positionValue.grossAssets += strategyPosition.collateral;
                if (block.timestamp >= OToken(strategyPosition.oToken).expiry()) {
                    positionValue.liabilities += _expiredPutLiability(positionId, strategyPosition, csp);
                } else {
                    (uint256 liability, uint256 exitCost, uint256 used) = _preExpiryLiability(
                        adapter, positionId, snapshotBlock, strategyPosition, valuationData.optionObservations
                    );
                    positionValue.liabilities += liability;
                    positionValue.baseExitCost += exitCost;
                    usedObservations += used;
                }
            } else if (strategyPosition.lifecycle == ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery) {
                ++observedActivePositions;
                _validateAwaitingDelivery(adapter, positionId, strategyPosition, csp);
                uint256 pendingDeliveryValue =
                    _pendingDeliveryValue(positionId, strategyPosition, csp, spotPrice, usdcAddress);
                positionValue.grossAssets += pendingDeliveryValue;
                positionValue.baseExitCost += _swapExitCost(pendingDeliveryValue, config.riskConfig.maxSwapSlippageBps);
            } else {
                _validateTerminalProtocolState(adapter, positionId, strategyPosition, csp);
            }
        }
        if (
            usedObservations != valuationData.optionObservations.length
                || (selectedPositionId != 0
                    && (adapterState_.activePositionCount > 1
                        || observedActivePositions != adapterState_.activePositionCount))
        ) revert InvalidObservation(0);

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
        uint256[] memory liabilityMarks = new uint256[](observationQuorum);
        uint256[] memory exitCostMarks = new uint256[](observationQuorum);
        bool hasIndependentObserver;
        for (uint256 i; i < observations.length; ++i) {
            OptionObservation memory observation = observations[i];
            if (observation.positionId != positionId) continue;
            if (
                observation.snapshotBlock != snapshotBlock || observation.validUntilBlock < block.number
                    || observation.validUntilBlock > snapshotBlock + maxObservationWindow
                    || observation.liability > strategyPosition.collateral
                    || observation.baseExitCost > strategyPosition.collateral
            ) revert InvalidObservation(positionId);
            uint64 modelVersion = uint64(observation.nonce >> 192);
            if (modelVersion != requiredModelVersion) {
                revert InvalidModelVersion(positionId, requiredModelVersion, modelVersion);
            }
            if (uint192(observation.nonce) == 0) revert InvalidObservation(positionId);
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
            liabilityMarks[used] = observation.liability;
            exitCostMarks[used] = observation.baseExitCost;
            ++used;
            if (observer != strategyPosition.marketMaker) hasIndependentObserver = true;
        }
        if (used != observationQuorum || !hasIndependentObserver) {
            revert InsufficientObservationQuorum(positionId, observationQuorum, used);
        }
        _sort(liabilityMarks);
        _sort(exitCostMarks);
        liability = _median(liabilityMarks);
        baseExitCost = _median(exitCostMarks);
        _validateDivergence(positionId, liabilityMarks[0], liabilityMarks[used - 1], liability);
        _validateDivergence(positionId, exitCostMarks[0], exitCostMarks[used - 1], baseExitCost);
    }

    function _expiredPutLiability(
        uint256 positionId,
        ICspFundAdapter.Position memory strategyPosition,
        ICspFundAdapter csp
    ) private view returns (uint256) {
        OToken oToken = OToken(strategyPosition.oToken);
        (uint256 expiryPrice, bool isSet) =
            Oracle(AddressBook(csp.addressBook()).oracle()).getExpiryPrice(csp.weth(), oToken.expiry());
        if (!isSet) revert ExpiryPriceUnavailable(positionId, oToken.expiry());
        uint256 strike = oToken.strikePrice();
        if (expiryPrice >= strike) return 0;
        return Math.mulDiv(strategyPosition.optionAmount, strike - expiryPrice, 1e10);
    }

    function _pendingDeliveryValue(
        uint256 positionId,
        ICspFundAdapter.Position memory strategyPosition,
        ICspFundAdapter csp,
        uint256 spotPrice,
        address usdcAddress
    ) private view returns (uint256) {
        OToken oToken = OToken(strategyPosition.oToken);
        (uint256 expiryPrice, bool isSet) =
            Oracle(AddressBook(csp.addressBook()).oracle()).getExpiryPrice(csp.weth(), oToken.expiry());
        if (!isSet) revert ExpiryPriceUnavailable(positionId, oToken.expiry());

        uint256 strike = oToken.strikePrice();
        if (expiryPrice >= strike) revert LedgerMismatch(positionId);
        uint256 redemptionPayout = Math.mulDiv(strategyPosition.optionAmount, strike, 1e10);
        uint256 mmCashPayout = Math.mulDiv(strategyPosition.optionAmount, strike - expiryPrice, 1e10);
        uint256 fallbackRecoverable = redemptionPayout - mmCashPayout;
        uint256 liveReceivable = _wethValue(strategyPosition.optionAmount * 1e10, spotPrice, usdcAddress);
        return Math.min(liveReceivable, fallbackRecoverable);
    }

    function _validateDivergence(uint256 positionId, uint256 minimum, uint256 maximum, uint256 median) private pure {
        uint256 permitted = Math.mulDiv(median, maxObservationDivergenceBps, FundConstants.BPS);
        if (maximum - minimum > permitted) {
            revert ObservationDivergence(positionId, minimum, maximum, median);
        }
    }

    function _median(uint256[] memory values) private pure returns (uint256) {
        uint256 middle = values.length / 2;
        if (values.length % 2 == 1) return values[middle];
        return Math.average(values[middle - 1], values[middle]);
    }

    function _sort(uint256[] memory values) private pure {
        for (uint256 i = 1; i < values.length; ++i) {
            uint256 value_ = values[i];
            uint256 j = i;
            while (j != 0 && values[j - 1] > value_) {
                values[j] = values[j - 1];
                --j;
            }
            values[j] = value_;
        }
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

    function _swapExitCost(uint256 fairValue, uint16 maxSwapSlippageBps) private pure returns (uint256) {
        return Math.mulDiv(fairValue, maxSwapSlippageBps, FundConstants.BPS, Math.Rounding.Ceil);
    }
}
