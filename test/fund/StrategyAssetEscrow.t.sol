// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {FundConstants} from "../../src/fund/FundConstants.sol";
import {StrategyAssetEscrow} from "../../src/fund/StrategyAssetEscrow.sol";
import {IStrategyAssetEscrow} from "../../src/fund/interfaces/IStrategyAssetEscrow.sol";
import {FundAccessPolicy} from "../../src/fund/libraries/FundAccessPolicy.sol";

contract StrategyAssetEscrowFundReceiver {}

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
            return;
        }
        super._update(from, to, value);
    }
}

contract StrategyAssetEscrowTest is Test {
    bytes32 internal constant IN_KIND_PURPOSE = keccak256("B1NARY_STRATEGY_IN_KIND_ESCROW");

    AccessManager internal manager;
    StrategyAssetEscrowFundReceiver internal fund;
    StrategyAssetEscrow internal escrow;
    MockERC20 internal asset;
    address internal curator = address(0xC0A7);

    function setUp() public {
        manager = new AccessManager(address(this));
        fund = new StrategyAssetEscrowFundReceiver();
        escrow = new StrategyAssetEscrow(address(fund), address(manager), IN_KIND_PURPOSE);
        asset = new MockERC20("USD Coin", "USDC", 6);

        FundAccessPolicy.Rule[] memory rules = FundAccessPolicy.strategyAssetEscrowRules();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = rules[0].selector;
        manager.setTargetFunctionRole(address(escrow), selectors, rules[0].role);
        manager.grantRole(FundConstants.CURATOR_ROLE, curator, rules[0].executionDelay);
        manager.grantRole(FundConstants.CURATOR_ROLE, address(this), 0);
    }

    function test_constructorBindsFundAuthorityAndPurpose() public view {
        assertEq(escrow.FUND(), address(fund));
        assertEq(escrow.authority(), address(manager));
        assertEq(escrow.PURPOSE(), IN_KIND_PURPOSE);
    }

    function test_constructorRejectsInvalidBindings() public {
        vm.expectRevert(IStrategyAssetEscrow.InvalidAddress.selector);
        new StrategyAssetEscrow(address(0), address(manager), IN_KIND_PURPOSE);

        vm.expectRevert(IStrategyAssetEscrow.InvalidAddress.selector);
        new StrategyAssetEscrow(address(fund), address(0xBEEF), IN_KIND_PURPOSE);

        vm.expectRevert(IStrategyAssetEscrow.InvalidAddress.selector);
        new StrategyAssetEscrow(address(fund), address(manager), bytes32(0));
    }

    function test_releaseRequiresCuratorScheduleAndReturnsOnlyToFund() public {
        asset.mint(address(escrow), 25e6);
        bytes memory data = abi.encodeCall(escrow.releaseToFund, (address(asset), 25e6));

        vm.prank(curator);
        vm.expectRevert();
        escrow.releaseToFund(address(asset), 25e6);

        vm.prank(curator);
        manager.schedule(address(escrow), data, 0);
        vm.warp(block.timestamp + FundConstants.CURATOR_DELAY);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit IStrategyAssetEscrow.AssetReleasedToFund(address(asset), 25e6);
        vm.prank(curator);
        escrow.releaseToFund(address(asset), 25e6);

        assertEq(asset.balanceOf(address(fund)), 25e6);
        assertEq(asset.balanceOf(address(escrow)), 0);
    }

    function test_releaseRejectsZeroAmountAndNonToken() public {
        vm.expectRevert(IStrategyAssetEscrow.InvalidAmount.selector);
        escrow.releaseToFund(address(asset), 0);

        vm.expectRevert(IStrategyAssetEscrow.InvalidAddress.selector);
        escrow.releaseToFund(address(0xBEEF), 1);
    }

    function test_releaseRejectsFeeOnTransferAssetToPreserveExactReconciliation() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        feeToken.mint(address(escrow), 25);

        vm.expectRevert(
            abi.encodeWithSelector(IStrategyAssetEscrow.BalanceDeltaMismatch.selector, address(feeToken), 25, 24)
        );
        escrow.releaseToFund(address(feeToken), 25);

        assertEq(feeToken.balanceOf(address(escrow)), 25);
        assertEq(feeToken.balanceOf(address(fund)), 0);
    }
}
