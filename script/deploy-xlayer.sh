#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BLOCKCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Options Protocol — XLayer Testnet Deploy ==="

# --- 1. Load env vars from .env.xlayer-testnet (fish format) ---
ENV_FILE="$BLOCKCHAIN_DIR/.env.xlayer-testnet"
if [ -f "$ENV_FILE" ]; then
    echo "[..] Loading .env.xlayer-testnet..."
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        if [[ "$line" =~ ^set\ -x\ ([A-Z_]+)\ (.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            export "$key=$val"
        fi
    done < "$ENV_FILE"
fi

# --- 2. Verify required env vars ---
for var in PRIVATE_KEY XLAYER_TESTNET_RPC_URL; do
    if [ -z "${!var:-}" ]; then
        echo "[FAIL] Missing env var: $var"
        echo "Set it in .env.xlayer-testnet or export it before running."
        exit 1
    fi
done

echo "[ok] Env vars loaded"

# --- 3. Build contracts ---
echo "[..] Building contracts..."
cd "$BLOCKCHAIN_DIR"
forge build --force --silent 2>/dev/null || forge build --force

# --- 4. Deploy to XLayer testnet ---
echo "[..] Deploying to XLayer testnet..."
DEPLOY_OUTPUT=$(forge script script/DeployXLayer.s.sol:DeployXLayer \
    --rpc-url "$XLAYER_TESTNET_RPC_URL" \
    --broadcast \
    --slow \
    -vvvv 2>&1) || {
    echo "$DEPLOY_OUTPUT"
    echo "[FAIL] Deployment failed"
    exit 1
}

echo "$DEPLOY_OUTPUT" | grep "DEPLOYED:" || true

# --- 5. Parse deployed addresses ---
echo "[..] Parsing addresses..."
ADDR_FILE=$(mktemp)
echo "$DEPLOY_OUTPUT" | grep -oE 'DEPLOYED:[A-Za-z]+:0x[0-9a-fA-F]+' | sed 's/DEPLOYED://' > "$ADDR_FILE"

get_addr() {
    grep "^$1:" "$ADDR_FILE" | cut -d: -f2
}

# --- 6. Write deployments-xlayer.json ---
echo "[..] Writing deployments-xlayer.json..."
DEPLOYER_ADDR=$(uv run python3 -c "
from eth_keys import keys
pk = bytes.fromhex('${PRIVATE_KEY#0x}')
print(keys.PrivateKey(pk).public_key.to_checksum_address())
" 2>/dev/null || echo "unknown")

uv run python3 -c "
import json

addrs = {}
with open('$ADDR_FILE') as f:
    for line in f:
        line = line.strip()
        if ':' in line:
            name, addr = line.split(':', 1)
            addrs[name] = addr

deployment = {
    'chain': 'xlayer-testnet',
    'chainId': 1952,
    'rpcUrl': '$XLAYER_TESTNET_RPC_URL',
    'deployer': '$DEPLOYER_ADDR',
    'contracts': {
        'MockOKB': addrs.get('MockOKB', ''),
        'MockUSDC': addrs.get('MockUSDC', ''),
        'MockChainlinkFeedOKB': addrs.get('MockChainlinkFeedOKB', ''),
        'MockAavePool': addrs.get('MockAavePool', ''),
        'MockSwapRouter': addrs.get('MockSwapRouter', ''),
        'AddressBook': addrs.get('AddressBook', ''),
        'Controller': addrs.get('Controller', ''),
        'MarginPool': addrs.get('MarginPool', ''),
        'OTokenFactory': addrs.get('OTokenFactory', ''),
        'Oracle': addrs.get('Oracle', ''),
        'Whitelist': addrs.get('Whitelist', ''),
        'BatchSettler': addrs.get('BatchSettler', ''),
    },
    'config': {
        'protocolFeeBps': 400,
        'swapFeeTier': 500,
        'initialOkbPrice': '50e8',
        'priceDeviationThresholdBps': 1000,
    }
}

with open('$BLOCKCHAIN_DIR/deployments-xlayer.json', 'w') as f:
    json.dump(deployment, f, indent=2)
    f.write('\n')

print()
print('=== Deploy Complete ===')
print('Contracts:')
for name, addr in sorted(addrs.items()):
    print(f'  {name:<25s} {addr}')
"

# --- 7. Attempt contract verification ---
echo "[..] Attempting contract verification on XLayer explorer..."
RPC_URL="$XLAYER_TESTNET_RPC_URL"

verify_contract() {
    local addr="$1"
    local contract_path="$2"
    echo "  Verifying $contract_path at $addr..."
    forge verify-contract \
        --rpc-url "$RPC_URL" \
        --verifier blockscout \
        --verifier-url "https://www.okx.com/web3/explorer/xlayer-test/api/" \
        "$addr" \
        "$contract_path" 2>&1 | tail -1 || true
}

verify_contract "$(get_addr MockOKB)" "src/mocks/MockERC20.sol:MockERC20"
verify_contract "$(get_addr MockUSDC)" "src/mocks/MockERC20.sol:MockERC20"
verify_contract "$(get_addr MockChainlinkFeedOKB)" "src/mocks/MockChainlinkFeed.sol:MockChainlinkFeed"
verify_contract "$(get_addr MockAavePool)" "src/mocks/MockAavePool.sol:MockAavePool"
verify_contract "$(get_addr MockSwapRouter)" "src/mocks/MockSwapRouter.sol:MockSwapRouter"
verify_contract "$(get_addr AddressBook)" "src/core/AddressBook.sol:AddressBook"
verify_contract "$(get_addr Controller)" "src/core/Controller.sol:Controller"
verify_contract "$(get_addr MarginPool)" "src/core/MarginPool.sol:MarginPool"
verify_contract "$(get_addr OTokenFactory)" "src/core/OTokenFactory.sol:OTokenFactory"
verify_contract "$(get_addr Oracle)" "src/core/Oracle.sol:Oracle"
verify_contract "$(get_addr Whitelist)" "src/core/Whitelist.sol:Whitelist"
verify_contract "$(get_addr BatchSettler)" "src/core/BatchSettler.sol:BatchSettler"

echo "[ok] Verification attempted (best-effort)"

# --- 8. Export ABIs ---
echo "[..] Exporting ABIs..."
ABI_DIR="$BLOCKCHAIN_DIR/abis"
mkdir -p "$ABI_DIR"

for contract in AddressBook Controller MarginPool OTokenFactory Oracle Whitelist BatchSettler OToken; do
    ABI_FILE="$BLOCKCHAIN_DIR/out/${contract}.sol/${contract}.json"
    if [ -f "$ABI_FILE" ]; then
        uv run python3 -c "
import json
with open('$ABI_FILE') as f:
    data = json.load(f)
print(json.dumps(data['abi'], indent=2))
" > "$ABI_DIR/${contract}.json"
    else
        echo "  [!] ABI not found for $contract"
    fi
done

for contract in MockERC20 MockChainlinkFeed MockAavePool MockSwapRouter; do
    ABI_FILE="$BLOCKCHAIN_DIR/out/${contract}.sol/${contract}.json"
    if [ -f "$ABI_FILE" ]; then
        uv run python3 -c "
import json
with open('$ABI_FILE') as f:
    data = json.load(f)
print(json.dumps(data['abi'], indent=2))
" > "$ABI_DIR/${contract}.json"
    else
        echo "  [!] ABI not found for $contract"
    fi
done

echo ""
echo "=== XLayer Testnet Deployment Summary ==="
echo "  Chain:                    XLayer Testnet (1952)"
echo "  Deployer:                 $DEPLOYER_ADDR"
echo "  Protocol fee:             400 bps (4%)"
echo "  deployments-xlayer.json:  $BLOCKCHAIN_DIR/deployments-xlayer.json"
echo "  ABIs:                     $ABI_DIR/"
echo ""
echo "Next: share deployments-xlayer.json with backend (B1N-287) and frontend (B1N-288)"

rm -f "$ADDR_FILE"
