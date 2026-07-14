// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./interfaces/IEthCspOptionSelector.sol";
import "../core/OToken.sol";

contract EthCspOptionSelector is IEthCspOptionSelector {
    address public owner;
    address public curator;
    StrategyConfig public strategyConfig;

    event CuratorUpdated(address indexed oldCurator, address indexed newCurator);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event StrategyConfigUpdated(StrategyConfig config);

    error InvalidAddress();
    error InvalidOToken();
    error OnlyOwner();
    error OnlyCurator();
    error StrategyConstraint();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != owner && msg.sender != curator) revert OnlyCurator();
        _;
    }

    constructor(address _owner, StrategyConfig memory _strategyConfig) {
        if (_owner == address(0)) revert InvalidAddress();
        _validateConfig(_strategyConfig);

        owner = _owner;
        curator = _owner;
        strategyConfig = _strategyConfig;
    }

    function setCurator(address newCurator) external onlyOwner {
        if (newCurator == address(0)) revert InvalidAddress();
        emit CuratorUpdated(curator, newCurator);
        curator = newCurator;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        address oldOwner = owner;
        emit OwnershipTransferred(oldOwner, newOwner);
        owner = newOwner;
        if (curator == oldOwner) {
            emit CuratorUpdated(oldOwner, newOwner);
            curator = newOwner;
        }
    }

    function setStrategyConfig(StrategyConfig calldata newConfig) external onlyCurator {
        _validateConfig(newConfig);
        strategyConfig = newConfig;
        emit StrategyConfigUpdated(newConfig);
    }

    function validateOption(
        address oTokenAddress,
        address ethUnderlying,
        address usdc,
        uint256 collateral,
        uint256 activeCollateral,
        uint256 totalManagedAssets
    ) external view {
        if (oTokenAddress == address(0)) revert InvalidOToken();

        OToken oToken = OToken(oTokenAddress);
        if (
            !oToken.isPut() || oToken.underlying() != ethUnderlying || oToken.strikeAsset() != usdc
                || oToken.collateralAsset() != usdc
        ) {
            revert InvalidOToken();
        }

        StrategyConfig memory config = strategyConfig;
        if (collateral > config.maxCollateralPerBatch) revert StrategyConstraint();

        uint256 nextActiveCollateral = activeCollateral + collateral;
        if (nextActiveCollateral * 10_000 > totalManagedAssets * config.maxUtilizationBps) {
            revert StrategyConstraint();
        }

        uint256 expiryDelay = oToken.expiry() > block.timestamp ? oToken.expiry() - block.timestamp : 0;
        if (expiryDelay < config.minExpiryDelay || expiryDelay > config.maxExpiryDelay) revert StrategyConstraint();

        uint256 strike = oToken.strikePrice();
        if (strike < config.minStrike || strike > config.maxStrike) revert StrategyConstraint();
    }

    function validatePremium(uint256 collateral, uint256 premiumEarned) external view {
        uint256 minPremiumBps = strategyConfig.minPremiumBps;
        if (premiumEarned * 10_000 < collateral * minPremiumBps) revert StrategyConstraint();
    }

    function _validateConfig(StrategyConfig memory config) internal pure {
        if (config.maxUtilizationBps > 10_000) revert StrategyConstraint();
        if (config.maxExpiryDelay < config.minExpiryDelay) revert StrategyConstraint();
        if (config.maxStrike < config.minStrike) revert StrategyConstraint();
    }
}
