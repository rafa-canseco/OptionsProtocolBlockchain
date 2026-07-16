// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {IFundStrategyAdapter} from "../../src/fund/interfaces/IFundStrategyAdapter.sol";
import {IPositionValuator} from "../../src/fund/interfaces/IPositionValuator.sol";

contract MockFundStrategyAdapter is IFundStrategyAdapter {
    address public immutable override fund;
    address public immutable override accountingAsset;
    uint256 public claimedValue;
    uint64 public positionNonce;

    constructor(address fund_, address accountingAsset_) {
        fund = fund_;
        accountingAsset = accountingAsset_;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 1;
    }

    function positionStateHash() external view returns (bytes32) {
        return keccak256(abi.encode(positionNonce, IERC20(accountingAsset).balanceOf(address(this))));
    }

    function freeAssets(address asset) external view returns (uint256) {
        return asset == accountingAsset ? IERC20(asset).balanceOf(address(this)) : 0;
    }

    function setClaimedValue(uint256 value) external {
        claimedValue = value;
    }

    function allocate(address, uint256, bytes calldata) external {
        ++positionNonce;
    }

    function deallocate(uint256 targetValue, uint256 minAccountingAssetsOut, bytes calldata)
        external
        returns (uint256 accountingAssetsOut)
    {
        accountingAssetsOut = targetValue;
        require(accountingAssetsOut >= minAccountingAssetsOut);
        ++positionNonce;
    }

    function deallocateInKind(uint256, address, bytes calldata)
        external
        pure
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](0);
        amounts = new uint256[](0);
    }

    function emergencyExit(address, bytes calldata)
        external
        pure
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](0);
        amounts = new uint256[](0);
    }
}

    contract MockIndependentValuator is IPositionValuator {
        IERC20 public immutable accountingAsset;
        uint256 public immutable liability;
        uint256 public immutable baseExitCost;

        constructor(IERC20 accountingAsset_, uint256 liability_, uint256 baseExitCost_) {
            accountingAsset = accountingAsset_;
            liability = liability_;
            baseExitCost = baseExitCost_;
        }

        function interfaceVersion() external pure returns (uint64) {
            return 1;
        }

        function value(address adapter, uint64 snapshotBlock, bytes calldata)
            external
            view
            returns (FundTypes.PositionValue memory positionValue)
        {
            uint256 balance = accountingAsset.balanceOf(adapter);
            positionValue = FundTypes.PositionValue({
                grossAssets: balance,
                liabilities: liability,
                liquidAccountingAssets: balance,
                baseExitCost: baseExitCost,
                dataHash: keccak256(abi.encode(snapshotBlock, balance, liability, baseExitCost))
            });
        }
    }

    contract StrategyValuationSpecTest is Test {
        function test_adapterCannotSetItsOwnAuthoritativeValue() public {
            MockERC20 asset = new MockERC20("Mock USDC", "mUSDC", 6);
            MockFundStrategyAdapter adapter = new MockFundStrategyAdapter(address(this), address(asset));
            MockIndependentValuator valuator = new MockIndependentValuator(asset, 100e6, 5e6);
            asset.mint(address(adapter), 500e6);
            adapter.setClaimedValue(type(uint256).max);

            FundTypes.PositionValue memory positionValue = valuator.value(address(adapter), 123, "");

            assertEq(positionValue.grossAssets, 500e6);
            assertEq(positionValue.liabilities, 100e6);
            assertEq(positionValue.baseExitCost, 5e6);
            assertTrue(positionValue.grossAssets != adapter.claimedValue());
        }

        function test_positionHashChangesAfterStrategyOperation() public {
            MockERC20 asset = new MockERC20("Mock USDC", "mUSDC", 6);
            MockFundStrategyAdapter adapter = new MockFundStrategyAdapter(address(this), address(asset));
            bytes32 beforeHash = adapter.positionStateHash();

            adapter.allocate(address(asset), 0, "");

            assertTrue(adapter.positionStateHash() != beforeHash);
        }
    }
