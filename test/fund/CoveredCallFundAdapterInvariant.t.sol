// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockSwapRouter} from "../../src/mocks/MockSwapRouter.sol";

contract CoveredCallInvariantCodeStub {}

contract CoveredCallDonationHandler {
    MockERC20 public immutable weth;
    MockERC20 public immutable usdc;
    address public immutable adapter;
    uint256 public totalWethDonated;
    uint256 public totalUsdcDonated;

    constructor(MockERC20 weth_, MockERC20 usdc_, address adapter_) {
        weth = weth_;
        usdc = usdc_;
        adapter = adapter_;
    }

    function donate(uint96 wethAmount, uint96 usdcAmount) external {
        totalWethDonated += wethAmount;
        totalUsdcDonated += usdcAmount;
        weth.mint(adapter, wethAmount);
        usdc.mint(adapter, usdcAmount);
    }
}

/// @notice Stateful donation isolation checks for the WETH-only covered-call accounting boundary.
contract CoveredCallFundAdapterInvariantTest is StdInvariant, Test {
    MockERC20 private weth;
    MockERC20 private usdc;
    CoveredCallFundAdapter private adapter;
    CoveredCallDonationHandler private handler;

    function setUp() public {
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        MockSwapRouter router = new MockSwapRouter(address(usdc));
        CoveredCallInvariantCodeStub codeStub = new CoveredCallInvariantCodeStub();
        AccessManager authority = new AccessManager(address(this));
        CoveredCallFundAdapter implementation = new CoveredCallFundAdapter();
        adapter = CoveredCallFundAdapter(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        CoveredCallFundAdapter.initialize,
                        (CoveredCallFundAdapter.InitializeParams({
                                fund: address(this),
                                strategyManager: address(this),
                                addressBook: address(codeStub),
                                accountingAsset: address(weth),
                                usdc: address(usdc),
                                swapRouter: address(router),
                                swapFeeTier: 500,
                                authority: address(authority),
                                riskConfig: _riskConfig()
                            }))
                    )
                )
            )
        );
        handler = new CoveredCallDonationHandler(weth, usdc, address(adapter));

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = CoveredCallDonationHandler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_rawTokenDonationsRemainOutsideFundAccounting() public view {
        ICoveredCallFundAdapter.AdapterState memory state = adapter.adapterState();
        assertEq(state.stateNonce, 0);
        assertEq(state.positionCount, 0);
        assertEq(state.activePositionCount, 0);
        assertEq(state.activeCollateral, 0);
        assertEq(state.accountedWeth, 0);
        assertEq(state.accountedUsdc, 0);
        assertEq(adapter.freeAssets(address(weth)), 0);
        assertEq(adapter.freeAssets(address(usdc)), 0);
        assertEq(weth.balanceOf(address(adapter)), handler.totalWethDonated());
        assertEq(usdc.balanceOf(address(adapter)), handler.totalUsdcDonated());
        assertEq(usdc.balanceOf(address(this)), 0);
    }

    function _riskConfig() private pure returns (ICoveredCallFundAdapter.RiskConfig memory) {
        return ICoveredCallFundAdapter.RiskConfig({
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 2 days,
            settlementDefaultDelay: 6 hours,
            minPremiumBps: 100,
            maxSwapSlippageBps: 100,
            maxOpenPositions: 1,
            maxUtilizationBps: 9_000,
            minStrike: 1_000e8,
            maxStrike: 4_000e8,
            maxCollateralPerPosition: 2e18,
            maxUsdcPerSwap: 10_000e6
        });
    }
}
