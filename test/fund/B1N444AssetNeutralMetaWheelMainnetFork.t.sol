// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {
    AssetNeutralCoveredCallFundAdapterV2,
    AssetNeutralCspFundAdapterV2,
    AssetNeutralOptionsFundAdapterV2
} from "../../src/fund/AssetNeutralOptionsFundAdapterV2.sol";
import {
    IAssetNeutralOptionsAdapterOperationsV2 as IAdapterOps
} from "../../src/fund/interfaces/IAssetNeutralOptionsAdapterOperationsV2.sol";
import {
    AssetNeutralCspWheelChildLaneV2,
    AssetNeutralCoveredCallWheelChildLaneV2,
    AssetNeutralMetaWheelCoordinatorV2,
    AssetNeutralWheelChildLaneV2
} from "../../src/fund/AssetNeutralMetaWheelV2.sol";

contract B1N444AuthorizedLegacyUups is Initializable, UUPSUpgradeable {
    address public owner;
    uint256 public value;

    function initialize(address owner_, uint256 value_) external initializer {
        owner = owner_;
        value = value_;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == owner);
    }
}

contract B1N444MainnetFundBinding {
    address public strategyManager;
    address public asset;

    function bind(address manager_, address asset_) external {
        require(strategyManager == address(0));
        strategyManager = manager_;
        asset = asset_;
    }
}

contract B1N444MainnetManagerBinding {
    address public fund;

    function bind(address fund_) external {
        require(fund == address(0));
        fund = fund_;
    }
}

