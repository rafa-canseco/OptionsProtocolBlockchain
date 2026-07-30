// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AddressBook} from "../../src/core/AddressBook.sol";
import {BatchSettler} from "../../src/core/BatchSettler.sol";
import {Controller} from "../../src/core/Controller.sol";
import {Oracle} from "../../src/core/Oracle.sol";
import {OToken} from "../../src/core/OToken.sol";
import {OTokenFactory} from "../../src/core/OTokenFactory.sol";
import {FundAccessManager} from "../../src/fund/FundAccessManager.sol";
import {FundAccounting} from "../../src/fund/FundAccounting.sol";
import {FundFlowManager} from "../../src/fund/FundFlowManager.sol";
import {FundTypes} from "../../src/fund/FundTypes.sol";
import {FundVault} from "../../src/fund/FundVault.sol";
import {StrategyManager} from "../../src/fund/StrategyManager.sol";
import {CspFundAdapter} from "../../src/fund/CspFundAdapter.sol";
import {CoveredCallFundAdapter} from "../../src/fund/CoveredCallFundAdapter.sol";
import {ICspFundAdapter} from "../../src/fund/interfaces/ICspFundAdapter.sol";
import {ICoveredCallFundAdapter} from "../../src/fund/interfaces/ICoveredCallFundAdapter.sol";
import {MarginVault} from "../../src/interfaces/IMarginVault.sol";

interface IMintableToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface ISettablePriceFeed {
    function owner() external view returns (address);
    function setPrice(int256 price) external;
}

