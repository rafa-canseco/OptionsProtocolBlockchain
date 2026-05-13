#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    if [[ "$line" =~ ^set\ -x\ ([A-Z0-9_]+)\ (.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      if [[ -z "${!key:-}" ]]; then
        export "$key=${BASH_REMATCH[2]}"
      fi
    elif [[ "$line" == *=* ]]; then
      line="${line#export }"
      key="${line%%=*}"
      value="${line#*=}"
      value="${value%\"}"
      value="${value#\"}"
      value="${value%\'}"
      value="${value#\'}"
      if [[ -z "${!key:-}" ]]; then
        export "$key=$value"
      fi
    fi
  done < .env
fi

: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${ARC_TESTNET_RPC_URL:?ARC_TESTNET_RPC_URL is required}"

ARC_USDC="0x3600000000000000000000000000000000000000"
ARC_CCTP_DOMAIN="26"
ARC_BLOCKSCOUT_URL="${ARC_BLOCKSCOUT_URL:-https://testnet.arcscan.app/api/}"

forge build

LOG_FILE="$(mktemp)"
forge script script/DeployArcMetaVault.s.sol:DeployArcMetaVault \
  --rpc-url "$ARC_TESTNET_RPC_URL" \
  --broadcast \
  --slow \
  -vvvv | tee "$LOG_FILE"

VAULT="$(sed -n 's/.*DEPLOYED:ArcMetaVault:\(0x[a-fA-F0-9]\{40\}\).*/\1/p' "$LOG_FILE" | tail -1)"

if [[ -z "$VAULT" ]]; then
  echo "Could not parse ArcMetaVault address" >&2
  exit 1
fi

DEPLOYER_ADDR="$(cast wallet address --private-key "$PRIVATE_KEY")"
CHAIN_ID="$(cast chain-id --rpc-url "$ARC_TESTNET_RPC_URL")"
OWNER="${ARC_OWNER:-$DEPLOYER_ADDR}"
OPERATOR="${ARC_OPERATOR:-$DEPLOYER_ADDR}"
AGENT="${ARC_AGENT:-$OPERATOR}"
EPOCH_DURATION="${ARC_EPOCH_DURATION:-86400}"

python3 - "$ROOT_DIR" "$CHAIN_ID" "$DEPLOYER_ADDR" "$VAULT" "$ARC_USDC" "$OWNER" "$OPERATOR" "$AGENT" "$EPOCH_DURATION" "$ARC_CCTP_DOMAIN" <<'PY'
import json
import sys

root, chain_id, deployer, vault, usdc, owner, operator, agent, epoch_duration, cctp_domain = sys.argv[1:11]

deployment = {
    "chain": "arc-testnet",
    "chainId": int(chain_id),
    "deployer": deployer,
    "contracts": {
        "ARC_USDC": usdc,
        "ArcMetaVault": vault,
    },
    "config": {
        "owner": owner,
        "operator": operator,
        "agent": agent,
        "epochDuration": int(epoch_duration),
        "cctpDomain": int(cctp_domain),
        "deploymentType": "direct-constructor",
    },
}

path = f"{root}/deployments-arc-testnet-metavault.json"
with open(path, "w") as f:
    json.dump(deployment, f, indent=2)
    f.write("\n")

print(f"Wrote {path}")
PY

mkdir -p abis
jq '.abi' out/ArcMetaVault.sol/ArcMetaVault.json > abis/ArcMetaVault.json

CONSTRUCTOR_ARGS="$(cast abi-encode "constructor(address,address,address,address,uint64)" "$ARC_USDC" "$OWNER" "$OPERATOR" "$AGENT" "$EPOCH_DURATION")"

forge verify-contract \
  --rpc-url "$ARC_TESTNET_RPC_URL" \
  --verifier blockscout \
  --verifier-url "$ARC_BLOCKSCOUT_URL" \
  --constructor-args "$CONSTRUCTOR_ARGS" \
  "$VAULT" \
  "src/vaults/ArcMetaVault.sol:ArcMetaVault" || true

echo "ArcMetaVault: $VAULT"
echo "ARC_USDC: $ARC_USDC"
echo "Deployment JSON: $ROOT_DIR/deployments-arc-testnet-metavault.json"

rm -f "$LOG_FILE"