/// @notice Pinned Base-mainnet proof that LBTC-wheel proxy initialization remains impossible on chain 8453.
contract B1N444AssetNeutralMetaWheelMainnetForkTest is Test {
    bytes32 private constant LBTC8_POLICY_HASH = 0xa346ca8b9d7988dd0a4212417b1ca38e61d744213f748f426ba9e61f2c70a180;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockERC20 private underlying;
    MockERC20 private settlement;
    AccessManager private authority;
    B1N444MainnetFundBinding private fund;
    B1N444MainnetManagerBinding private manager;
    B1N444MainnetFundBinding private callFund;
    B1N444MainnetManagerBinding private callManager;

    function setUp() public {
        assertEq(block.chainid, 8_453);
        assertEq(block.number, 50_104_319);
        underlying = new MockERC20("LBTC", "LBTC", 8);
        settlement = new MockERC20("USDC", "USDC", 6);
        authority = new AccessManager(address(this));
        fund = new B1N444MainnetFundBinding();
        manager = new B1N444MainnetManagerBinding();
        fund.bind(address(manager), address(settlement));
        manager.bind(address(fund));
        callFund = new B1N444MainnetFundBinding();
        callManager = new B1N444MainnetManagerBinding();
        callFund.bind(address(callManager), address(underlying));
        callManager.bind(address(callFund));
    }

    function test_authorizedLegacyUupsCannotRouteToLbtcImplementationsOnBaseMainnet() public {
        _assertAuthorizedInboundUpgradeRejected(address(new AssetNeutralMetaWheelCoordinatorV2()));
        _assertAuthorizedInboundUpgradeRejected(address(new AssetNeutralCspWheelChildLaneV2()));
        _assertAuthorizedInboundUpgradeRejected(address(new AssetNeutralCoveredCallWheelChildLaneV2()));
        _assertAuthorizedInboundUpgradeRejected(address(new AssetNeutralCspFundAdapterV2()));
        _assertAuthorizedInboundUpgradeRejected(address(new AssetNeutralCoveredCallFundAdapterV2()));
    }

    function _assertAuthorizedInboundUpgradeRejected(address lbtcImplementation) private {
        address owner = address(0xA11CE);
        B1N444AuthorizedLegacyUups legacy = B1N444AuthorizedLegacyUups(
            address(
                new ERC1967Proxy(
                    address(new B1N444AuthorizedLegacyUups()),
                    abi.encodeCall(B1N444AuthorizedLegacyUups.initialize, (owner, uint256(444)))
                )
            )
        );
        bytes32 implementationBefore = vm.load(address(legacy), ERC1967_IMPLEMENTATION_SLOT);
        bytes32 proxyCodehashBefore = address(legacy).codehash;

        vm.expectRevert(
            abi.encodeWithSelector(AssetNeutralMetaWheelCoordinatorV2.UnsupportedChain.selector, uint256(8_453))
        );
        UUPSUpgradeable(lbtcImplementation).proxiableUUID();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, lbtcImplementation));
        legacy.upgradeToAndCall(lbtcImplementation, "");

        assertEq(vm.load(address(legacy), ERC1967_IMPLEMENTATION_SLOT), implementationBefore);
        assertEq(address(legacy).codehash, proxyCodehashBefore);
        assertEq(legacy.owner(), owner);
        assertEq(legacy.value(), 444);
    }

    function test_baseMainnetCannotInitializeEitherAdapter() public {
        AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory cspParams =
            _adapterParams(address(fund), address(manager));
        address cspImplementation = address(new AssetNeutralCspFundAdapterV2());
        vm.expectRevert(
            abi.encodeWithSelector(AssetNeutralOptionsFundAdapterV2.UnsupportedChain.selector, uint256(8_453))
        );
        new ERC1967Proxy(cspImplementation, abi.encodeCall(AssetNeutralCspFundAdapterV2.initialize, (cspParams)));

        AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory callParams =
            _adapterParams(address(callFund), address(callManager));
        address callImplementation = address(new AssetNeutralCoveredCallFundAdapterV2());
        vm.expectRevert(
            abi.encodeWithSelector(AssetNeutralOptionsFundAdapterV2.UnsupportedChain.selector, uint256(8_453))
        );
        new ERC1967Proxy(
            callImplementation, abi.encodeCall(AssetNeutralCoveredCallFundAdapterV2.initialize, (callParams))
        );
    }

    function test_baseMainnetCannotInitializeCoordinator() public {
        address implementation = address(new AssetNeutralMetaWheelCoordinatorV2());
        vm.expectRevert(
            abi.encodeWithSelector(AssetNeutralMetaWheelCoordinatorV2.UnsupportedChain.selector, uint256(8_453))
        );
        new ERC1967Proxy(
            implementation,
            abi.encodeCall(
                AssetNeutralMetaWheelCoordinatorV2.initialize,
                (AssetNeutralMetaWheelCoordinatorV2.InitializeParams(
                        address(fund),
                        address(manager),
                        address(underlying),
                        address(settlement),
                        address(authority),
                        4,
                        4,
                        0,
                        LBTC8_POLICY_HASH
                    ))
            )
        );
    }

    function test_baseMainnetCannotInitializeCspLane() public {
        AssetNeutralWheelChildLaneV2.InitializeParams memory p = _laneParams();
        address implementation = address(new AssetNeutralCspWheelChildLaneV2());
        vm.expectRevert(abi.encodeWithSelector(AssetNeutralWheelChildLaneV2.UnsupportedChain.selector, uint256(8_453)));
        new ERC1967Proxy(implementation, abi.encodeCall(AssetNeutralCspWheelChildLaneV2.initialize, (p)));
    }

    function test_baseMainnetCannotInitializeCoveredCallLane() public {
        AssetNeutralWheelChildLaneV2.InitializeParams memory p = _laneParams();
        address implementation = address(new AssetNeutralCoveredCallWheelChildLaneV2());
        vm.expectRevert(abi.encodeWithSelector(AssetNeutralWheelChildLaneV2.UnsupportedChain.selector, uint256(8_453)));
        new ERC1967Proxy(implementation, abi.encodeCall(AssetNeutralCoveredCallWheelChildLaneV2.initialize, (p)));
    }

    function _adapterParams(address fund_, address manager_)
        private
        view
        returns (AssetNeutralOptionsFundAdapterV2.InitializeParamsV2 memory)
    {
        return AssetNeutralOptionsFundAdapterV2.InitializeParamsV2(
            fund_,
            manager_,
            address(this),
            address(underlying),
            address(settlement),
            address(this),
            500,
            address(authority),
            IAdapterOps.RiskConfigV2(1 hours, 3 days, 1 hours, 1, 500, 4, 10_000, 1, 1e16, 1e18, 1e18, 0)
        );
    }

    function _laneParams() private view returns (AssetNeutralWheelChildLaneV2.InitializeParams memory) {
        return AssetNeutralWheelChildLaneV2.InitializeParams(
            address(this),
            address(0),
            address(underlying),
            address(settlement),
            address(authority),
            1e18,
            0,
            LBTC8_POLICY_HASH
        );
    }
}
