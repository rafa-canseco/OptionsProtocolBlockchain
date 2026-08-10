// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FundCoreProductionTest} from "./FundCoreProduction.t.sol";
import {
    AssetNeutralCspFundAdapterV2,
    AssetNeutralOptionsFundAdapterV2
} from "../../src/fund/AssetNeutralOptionsFundAdapterV2.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {IFundStrategyAdapter} from "../../src/fund/interfaces/IFundStrategyAdapter.sol";
import {IPositionValuator} from "../../src/fund/interfaces/IPositionValuator.sol";
import {IAssetNeutralOptionsAdapterV2 as IAdapter} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IOperations
} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";

contract AssetNeutralCspFundAdapterV2ManagerHarness is AssetNeutralCspFundAdapterV2 {
    address public immutable custody;

    constructor(address custody_) {
        custody = custody_;
    }

    function allocate(address asset_, uint256 amount, bytes calldata) external override onlyStrategyManager {
        Layout storage $ = _layout();
        require(asset_ == $.settlement && amount != 0, "ALLOCATION");
        $.activeCollateral += amount;
        ++$.activePositionCount;
        require(IERC20(asset_).transfer(custody, amount), "CUSTODY");
    }

    function recordTerminalReturn(uint256 principal, uint256 returnedAssets) external {
        Layout storage $ = _layout();
        require(principal != 0 && principal <= $.activeCollateral, "PRINCIPAL");
        require(IERC20($.settlement).balanceOf(address(this)) >= $.accountedSettlement + returnedAssets, "RETURN");
        $.activeCollateral -= principal;
        if ($.activeCollateral == 0) $.activePositionCount = 0;
        $.accountedSettlement += returnedAssets;
        $.releasablePrincipal += principal;
        ++$.stateNonce;
        $.positionsHash = keccak256(abi.encode($.positionsHash, principal, returnedAssets, $.stateNonce));
    }
}

