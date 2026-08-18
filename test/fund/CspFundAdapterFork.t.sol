// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {MarginPool} from "../../src/core/MarginPool.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";

contract ForkFundReceiver {}

contract ForkStrategyManagerCaller {
    function allocate(CspFundAdapter adapter, address asset, uint256 amount, bytes calldata data) external {
        IERC20(asset).transfer(address(adapter), amount);
        adapter.allocate(asset, amount, data);
    }
}

/// @notice Verifies fail-closed CSP activation against the deployed Base V1 protocol without replacing V1 bytecode.
/// @dev Run with: forge test --match-contract CspFundAdapterForkTest --fork-url $BASE_RPC_URL -vv
contract CspFundAdapterForkTest is Test {
    AddressBook private constant ADDRESS_BOOK = AddressBook(0x48FE24a69417038a2D3d46B2B6B9De03b884eD72);
    Controller private constant CONTROLLER = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    MarginPool private constant MARGIN_POOL = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);
    OTokenFactory private constant OTOKEN_FACTORY = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    BatchSettler private constant SETTLER = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant WETH = 0x4200000000000000000000000000000000000006;

    function test_mainnetV1WiringFailsClosedUntilPhysicalDeliveryControllerUpgrade() public {
        if (block.chainid != 8453) return;

        assertEq(ADDRESS_BOOK.controller(), address(CONTROLLER));
        assertEq(ADDRESS_BOOK.marginPool(), address(MARGIN_POOL));
        assertEq(ADDRESS_BOOK.oTokenFactory(), address(OTOKEN_FACTORY));
        assertEq(ADDRESS_BOOK.batchSettler(), address(SETTLER));
        assertEq(address(CONTROLLER.addressBook()), address(ADDRESS_BOOK));
        assertEq(address(SETTLER.addressBook()), address(ADDRESS_BOOK));
        assertNotEq(SETTLER.swapRouter(), address(0));
        (bool hasCustodiedRedemptionOnly,) =
            address(CONTROLLER).staticcall(abi.encodeCall(CONTROLLER.custodiedRedemptionOnly, ()));
        assertFalse(hasCustodiedRedemptionOnly);

        bytes32 controllerCodeHash = address(CONTROLLER).codehash;
        bytes32 settlerCodeHash = address(SETTLER).codehash;
        bytes32 poolCodeHash = address(MARGIN_POOL).codehash;

        ForkFundReceiver fund = new ForkFundReceiver();
        ForkStrategyManagerCaller strategyManager = new ForkStrategyManagerCaller();
        AccessManager authority = new AccessManager(address(this));
        CspFundAdapter adapter = CspFundAdapter(
            address(
                new ERC1967Proxy(
                    address(new CspFundAdapter()),
                    abi.encodeCall(
                        CspFundAdapter.initialize,
                        (CspFundAdapter.InitializeParams({
                                fund: address(fund),
                                strategyManager: address(strategyManager),
                                addressBook: address(ADDRESS_BOOK),
                                accountingAsset: USDC,
                                weth: WETH,
                                swapRouter: SETTLER.swapRouter(),
                                swapFeeTier: SETTLER.swapFeeTier(),
                                authority: address(authority),
                                riskConfig: _riskConfig()
                            }))
                    )
                )
            )
        );

        assertFalse(adapter.isOnboarded());
        deal(USDC, address(strategyManager), 1);
        vm.expectRevert(ICspFundAdapter.AdapterNotOnboarded.selector);
        strategyManager.allocate(adapter, USDC, 1, "");
        assertEq(IERC20(USDC).balanceOf(address(strategyManager)), 1);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(address(CONTROLLER).codehash, controllerCodeHash);
        assertEq(address(SETTLER).codehash, settlerCodeHash);
        assertEq(address(MARGIN_POOL).codehash, poolCodeHash);
    }

    function _riskConfig() private pure returns (ICspFundAdapter.RiskConfig memory) {
        return ICspFundAdapter.RiskConfig({
            minExpiryDelay: 1 hours,
            maxExpiryDelay: 2 days,
            settlementDefaultDelay: 6 hours,
            minPremiumBps: 100,
            maxSwapSlippageBps: 100,
            maxOpenPositions: 2,
            minStrike: 1_000e8,
            maxStrike: 4_000e8,
            maxCollateralPerPosition: 10_000e6,
            maxWethPerSwap: 5e18
        });
    }
}
