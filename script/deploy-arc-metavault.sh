#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BLOCKCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Options Protocol — Arc MetaVault Deploy ==="

ENV_FILE="$BLOCKCHAIN_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "[..] Loading .env..."
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        if [[ "$line" =~ ^set\ -x\ ([A-Z_]+)\ (.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            export "$key=$val"
        fi
    done < "$ENV_FILE"
fi

for var in PRIVATE_KEY ARC_RPC_URL ARC_USDC; do
    if [ -z "${!var:-}" ]; then
        echo "[FAIL] Missing env var: $var"
        echo "Set it in .env or export it before running this script."
        exit 1
    fi
done

echo "[ok] Env vars loaded"

cd "$BLOCKCHAIN_DIR"

echo "[..] Building contracts..."
forge build --force --silent 2>/dev/null || forge build --force

echo "[..] Deploying Arc MetaVault proxy..."
DEPLOY_OUTPUT=$(forge script script/DeployArcMetaVault.s.sol:DeployArcMetaVault \
    --rpc-url "$ARC_RPC_URL" \
    --broadcast \
    --slow \
    -vvvv 2>&1) || {
    echo "$DEPLOY_OUTPUT"
    echo "[FAIL] Deployment failed"
    exit 1
}

echo "$DEPLOY_OUTPUT" | grep "DEPLOYED:" || true
echo "$DEPLOY_OUTPUT" | grep "CONFIG:" || true

ADDR_FILE=$(mktemp)
CONFIG_FILE=$(mktemp)
echo "$DEPLOY_OUTPUT" | grep -oE 'DEPLOYED:[A-Za-z]+:0x[0-9a-fA-F]+' | sed 's/DEPLOYED://' > "$ADDR_FILE"
echo "$DEPLOY_OUTPUT" | grep -oE 'CONFIG:[A-Za-z]+:[^[:space:]]+' | sed 's/CONFIG://' > "$CONFIG_FILE"

get_addr() {
    grep "^$1:" "$ADDR_FILE" | cut -d: -f2
}

get_config() {
    grep "^$1:" "$CONFIG_FILE" | cut -d: -f2-
}

IMPLEMENTATION_ADDR="$(get_addr ArcMetaVaultImplementation)"
PROXY_ADDR="$(get_addr ArcMetaVault)"

if [ -z "$IMPLEMENTATION_ADDR" ] || [ -z "$PROXY_ADDR" ]; then
    echo "[FAIL] Could not parse deployment addresses"
    exit 1
fi

DEPLOYER_ADDR=$(uv run python3 -c "
from eth_keys import keys
pk = bytes.fromhex('${PRIVATE_KEY#0x}')
print(keys.PrivateKey(pk).public_key.to_checksum_address())
" 2>/dev/null || echo "unknown")

echo "[..] Writing deployments-arc-metavault.json..."
uv run python3 -c "
import json, os

deployment = {
    'chain': os.environ.get('ARC_CHAIN_NAME', 'arc'),
    'rpcUrl': os.environ.get('ARC_RPC_URL', ''),
    'deployer': '$DEPLOYER_ADDR',
    'contracts': {
        'ArcMetaVault': '$PROXY_ADDR',
        'ArcMetaVaultImplementation': '$IMPLEMENTATION_ADDR',
    },
    'config': {
        'usdc': '$(get_config USDC)',
        'owner': '$(get_config Owner)',
        'operator': '$(get_config Operator)',
        'agent': '$(get_config Agent)',
        'epochDuration': '$(get_config EpochDuration)',
    }
}

with open('$BLOCKCHAIN_DIR/deployments-arc-metavault.json', 'w') as f:
    json.dump(deployment, f, indent=2)
    f.write('\\n')
"

if [ -n "${ARC_BLOCKSCOUT_URL:-}" ]; then
    echo "[..] Verifying ArcMetaVault implementation on Blockscout..."
    forge verify-contract \
        --rpc-url "$ARC_RPC_URL" \
        --verifier blockscout \
        --verifier-url "$ARC_BLOCKSCOUT_URL" \
        "$IMPLEMENTATION_ADDR" \
        "src/vaults/ArcMetaVault.sol:ArcMetaVault" 2>&1 | tail -1 || true

    echo "[..] Proxy verification note: proxy address is $PROXY_ADDR"
    echo "     Verify as ERC1967Proxy with constructor args if Blockscout does not auto-detect the proxy."
else
    echo "[skip] ARC_BLOCKSCOUT_URL not set; skipping verification"
fi

echo "[..] Exporting ArcMetaVault ABI..."
ABI_DIR="$BLOCKCHAIN_DIR/abis"
mkdir -p "$ABI_DIR"
ABI_FILE="$BLOCKCHAIN_DIR/out/ArcMetaVault.sol/ArcMetaVault.json"
uv run python3 -c "
import json
with open('$ABI_FILE') as f:
    data = json.load(f)
print(json.dumps(data['abi'], indent=2))
" > "$ABI_DIR/ArcMetaVault.json"

echo ""
echo "=== Arc MetaVault Deployment Summary ==="
echo "  Proxy:                         $PROXY_ADDR"
echo "  Implementation:                 $IMPLEMENTATION_ADDR"
echo "  USDC:                           $(get_config USDC)"
echo "  Owner:                          $(get_config Owner)"
echo "  Operator:                       $(get_config Operator)"
echo "  Agent:                          $(get_config Agent)"
echo "  deployments-arc-metavault.json: $BLOCKCHAIN_DIR/deployments-arc-metavault.json"
echo "  ABI:                            $ABI_DIR/ArcMetaVault.json"

rm -f "$ADDR_FILE" "$CONFIG_FILE"
