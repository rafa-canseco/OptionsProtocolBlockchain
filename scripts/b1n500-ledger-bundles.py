#!/usr/bin/env python3
"""Generate or verify unsigned B1N-500 Ledger bundle calldata. Never broadcasts."""

import argparse
import json
import subprocess
from pathlib import Path

CHAIN_ID = 8453
OWNER = "0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7"
WHITELIST = "0xC0E6b9F214151cEDbeD3735dF77E9d8EE70ebA8A"
SETTLER = "0xd281ADdB8b5574360Fd6BFC245B811ad5C582a3B"
FACADE = "0xFcecd17d0f5e15ed881974a2602c1833C418e28e"
USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
WETH = "0x4200000000000000000000000000000000000006"
CBBTC = "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf"
NVDAC = "0xb20000000000000000000078ee7ce2fE4908108C"
CBZEC = "0xB2000000000000000000008501b13360000cb2EC"
CBHYPE = "0xB200000000000000000000451d033a5000cb479e"
VVV = "0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf"
NVDAC_ADAPTER = "0xE2562017C63C5B7EcD6F91F4C1510367bcF6284D"
CBHYPE_ADAPTER = "0xc76287aB15C8ced24f4164CF88B4094B6DC1c039"
UNI_ROUTER = "0x2626664c2603336E57B271c5C0b26F421741e481"
OUTPUT = Path("deployments/base-mainnet/b1n-500/ledger-bundles.json")


def calldata(signature: str, *args: object) -> str:
    return subprocess.check_output(
        ["cast", "calldata", signature, *(str(arg).lower() if isinstance(arg, bool) else str(arg) for arg in args)],
        text=True,
    ).strip()


def tx(index: int, to: str, description: str, signature: str, *args: object) -> dict:
    data = calldata(signature, *args)
    return {
        "index": index,
        "to": to,
        "value": "0",
        "data": data,
        "selector": data[:10],
        "description": description,
    }


def activate(index: int, asset: str, symbol: str, put: bool = False) -> dict:
    token_in, token_out, kind = (USDC, asset, 1) if put else (asset, USDC, 0)
    side = "PUT exact-output" if put else "CALL exact-input"
    return tx(index, FACADE, f"Activate {symbol} {side} route", "activateRoute(address,address,uint8)", token_in, token_out, kind)


def propose(index: int, asset: str, symbol: str, adapter: str, put: bool = False) -> dict:
    token_in, token_out, kind = (USDC, asset, 1) if put else (asset, USDC, 0)
    side = "PUT exact-output" if put else "CALL exact-input"
    return tx(
        index,
        FACADE,
        f"Propose {symbol} {side} route",
        "proposeRoute(address,address,uint8,address)",
        token_in,
        token_out,
        kind,
        adapter,
    )


def product_txs(start: int, asset: str, symbol: str) -> list[dict]:
    return [
        tx(start, WHITELIST, f"Whitelist {symbol} underlying", "whitelistUnderlying(address)", asset),
        tx(start + 1, WHITELIST, f"Whitelist {symbol} collateral", "whitelistCollateral(address)", asset),
        tx(
            start + 2,
            WHITELIST,
            f"Whitelist {symbol}/USDC cash-secured PUT product",
            "whitelistProduct(address,address,address,bool)",
            asset,
            USDC,
            USDC,
            True,
        ),
        tx(
            start + 3,
            WHITELIST,
            f"Whitelist {symbol}/USDC covered CALL product",
            "whitelistProduct(address,address,address,bool)",
            asset,
            USDC,
            asset,
            False,
        ),
    ]