contract AssetNeutralManagerReturnAdapterV2 is IFundStrategyAdapter {
    address public immutable override fund;
    address public immutable override accountingAsset;
    uint64 public nonce;

    constructor(address fund_, address accountingAsset_) {
        fund = fund_;
        accountingAsset = accountingAsset_;
    }

    function interfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function deallocationInterfaceVersion() external pure returns (uint64) {
        return 2;
    }

    function positionStateHash() external view returns (bytes32) {
        return keccak256(abi.encode(nonce, IERC20(accountingAsset).balanceOf(address(this))));
    }

    function freeAssets(address asset_) external view returns (uint256) {
        return IERC20(asset_).balanceOf(address(this));
    }

    function allocate(address asset_, uint256 amount, bytes calldata) external {
        require(asset_ == accountingAsset && IERC20(asset_).balanceOf(address(this)) >= amount, "ALLOCATION");
        ++nonce;
    }

    function deallocate(uint256, uint256, bytes calldata data)
        external
        returns (uint256 accountingAssetsOut, uint256 principalReleased)
    {
        (accountingAssetsOut, principalReleased) = abi.decode(data, (uint256, uint256));
        IERC20(accountingAsset).transfer(fund, accountingAssetsOut);
        ++nonce;
    }

    function deallocateInKind(uint256, address, bytes calldata)
        external
        pure
        returns (address[] memory, uint256[] memory)
    {
        revert("UNUSED");
    }

    function emergencyExit(address, bytes calldata) external pure returns (address[] memory, uint256[] memory) {
        revert("UNUSED");
    }
}

    contract AssetNeutralManagerValuatorV2 is IPositionValuator {
        function interfaceVersion() external pure returns (uint64) {
            return 2;
        }

        function value(address adapter, uint64, bytes calldata)
            external
            view
            returns (FundTypes.PositionValue memory v)
        {
            v.grossAssets = IERC20(AssetNeutralManagerReturnAdapterV2(adapter).accountingAsset()).balanceOf(adapter);
            v.liquidAccountingAssets = v.grossAssets;
            v.dataHash = AssetNeutralManagerReturnAdapterV2(adapter).positionStateHash();
        }
    }

    contract AssetNeutralOptionsV2StrategyManagerTest is FundCoreProductionTest {
        function test_productionManagerReconcilesReturnAndEnforcesLossBound() public {
            asset.mint(alice, 100e6);
            vm.startPrank(alice);
            asset.approve(address(vault), 100e6);
            vault.deposit(100e6, alice);
            vm.stopPrank();

            AssetNeutralManagerReturnAdapterV2 adapter =
                new AssetNeutralManagerReturnAdapterV2(address(vault), address(asset));
            AssetNeutralManagerValuatorV2 valuator = new AssetNeutralManagerValuatorV2();
            _scheduledCall(
                address(accounting),
                abi.encodeCall(
                    accounting.setComponent,
                    (accounting.strategyComponentId(address(adapter)), address(valuator), uint64(2), true)
                )
            );
            FundTypes.StrategyConfig memory config = FundTypes.StrategyConfig({
                active: true,
                maxAllocationBps: 5_000,
                maxLossBps: 100,
                cooldown: 0,
                interfaceVersion: 2,
                valuator: address(valuator),
                absoluteCap: 50e6
            });
            _scheduledCall(address(strategy), abi.encodeCall(strategy.setStrategyConfig, (address(adapter), config)));

            strategy.allocate(address(adapter), address(asset), 40e6, "");
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 40e6);
            asset.mint(address(adapter), 5e6);

            vm.expectRevert();
            strategy.deallocate(address(adapter), 46e6, 0, abi.encode(45e6, 40e6));
            assertEq(asset.balanceOf(address(adapter)), 45e6);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 40e6);

            assertEq(strategy.deallocate(address(adapter), 45e6, 45e6, abi.encode(45e6, 40e6)), 45e6);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 0);
            assertEq(vault.accountedIdleAssets(), 105e6);
        }

        function test_actualAdapterTerminalLossCannotUnderReportPrincipalWithCallerTarget() public {
            _depositAssets(100e6);
            (AssetNeutralCspFundAdapterV2ManagerHarness adapter, AssetNeutralManagerValuatorV2 valuator) =
                _deployActualAdapter();
            FundTypes.StrategyConfig memory config = _configureActualAdapter(adapter, valuator, 100);

            strategy.allocate(address(adapter), address(asset), 40e6, "");
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 40e6);
            asset.mint(address(adapter), 36e6);
            adapter.recordTerminalReturn(40e6, 36e6);

            bytes memory returnIdle = abi.encode(
                IAdapter.DeallocateDataV2({
                    action: IAdapter.DeallocateAction.ReturnIdle, positionId: 0, amount: 0, minAmountOut: 0
                })
            );
            vm.expectRevert();
            strategy.deallocate(address(adapter), 36e6, 0, returnIdle);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 40e6);
            assertEq(asset.balanceOf(address(adapter)), 36e6);

            config.maxLossBps = 1_000;
            _scheduledCall(address(strategy), abi.encodeCall(strategy.setStrategyConfig, (address(adapter), config)));
            assertEq(strategy.deallocate(address(adapter), 36e6, 36e6, returnIdle), 36e6);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 0);
            assertEq(asset.balanceOf(address(adapter)), 0);
        }

        function test_actualAdapterPartialTerminalLotReleasesExactPrincipalAndKeepsRemainderAllocated() public {
            _depositAssets(100e6);
            (AssetNeutralCspFundAdapterV2ManagerHarness adapter, AssetNeutralManagerValuatorV2 valuator) =
                _deployActualAdapter();
            _configureActualAdapter(adapter, valuator, 100);

            strategy.allocate(address(adapter), address(asset), 40e6, "");
            asset.mint(address(adapter), 20e6);
            adapter.recordTerminalReturn(20e6, 20e6);
            bytes memory returnIdle = abi.encode(
                IAdapter.DeallocateDataV2({
                    action: IAdapter.DeallocateAction.ReturnIdle, positionId: 0, amount: 0, minAmountOut: 0
                })
            );

            assertEq(strategy.deallocate(address(adapter), 1, 20e6, returnIdle), 20e6);
            assertEq(strategy.allocatedToAdapter(address(adapter), address(asset)), 20e6);
            IAdapter.AdapterStateV2 memory state = adapter.adapterStateV2();
            assertEq(state.activePositionCount, 1);
            assertEq(state.activeCollateralAmount, 20e6);
            assertEq(state.accountedSettlementAmount, 0);
        }

        function _depositAssets(uint256 amount) private {
            asset.mint(alice, amount);
            vm.startPrank(alice);
            asset.approve(address(vault), amount);
            vault.deposit(amount, alice);
            vm.stopPrank();
        }

        function _deployActualAdapter()
            private
            returns (AssetNeutralCspFundAdapterV2ManagerHarness adapter, AssetNeutralManagerValuatorV2 valuator)
        {
            MockERC20 underlying = new MockERC20("Loot BTC", "LBTC", 8);
            AddressBook addressBook = new AddressBook();
            MockSwapRouter router = new MockSwapRouter(address(asset));
            AssetNeutralCspFundAdapterV2ManagerHarness implementation =
                new AssetNeutralCspFundAdapterV2ManagerHarness(address(0xC0570D1));
            AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory params =
                AssetNeutralOptionsFundAdapterV2.InitializeParamsV2({
                    fund: address(vault),
                    strategyManager: address(strategy),
                    addressBook: address(addressBook),
                    underlyingAsset: address(underlying),
                    settlementAsset: address(asset),
                    swapRouter: address(router),
                    swapFeeTier: 500,
                    authority: address(manager),
                    riskConfig: IOperations.RiskConfigV2({
                        minExpiryDelay: 1 hours,
                        maxExpiryDelay: 2 days,
                        settlementDefaultDelay: 6 hours,
                        minPremiumBps: 1,
                        maxSwapSlippageBps: 100,
                        maxOpenPositions: 4,
                        maxUtilizationBps: 10_000,
                        minStrikeUsd8: 1,
                        maxStrikeUsd8: 100_000e8,
                        maxCollateralPerPosition: 1_000_000e6,
                        maxNormalizationInput: 1_000_000e6,
                        protectedBasisUsd8: 0
                    })
                });
            adapter = AssetNeutralCspFundAdapterV2ManagerHarness(
                address(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(AssetNeutralCspFundAdapterV2.initialize, (params))
                    )
                )
            );
            valuator = new AssetNeutralManagerValuatorV2();
        }

        function _configureActualAdapter(
            AssetNeutralCspFundAdapterV2ManagerHarness adapter,
            AssetNeutralManagerValuatorV2 valuator,
            uint16 maxLossBps
        ) private returns (FundTypes.StrategyConfig memory config) {
            _scheduledCall(
                address(accounting),
                abi.encodeCall(
                    accounting.setComponent,
                    (accounting.strategyComponentId(address(adapter)), address(valuator), uint64(2), true)
                )
            );
            config = FundTypes.StrategyConfig({
                active: true,
                maxAllocationBps: 5_000,
                maxLossBps: maxLossBps,
                cooldown: 0,
                interfaceVersion: 2,
                valuator: address(valuator),
                absoluteCap: 50e6
            });
            _scheduledCall(address(strategy), abi.encodeCall(strategy.setStrategyConfig, (address(adapter), config)));
        }

        function _scheduledCall(address target, bytes memory data) private {
            manager.schedule(target, data, 0);
            vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);
            (bool ok, bytes memory result) = target.call(data);
            if (!ok) assembly { revert(add(result, 32), mload(result)) }
        }
    }
