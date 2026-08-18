// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../src/core/AddressBook.sol";
import "../src/core/Controller.sol";
import "../src/core/MarginPool.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Whitelist.sol";
import "../src/vaults/CspBatchSettler.sol";

/**
 * @title LazyCreate2BaseSepoliaForkTest
 * @notice B1N-389 verification against the active Base Sepolia staging stack.
 *
 * The active core addresses are loaded from deployments-csp-base-sepolia.json
 * and cross-checked against the reconciled B1N-352 trust boundary. Before
 * exercising the lazy path, setUp fails closed unless the proxy implementations,
 * codehashes, AddressBook wiring, assets, and product whitelist all agree.
 *
 * Run locally:
 *   forge test --match-contract LazyCreate2BaseSepoliaForkTest \
 *     --fork-url https://sepolia.base.org -vv
 *
 * The test is skipped without a Base Sepolia fork. All impersonation, balances,
 * MM authorization, series creation, and execution exist only in Foundry's
 * ephemeral fork and never mutate the deployed testnet.
 */
contract LazyCreate2BaseSepoliaForkTest is Test {
    string internal constant MANIFEST_PATH = "deployments-csp-base-sepolia.json";
    string internal constant TRUST_MANIFEST_PATH = "deployments/base-sepolia/b1n-352/v2/manifest.json";

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant MM_KEY = 0xB1389;
    uint256 internal constant AMOUNT = 1e8;
    uint256 internal constant BID_PRICE = 50e6;
    uint256 internal constant STRIKE_PRICE = 1_234_567e8;

    AddressBook internal addressBook;
    Controller internal controller;
    MarginPool internal marginPool;
    OTokenFactory internal factory;
    Whitelist internal whitelist;
    CspBatchSettler internal settler;
    address internal oracle;
    address internal leth;
    address internal lusd;
    address internal deployer;
    uint256 internal protocolFeeBps;
    uint256 internal swapFeeTier;

    address internal user = makeAddr("lazy-create2-base-sepolia-user");
    address internal mm;
    uint256 internal expiry;

    function setUp() public {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) return;

        string memory manifest = vm.readFile(MANIFEST_PATH);
        assertEq(vm.parseJsonUint(manifest, ".network.chainId"), BASE_SEPOLIA_CHAIN_ID, "manifest chain mismatch");
        assertEq(vm.parseJsonString(manifest, ".network.name"), "base-sepolia", "manifest network mismatch");

        addressBook = AddressBook(vm.parseJsonAddress(manifest, ".contracts.addressBook"));
        controller = Controller(vm.parseJsonAddress(manifest, ".contracts.controller"));
        marginPool = MarginPool(vm.parseJsonAddress(manifest, ".contracts.marginPool"));
        factory = OTokenFactory(vm.parseJsonAddress(manifest, ".contracts.oTokenFactory"));
        whitelist = Whitelist(vm.parseJsonAddress(manifest, ".contracts.whitelist"));
        settler = CspBatchSettler(vm.parseJsonAddress(manifest, ".contracts.cspBatchSettler"));
        oracle = vm.parseJsonAddress(manifest, ".contracts.oracle");
        leth = vm.parseJsonAddress(manifest, ".tokens.mockWeth.address");
        lusd = vm.parseJsonAddress(manifest, ".tokens.mockUsdc.address");
        deployer = vm.parseJsonAddress(manifest, ".deployment.deployer");
        protocolFeeBps = vm.parseJsonUint(manifest, ".caps.protocolFeeBps");
        swapFeeTier = vm.parseJsonUint(manifest, ".caps.swapFeeTier");

        _assertManifestAgreement(manifest);
        _assertCoherentManifestStack();

        mm = vm.addr(MM_KEY);
        uint256 candidate = block.timestamp + 7 days;
        expiry = candidate - (candidate % 1 days) + 8 hours;
        if (expiry <= block.timestamp) expiry += 1 days;

        vm.prank(settler.owner());
        settler.setWhitelistedMM(mm, true);

        uint256 collateral = (AMOUNT * STRIKE_PRICE) / 1e10;
        deal(lusd, user, collateral);
        deal(lusd, mm, 1_000_000e6);

        vm.prank(user);
        IERC20(lusd).approve(address(marginPool), type(uint256).max);
        vm.prank(mm);
        IERC20(lusd).approve(address(settler), type(uint256).max);
    }

    function test_manifestTrustAnchors_matchForkedStagingStack() public view {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) return;
        _assertManifestAgreement(vm.readFile(MANIFEST_PATH));
        _assertCoherentManifestStack();
    }

    function test_virtualSeries_materializesAtPredictionAndExecutesExistingOrder() public {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) return;

        address predicted = factory.getTargetOTokenAddress(leth, lusd, lusd, STRIKE_PRICE, expiry, true);
        assertEq(predicted.code.length, 0, "fixture prediction already has code");
        assertFalse(factory.isOToken(predicted), "fixture series already exists");

        vm.recordLogs();
        vm.prank(factory.operator());
        address created = factory.createOToken(leth, lusd, lusd, STRIKE_PRICE, expiry, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(created, predicted, "CREATE2 prediction mismatch");
        assertGt(predicted.code.length, 0, "materialized series has no code");
        assertTrue(factory.isOToken(predicted), "factory readiness missing");
        assertTrue(whitelist.isWhitelistedOToken(predicted), "whitelist readiness missing");
        assertTrue(_sawCreatedEvent(logs, predicted), "OTokenCreated address mismatch");

        CspBatchSettler.Quote memory quote = CspBatchSettler.Quote({
            oToken: predicted,
            bidPrice: BID_PRICE,
            deadline: block.timestamp + 5 minutes,
            quoteId: 84532_389,
            maxAmount: AMOUNT,
            makerNonce: settler.makerNonce(mm)
        });
        bytes32 digest = settler.hashQuoteFor(user, quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(MM_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        uint256 collateral = (AMOUNT * STRIKE_PRICE) / 1e10;

        vm.prank(user);
        uint256 vaultId = settler.executeOrder(quote, signature, AMOUNT, collateral);

        assertEq(controller.vaultCount(user), 1, "user vault not opened");
        assertEq(vaultId, 1, "unexpected vault id");
        assertEq(settler.mmOTokenBalance(mm, predicted), AMOUNT, "MM fill not recorded");
    }

    function _assertCoherentManifestStack() internal view {
        assertGt(address(addressBook).code.length, 0, "AddressBook has no code");
        assertGt(address(controller).code.length, 0, "Controller has no code");
        assertGt(address(marginPool).code.length, 0, "MarginPool has no code");
        assertGt(address(factory).code.length, 0, "OTokenFactory has no code");
        assertGt(address(whitelist).code.length, 0, "Whitelist has no code");
        assertGt(address(settler).code.length, 0, "BatchSettler has no code");
        assertGt(oracle.code.length, 0, "Oracle has no code");
        assertGt(leth.code.length, 0, "LETH has no code");
        assertGt(lusd.code.length, 0, "LUSD has no code");

        assertEq(addressBook.controller(), address(controller), "AddressBook Controller mismatch");
        assertEq(addressBook.marginPool(), address(marginPool), "AddressBook MarginPool mismatch");
        assertEq(addressBook.oTokenFactory(), address(factory), "AddressBook Factory mismatch");
        assertEq(addressBook.whitelist(), address(whitelist), "AddressBook Whitelist mismatch");
        assertEq(addressBook.batchSettler(), address(settler), "AddressBook Settler mismatch");
        assertEq(addressBook.oracle(), oracle, "AddressBook Oracle mismatch");

        assertEq(address(controller.addressBook()), address(addressBook), "Controller AddressBook mismatch");
        assertEq(address(marginPool.addressBook()), address(addressBook), "MarginPool AddressBook mismatch");
        assertEq(address(factory.addressBook()), address(addressBook), "Factory AddressBook mismatch");
        assertEq(address(whitelist.addressBook()), address(addressBook), "Whitelist AddressBook mismatch");
        assertEq(address(settler.addressBook()), address(addressBook), "Settler AddressBook mismatch");

        assertTrue(whitelist.isWhitelistedUnderlying(leth), "LETH underlying not whitelisted");
        assertTrue(whitelist.isWhitelistedCollateral(lusd), "LUSD collateral not whitelisted");
        assertTrue(whitelist.isProductWhitelisted(leth, lusd, lusd, true), "LETH/LUSD put not whitelisted");
        assertEq(IERC20Metadata(leth).decimals(), 18, "unexpected LETH decimals");
        assertEq(IERC20Metadata(lusd).decimals(), 6, "unexpected LUSD decimals");
        assertEq(addressBook.owner(), deployer, "AddressBook owner mismatch");
        assertEq(factory.operator(), deployer, "Factory operator mismatch");
        assertEq(settler.owner(), deployer, "Settler owner mismatch");
        assertEq(settler.protocolFeeBps(), protocolFeeBps, "protocol fee mismatch");
        assertEq(settler.swapFeeTier(), swapFeeTier, "swap fee tier mismatch");
    }

    function _assertManifestAgreement(string memory deploymentManifest) internal view {
        string memory trustManifest = vm.readFile(TRUST_MANIFEST_PATH);
        assertEq(vm.parseJsonString(trustManifest, ".deploymentStatus"), "DEPLOYED", "trust deployment not final");
        assertEq(
            vm.parseJsonUint(trustManifest, ".network.chainId"), BASE_SEPOLIA_CHAIN_ID, "trust manifest chain mismatch"
        );
        assertEq(
            vm.parseJsonAddress(trustManifest, ".v1Boundary.accountingAsset"), lusd, "trust manifest LUSD mismatch"
        );
        assertEq(vm.parseJsonAddress(trustManifest, ".v1Boundary.weth"), leth, "trust manifest LETH mismatch");

        _assertProxyAnchor(trustManifest, ".v1Boundary.addressBook", address(addressBook));
        _assertProxyAnchor(trustManifest, ".v1Boundary.controller", address(controller));
        _assertProxyAnchor(trustManifest, ".v1Boundary.marginPool", address(marginPool));
        _assertProxyAnchor(trustManifest, ".v1Boundary.oTokenFactory", address(factory));
        _assertProxyAnchor(trustManifest, ".v1Boundary.oracle", oracle);
        _assertProxyAnchor(trustManifest, ".v1Boundary.whitelist", address(whitelist));
        _assertProxyAnchor(trustManifest, ".v1Boundary.batchSettler", address(settler));

        assertEq(
            vm.parseJsonAddress(deploymentManifest, ".implementations.addressBook"),
            _implementationOf(address(addressBook)),
            "deployment AddressBook implementation mismatch"
        );
        assertEq(
            vm.parseJsonAddress(deploymentManifest, ".implementations.controller"),
            _implementationOf(address(controller)),
            "deployment Controller implementation mismatch"
        );
        assertEq(
            vm.parseJsonAddress(deploymentManifest, ".implementations.marginPool"),
            _implementationOf(address(marginPool)),
            "deployment MarginPool implementation mismatch"
        );
        assertEq(
            vm.parseJsonAddress(deploymentManifest, ".implementations.oTokenFactory"),
            _implementationOf(address(factory)),
            "deployment Factory implementation mismatch"
        );
        assertEq(
            vm.parseJsonAddress(deploymentManifest, ".implementations.oracle"),
            _implementationOf(oracle),
            "deployment Oracle implementation mismatch"
        );
        assertEq(
            vm.parseJsonAddress(deploymentManifest, ".implementations.whitelist"),
            _implementationOf(address(whitelist)),
            "deployment Whitelist implementation mismatch"
        );
        assertEq(
            vm.parseJsonAddress(deploymentManifest, ".implementations.cspBatchSettler"),
            _implementationOf(address(settler)),
            "deployment Settler implementation mismatch"
        );
    }

    function _assertProxyAnchor(string memory trustManifest, string memory path, address proxy) internal view {
        assertEq(vm.parseJsonAddress(trustManifest, string.concat(path, ".proxy")), proxy, "proxy trust mismatch");
        address implementation = _implementationOf(proxy);
        assertEq(
            vm.parseJsonAddress(trustManifest, string.concat(path, ".implementation")),
            implementation,
            "implementation trust mismatch"
        );
        assertEq(
            vm.parseJsonBytes32(trustManifest, string.concat(path, ".implementationCodehash")),
            implementation.codehash,
            "implementation codehash mismatch"
        );
        assertTrue(vm.parseJsonBool(trustManifest, string.concat(path, ".unchanged")), "proxy not reconciled");
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _sawCreatedEvent(Vm.Log[] memory logs, address predicted) internal view returns (bool) {
        bytes32 signature = keccak256("OTokenCreated(address,address,address,address,uint256,uint256,bool)");
        bytes32 indexedAddress = bytes32(uint256(uint160(predicted)));
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(factory) && logs[i].topics.length >= 2 && logs[i].topics[0] == signature
                    && logs[i].topics[1] == indexedAddress
            ) return true;
        }
        return false;
    }
}
