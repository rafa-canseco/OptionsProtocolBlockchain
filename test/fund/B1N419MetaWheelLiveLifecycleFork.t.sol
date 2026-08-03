// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {WheelCoordinatorAdapter} from "../../src/fund/WheelCoordinatorAdapter.sol";
import {WheelCoveredCallChildLane} from "../../src/fund/WheelCoveredCallChildLane.sol";
import {WheelCspChildLane} from "../../src/fund/WheelCspChildLane.sol";
import {WheelTypes} from "../../src/fund/WheelTypes.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {INavReportVerifier} from "../../src/fund/interfaces/INavReportVerifier.sol";

interface IB1N419MintableToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IB1N419SettablePriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Fork-only rehearsal against the exact inactive B1N-419 Base Sepolia deployment.
/// @dev Never broadcasts. Roles and beta infrastructure are impersonated only inside the fork.
contract B1N419MetaWheelLiveLifecycleForkTest is Test {
    bytes32 private constant LIVE_QUOTE_TYPEHASH = keccak256(
        "Quote(address owner,address oToken,uint256 bidPrice,uint256 deadline,uint256 quoteId,uint256 maxAmount,uint256 makerNonce)"
    );
    uint256 private constant FORK_BLOCK = 45_009_468;
    uint256 private constant MM_KEY = 0xB1A419;
    uint256 private constant CSP_STRIKE = 2_000e8;
    uint256 private constant CALL_STRIKE = 2_010e8;
    uint256 private constant CSP_OPTION_AMOUNT = 4e8;
    uint256 private constant CSP_COLLATERAL = 8_000e6;
    uint256 private constant SECOND_OPTION_AMOUNT = 2e8;
    uint256 private constant SECOND_COLLATERAL = 4_000e6;
    uint256 private constant BID_PRICE = 10e6;

    address private constant USDC = 0xAB51a471493832C1D70cef8ff937A850cf37c860;
    address private constant WETH = 0x8A6Aa2304797898d46eC1d342Fedc817D3a973B6;
    address private constant ADDRESS_BOOK = 0x033d9d37Baf83dBc71935239b6fA22a6905dbaa0;
    address private constant VAULT = 0xD6E6e6e16F2Ef0915eaEBfbDe8B2f8125B9194e9;
    address private constant SHARE = 0xD19B95d67E1f0C73fa26cC63D4949Cb8C2e5F529;
    address private constant ACCOUNTING = 0xe51F4b40c416F29207088a766728AdF8e8D210FB;
    address private constant FLOW = 0x160efcA91615Ac89d0059b4302C6c86066d5A03e;
    address private constant STRATEGY = 0x099139C606EE096fa66B7F01C2098f7623625496;
    address private constant COORDINATOR = 0xaDEAb3563E6D38Ea6415b374DD8f81232BfdF866;
    address private constant NAV_VERIFIER = 0xDCcd048988BeB1ACE40E24ddd4D3f0Ad544873A8;
    address private constant CURATOR = 0xF00d384732D210373F899cA1aa3F1F81EAeb122A;
    address private constant ACCOUNTANT = 0x7966ce08dA54E56db824BF33f82FF2144AC822A5;
    address private constant ALLOCATOR = 0x1eCF7C70B2DA8BcC34dF08Ae9957582AD686C5dd;
    address private constant PROCESSOR = 0x72ebF9B2AB4433093D280dbbc2bbCdE4d37c05da;
    address private constant CSP_LANE_1 = 0x94e40a136d8D50a849fe957870d00E4bC6E5b74a;
    address private constant CSP_LANE_2 = 0xadcDb973Aeb4C7d49D9a2fD937db7D2af579ea37;
    address private constant CC_LANE_1 = 0x0F7Bd57EcA057178d29a8C4f93B9BF4A44Ed38E1;

    FundVault private vault = FundVault(VAULT);
    FundAccounting private accounting = FundAccounting(ACCOUNTING);
    FundFlowManager private flow = FundFlowManager(FLOW);
    StrategyManager private strategy = StrategyManager(STRATEGY);
    WheelCoordinatorAdapter private coordinator = WheelCoordinatorAdapter(COORDINATOR);
    AddressBook private book = AddressBook(ADDRESS_BOOK);
    BatchSettler private settler;
    Oracle private oracle;
    OTokenFactory private factory;
    address private mm;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")), FORK_BLOCK);
        settler = BatchSettler(book.batchSettler());
        oracle = Oracle(book.oracle());
        factory = OTokenFactory(book.oTokenFactory());
        mm = vm.addr(MM_KEY);
    }

    function test_liveDeploymentAssignedWheelCycleConcurrentTrancheAndUsdcRedemption() public {
        _activateForkOnly();

        address alice = makeAddr("wheel-alice");
        address bob = makeAddr("wheel-bob");
        _deposit(alice, 10_000e6);
        _allocate(CSP_COLLATERAL, keccak256("alice-wheel-allocation"));

        uint256 cspExpiry = _nextEligibleExpiry();
        address put = _createSeries(CSP_STRIKE, cspExpiry, true);
        _openCsp(1, CSP_LANE_1, put, CSP_OPTION_AMOUNT, CSP_COLLATERAL, 419_001);

        _setExpiryPrice(cspExpiry, 1_800e8);
        _settleCsp(1);
        CspFundAdapter cspAdapter = CspFundAdapter(WheelCspChildLane(CSP_LANE_1).adapter());
        ICspFundAdapter.Position memory cspPosition = cspAdapter.position(1);
        assertEq(uint256(cspPosition.lifecycle), uint256(ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery));
        vm.prank(settler.operator());
        settler.operatorPhysicalRedeemVault(address(cspAdapter), cspPosition.protocolVaultId, CSP_COLLATERAL);
        _settleCsp(1);
        _handoffCsp(1);

        WheelTypes.Tranche memory assigned = coordinator.tranche(1);
        WheelTypes.AssignmentLot memory lot = coordinator.assignmentLot(assigned.assignmentLotId);
        assertEq(lot.wethReceived, 4e18);
        assertEq(lot.literalAssignmentStrike8, CSP_STRIKE);

        uint256 callExpiry = _nextEligibleExpiry();
        address belowFloorCall = _createSeries(CALL_STRIKE - 1, callExpiry, false);
        _expectOpenCallBelowFloor(1, CC_LANE_1, belowFloorCall, CSP_OPTION_AMOUNT, 4e18, 419_002);

        address call = _createSeries(CALL_STRIKE, callExpiry, false);
        _openCall(1, CC_LANE_1, call, CSP_OPTION_AMOUNT, 4e18, 419_003);
        assertEq(WheelCoveredCallChildLane(CC_LANE_1).requiredFloor8(), CALL_STRIKE);

        _submitFreshNav(vault.committedNav());
        _deposit(bob, 5_000e6);
        _allocate(SECOND_COLLATERAL, keccak256("bob-concurrent-allocation"));
        address secondPut = _createSeries(CSP_STRIKE, callExpiry, true);
        uint256 secondTrancheId = coordinator.summary().trancheCount;
        _openCsp(secondTrancheId, CSP_LANE_2, secondPut, SECOND_OPTION_AMOUNT, SECOND_COLLATERAL, 419_004);
        assertEq(uint256(coordinator.tranche(secondTrancheId).leg), uint256(WheelTypes.TrancheLeg.CspOpen));
        assertEq(uint256(coordinator.tranche(1).leg), uint256(WheelTypes.TrancheLeg.CallOpen));

        _setExpiryPrice(callExpiry, 2_200e8);
        _settleCall(1);
        CoveredCallFundAdapter ccAdapter = CoveredCallFundAdapter(WheelCoveredCallChildLane(CC_LANE_1).adapter());
        ICoveredCallFundAdapter.Position memory ccPosition = ccAdapter.position(1);
        assertEq(uint256(ccPosition.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.AwaitingPhysicalDelivery));
        vm.prank(settler.operator());
        settler.operatorPhysicalRedeemVault(address(ccAdapter), ccPosition.protocolVaultId, 8_040e6);
        _settleCall(1);
        _handoffCall(1);
        assertEq(uint256(coordinator.tranche(1).leg), uint256(WheelTypes.TrancheLeg.PendingCsp));
        assertEq(
            uint256(coordinator.assignmentLot(assigned.assignmentLotId).status),
            uint256(WheelTypes.LotStatus.CalledAway)
        );

        _reserveRedemption(1, CSP_COLLATERAL);
        vm.prank(ALLOCATOR);
        strategy.deallocate(COORDINATOR, CSP_COLLATERAL, CSP_COLLATERAL, "");

        _submitFreshNav(vault.committedNav());
        uint256 aliceShares = IERC20(SHARE).balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares, alice, alice);
        vm.prank(PROCESSOR);
        flow.sealRedeemBatch(1);
        vm.prank(PROCESSOR);
        flow.startRedeemBatch(1, aliceShares, 0);
        vm.prank(PROCESSOR);
        flow.processRedeemBatch(1, 16);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.redeem(aliceShares, alice, alice);
        assertGt(assets, 9_900e6);
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, assets);
        assertEq(uint256(coordinator.tranche(secondTrancheId).leg), uint256(WheelTypes.TrancheLeg.CspOpen));
    }

    function _activateForkOnly() private {
        assertTrue(vault.depositsPaused());
        assertTrue(vault.redemptionsPaused());
        assertTrue(coordinator.allocationsPaused());

        address[8] memory lanes = [
            CSP_LANE_1,
            CSP_LANE_2,
            address(0xaC6406742B48AE230293B22c22bc869e0f04De19),
            address(0x779174D14Aa543f83D692192B271eA47Ab937818),
            CC_LANE_1,
            address(0xBe7be770A898c828e34310e01b2Fbb7FB26A384C),
            address(0x63c55e134443a20648723771B6245EbAE689A6a2),
            address(0x1b68555BAA0c8524200F449557E44481a36Ee100)
        ];
        vm.startPrank(CURATOR);
        for (uint256 i; i < 4; ++i) {
            WheelCspChildLane(lanes[i]).resumeAllocations();
        }
        for (uint256 i = 4; i < 8; ++i) {
            WheelCoveredCallChildLane(lanes[i]).resumeAllocations();
        }
        strategy.executeAdapterConfigurationOperation(
            COORDINATOR, abi.encode(WheelTypes.ManagedOperation.ResumeAllocations, bytes(""))
        );
        strategy.resumeAllocation(COORDINATOR, strategy.allocationPauseNonce(COORDINATOR));
        vm.stopPrank();

        _submitFreshNav(0);
        vm.startPrank(CURATOR);
        vault.resumeRedemptions();
        vault.resumeDeposits();
        vm.stopPrank();

        vm.prank(settler.owner());
        settler.setWhitelistedMM(mm, true);
        IB1N419MintableToken(USDC).mint(mm, 1_000_000e6);
        vm.prank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);
    }

    function _submitFreshNav(uint256 netAssets) private {
        FundTypes.NavCommit memory nav = FundTypes.NavCommit({
            grossAssets: netAssets,
            liabilities: 0,
            netAssets: netAssets,
            liquidAccountingAssets: vault.accountedIdleAssets(),
            baseExitCost: 0,
            snapshotBlock: uint64(block.number),
            validAfterBlock: uint64(block.number + 1),
            validUntilBlock: uint64(block.number + 20),
            reporterSetVersion: accounting.reporterSetVersion(),
            reportNonce: accounting.lastReportNonce() + 1,
            positionsHash: strategy.positionsHash(),
            reportHash: keccak256(abi.encode("B1N419_LIVE_FORK", block.number, netAssets)),
            signaturesHash: keccak256("B1N419_FORK_SIGNATURES"),
            fundFlowNonce: vault.fundFlowNonce(),
            idleStateHash: vault.idleStateHash()
        });
        vm.clearMockedCalls();
        vm.mockCall(NAV_VERIFIER, abi.encodeWithSelector(INavReportVerifier.verifyNavReport.selector), abi.encode(nav));
        vm.prank(ACCOUNTANT);
        accounting.submitNav(nav.reportNonce, new FundTypes.ComponentReport[](0), new address[](0), new bytes[](0));
        vm.roll(nav.validAfterBlock);
    }

    function _deposit(address user, uint256 amount) private {
        IB1N419MintableToken(USDC).mint(user, amount);
        vm.startPrank(user);
        IERC20(USDC).approve(VAULT, amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _allocate(uint256 amount, bytes32 allocationId) private {
        vm.prank(ALLOCATOR);
        strategy.allocate(COORDINATOR, USDC, amount, abi.encode(allocationId));
    }

    function _openCsp(
        uint256 trancheId,
        address lane,
        address oToken,
        uint256 optionAmount,
        uint256 collateral,
        uint256 quoteId
    ) private {
        ICspFundAdapter.OpenPositionData memory openData = ICspFundAdapter.OpenPositionData({
            quote: _quote(oToken, optionAmount, quoteId),
            signature: "",
            optionAmount: optionAmount,
            collateral: collateral
        });
        openData.signature = _sign(WheelCspChildLane(lane).adapter(), openData.quote);
        vm.prank(ALLOCATOR);
        strategy.executeAdapterAllocationOperation(
            COORDINATOR,
            abi.encode(WheelTypes.ManagedOperation.OpenCsp, abi.encode(trancheId, lane, abi.encode(openData)))
        );
    }

    function _openCall(
        uint256 trancheId,
        address lane,
        address oToken,
        uint256 optionAmount,
        uint256 collateral,
        uint256 quoteId
    ) private {
        ICoveredCallFundAdapter.OpenPositionData memory openData =
            ICoveredCallFundAdapter.OpenPositionData({
                quote: _quote(oToken, optionAmount, quoteId),
                signature: "",
                optionAmount: optionAmount,
                collateral: collateral
            });
        openData.signature = _sign(WheelCoveredCallChildLane(lane).adapter(), openData.quote);
        vm.prank(ALLOCATOR);
        strategy.executeAdapterAllocationOperation(
            COORDINATOR,
            abi.encode(WheelTypes.ManagedOperation.OpenCoveredCall, abi.encode(trancheId, lane, abi.encode(openData)))
        );
    }

    function _expectOpenCallBelowFloor(
        uint256 trancheId,
        address lane,
        address oToken,
        uint256 optionAmount,
        uint256 collateral,
        uint256 quoteId
    ) private {
        ICoveredCallFundAdapter.OpenPositionData memory openData =
            ICoveredCallFundAdapter.OpenPositionData({
                quote: _quote(oToken, optionAmount, quoteId),
                signature: "",
                optionAmount: optionAmount,
                collateral: collateral
            });
        openData.signature = _sign(WheelCoveredCallChildLane(lane).adapter(), openData.quote);
        vm.expectRevert(WheelCoordinatorAdapter.CallStrikeBelowFloor.selector);
        vm.prank(ALLOCATOR);
        strategy.executeAdapterAllocationOperation(
            COORDINATOR,
            abi.encode(WheelTypes.ManagedOperation.OpenCoveredCall, abi.encode(trancheId, lane, abi.encode(openData)))
        );
    }

    function _settleCsp(uint256 trancheId) private {
        vm.prank(PROCESSOR);
        strategy.executeAdapterProcessingOperation(
            COORDINATOR, abi.encode(WheelTypes.ManagedOperation.SettleCsp, abi.encode(trancheId))
        );
    }

    function _handoffCsp(uint256 trancheId) private {
        vm.prank(PROCESSOR);
        strategy.executeAdapterProcessingOperation(
            COORDINATOR, abi.encode(WheelTypes.ManagedOperation.HandoffCsp, abi.encode(trancheId))
        );
    }

    function _settleCall(uint256 trancheId) private {
        vm.prank(PROCESSOR);
        strategy.executeAdapterProcessingOperation(
            COORDINATOR, abi.encode(WheelTypes.ManagedOperation.SettleCoveredCall, abi.encode(trancheId))
        );
    }

    function _handoffCall(uint256 trancheId) private {
        vm.prank(PROCESSOR);
        strategy.executeAdapterProcessingOperation(
            COORDINATOR, abi.encode(WheelTypes.ManagedOperation.HandoffCoveredCall, abi.encode(trancheId))
        );
    }

    function _reserveRedemption(uint256 trancheId, uint256 amount) private {
        vm.prank(PROCESSOR);
        strategy.executeAdapterProcessingOperation(
            COORDINATOR, abi.encode(WheelTypes.ManagedOperation.ReserveRedemption, abi.encode(trancheId, amount))
        );
    }

    function _createSeries(uint256 strike, uint256 expiry, bool isPut) private returns (address oToken) {
        vm.prank(factory.operator());
        oToken = factory.createOToken(WETH, USDC, isPut ? USDC : WETH, strike, expiry, isPut);
    }

    function _nextEligibleExpiry() private view returns (uint256) {
        uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
        uint256 candidate = dayStart + 2 days + 8 hours;
        if (candidate - block.timestamp < 36 hours) candidate += 1 days;
        return candidate;
    }

    function _quote(address oToken, uint256 optionAmount, uint256 quoteId)
        private
        view
        returns (BatchSettler.Quote memory)
    {
        return BatchSettler.Quote({
            oToken: oToken,
            bidPrice: BID_PRICE,
            deadline: block.timestamp + 1 hours,
            quoteId: quoteId,
            maxAmount: optionAmount,
            makerNonce: settler.makerNonce(mm)
        });
    }

    function _sign(address owner, BatchSettler.Quote memory quote) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                LIVE_QUOTE_TYPEHASH,
                owner,
                quote.oToken,
                quote.bidPrice,
                quote.deadline,
                quote.quoteId,
                quote.maxAmount,
                quote.makerNonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settler.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _setExpiryPrice(uint256 expiry, uint256 price) private {
        vm.warp(expiry + 1);
        address feed = oracle.priceFeed(WETH);
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IB1N419SettablePriceFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(price), block.timestamp, block.timestamp, uint80(1))
        );
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, price);
    }
}