def artifact() -> dict:
    bundle1 = product_txs(1, NVDAC, "NVDAc") + product_txs(5, CBHYPE, "cbHYPE")
    for asset, symbol in ((WETH, "WETH"), (CBBTC, "cbBTC"), (CBZEC, "cbZEC"), (VVV, "VVV")):
        bundle1 += [activate(len(bundle1) + 1, asset, symbol), activate(len(bundle1) + 2, asset, symbol, True)]
    bundle1 += [
        propose(17, NVDAC, "NVDAc", NVDAC_ADAPTER),
        propose(18, NVDAC, "NVDAc", NVDAC_ADAPTER, True),
        propose(19, CBHYPE, "cbHYPE", CBHYPE_ADAPTER),
        propose(20, CBHYPE, "cbHYPE", CBHYPE_ADAPTER, True),
    ]
    bundle2 = [
        activate(1, NVDAC, "NVDAc"),
        activate(2, NVDAC, "NVDAc", True),
        activate(3, CBHYPE, "cbHYPE"),
        activate(4, CBHYPE, "cbHYPE", True),
        tx(5, SETTLER, "Cut BatchSettler over to PairRoutingSwapRouter", "setSwapRouter(address)", FACADE),
    ]
    rollback = tx(1, SETTLER, "Rollback BatchSettler to direct Uniswap V3 router", "setSwapRouter(address)", UNI_ROUTER)
    assert len(bundle1) == 20 and len(bundle2) == 5
    return {
        "status": "PREPARED_NOT_SIGNED_NOT_BROADCAST",
        "chainId": CHAIN_ID,
        "owner": OWNER,
        "sourceBaseCommit": "0765535c66b4f2df65cbfd75f0836c22a5ab98cd",
        "observedFinalizedBlock": {
            "number": 51712872,
            "hash": "0x315f9ee1367c2436937d96527aab135973307c4650978b05850447c61bef1a23",
            "parentHash": "0x8dbbd85f89bf8088a21654454fcaf820a3a03fda2922bc5277b9bbedfb2937eb",
            "timestamp": 1790215091,
        },
        "latestObservedPreflight": {
            "status": "BLOCKED_BY_NVDAC_MARKET_HOURS_FRESHNESS",
            "nvdac": {"eligible": False, "deviationBps": 1},
            "cbzec": {"eligible": True, "deviationBps": 5},
            "cbhype": {"eligible": True, "deviationBps": 12},
            "vvv": {"eligible": True, "deviationBps": 3},
            "note": "Informational only; rerun immediately before every Ledger bundle",
        },
        "contracts": {
            "whitelistProxy": {"address": WHITELIST, "codehash": "0x8fe6e1498a3a26da266dcc51fdd7731c0fb33355713bd01574ed5c6574a98637"},
            "whitelistImplementation": {"address": "0x5F3b652b2b258e36bc88C3Bdf3c4e1EcF04BCF00", "codehash": "0x346c0ac9e338e6a8080629689a5ba300c66f5de2ecc19591f0a910fb2e99e649"},
            "settlerProxy": {"address": SETTLER, "codehash": "0x8fe6e1498a3a26da266dcc51fdd7731c0fb33355713bd01574ed5c6574a98637"},
            "settlerImplementation": {"address": "0x645a8A66B812A13D5042939b88C144467B825648", "codehash": "0x961901664cba1e17fe5dfaeef550b91ecdbe08834ef16065dfb6e462a095209a"},
            "facade": {"address": FACADE, "codehash": "0x8520cccdac2846a4817c26368f2b3ab04f1e0d3cc872ce11418ade10d496f678"},
            "nvdacAdapter": {"address": NVDAC_ADAPTER, "codehash": "0xa4b70749fc39ee3ab532fef6ff604710b2cdbc0de0f071e6d434f8ac76d36a2a"},
            "cbzecAdapter": {"address": "0xF8c97C9CaefB9799eC55a0a3095c40E1c580Caf1", "codehash": "0x59e49007bee0ff9dddf105c8c6cd7f7830bc283025f610e3e4e6f68c35035a4b"},
            "cbhypeAdapter": {"address": CBHYPE_ADAPTER, "codehash": "0x11e20e91e531b78036f02fd5e7fd683402ec14692fd24faffbc6ba3b1388b1de"},
            "uniswapAdapter": {"address": "0x9baED665316cCA02BeA40f059F8b84874787210B", "codehash": "0x458568b4f0efd1dbf5ee64adc7228eb6fd27073c6d29eb1ce047a4d7dc0586ee"},
        },
        "bundle1": {
            "status": "PREPARED_FOR_LEDGER_AFTER_REVIEW",
            "preconditions": [
                "cbZEC, cbHYPE, and VVV pass the latest-finalized preflight in the signing session",
                "NVDAc deviation is <=100 bps; market-hours freshness may be false because Bundle 1 only proposes its inert delayed route",
                "Owner, codehashes, controller pause state, router, route pending state, and whitelist baseline match",
                "scripts/b1n500-runtime-gate.py passes in the signing session",
                "BatchSettler remains on the direct Uniswap router and backend workers/publishing remain disabled",
                "No transaction is sent if any precondition drifts",
            ],
            "transactions": bundle1,
        },
        "bundle2": {
            "status": "BLOCKED_UNTIL_BUNDLE1_RECONCILED_AND_24H_DELAY_ELAPSED",
            "preconditions": [
                "Bundle 1 receipts and actual activateAfter values are reconciled on Base",
                "Both NVDAc and cbHYPE route delays have elapsed",
                "B1N500LedgerBundle2Gate.run succeeds against fresh finalized Base/Arbitrum/HyperEVM state in the signing session",
                "All six asset route pairs and proxy state match the fork rehearsal before cutover",
            ],
            "transactions": bundle2,
        },
        "rollback": rollback,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered = json.dumps(artifact(), indent=2) + "\n"
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != rendered:
            raise SystemExit(f"stale or missing artifact: {OUTPUT}")
        print(f"verified {OUTPUT}")
        return
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered)
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
