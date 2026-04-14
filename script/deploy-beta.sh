#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BLOCKCHAIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Options Protocol — Beta Deploy (Base Sepolia) ==="

# --- 1. Load env vars from .env (fish format: set -x KEY value) ---
ENV_FILE="$BLOCKCHAIN_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "[..] Loading .env..."
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        # Parse fish "set -x KEY VALUE" format
        if [[ "$line" =~ ^set\ -x\ ([A-Z_]+)\ (.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            export "$key=$val"
        fi
    done < "$ENV_FILE"
fi

# --- 2. Verify required env vars ---
for var in PRIVATE_KEY BASE_SEPOLIA_RPC_URL; do
    if [ -z "${!var:-}" ]; then
        echo "[FAIL] Missing env var: $var"
        echo "Set it in .env or export it before running this script."
        exit 1
    fi
done

echo "[ok] Env vars loaded"

# --- 3. Build contracts ---
echo "[..] Building contracts..."
cd "$BLOCKCHAIN_DIR"
forge build --force --silent 2>/dev/null || forge build --force

# --- 4. Deploy (no inline verification — we verify with Blockscout after) ---
echo "[..] Deploying to Base Sepolia..."
DEPLOY_OUTPUT=$(forge script script/DeployBeta.s.sol:DeployBeta \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
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

# --- 6. Write deployments-beta.json ---
echo "[..] Writing deployments-beta.json..."
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
    'chain': 'base-sepolia',
    'chainId': 84532,
    'rpcUrl': '$BASE_SEPOLIA_RPC_URL',
    'deployer': '$DEPLOYER_ADDR',
    'contracts': {
        'LETH': addrs.get('LETH', ''),
        'LUSD': addrs.get('LUSD', ''),
        'LBTC': addrs.get('LBTC', ''),
        'MockChainlinkFeedETH': addrs.get('MockChainlinkFeedETH', ''),
        'MockChainlinkFeedBTC': addrs.get('MockChainlinkFeedBTC', ''),
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
        'initialEthPrice': '2500e8',
        'initialBtcPrice': '90000e8',
        'priceDeviationThresholdBps': 1000,
    }
}

with open('$BLOCKCHAIN_DIR/deployments-beta.json', 'w') as f:
    json.dump(deployment, f, indent=2)
    f.write('\n')

print()
print('=== Deploy Complete ===')
print('Contracts:')
for name, addr in sorted(addrs.items()):
    print(f'  {name:<20s} {addr}')
"

# --- 7. Verify contracts on Blockscout ---
echo "[..] Verifying contracts on Blockscout..."
BLOCKSCOUT_URL="https://base-sepolia.blockscout.com/api/"
RPC_URL="$BASE_SEPOLIA_RPC_URL"

verify_contract() {
    local addr="$1"
    local contract_path="$2"
    echo "  Verifying $contract_path at $addr..."
    forge verify-contract \
        --rpc-url "$RPC_URL" \
        --verifier blockscout \
        --verifier-url "$BLOCKSCOUT_URL" \
        "$addr" \
        "$contract_path" 2>&1 | tail -1 || true
}

verify_contract "$(get_addr LETH)" "src/mocks/MockERC20.sol:MockERC20"
verify_contract "$(get_addr LUSD)" "src/mocks/MockERC20.sol:MockERC20"
verify_contract "$(get_addr LBTC)" "src/mocks/MockERC20.sol:MockERC20"
verify_contract "$(get_addr MockChainlinkFeedETH)" "src/mocks/MockChainlinkFeed.sol:MockChainlinkFeed"
verify_contract "$(get_addr MockChainlinkFeedBTC)" "src/mocks/MockChainlinkFeed.sol:MockChainlinkFeed"
verify_contract "$(get_addr MockAavePool)" "src/mocks/MockAavePool.sol:MockAavePool"
verify_contract "$(get_addr MockSwapRouter)" "src/mocks/MockSwapRouter.sol:MockSwapRouter"
verify_contract "$(get_addr AddressBook)" "src/core/AddressBook.sol:AddressBook"
verify_contract "$(get_addr Controller)" "src/core/Controller.sol:Controller"
verify_contract "$(get_addr MarginPool)" "src/core/MarginPool.sol:MarginPool"
verify_contract "$(get_addr OTokenFactory)" "src/core/OTokenFactory.sol:OTokenFactory"
verify_contract "$(get_addr Oracle)" "src/core/Oracle.sol:Oracle"
verify_contract "$(get_addr Whitelist)" "src/core/Whitelist.sol:Whitelist"
verify_contract "$(get_addr BatchSettler)" "src/core/BatchSettler.sol:BatchSettler"

echo "[ok] Verification submitted"

# --- 8. Export ABIs ---
echo "[..] Exporting ABIs..."
ABI_DIR="$BLOCKCHAIN_DIR/abis"
mkdir -p "$ABI_DIR"

# Protocol contracts
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

# Mock contracts
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
echo "=== Beta Deployment Summary ==="
echo "  Chain:                 Base Sepolia (84532)"
echo "  Deployer:              $DEPLOYER_ADDR"
echo "  Protocol fee:          400 bps (4%)"
echo "  deployments-beta.json: $BLOCKCHAIN_DIR/deployments-beta.json"
echo "  ABIs:                  $ABI_DIR/"
echo ""
echo "Next: share deployments-beta.json with backend (B1) and frontend (F1)"

rm -f "$ADDR_FILE"