/// @notice B1N-394: rehearses the proposed Fund V2 upgrade against the exact live Base Sepolia state.
/// @dev No broadcast is performed. The test upgrades fork-local proxy state only.
contract B1N394ActivePositionUpgradeForkTest is Test {
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint256 private constant SNAPSHOT_BLOCK = 44_811_440;
    uint256 private constant SETTLEMENT_PRICE = 1_800e8;
    uint256 private constant NEXT_STRIKE = 1_800e8;
    uint256 private constant NEXT_OPTION_AMOUNT = 0.5e8;
    uint256 private constant NEXT_CSP_COLLATERAL = 900e6;
    uint256 private constant NEXT_CC_COLLATERAL = 0.5e18;
    uint256 private constant NEXT_BID_PRICE = 10e6;
    uint256 private constant MM_KEY = 0xB1A394;
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(address owner,address oToken,uint256 bidPrice,uint256 deadline,uint256 quoteId,uint256 maxAmount,uint256 makerNonce)"
    );
    uint64 private constant UPGRADER_ROLE = 1;
    uint64 private constant ALLOCATOR_ROLE = 3;
    uint64 private constant ADAPTER_UPGRADER_ROLE = 8;

    address private constant ADMIN = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant ADDRESS_BOOK = 0x033d9d37Baf83dBc71935239b6fA22a6905dbaa0;
    address private constant WETH = 0x8A6Aa2304797898d46eC1d342Fedc817D3a973B6;
    address private constant USDC = 0xAB51a471493832C1D70cef8ff937A850cf37c860;

    address private constant CSP_ACCESS = 0x729d5076C1C59a7C2676Faf3fB9133Ff80cDaB12;
    address private constant CSP_VAULT = 0x53e38Baf2fC55259729085b7542BFF066F6a509e;
    address private constant CSP_ACCOUNTING = 0x21d3acc5a2c64666dA93ABC8c77AB483b96836a3;
    address private constant CSP_FLOW = 0x0206C0A5050b09B7A2AD4E8CbF83a06ae2193080;
    address private constant CSP_MANAGER = 0xfC28237145596D4E1dfD28B80e186EFC09A1F988;
    address private constant CSP_ADAPTER = 0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3;
    uint256 private constant CSP_POSITION_ID = 3;

    address private constant CC_ACCESS = 0x5AfD3d840ec2f7fE078b44b75462C2dCD3DC3F6D;
    address private constant CC_VAULT = 0x9060946E6ACC4E430A823E90120743c7305EE2CA;
    address private constant CC_ACCOUNTING = 0x9a112A65FE8510bCf5DC894fFBf06aEa8d12d311;
    address private constant CC_FLOW = 0x59fc0d88aAF3D14b82696cc7E91ea37b629E48cc;
    address private constant CC_MANAGER = 0x745422dd14E84ee27C2E56D2845C3BB1658027d9;
    address private constant CC_ADAPTER = 0x0BF96C5cE0D637d4D686d342aE42Bc00fDa19De9;
    uint256 private constant CC_POSITION_ID = 1;

    AddressBook private book = AddressBook(ADDRESS_BOOK);
    Controller private controller;
    BatchSettler private settler;
    Oracle private oracle;
    OTokenFactory private factory;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")), SNAPSHOT_BLOCK);
        assertEq(block.chainid, BASE_SEPOLIA_CHAIN_ID);
        assertEq(block.number, SNAPSHOT_BLOCK);

        controller = Controller(book.controller());
        settler = BatchSettler(book.batchSettler());
        oracle = Oracle(book.oracle());
        factory = OTokenFactory(book.oTokenFactory());
    }

    function test_openPositionsSurviveUpgradeThenSettleAndRollover() public {
        _assertPinnedLiveState();

        bytes32 cspStateBefore = _cspPreservedStateHash();
        bytes32 ccStateBefore = _ccPreservedStateHash();
        bytes32 cspPositionStateBefore = CspFundAdapter(CSP_ADAPTER).positionStateHash();
        bytes32 ccPositionStateBefore = CoveredCallFundAdapter(CC_ADAPTER).positionStateHash();

        _upgradeForkLocalImplementations();

        assertEq(_cspPreservedStateHash(), cspStateBefore, "CSP state changed during upgrade");
        assertEq(_ccPreservedStateHash(), ccStateBefore, "CC state changed during upgrade");
        assertEq(CspFundAdapter(CSP_ADAPTER).deallocationInterfaceVersion(), 2);
        assertEq(CoveredCallFundAdapter(CC_ADAPTER).deallocationInterfaceVersion(), 2);
        assertNotEq(CspFundAdapter(CSP_ADAPTER).positionStateHash(), cspPositionStateBefore);
        assertNotEq(CoveredCallFundAdapter(CC_ADAPTER).positionStateHash(), ccPositionStateBefore);

        _settleBothOtm();
        _assertBothPositionsClosedAndPrincipalReleased(
            ICspFundAdapter.Lifecycle.SettledOtm, ICoveredCallFundAdapter.Lifecycle.SettledOtm
        );

        _openNextPositions();
        _assertNextPositionsOpen();
    }

    function test_coveredCallItmFallbackAfterUpgradeThenBothRollover() public {
        _assertPinnedLiveState();
        _upgradeForkLocalImplementations();
        _setExpiryPrice(2_100e8);

        _settleCspOtm();
        _settleCoveredCallItmFallback(2_100e8);
        _assertBothPositionsClosedAndPrincipalReleased(
            ICspFundAdapter.Lifecycle.SettledOtm, ICoveredCallFundAdapter.Lifecycle.CashFallback
        );

        _openNextPositions();
        _assertNextPositionsOpen();
    }

    function test_cspItmFallbackAfterUpgradeThenBothRollover() public {
        _assertPinnedLiveState();
        _upgradeForkLocalImplementations();
        _setExpiryPrice(1_600e8);

        _settleCspItmFallback();
        _settleCoveredCallOtm(1_600e8);
        _assertBothPositionsClosedAndPrincipalReleased(
            ICspFundAdapter.Lifecycle.CashFallback, ICoveredCallFundAdapter.Lifecycle.SettledOtm
        );

        _openNextPositions();
        _assertNextPositionsOpen();
    }

    function _assertPinnedLiveState() private view {
        ICspFundAdapter.AdapterState memory cspState = CspFundAdapter(CSP_ADAPTER).adapterState();
        ICspFundAdapter.Position memory cspPosition = CspFundAdapter(CSP_ADAPTER).position(CSP_POSITION_ID);
        ICoveredCallFundAdapter.AdapterState memory ccState = CoveredCallFundAdapter(CC_ADAPTER).adapterState();
        ICoveredCallFundAdapter.Position memory ccPosition = CoveredCallFundAdapter(CC_ADAPTER).position(CC_POSITION_ID);

        assertEq(cspState.positionCount, 3);
        assertEq(cspState.activePositionCount, 1);
        assertEq(cspPosition.collateral, 3_142_399_992);
        assertEq(uint256(cspPosition.lifecycle), uint256(ICspFundAdapter.Lifecycle.Open));
        assertEq(StrategyManager(CSP_MANAGER).allocatedToAdapter(CSP_ADAPTER, USDC), cspPosition.collateral);

        assertEq(ccState.positionCount, 1);
        assertEq(ccState.activePositionCount, 1);
        assertEq(ccState.activeCollateral, 1.25e18);
        assertEq(ccPosition.collateral, 1.25e18);
        assertEq(uint256(ccPosition.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.Open));
        assertEq(StrategyManager(CC_MANAGER).allocatedToAdapter(CC_ADAPTER, WETH), ccPosition.collateral);

        assertEq(OToken(cspPosition.oToken).expiry(), OToken(ccPosition.oToken).expiry());
        assertEq(FundVault(CSP_VAULT).executionLockOwner(), address(0));
        assertEq(FundVault(CC_VAULT).executionLockOwner(), address(0));
        assertFalse(FundFlowManager(CSP_FLOW).hasActiveProcessing());
        assertFalse(FundFlowManager(CC_FLOW).hasActiveProcessing());
    }

    function _upgradeForkLocalImplementations() private {
        CspFundAdapter newCspAdapter = new CspFundAdapter();
        CoveredCallFundAdapter newCcAdapter = new CoveredCallFundAdapter();
        StrategyManager newStrategyManager = new StrategyManager();
        FundAccounting newAccounting = new FundAccounting();
        FundFlowManager newFlow = new FundFlowManager();

        vm.prank(_roleMember(CSP_ACCESS, ADAPTER_UPGRADER_ROLE));
        CspFundAdapter(CSP_ADAPTER).upgradeToAndCall(address(newCspAdapter), "");
        vm.prank(_roleMember(CC_ACCESS, ADAPTER_UPGRADER_ROLE));
        CoveredCallFundAdapter(CC_ADAPTER).upgradeToAndCall(address(newCcAdapter), "");

        vm.startPrank(_roleMember(CSP_ACCESS, UPGRADER_ROLE));
        FundAccounting(CSP_ACCOUNTING).upgradeToAndCall(address(newAccounting), "");
        FundFlowManager(CSP_FLOW).upgradeToAndCall(address(newFlow), "");
        StrategyManager(CSP_MANAGER).upgradeToAndCall(address(newStrategyManager), "");
        vm.stopPrank();

        vm.startPrank(_roleMember(CC_ACCESS, UPGRADER_ROLE));
        FundAccounting(CC_ACCOUNTING).upgradeToAndCall(address(newAccounting), "");
        FundFlowManager(CC_FLOW).upgradeToAndCall(address(newFlow), "");
        StrategyManager(CC_MANAGER).upgradeToAndCall(address(newStrategyManager), "");
        vm.stopPrank();
    }

    function _settleBothOtm() private {
        _setExpiryPrice(SETTLEMENT_PRICE);
        _settleCspOtm();
        _settleCoveredCallOtm(SETTLEMENT_PRICE);
    }

    function _setExpiryPrice(uint256 price) private {
        ICspFundAdapter.Position memory cspPosition = CspFundAdapter(CSP_ADAPTER).position(CSP_POSITION_ID);
        uint256 expiry = OToken(cspPosition.oToken).expiry();
        vm.warp(expiry + 1);
        address priceFeed = oracle.priceFeed(WETH);
        vm.prank(ISettablePriceFeed(priceFeed).owner());
        ISettablePriceFeed(priceFeed).setPrice(int256(price));
        vm.prank(oracle.operator());
        oracle.setExpiryPrice(WETH, expiry, price);
    }

    function _settleCspOtm() private {
        ICspFundAdapter.Position memory cspPosition = CspFundAdapter(CSP_ADAPTER).position(CSP_POSITION_ID);
        uint256 cspTarget = cspPosition.collateral + CspFundAdapter(CSP_ADAPTER).adapterState().accountedUsdc;
        vm.prank(_roleMember(CSP_ACCESS, ALLOCATOR_ROLE));
        uint256 cspReturned = StrategyManager(CSP_MANAGER)
            .deallocate(
                CSP_ADAPTER,
                cspTarget,
                0,
                abi.encode(
                    ICspFundAdapter.DeallocateData({
                        action: ICspFundAdapter.DeallocateAction.Settle,
                        positionId: CSP_POSITION_ID,
                        amount: 0,
                        minAmountOut: 0
                    })
                )
            );
        assertEq(cspReturned, cspTarget);
    }

    function _settleCoveredCallOtm(uint256 price) private {
        ICoveredCallFundAdapter.Position memory ccPosition = CoveredCallFundAdapter(CC_ADAPTER).position(CC_POSITION_ID);
        vm.prank(_roleMember(CC_ACCESS, ALLOCATOR_ROLE));
        uint256 ccSettlementReturn = StrategyManager(CC_MANAGER)
            .deallocate(
                CC_ADAPTER,
                1,
                0,
                abi.encode(
                    ICoveredCallFundAdapter.DeallocateData({
                        action: ICoveredCallFundAdapter.DeallocateAction.Settle,
                        positionId: CC_POSITION_ID,
                        amount: 0,
                        minAmountOut: 0
                    })
                )
            );
        assertEq(ccSettlementReturn, 0);

        ICoveredCallFundAdapter.AdapterState memory ccState = CoveredCallFundAdapter(CC_ADAPTER).adapterState();
        uint256 expectedWeth = Math.mulDiv(ccState.accountedUsdc, 1e20, price);
        uint256 policyMinimum = Math.mulDiv(
            expectedWeth,
            10_000 - CoveredCallFundAdapter(CC_ADAPTER).adapterConfig().riskConfig.maxSwapSlippageBps,
            10_000
        );
        vm.prank(_roleMember(CC_ACCESS, ALLOCATOR_ROLE));
        uint256 ccReturned = StrategyManager(CC_MANAGER)
            .deallocate(
                CC_ADAPTER,
                ccPosition.collateral + 1e18,
                0,
                abi.encode(
                    ICoveredCallFundAdapter.DeallocateData({
                        action: ICoveredCallFundAdapter.DeallocateAction.NormalizeUsdc,
                        positionId: 0,
                        amount: ccState.accountedUsdc,
                        minAmountOut: policyMinimum
                    })
                )
            );
        assertEq(ccReturned, ccPosition.collateral + expectedWeth);
    }

    function _settleCspItmFallback() private {
        ICspFundAdapter.Position memory cspPosition = CspFundAdapter(CSP_ADAPTER).position(CSP_POSITION_ID);
        vm.prank(_roleMember(CSP_ACCESS, ALLOCATOR_ROLE));
        StrategyManager(CSP_MANAGER)
            .deallocate(
                CSP_ADAPTER,
                1,
                0,
                abi.encode(
                    ICspFundAdapter.DeallocateData({
                        action: ICspFundAdapter.DeallocateAction.Settle,
                        positionId: CSP_POSITION_ID,
                        amount: 0,
                        minAmountOut: 0
                    })
                )
            );
        ICspFundAdapter.Position memory awaiting = CspFundAdapter(CSP_ADAPTER).position(CSP_POSITION_ID);
        assertEq(uint256(awaiting.lifecycle), uint256(ICspFundAdapter.Lifecycle.AwaitingPhysicalDelivery));

        vm.warp(awaiting.fallbackEligibleAt);
        vm.prank(_roleMember(CSP_ACCESS, ALLOCATOR_ROLE));
        StrategyManager(CSP_MANAGER)
            .deallocate(
                CSP_ADAPTER,
                cspPosition.collateral,
                0,
                abi.encode(
                    ICspFundAdapter.DeallocateData({
                        action: ICspFundAdapter.DeallocateAction.Settle,
                        positionId: CSP_POSITION_ID,
                        amount: 0,
                        minAmountOut: 0
                    })
                )
            );
    }

    function _settleCoveredCallItmFallback(uint256 price) private {
        ICoveredCallFundAdapter.Position memory ccPosition = CoveredCallFundAdapter(CC_ADAPTER).position(CC_POSITION_ID);
        vm.prank(_roleMember(CC_ACCESS, ALLOCATOR_ROLE));
        StrategyManager(CC_MANAGER)
            .deallocate(
                CC_ADAPTER,
                1,
                0,
                abi.encode(
                    ICoveredCallFundAdapter.DeallocateData({
                        action: ICoveredCallFundAdapter.DeallocateAction.Settle,
                        positionId: CC_POSITION_ID,
                        amount: 0,
                        minAmountOut: 0
                    })
                )
            );
        ICoveredCallFundAdapter.Position memory awaiting = CoveredCallFundAdapter(CC_ADAPTER).position(CC_POSITION_ID);
        assertEq(uint256(awaiting.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.AwaitingPhysicalDelivery));

        vm.warp(awaiting.fallbackEligibleAt);
        vm.prank(_roleMember(CC_ACCESS, ALLOCATOR_ROLE));
        StrategyManager(CC_MANAGER)
            .deallocate(
                CC_ADAPTER,
                1,
                0,
                abi.encode(
                    ICoveredCallFundAdapter.DeallocateData({
                        action: ICoveredCallFundAdapter.DeallocateAction.Settle,
                        positionId: CC_POSITION_ID,
                        amount: 0,
                        minAmountOut: 0
                    })
                )
            );

        ICoveredCallFundAdapter.AdapterState memory ccState = CoveredCallFundAdapter(CC_ADAPTER).adapterState();
        uint256 expectedWeth = Math.mulDiv(ccState.accountedUsdc, 1e20, price);
        uint256 policyMinimum = Math.mulDiv(
            expectedWeth,
            10_000 - CoveredCallFundAdapter(CC_ADAPTER).adapterConfig().riskConfig.maxSwapSlippageBps,
            10_000
        );
        vm.prank(_roleMember(CC_ACCESS, ALLOCATOR_ROLE));
        StrategyManager(CC_MANAGER)
            .deallocate(
                CC_ADAPTER,
                ccPosition.collateral,
                0,
                abi.encode(
                    ICoveredCallFundAdapter.DeallocateData({
                        action: ICoveredCallFundAdapter.DeallocateAction.NormalizeUsdc,
                        positionId: 0,
                        amount: ccState.accountedUsdc,
                        minAmountOut: policyMinimum
                    })
                )
            );
    }

    function _assertBothPositionsClosedAndPrincipalReleased(
        ICspFundAdapter.Lifecycle expectedCspLifecycle,
        ICoveredCallFundAdapter.Lifecycle expectedCcLifecycle
    ) private view {
        ICspFundAdapter.Position memory cspPosition = CspFundAdapter(CSP_ADAPTER).position(CSP_POSITION_ID);
        ICoveredCallFundAdapter.Position memory ccPosition = CoveredCallFundAdapter(CC_ADAPTER).position(CC_POSITION_ID);
        ICspFundAdapter.AdapterState memory cspState = CspFundAdapter(CSP_ADAPTER).adapterState();
        ICoveredCallFundAdapter.AdapterState memory ccState = CoveredCallFundAdapter(CC_ADAPTER).adapterState();

        assertEq(uint256(cspPosition.lifecycle), uint256(expectedCspLifecycle));
        assertEq(uint256(ccPosition.lifecycle), uint256(expectedCcLifecycle));
        assertEq(cspState.activePositionCount, 0);
        assertEq(ccState.activePositionCount, 0);
        assertEq(cspState.accountedUsdc, 0);
        assertEq(cspState.accountedWeth, 0);
        assertEq(ccState.accountedUsdc, 0);
        assertEq(ccState.accountedWeth, 0);
        assertEq(ccState.activeCollateral, 0);
        assertEq(StrategyManager(CSP_MANAGER).allocatedToAdapter(CSP_ADAPTER, USDC), 0);
        assertEq(StrategyManager(CC_MANAGER).allocatedToAdapter(CC_ADAPTER, WETH), 0);
        assertEq(FundVault(CSP_VAULT).executionLockOwner(), address(0));
        assertEq(FundVault(CC_VAULT).executionLockOwner(), address(0));
        assertLt(FundVault(CSP_VAULT).activeNavWindow().validUntilBlock, block.number);
        assertLt(FundVault(CC_VAULT).activeNavWindow().validUntilBlock, block.number);
    }

    function _openNextPositions() private {
        address mm = vm.addr(MM_KEY);
        vm.prank(settler.owner());
        settler.setWhitelistedMM(mm, true);
        IMintableToken(USDC).mint(mm, 100e6);
        vm.prank(mm);
        IERC20(USDC).approve(address(settler), type(uint256).max);

        uint256 nextExpiry = _nextEligibleExpiry();
        address factoryOperator = factory.operator();

        vm.prank(factoryOperator);
        address nextPut = factory.createOToken(WETH, USDC, USDC, NEXT_STRIKE, nextExpiry, true);
        ICspFundAdapter.OpenPositionData memory cspOpen = ICspFundAdapter.OpenPositionData({
            quote: _quote(nextPut, 394_001, mm),
            signature: "",
            optionAmount: NEXT_OPTION_AMOUNT,
            collateral: NEXT_CSP_COLLATERAL
        });
        cspOpen.signature = _sign(CSP_ADAPTER, cspOpen.quote);
        vm.prank(_roleMember(CSP_ACCESS, ALLOCATOR_ROLE));
        StrategyManager(CSP_MANAGER).allocate(CSP_ADAPTER, USDC, NEXT_CSP_COLLATERAL, abi.encode(cspOpen));

        vm.prank(factoryOperator);
        address nextCall = factory.createOToken(WETH, USDC, WETH, NEXT_STRIKE, nextExpiry, false);
        ICoveredCallFundAdapter.OpenPositionData memory ccOpen = ICoveredCallFundAdapter.OpenPositionData({
            quote: _quote(nextCall, 394_002, mm),
            signature: "",
            optionAmount: NEXT_OPTION_AMOUNT,
            collateral: NEXT_CC_COLLATERAL
        });
        ccOpen.signature = _sign(CC_ADAPTER, ccOpen.quote);
        vm.prank(_roleMember(CC_ACCESS, ALLOCATOR_ROLE));
        StrategyManager(CC_MANAGER).allocate(CC_ADAPTER, WETH, NEXT_CC_COLLATERAL, abi.encode(ccOpen));
    }

    function _assertNextPositionsOpen() private view {
        ICspFundAdapter.Position memory cspNext = CspFundAdapter(CSP_ADAPTER).position(4);
        ICoveredCallFundAdapter.Position memory ccNext = CoveredCallFundAdapter(CC_ADAPTER).position(2);

        assertEq(uint256(cspNext.lifecycle), uint256(ICspFundAdapter.Lifecycle.Open));
        assertEq(cspNext.optionAmount, NEXT_OPTION_AMOUNT);
        assertEq(cspNext.collateral, NEXT_CSP_COLLATERAL);
        assertEq(uint256(ccNext.lifecycle), uint256(ICoveredCallFundAdapter.Lifecycle.Open));
        assertEq(ccNext.optionAmount, NEXT_OPTION_AMOUNT);
        assertEq(ccNext.collateral, NEXT_CC_COLLATERAL);
        assertEq(StrategyManager(CSP_MANAGER).allocatedToAdapter(CSP_ADAPTER, USDC), NEXT_CSP_COLLATERAL);
        assertEq(StrategyManager(CC_MANAGER).allocatedToAdapter(CC_ADAPTER, WETH), NEXT_CC_COLLATERAL);
        assertEq(FundVault(CSP_VAULT).executionLockOwner(), address(0));
        assertEq(FundVault(CC_VAULT).executionLockOwner(), address(0));
    }

    function _cspPreservedStateHash() private view returns (bytes32) {
        ICspFundAdapter.Position memory current = CspFundAdapter(CSP_ADAPTER).position(CSP_POSITION_ID);
        MarginVault.Vault memory protocolVault = controller.getVault(CSP_ADAPTER, current.protocolVaultId);
        FundTypes.StrategyConfig memory config = StrategyManager(CSP_MANAGER).strategyConfig(CSP_ADAPTER);
        return keccak256(
            abi.encode(
                CspFundAdapter(CSP_ADAPTER).adapterState(),
                CspFundAdapter(CSP_ADAPTER).adapterConfig(),
                current,
                protocolVault,
                StrategyManager(CSP_MANAGER).allocatedToAdapter(CSP_ADAPTER, USDC),
                config,
                FundVault(CSP_VAULT).accountedIdleAssets(),
                FundVault(CSP_VAULT).committedNav(),
                FundVault(CSP_VAULT).executionLockOwner(),
                IERC20(USDC).balanceOf(CSP_ADAPTER),
                IERC20(WETH).balanceOf(CSP_ADAPTER),
                FundAccounting(CSP_ACCOUNTING).lastReportNonce(),
                FundFlowManager(CSP_FLOW).totalPendingShares(),
                FundFlowManager(CSP_FLOW).totalClaimableShares()
            )
        );
    }

    function _ccPreservedStateHash() private view returns (bytes32) {
        ICoveredCallFundAdapter.Position memory current = CoveredCallFundAdapter(CC_ADAPTER).position(CC_POSITION_ID);
        MarginVault.Vault memory protocolVault = controller.getVault(CC_ADAPTER, current.protocolVaultId);
        FundTypes.StrategyConfig memory config = StrategyManager(CC_MANAGER).strategyConfig(CC_ADAPTER);
        return keccak256(
            abi.encode(
                CoveredCallFundAdapter(CC_ADAPTER).adapterState(),
                CoveredCallFundAdapter(CC_ADAPTER).adapterConfig(),
                current,
                protocolVault,
                StrategyManager(CC_MANAGER).allocatedToAdapter(CC_ADAPTER, WETH),
                config,
                FundVault(CC_VAULT).accountedIdleAssets(),
                FundVault(CC_VAULT).committedNav(),
                FundVault(CC_VAULT).executionLockOwner(),
                IERC20(WETH).balanceOf(CC_ADAPTER),
                IERC20(USDC).balanceOf(CC_ADAPTER),
                FundAccounting(CC_ACCOUNTING).lastReportNonce(),
                FundFlowManager(CC_FLOW).totalPendingShares(),
                FundFlowManager(CC_FLOW).totalClaimableShares()
            )
        );
    }

    function _quote(address oToken, uint256 quoteId, address mm) private view returns (BatchSettler.Quote memory) {
        return BatchSettler.Quote({
            oToken: oToken,
            bidPrice: NEXT_BID_PRICE,
            deadline: block.timestamp + 1 hours,
            quoteId: quoteId,
            maxAmount: NEXT_OPTION_AMOUNT,
            makerNonce: settler.makerNonce(mm)
        });
    }

    function _sign(address owner, BatchSettler.Quote memory quote) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
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

    function _nextEligibleExpiry() private view returns (uint256) {
        uint256 dayStart = block.timestamp - (block.timestamp % 1 days);
        return dayStart + 2 days + 8 hours;
    }

    function _roleMember(address accessManager, uint64 role) private view returns (address) {
        FundAccessManager manager = FundAccessManager(accessManager);
        assertGt(manager.roleMemberCount(role), 0);
        return manager.roleMemberAt(role, 0);
    }
}
