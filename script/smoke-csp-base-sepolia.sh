#!/usr/bin/env bash
set -euo pipefail

: "${BASE_SEPOLIA_RPC_URL:?Set BASE_SEPOLIA_RPC_URL (for example https://sepolia.base.org)}"

PHASE="${1:-}"
FOUNDRY_ACCOUNT="${FOUNDRY_ACCOUNT:-operator}"
SCRIPT="script/SmokeCspVaultBaseSepolia.s.sol:SmokeCspVaultBaseSepolia"
VAULT="0xcf2c5b2e065bB7ADD2a29ed4d3A61910e6a59645"
DEPLOYER="0x9386365F8c1aF88B4A7Bfb3DB71E5Fa6d1f20382"

run_phase() {
  local phase="$1"
  local -a wallet_args=(--account "$FOUNDRY_ACCOUNT")

  if [[ "$phase" == OPEN ]]; then
    : "${PRIVATE_KEY:?OPEN requires PRIVATE_KEY for the EIP-712 quote signatures}"
    wallet_args=()
  fi

  CSP_SMOKE_PHASE="$phase" forge script "$SCRIPT" \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --broadcast \
    --slow \
    "${wallet_args[@]}" \
    -vvv
}

PAUSE_CLEANUP=0

cleanup_pause() {
  if [[ "$PAUSE_CLEANUP" == 1 ]]; then
    PAUSE_CLEANUP=0
    run_phase UNPAUSE
  fi
}

case "$PHASE" in
open)
  run_phase OPEN
  ;;
settle)
  run_phase SETTLE
  ;;
emergency)
  PAUSE_CLEANUP=1
  trap cleanup_pause EXIT
  run_phase PAUSE

  CALL_DATA="0x7e6bc385$(printf '%064x' 3)"
  EXPECTED_REVERT="0x4bcc2fc6"
  RESPONSE="$(curl --fail-with-body -sS -X POST "$BASE_SEPOLIA_RPC_URL" \
    -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":337,\"method\":\"eth_call\",\"params\":[{\"from\":\"$DEPLOYER\",\"to\":\"$VAULT\",\"data\":\"$CALL_DATA\"},\"latest\"]}")"

  if [[ "$RESPONSE" != *'"error"'* || "$RESPONSE" != *"$EXPECTED_REVERT"* ]]; then
    echo "Emergency guard failed: expected SettlementDefaultNotReady ($EXPECTED_REVERT): $RESPONSE" >&2
    exit 1
  fi

  cleanup_pause
  trap - EXIT
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
