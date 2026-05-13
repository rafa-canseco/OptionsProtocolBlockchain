#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  while IFS= read -r line; do
    line="${line#export }"
    if [[ -z "$line" || "$line" == \#* || "$line" != *=* ]]; then
      continue
    fi
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    export "$key=$value"
  done < .env
fi

: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${BASE_RPC_URL:?BASE_RPC_URL is required}"
: "${BASE_ADDRESS_BOOK:?BASE_ADDRESS_BOOK is required}"
: "${BASE_BATCH_SETTLER:?BASE_BATCH_SETTLER is required}"
: "${BASE_USDC:?BASE_USDC is required}"

forge build

LOG_FILE="$(mktemp)"
forge script script/DeployBaseVaultAdapter.s.sol:DeployBaseVaultAdapter \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  -vvvv | tee "$LOG_FILE"

IMPL="$(sed -n 's/.*DEPLOYED:BaseVaultAdapterImplementation:\(0x[a-fA-F0-9]\{40\}\).*/\1/p' "$LOG_FILE" | tail -1)"
PROXY="$(sed -n 's/.*DEPLOYED:BaseVaultAdapter:\(0x[a-fA-F0-9]\{40\}\).*/\1/p' "$LOG_FILE" | tail -1)"

if [[ -z "$IMPL" || -z "$PROXY" ]]; then
  echo "Could not parse deployed addresses" >&2
  exit 1
fi

cat > deployments-base-vault-adapter.json <<JSON
{
  "BaseVaultAdapter": "$PROXY",
  "BaseVaultAdapterImplementation": "$IMPL",
  "AddressBook": "$BASE_ADDRESS_BOOK",
  "BatchSettler": "$BASE_BATCH_SETTLER",
  "USDC": "$BASE_USDC"
}
JSON

mkdir -p abis
jq '.abi' out/BaseVaultAdapter.sol/BaseVaultAdapter.json > abis/BaseVaultAdapter.json

if [[ -n "${BASE_BLOCKSCOUT_URL:-}" ]]; then
  forge verify-contract \
    --rpc-url "$BASE_RPC_URL" \
    --verifier blockscout \
    --verifier-url "$BASE_BLOCKSCOUT_URL" \
    "$IMPL" \
    "src/adapters/BaseVaultAdapter.sol:BaseVaultAdapter"
else
  echo "Skipping verification: BASE_BLOCKSCOUT_URL not set"
fi

echo "BaseVaultAdapter proxy: $PROXY"
echo "BaseVaultAdapter implementation: $IMPL"
