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
import {ICoveredCallFundAdapter} from "./interfaces/ICoveredCallFundAdapter.sol";
import {ICoveredCallFundValuator} from "./interfaces/ICoveredCallFundValuator.sol";

interface ICoveredCallChainlinkSpotFeedV2 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Deterministic WETH-denominated fair-value policy for one covered-call adapter version.
/// @dev Pre-expiry liabilities require two convergent model-versioned observations. Expired open calls use the
///      protocol Oracle's authoritative expiry price and retain locked WETH as a gross asset.
contract CoveredCallFundValuatorV2 is IPositionValuator, ICoveredCallFundValuator {
    using ECDSA for bytes32;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("b1nary Covered Call Valuator");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes32 public constant OPTION_OBSERVATION_TYPEHASH = keccak256(
        "OptionObservation(address adapter,bytes32 positionStateHash,uint256 positionId,uint256 protocolVaultId,address oToken,uint256 optionAmount,uint256 liability,uint256 baseExitCost,uint64 snapshotBlock,uint64 validUntilBlock,uint256 nonce)"
    );
    uint64 public constant requiredModelVersion = 1;
    uint64 public constant valuationPolicyVersion = 2;
    uint16 public constant maxObservationDivergenceBps = 500;

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
        if (ICoveredCallChainlinkSpotFeedV2(spotFeed_).decimals() != spotFeedDecimals_) {
            revert InvalidSpotObservation();
        }
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
        ICoveredCallFundAdapter coveredCall = ICoveredCallFundAdapter(adapter);
        ICoveredCallFundAdapter.Position memory strategyPosition = coveredCall.position(positionId);
        bytes32 structHash = keccak256(
            abi.encode(
                OPTION_OBSERVATION_TYPEHASH,
                adapter,
                coveredCall.positionStateHash(),
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
        ICoveredCallFundAdapter coveredCall = ICoveredCallFundAdapter(adapter);
        if (coveredCall.interfaceVersion() != 1 || !coveredCall.isOnboarded()) revert InvalidAdapter(adapter);
        if (snapshotBlock != block.number) revert InvalidSnapshotBlock(uint64(block.number), snapshotBlock);

        ValuationData memory valuationData = abi.decode(data, (ValuationData));
        (uint80 spotRoundId, uint256 spotPrice, uint256 spotUpdatedAt) = _readSpot();
        ICoveredCallFundAdapter.AdapterState memory adapterState_ = coveredCall.adapterState();
        address wethAddress = coveredCall.accountingAsset();
        address usdcAddress = coveredCall.usdc();
        uint256 rawWeth = IERC20(wethAddress).balanceOf(adapter);
        uint256 rawUsdc = IERC20(usdcAddress).balanceOf(adapter);
        if (rawWeth < adapterState_.accountedWeth) {
            revert AccountingDeficit(wethAddress, adapterState_.accountedWeth, rawWeth);
        }
        if (rawUsdc < adapterState_.accountedUsdc) {
            revert AccountingDeficit(usdcAddress, adapterState_.accountedUsdc, rawUsdc);
        }

        uint256 transientUsdcValue = _usdcToWeth(adapterState_.accountedUsdc, spotPrice, usdcAddress);
        positionValue.grossAssets = adapterState_.accountedWeth + transientUsdcValue;
        if (adapterState_.activePositionCount == 0 && adapterState_.accountedUsdc == 0) {
            positionValue.liquidAccountingAssets = adapterState_.accountedWeth;
        }
        ICoveredCallFundAdapter.AdapterConfig memory config = coveredCall.adapterConfig();
        positionValue.baseExitCost = Math.mulDiv(
            transientUsdcValue, config.riskConfig.maxSwapSlippageBps, FundConstants.BPS, Math.Rounding.Ceil
        );

        uint256 usedObservations;
        uint256 observedActiveCollateral;
        uint256 observedActivePositions;
        uint256 count = adapterState_.positionCount;
        for (uint256 positionId = 1; positionId <= count; ++positionId) {
            ICoveredCallFundAdapter.Position memory strategyPosition = coveredCall.position(positionId);
            if (strategyPosition.lifecycle == ICoveredCallFundAdapter.Lifecycle.None) {
                revert InvalidObservation(positionId);
            }
            if (strategyPosition.lifecycle == ICoveredCallFundAdapter.Lifecycle.Open) {
                _validateOpenProtocolState(adapter, positionId, strategyPosition, coveredCall);
                positionValue.grossAssets += strategyPosition.collateral;
                observedActiveCollateral += strategyPosition.collateral;
                ++observedActivePositions;
                if (block.timestamp >= OToken(strategyPosition.oToken).expiry()) {
                    positionValue.liabilities += _expiredCallLiability(positionId, strategyPosition, coveredCall);
                } else {
                    (uint256 liability, uint256 exitCost, uint256 used) = _preExpiryLiability(
                        adapter, positionId, snapshotBlock, strategyPosition, valuationData.optionObservations
                    );
                    positionValue.liabilities += liability;
                    positionValue.baseExitCost += exitCost;
                    usedObservations += used;
                }
            } else if (strategyPosition.lifecycle == ICoveredCallFundAdapter.Lifecycle.AwaitingPhysicalDelivery) {
                _validateAwaitingDelivery(adapter, positionId, strategyPosition, coveredCall);
            } else {
                _validateTerminalProtocolState(adapter, positionId, strategyPosition, coveredCall);
            }
        }
        if (
            usedObservations != valuationData.optionObservations.length
                || observedActivePositions != adapterState_.activePositionCount
                || observedActiveCollateral != adapterState_.activeCollateral
        ) revert InvalidObservation(0);

        positionValue.dataHash = keccak256(
            abi.encode(
                adapter,
                coveredCall.positionStateHash(),
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
        ICoveredCallFundAdapter.Position memory strategyPosition,
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

    function _expiredCallLiability(
        uint256 positionId,
        ICoveredCallFundAdapter.Position memory strategyPosition,
        ICoveredCallFundAdapter coveredCall
    ) private view returns (uint256) {
        OToken oToken = OToken(strategyPosition.oToken);
        (uint256 expiryPrice, bool isSet) =
            Oracle(AddressBook(coveredCall.addressBook()).oracle()).getExpiryPrice(coveredCall.weth(), oToken.expiry());
        if (!isSet) revert ExpiryPriceUnavailable(positionId, oToken.expiry());
        uint256 strike = oToken.strikePrice();
        if (expiryPrice <= strike) return 0;
        uint256 underlyingAmount = strategyPosition.optionAmount * 1e10;
        uint256 intrinsic = Math.mulDiv(underlyingAmount, expiryPrice - strike, expiryPrice, Math.Rounding.Ceil);
        return Math.min(strategyPosition.collateral, intrinsic);
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
        ICoveredCallFundAdapter.Position memory strategyPosition,
        ICoveredCallFundAdapter coveredCall
    ) private view {
        AddressBook book = AddressBook(coveredCall.addressBook());
        Controller controller = Controller(book.controller());
        BatchSettler settler = BatchSettler(book.batchSettler());
        MarginVault.Vault memory vault = controller.getVault(adapter, strategyPosition.protocolVaultId);
        if (
            controller.vaultSettled(adapter, strategyPosition.protocolVaultId)
                || vault.shortOtoken != strategyPosition.oToken || vault.shortAmount != strategyPosition.optionAmount
                || vault.collateralAsset != coveredCall.accountingAsset()
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
        ICoveredCallFundAdapter.Position memory strategyPosition,
        ICoveredCallFundAdapter coveredCall
    ) private view {
        AddressBook book = AddressBook(coveredCall.addressBook());
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
        ICoveredCallFundAdapter.Position memory strategyPosition,
        ICoveredCallFundAdapter coveredCall
    ) private view {
        AddressBook book = AddressBook(coveredCall.addressBook());
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
        (roundId, answer,, updatedAt, answeredInRound) = ICoveredCallChainlinkSpotFeedV2(spotFeed).latestRoundData();
        if (
            answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp
                || block.timestamp - updatedAt > maxSpotStaleness || answeredInRound < roundId
        ) revert InvalidSpotObservation();
        price = uint256(answer);
    }

    function _usdcToWeth(uint256 usdcAmount, uint256 spotPrice, address usdcAddress) private view returns (uint256) {
        uint8 usdcDecimals = IERC20Metadata(usdcAddress).decimals();
        if (usdcDecimals > 18 || spotFeedDecimals > 18) revert InvalidSpotObservation();
        uint256 scale = 10 ** (18 - usdcDecimals + spotFeedDecimals);
        return Math.mulDiv(usdcAmount, scale, spotPrice);
    }
}
