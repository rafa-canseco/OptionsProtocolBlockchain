#!/usr/bin/env bash
set -euo pipefail

: "${PRIVATE_KEY:?Set PRIVATE_KEY to the B1N-336 deployer key}"
: "${BASE_SEPOLIA_RPC_URL:?Set BASE_SEPOLIA_RPC_URL (for example https://sepolia.base.org)}"

PHASE="${1:-}"
SCRIPT="script/SmokeCspVaultBaseSepolia.s.sol:SmokeCspVaultBaseSepolia"
VAULT="0xcf2c5b2e065bB7ADD2a29ed4d3A61910e6a59645"
DEPLOYER="0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382"

run_phase() {
    CSP_SMOKE_PHASE="$1" forge script "$SCRIPT" \
        --rpc-url "$BASE_SEPOLIA_RPC_URL" \
        --broadcast \
        --slow \
        -vvv
}

case "$PHASE" in
    open)
        run_phase OPEN
        ;;
    settle)
        run_phase SETTLE
        ;;
    emergency)
        run_phase PAUSE

        CALL_DATA="0x7e6bc385$(printf '%064x' 3)"
        RESPONSE="$(curl -sS -X POST "$BASE_SEPOLIA_RPC_URL" \
            -H 'content-type: application/json' \
            --data "{\"jsonrpc\":\"2.0\",\"id\":337,\"method\":\"eth_call\",\"params\":[{\"from\":\"$DEPLOYER\",\"to\":\"$VAULT\",\"data\":\"$CALL_DATA\"},\"latest\"]}")"

        run_phase UNPAUSE

        if [[ "$RESPONSE" != *'"error"'* ]]; then
            echo "Emergency guard failed: settleDefaultedCspBatch unexpectedly succeeded while fully paused" >&2
            exit 1
        fi
        echo "Emergency guard confirmed: $RESPONSE"
        ;;
    finalize)
        run_phase FINALIZE
        ;;
    *)
        echo "usage: $0 {open|settle|emergency|finalize}" >&2
        exit 2
        ;;
esac
