// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AssetNeutralCspWheelChildLaneV2,
    AssetNeutralCoveredCallWheelChildLaneV2,
    AssetNeutralMetaWheelCoordinatorV2
} from "../../src/fund/AssetNeutralMetaWheelV2.sol";
import {WheelManagedOperationDispatcher} from "../../src/fund/libraries/WheelManagedOperationDispatcher.sol";
import {B1N444AssetNeutralMetaWheelSecurityTest} from "./B1N444AssetNeutralMetaWheelSecurity.t.sol";
import {B1N443LBTCMetaWheelTest} from "./B1N443LBTCMetaWheel.t.sol";

interface IB1N444UupsUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @notice Pinned Base Sepolia readbacks for the B1N-444 LBTC wheel release boundary.
/// @dev The test deploys only ephemeral fork-local implementations and proves the existing ETH stack code is unchanged.
contract B1N444AssetNeutralMetaWheelForkTest is Test {
    uint256 internal constant PINNED_BLOCK = 45_614_849;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal constant LBTC = 0x39fA11EbBE82699Fd9F79C566D7384064571d2b4;
    address internal constant USDC = 0xAB51a471493832C1D70cef8ff937A850cf37c860;

    bytes32 internal constant MOCK_ERC20_CODEHASH = 0x599a6b80cccf2c7082103129c3725529a49d37b569dc0ecc031f0444b0ce0fff;
    bytes32 internal constant EXISTING_ETH_PROXY_CODEHASH =
        0x8fe6e1498a3a26da266dcc51fdd7731c0fb33355713bd01574ed5c6574a98637;

    address internal constant ETH_FUND_VAULT = 0x53e38Baf2fC55259729085b7542BFF066F6a509e;
    address internal constant ETH_STRATEGY_MANAGER = 0xfC28237145596D4E1dfD28B80e186EFC09A1F988;
    address internal constant ETH_CSP_ADAPTER = 0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3;

    address[7] internal existingEthStack = [
        0x033d9d37Baf83dBc71935239b6fA22a6905dbaa0,
        0xD52EFbBaA1b02BA65A7f0A1604A5dFb4C4dB1572,
        0xb94D6270B336dca566C2077d50c2C50F06398cB8,
        0xeEab53b8022C32349A80C8d905492EBa6b2deaE9,
        0xF95CC4aED4a0bD68e0F1BE7c779BC281189F8187,
        0x193ED89eB64d0179b4dB08E87E541b7b3c30002A,
        0xe0Ca66a93341eB0af0C136651c8B57C187aa60Ab
    ];

    function test_pinnedLbtcAssetsDispatcherAndExistingEthSnapshot() public {
        assertEq(block.chainid, 84_532);
        assertEq(block.number, PINNED_BLOCK);
        assertEq(LBTC.codehash, MOCK_ERC20_CODEHASH);
        assertEq(USDC.codehash, MOCK_ERC20_CODEHASH);
        assertEq(IERC20Metadata(LBTC).decimals(), 8);
        assertEq(IERC20Metadata(USDC).decimals(), 6);

        bytes32 ethProductBefore = _ethProductSnapshot();
        bytes32[7] memory beforeHashes;
        for (uint256 i; i < existingEthStack.length; ++i) {
            beforeHashes[i] = existingEthStack[i].codehash;
            assertEq(beforeHashes[i], EXISTING_ETH_PROXY_CODEHASH);
        }

        AssetNeutralMetaWheelCoordinatorV2 coordinator = new AssetNeutralMetaWheelCoordinatorV2();
        AssetNeutralCspWheelChildLaneV2 cspLane = new AssetNeutralCspWheelChildLaneV2();
        AssetNeutralCoveredCallWheelChildLaneV2 callLane = new AssetNeutralCoveredCallWheelChildLaneV2();

        assertGt(address(WheelManagedOperationDispatcher).code.length, 0);
        assertTrue(address(WheelManagedOperationDispatcher).codehash != bytes32(0));
        assertLt(address(coordinator).code.length, 24_576);
        assertLt(address(cspLane).code.length, 24_576);
        assertLt(address(callLane).code.length, 24_576);
        assertLt(vm.getDeployedCode("AssetNeutralMetaWheelV2.sol:AssetNeutralMetaWheelValuatorV2").length, 24_576);

        for (uint256 i; i < existingEthStack.length; ++i) {
            assertEq(existingEthStack[i].codehash, beforeHashes[i]);
        }
        assertEq(_ethProductSnapshot(), ethProductBefore);
    }

    function test_unauthorizedCannotRouteLbtcImplementationThroughExistingEthFundProxy() public {
        assertEq(block.chainid, 84_532);
        bytes32 productBefore = _ethProductSnapshot();
        bytes32 implementationBefore = vm.load(ETH_FUND_VAULT, ERC1967_IMPLEMENTATION_SLOT);
        bytes32 proxyCodehashBefore = ETH_FUND_VAULT.codehash;
        address lbtcImplementation = address(new AssetNeutralMetaWheelCoordinatorV2());

        vm.prank(address(0xB1A444));
        vm.expectRevert();
        IB1N444UupsUpgrade(ETH_FUND_VAULT).upgradeToAndCall(lbtcImplementation, "");

        assertEq(vm.load(ETH_FUND_VAULT, ERC1967_IMPLEMENTATION_SLOT), implementationBefore);
        assertEq(ETH_FUND_VAULT.codehash, proxyCodehashBefore);
        assertEq(_ethProductSnapshot(), productBefore);
    }

    function _ethProductSnapshot() private view returns (bytes32) {
        assertGt(ETH_FUND_VAULT.code.length, 0);
        assertGt(ETH_STRATEGY_MANAGER.code.length, 0);
        assertGt(ETH_CSP_ADAPTER.code.length, 0);
        return keccak256(
            abi.encode(
                ETH_FUND_VAULT.codehash,
                ETH_STRATEGY_MANAGER.codehash,
                ETH_CSP_ADAPTER.codehash,
                _read(ETH_FUND_VAULT, bytes4(keccak256("asset()"))),
                _read(ETH_FUND_VAULT, bytes4(keccak256("strategyManager()"))),
                _read(ETH_FUND_VAULT, bytes4(keccak256("depositsPaused()"))),
                _read(ETH_FUND_VAULT, bytes4(keccak256("totalAssets()"))),
                _read(ETH_STRATEGY_MANAGER, bytes4(keccak256("fund()"))),
                _read(ETH_CSP_ADAPTER, bytes4(keccak256("fund()"))),
                _read(ETH_CSP_ADAPTER, bytes4(keccak256("strategyManager()"))),
                _read(ETH_CSP_ADAPTER, bytes4(keccak256("positionStateHash()")))
            )
        );
    }

    function _read(address target, bytes4 selector) private view returns (bytes memory data) {
        (bool ok, bytes memory result) = target.staticcall(abi.encodeWithSelector(selector));
        assertTrue(ok);
        assertGt(result.length, 0);
        return result;
    }
}

/// @dev Re-runs the corrected real two-phase graph, exact same-kind valuators, UUPS and authorization tests on the pin.
contract B1N444CorrectiveGraphForkTest is B1N444AssetNeutralMetaWheelSecurityTest {}

/// @dev Re-runs the canonical floor call-away regression and parent-domain tests on the pinned fork.
contract B1N444CorrectiveLifecycleForkTest is B1N443LBTCMetaWheelTest {}
