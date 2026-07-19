#!/usr/bin/env bash
set -euo pipefail

: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL is required}"
: "${CONTRACT_ADDRESS:?CONTRACT_ADDRESS is required}"
: "${CONTRACT_FQN:?CONTRACT_FQN is required, e.g. src/fund/FundVault.sol:FundVault}"

args=(
  forge verify-contract
  --rpc-url "$BASE_SEPOLIA_RPC_URL"
  --verifier blockscout
  --verifier-url "https://base-sepolia.blockscout.com/api/"
)

if [[ -n "${CONSTRUCTOR_ARGS:-}" ]]; then
  args+=(--constructor-args "$CONSTRUCTOR_ARGS")
fi

if [[ -n "${CSP_ADAPTER_OPERATIONS_ADDRESS:-}" ]]; then
  args+=(
    --libraries
    "src/fund/libraries/CspFundAdapterOperations.sol:CspFundAdapterOperations:$CSP_ADAPTER_OPERATIONS_ADDRESS"
  )
fi

args+=("$CONTRACT_ADDRESS" "$CONTRACT_FQN")
"${args[@]}"
