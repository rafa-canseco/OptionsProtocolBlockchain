// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Whitelist.sol";

/**
 * @title LazyCreate2MainnetForkTest
 * @notice B1N-389 verification against the deployed Base mainnet protocol.
 *
 * Run locally:
 *   forge test --match-contract LazyCreate2MainnetForkTest \
 *     --fork-url "$BASE_RPC_URL" -vv
 *
 * The test is skipped without a Base mainnet fork. All role changes, balances,
 * series creation, and execution exist only in Foundry's ephemeral fork.
 */
contract LazyCreate2MainnetForkTest is Test {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    Controller internal constant CONTROLLER = Controller(0x2Ab6D1c41f0863Bc2324b392f1D8cF073cF42624);
    MarginPool internal constant MARGIN_POOL = MarginPool(0xa1e04873F6d112d84824C88c9D6937bE38811657);
    OTokenFactory internal constant FACTORY = OTokenFactory(0x0701b7De84eC23a3CaDa763bCA7A9E324486F6D7);
    Whitelist internal constant WHITELIST = Whitelist(0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A);
    BatchSettler internal constant SETTLER = BatchSettler(0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B);

    uint256 internal constant MM_KEY = 0xB1389;
    uint256 internal constant AMOUNT = 1e8;
    uint256 internal constant BID_PRICE = 50e6;
    uint256 internal constant STRIKE_PRICE = 1_234_567e8;

    address internal user = makeAddr("lazy-create2-user");
    address internal mm;
    uint256 internal expiry;

    function setUp() public {
        if (block.chainid != 8453) return;

        mm = vm.addr(MM_KEY);
        uint256 candidate = block.timestamp + 7 days;
        expiry = candidate - (candidate % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        vm.prank(SETTLER.owner());
        SETTLER.setWhitelistedMM(mm, true);

        uint256 collateral = (AMOUNT * STRIKE_PRICE) / 1e10;
        deal(USDC, user, collateral);
        deal(USDC, mm, 1_000_000e6);

        vm.prank(user);
        IERC20(USDC).approve(address(MARGIN_POOL), type(uint256).max);
        vm.prank(mm);
        IERC20(USDC).approve(address(SETTLER), type(uint256).max);
    }

    function test_virtualSeries_materializesAtPredictionAndExecutesExistingOrder() public {
        if (block.chainid != 8453) return;

        address predicted = FACTORY.getTargetOTokenAddress(WETH, USDC, USDC, STRIKE_PRICE, expiry, true);
        assertFalse(FACTORY.isOToken(predicted), "fixture series already exists");

        vm.recordLogs();
        vm.prank(FACTORY.operator());
        address created = FACTORY.createOToken(WETH, USDC, USDC, STRIKE_PRICE, expiry, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(created, predicted, "CREATE2 prediction mismatch");
        assertTrue(FACTORY.isOToken(predicted), "factory readiness missing");
        assertTrue(WHITELIST.isWhitelistedOToken(predicted), "whitelist readiness missing");
        assertTrue(_sawCreatedEvent(logs, predicted), "OTokenCreated address mismatch");

        BatchSettler.Quote memory quote = BatchSettler.Quote({
            oToken: predicted,
            bidPrice: BID_PRICE,
            deadline: block.timestamp + 5 minutes,
            quoteId: 389,
            maxAmount: AMOUNT,
            makerNonce: SETTLER.makerNonce(mm)
        });
        bytes32 digest = SETTLER.hashQuote(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        uint256 collateral = (AMOUNT * STRIKE_PRICE) / 1e10;

        vm.prank(user);
        uint256 vaultId = SETTLER.executeOrder(quote, signature, AMOUNT, collateral);

        assertEq(CONTROLLER.vaultCount(user), 1, "user vault not opened");
        assertEq(vaultId, 1, "unexpected vault id");
        assertEq(SETTLER.mmOTokenBalance(mm, predicted), AMOUNT, "MM fill not recorded");
    }

    function _sawCreatedEvent(Vm.Log[] memory logs, address predicted) internal pure returns (bool) {
        bytes32 signature = keccak256("OTokenCreated(address,address,address,address,uint256,uint256,bool)");
        bytes32 indexedAddress = bytes32(uint256(uint160(predicted)));
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(FACTORY) && logs[i].topics.length >= 2 && logs[i].topics[0] == signature
                    && logs[i].topics[1] == indexedAddress
            ) return true;
        }
        return false;
    }
}
