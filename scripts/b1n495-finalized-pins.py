#!/usr/bin/env python3
"""Return ABI words for the current finalized Base, HyperEVM, and Arbitrum blocks."""

import json
import os
import sys
import time
import urllib.error
import urllib.request

CHAINS = (
    ("B1N495_BASE_RPC_URL", 8453),
    ("B1N495_HYPEREVM_RPC_URL", 999),
    ("B1N495_ARBITRUM_RPC_URL", 42161),
)


def rpc(url: str, method: str, params: list[object]) -> object:
    request = urllib.request.Request(
        url,
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        {"Content-Type": "application/json", "User-Agent": "b1n495-preflight/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        raise RuntimeError(f"{method} transport failed") from None
    if payload.get("error") or payload.get("result") is None:
        raise RuntimeError(f"{method} failed: {payload.get('error')}")
    return payload["result"]


def word(value: int) -> str:
    return f"{value:064x}"


def verify() -> None:
    env_name, number_text, expected_hash = sys.argv[2:]
    url = os.environ[env_name]
    block = rpc(url, "eth_getBlockByNumber", [hex(int(number_text)), False])
    if block["hash"].lower() != expected_hash.lower():
        raise RuntimeError(f"{env_name}: finalized block hash changed")
    print("0x00")


def self_check() -> None:
    original = urllib.request.urlopen
    secret = "rpc-key-must-not-leak"

    def fail(*_args: object, **_kwargs: object) -> None:
        raise urllib.error.URLError(f"https://rpc.invalid/?key={secret}")

    urllib.request.urlopen = fail
    try:
        rpc("https://rpc.invalid", "eth_chainId", [])
    except RuntimeError as error:
        assert secret not in str(error)
    else:
        raise AssertionError("transport failure did not fail closed")
    finally:
        urllib.request.urlopen = original
    print("ok")


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-check":
        self_check()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--verify":
        verify()
        return
    words: list[str] = []
    evidence: list[str] = []
    for env_name, expected_chain_id in CHAINS:
        url = os.environ[env_name]
        chain_id = int(rpc(url, "eth_chainId", []), 16)
        if chain_id != expected_chain_id:
            raise RuntimeError(f"{env_name}: expected chain {expected_chain_id}, got {chain_id}")
        block = rpc(url, "eth_getBlockByNumber", ["finalized", False])
        number = int(block["number"], 16)
        block_hash = block["hash"]
        parent_hash = block["parentHash"]
        words.extend((word(number), block_hash[2:], parent_hash[2:]))
        evidence.append(f"{expected_chain_id}:{number}:{block_hash}")
    captured_at = int(time.time())
    words.append(word(captured_at))
    print("0x" + "".join(words))
    print(f"B1N-495 finalized capture {captured_at} " + " ".join(evidence), file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"B1N-495 finalized capture failed: {error}", file=sys.stderr)
        raise SystemExit(1)
