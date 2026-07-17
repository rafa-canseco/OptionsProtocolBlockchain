// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../src/core/BatchSettler.sol";
import "../src/core/Controller.sol";
import "../src/core/OToken.sol";
import "../src/core/OTokenFactory.sol";
import "../src/core/Oracle.sol";
import "../src/mocks/MockChainlinkFeed.sol";
import "../src/mocks/MockERC20.sol";
import "../src/vaults/CspBatchSettler.sol";
import "../src/vaults/EthCspVault.sol";

contract SmokeCspVaultBaseSepolia is Script {
    address private constant DEPLOYER = 0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382;
    address private constant MOCK_USDC = 0xAB51a471493832C1D70cef8ff937A850cf37c860;
    address private constant MOCK_WETH = 0x8A6Aa2304797898d46eC1d342Fedc817D3a973B6;
    address private constant MOCK_ETH_FEED = 0x08BE9b11ac8bbdeF7a53E4C05F5f7B76c3E441Ad;
    address private constant CONTROLLER = 0xD52EFbBaA1b02BA65A7f0A1604A5dFb4C4dB1572;
    address private constant FACTORY = 0x193ED89eB64d0179b4dB08E87E541b7b3c30002A;
    address private constant ORACLE = 0xF95CC4aED4a0bD68e0F1BE7c779BC281189F8187;
    address private constant CSP_SETTLER = 0xb94D6270B336dca566C2077d50c2C50F06398cB8;
    address private constant CSP_VAULT = 0xcf2c5b2e065bB7ADD2a29ed4d3A61910e6a59645;

    uint256 private constant DEPOSIT = 1_000e6;
    uint256 private constant OPTION_AMOUNT = 1e6; // 0.01 WETH at 8 oToken decimals.
    uint256 private constant OTM_STRIKE = 2_000e8;
    uint256 private constant PHYSICAL_STRIKE = 2_200e8;
    uint256 private constant DEFAULT_STRIKE = 2_300e8;
    uint256 private constant EXPIRY_PRICE = 2_100e8;
    uint256 private constant BID_PRICE = 1e6;

    MockERC20 private constant usdc = MockERC20(MOCK_USDC);
    MockERC20 private constant weth = MockERC20(MOCK_WETH);
    MockChainlinkFeed private constant feed = MockChainlinkFeed(MOCK_ETH_FEED);
    Controller private constant controller = Controller(CONTROLLER);
    OTokenFactory private constant factory = OTokenFactory(FACTORY);
    Oracle private constant oracle = Oracle(ORACLE);
    CspBatchSettler private constant settler = CspBatchSettler(CSP_SETTLER);
    EthCspVault private constant vault = EthCspVault(CSP_VAULT);

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");

        bytes32 phase = keccak256(bytes(vm.envString("CSP_SMOKE_PHASE")));
        if (phase == keccak256("OPEN")) {
            uint256 deployerKey = vm.envUint("PRIVATE_KEY");
            require(vm.addr(deployerKey) == DEPLOYER, "PRIVATE_KEY is not the B1N-336 deployer");
            _open(deployerKey);
        } else if (phase == keccak256("SETTLE")) {
            _settle();
        } else if (phase == keccak256("PAUSE")) {
            _setFullPause(true);
        } else if (phase == keccak256("UNPAUSE")) {
            _setFullPause(false);
        } else if (phase == keccak256("FINALIZE")) {
            _finalize();
        } else {
            revert("unknown CSP_SMOKE_PHASE");
        }
    }

    function _startBroadcast() private {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (deployerKey == 0) {
            vm.startBroadcast(DEPLOYER);
            return;
        }
        require(vm.addr(deployerKey) == DEPLOYER, "PRIVATE_KEY is not the B1N-336 deployer");
        vm.startBroadcast(deployerKey);
    }

    function _open(uint256 deployerKey) private {
        require(vault.batchCount() == 0 && vault.totalShares() == 0, "OPEN already executed");

        uint256 expiry = _nextExpiry();
        require(expiry >= block.timestamp + 1 hours, "expiry violates strategy delay");

        vm.startBroadcast(deployerKey);
        usdc.mint(DEPLOYER, DEPOSIT);
        usdc.approve(CSP_VAULT, DEPOSIT);
        uint256 mintedShares = vault.deposit(DEPOSIT, DEPOSIT);

        address otm = factory.createOToken(MOCK_WETH, MOCK_USDC, MOCK_USDC, OTM_STRIKE, expiry, true);
        address physical = factory.createOToken(MOCK_WETH, MOCK_USDC, MOCK_USDC, PHYSICAL_STRIKE, expiry, true);
        address fallbackToken = factory.createOToken(MOCK_WETH, MOCK_USDC, MOCK_USDC, DEFAULT_STRIKE, expiry, true);

        (uint256 otmBatchId, uint256 otmVaultId) = _openBatch(deployerKey, otm, 337_001, OTM_STRIKE);
        (uint256 physicalBatchId, uint256 physicalVaultId) = _openBatch(deployerKey, physical, 337_002, PHYSICAL_STRIKE);
        (uint256 fallbackBatchId, uint256 fallbackVaultId) =
            _openBatch(deployerKey, fallbackToken, 337_003, DEFAULT_STRIKE);
        vm.stopBroadcast();

        require(mintedShares == DEPOSIT, "unexpected initial share price");
        require(otmBatchId == 1 && physicalBatchId == 2 && fallbackBatchId == 3, "unexpected batch ids");
        require(otmVaultId == 1 && physicalVaultId == 2 && fallbackVaultId == 3, "unexpected vault ids");
        require(vault.activeCollateral() == 65e6, "unexpected active collateral");

        console.log("B1N337:EXPIRY:%s", expiry);
        console.log("B1N337:OTM_OTOKEN:%s", otm);
        console.log("B1N337:PHYSICAL_OTOKEN:%s", physical);
        console.log("B1N337:FALLBACK_OTOKEN:%s", fallbackToken);
        _logBalances("OPEN");
    }

    function _openBatch(uint256 deployerKey, address oToken, uint256 quoteId, uint256 strike)
        private
        returns (uint256 batchId, uint256 protocolVaultId)
    {
        CspBatchSettler.Quote memory cspQuote = CspBatchSettler.Quote({
            oToken: oToken,
            bidPrice: BID_PRICE,
            deadline: block.timestamp + 1 hours,
            quoteId: quoteId,
            maxAmount: OPTION_AMOUNT,
            makerNonce: settler.makerNonce(DEPLOYER)
        });
        bytes32 digest = settler.hashQuoteFor(CSP_VAULT, cspQuote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerKey, digest);

        BatchSettler.Quote memory vaultQuote = BatchSettler.Quote({
            oToken: cspQuote.oToken,
            bidPrice: cspQuote.bidPrice,
            deadline: cspQuote.deadline,
            quoteId: cspQuote.quoteId,
            maxAmount: cspQuote.maxAmount,
            makerNonce: cspQuote.makerNonce
        });
        uint256 collateral = (OPTION_AMOUNT * strike) / 1e10;
        return vault.openCspBatch(vaultQuote, abi.encodePacked(r, s, v), OPTION_AMOUNT, collateral);
    }

    function _settle() private {
        require(vault.activeBatches() == 3 && vault.preparedSettlementBatchId() == 0, "SETTLE wrong state");
        (, address otm, uint256 otmVaultId,,,,,) = vault.batches(1);
        (, address physical, uint256 physicalVaultId,,,,,) = vault.batches(2);
        (, address fallbackToken, uint256 fallbackVaultId,,,,,) = vault.batches(3);
        uint256 expiry = OToken(otm).expiry();
        require(block.timestamp >= expiry, "option has not expired");
        require(OToken(physical).expiry() == expiry && OToken(fallbackToken).expiry() == expiry, "expiry mismatch");

        _startBroadcast();
        feed.setPrice(int256(EXPIRY_PRICE));
        oracle.setExpiryPrice(MOCK_WETH, expiry, EXPIRY_PRICE);

        vault.prepareCspBatchSettlement(1, 20e6);
        vault.prepareCspBatchSettlement(2, 0);
        settler.operatorPhysicalRedeemVault(CSP_VAULT, physicalVaultId, 22e6);
        vault.finalizeCspBatchSettlement(2);
        vault.prepareCspBatchSettlement(3, 0);
        vm.stopBroadcast();

        require(otmVaultId == 1 && physicalVaultId == 2 && fallbackVaultId == 3, "protocol vault mismatch");
        require(vault.activeBatches() == 1 && vault.preparedSettlementBatchId() == 3, "settlement incomplete");
        require(vault.batchUnderlyingReceived(2) == OPTION_AMOUNT * 1e10, "WETH not delivered");
        console.log("B1N337:FALLBACK_ELIGIBLE_AT:%s", block.timestamp + vault.settlementDefaultDelay());
        _logBalances("SETTLE");
    }

    function _setFullPause(bool paused) private {
        require(controller.systemFullyPaused() != paused, "pause state already set");
        _startBroadcast();
        controller.setSystemFullyPaused(paused);
        vm.stopBroadcast();
        require(controller.systemFullyPaused() == paused, "pause state mismatch");
        console.log(paused ? "B1N337:FULL_PAUSE:ON" : "B1N337:FULL_PAUSE:OFF");
    }

    function _finalize() private {
        require(!controller.systemFullyPaused(), "unpause before FINALIZE");
        require(vault.activeBatches() == 1 && vault.preparedSettlementBatchId() == 3, "FINALIZE wrong state");

        uint256 usdcBefore = usdc.balanceOf(DEPLOYER);
        uint256 wethBefore = weth.balanceOf(DEPLOYER);
        uint256 shares = vault.sharesOf(DEPLOYER);

        _startBroadcast();
        vault.settleDefaultedCspBatch(3);
        vault.closeEpoch();
        uint256 wethClaimed = vault.claimAssignedUnderlying(DEPLOYER);
        uint256 usdcWithdrawn = vault.withdrawIdle(shares, DEPLOYER);
        vm.stopBroadcast();

        require(vault.activeBatches() == 0 && vault.totalShares() == 0, "vault not drained");
        require(wethClaimed == OPTION_AMOUNT * 1e10, "unexpected WETH claim");
        require(weth.balanceOf(DEPLOYER) == wethBefore + wethClaimed, "WETH balance mismatch");
        require(usdc.balanceOf(DEPLOYER) == usdcBefore + usdcWithdrawn, "USDC balance mismatch");

        console.log("B1N337:WETH_CLAIMED:%s", wethClaimed);
        console.log("B1N337:USDC_WITHDRAWN:%s", usdcWithdrawn);
        _logBalances("FINALIZE");
    }

    function _nextExpiry() private view returns (uint256 expiry) {
        expiry = (block.timestamp / 1 days) * 1 days + 8 hours;
        if (expiry < block.timestamp + 1 hours) expiry += 1 days;
    }

    function _logBalances(string memory phase) private view {
        console.log("B1N337:PHASE:%s", phase);
        console.log("B1N337:DEPLOYER_USDC:%s", usdc.balanceOf(DEPLOYER));
        console.log("B1N337:DEPLOYER_WETH:%s", weth.balanceOf(DEPLOYER));
        console.log("B1N337:VAULT_USDC:%s", usdc.balanceOf(CSP_VAULT));
        console.log("B1N337:VAULT_WETH:%s", weth.balanceOf(CSP_VAULT));
        console.log("B1N337:TOTAL_SHARES:%s", vault.totalShares());
        console.log("B1N337:ACTIVE_BATCHES:%s", vault.activeBatches());
        console.log("B1N337:ACTIVE_COLLATERAL:%s", vault.activeCollateral());
    }
}
