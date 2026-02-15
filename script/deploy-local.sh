#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BLOCKCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="$(cd "$BLOCKCHAIN_DIR/../.." && pwd)/options-scenarios/artifacts"

echo "=== Options Protocol — Local Deploy ==="
echo "Blockchain dir: $BLOCKCHAIN_DIR"
echo "Artifacts dir:  $ARTIFACTS_DIR"

# --- 1. Start Anvil if not running ---
if lsof -i :8545 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[ok] Anvil already running on :8545"
else
    echo "[..] Starting Anvil..."
    anvil --silent &
    ANVIL_PID=$!
    for i in $(seq 1 30); do
        if lsof -i :8545 -sTCP:LISTEN >/dev/null 2>&1; then
            echo "[ok] Anvil started (PID $ANVIL_PID)"
            break
        fi
        sleep 0.2
    done
    if ! lsof -i :8545 -sTCP:LISTEN >/dev/null 2>&1; then
        echo "[FAIL] Failed to start Anvil"
        exit 1
    fi
fi

# --- 2. Build contracts ---
echo "[..] Building contracts..."
cd "$BLOCKCHAIN_DIR"
forge build --force --silent 2>/dev/null || forge build --force

# --- 3. Deploy ---
echo "[..] Deploying to Anvil..."
DEPLOY_OUTPUT=$(forge script script/DeployLocal.s.sol:DeployLocal \
    --rpc-url http://127.0.0.1:8545 \
    --broadcast 2>&1)

echo "$DEPLOY_OUTPUT" | grep "DEPLOYED:" || true

# --- 4. Parse deployed addresses into a temp file ---
echo "[..] Parsing addresses..."
ADDR_FILE=$(mktemp)
echo "$DEPLOY_OUTPUT" | grep "DEPLOYED:" | sed 's/.*DEPLOYED://' > "$ADDR_FILE"

get_addr() {
    grep "^$1:" "$ADDR_FILE" | cut -d: -f2
}

# --- 5. Create artifacts directory ---
mkdir -p "$ARTIFACTS_DIR"

# --- 6. Export deployments.json via python (avoids bash associative array) ---
echo "[..] Writing deployments.json..."
python3 -c "
import json

addrs = {}
with open('$ADDR_FILE') as f:
    for line in f:
        line = line.strip()
        if ':' in line:
            name, addr = line.split(':', 1)
            addrs[name] = addr

deployment = {
    'chain': 'anvil-localhost',
    'chainId': 31337,
    'rpcUrl': 'http://127.0.0.1:8545',
    'deployer': '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
    'contracts': {
        'AddressBook': addrs.get('AddressBook', ''),
        'Controller': addrs.get('Controller', ''),
        'MarginPool': addrs.get('MarginPool', ''),
        'OTokenFactory': addrs.get('OTokenFactory', ''),
        'Oracle': addrs.get('Oracle', ''),
        'Whitelist': addrs.get('Whitelist', ''),
        'BatchSettler': addrs.get('BatchSettler', ''),
        'PriceSheet': addrs.get('PriceSheet', ''),
        'MockWETH': addrs.get('MockWETH', ''),
        'MockUSDC': addrs.get('MockUSDC', ''),
        'MockChainlinkFeed': addrs.get('MockChainlinkFeed', ''),
    },
    'accounts': {
        'deployer': '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
        'user1': '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
        'user2': '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
        'user3': '0x90F79bf6EB2c4f870365E785982E1f101E93b906',
    }
}

with open('$ARTIFACTS_DIR/deployments.json', 'w') as f:
    json.dump(deployment, f, indent=2)
    f.write('\n')

# Print summary
print()
print('=== Deploy Complete ===')
print('Contracts:')
for name, addr in sorted(addrs.items()):
    print(f'  {name:<20s} {addr}')
"

# --- 7. Export ABIs ---
echo "[..] Exporting ABIs..."
ABI_DIR="$ARTIFACTS_DIR/abis"
mkdir -p "$ABI_DIR"

for contract in AddressBook Controller MarginPool OTokenFactory Oracle Whitelist BatchSettler PriceSheet OToken; do
    ABI_FILE="$BLOCKCHAIN_DIR/out/${contract}.sol/${contract}.json"
    if [ -f "$ABI_FILE" ]; then
        python3 -c "
import json
with open('$ABI_FILE') as f:
    data = json.load(f)
print(json.dumps(data['abi'], indent=2))
" > "$ABI_DIR/${contract}.json"
    else
        echo "  [!] ABI not found for $contract"
    fi
done

# Export mock ABIs
for contract in MockERC20 MockChainlinkFeed; do
    ABI_FILE="$BLOCKCHAIN_DIR/out/DeployLocal.s.sol/${contract}.json"
    if [ -f "$ABI_FILE" ]; then
        python3 -c "
import json
with open('$ABI_FILE') as f:
    data = json.load(f)
print(json.dumps(data['abi'], indent=2))
" > "$ABI_DIR/${contract}.json"
    fi
done

echo ""
echo "Artifacts exported to: $ARTIFACTS_DIR"
echo "  deployments.json  -- contract addresses"
echo "  abis/             -- contract ABIs"

rm -f "$ADDR_FILE"
