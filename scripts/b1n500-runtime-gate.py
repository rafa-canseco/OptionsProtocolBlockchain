#!/usr/bin/env python3
"""Fail closed unless production remains inert before Ledger Bundle 1. Prints no secrets."""

import json
import subprocess
from pathlib import Path
from typing import Optional

WORKSPACE = Path(__file__).resolve().parents[3]


def railway_variables(repository: str, service: str) -> dict[str, str]:
    result = subprocess.run(
        ["railway", "variable", "list", "--service", service, "--environment", "production", "--json"],
        cwd=WORKSPACE / repository,
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout)


def expect(values: dict[str, str], key: str, expected: Optional[str]) -> None:
    actual = values.get(key)
    if expected is None:
        if actual not in (None, "", "false", "False", "0"):
            raise SystemExit(f"runtime gate failed: {key} must be unset/false")
    elif actual != expected:
        raise SystemExit(f"runtime gate failed: {key} expected {expected!r}, got {actual!r}")


def main() -> None:
    backend = railway_variables("backend", "OptionsProtocolBackend")
    market_maker = railway_variables("marketMaker", "OptionsProtocolMarketMaker")

    expect(backend, "BACKGROUND_WORKERS_ENABLED", "false")
    expect(backend, "BASE_OTOKEN_MANAGER_ENABLED", None)
    expect(backend, "BASE_EVENT_INDEXER_ENABLED", None)
    expect(backend, "BASE_EXPIRY_SETTLER_ENABLED", None)
    expect(backend, "ROUTED_SETTLEMENT_ENABLED", "true")
    expect(backend, "ROUTED_SETTLEMENT_PUBLISHING_ENABLED", "false")
    expect(backend, "ROUTED_SETTLEMENT_ASSETS", "nvdac,cbzec,cbhype,vvv")

    expect(market_maker, "HEDGE_MODE", "live")
    expect(market_maker, "HYPERLIQUID_TESTNET", "false")
    expect(market_maker, "SOLANA_QUOTE_PUBLISHING_ENABLED", "false")
    expect(market_maker, "ETH_HEDGE_LEVERAGE", "5")
    for asset in ("NVDAC", "CBZEC", "CBHYPE", "VVV"):
        expect(market_maker, f"{asset}_HEDGE_LEVERAGE", "3")
        expect(market_maker, f"{asset}_MAX_EXPOSURE", "0.05")
        expect(market_maker, f"{asset}_HEDGE_ENABLED", "true")

    print("runtime gate passed: workers/publication inert; hedge limits match approved configuration")


if __name__ == "__main__":
    main()
