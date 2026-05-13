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
: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL is required}"

BASE_SEPOLIA_USDC="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
BLOCKSCOUT_URL="${BASE_BLOCKSCOUT_URL:-https://base-sepolia.blockscout.com/api/}"

forge build

LOG_FILE="$(mktemp)"
forge script script/DeployBaseSepoliaCircleUSDC.s.sol:DeployBaseSepoliaCircleUSDC \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --broadcast \
  --slow \
  -vvvv | tee "$LOG_FILE"

ADDR_FILE="$(mktemp)"
grep -oE 'DEPLOYED:[A-Za-z0-9]+:0x[0-9a-fA-F]+' "$LOG_FILE" | sed 's/DEPLOYED://' > "$ADDR_FILE"

get_addr() {
  grep "^$1:" "$ADDR_FILE" | tail -1 | cut -d: -f2
}

DEPLOYER_ADDR="$(cast wallet address --private-key "$PRIVATE_KEY")"

python3 - "$ADDR_FILE" "$ROOT_DIR" "$DEPLOYER_ADDR" "$BASE_SEPOLIA_USDC" <<'PY'
import json
import sys

addr_file, root, deployer, usdc = sys.argv[1:5]
addrs = {}
with open(addr_file) as f:
    for line in f:
        line = line.strip()
        if ":" in line:
            name, addr = line.split(":", 1)
            addrs[name] = addr

deployment = {
    "chain": "base-sepolia",
    "chainId": 84532,
    "deployer": deployer,
    "contracts": {
        "USDC": usdc,
        "LETH": addrs.get("LETH", ""),
        "LBTC": addrs.get("LBTC", ""),
        "MockChainlinkFeedETH": addrs.get("MockChainlinkFeedETH", ""),
        "MockChainlinkFeedBTC": addrs.get("MockChainlinkFeedBTC", ""),
        "MockAavePool": addrs.get("MockAavePool", ""),
        "MockFundedSwapRouter": addrs.get("MockFundedSwapRouter", ""),
        "AddressBook": addrs.get("AddressBook", ""),
        "Controller": addrs.get("Controller", ""),
        "MarginPool": addrs.get("MarginPool", ""),
        "OTokenFactory": addrs.get("OTokenFactory", ""),
        "Oracle": addrs.get("Oracle", ""),
        "Whitelist": addrs.get("Whitelist", ""),
        "BatchSettler": addrs.get("BatchSettler", ""),
        "BaseVaultAdapterImplementation": addrs.get("BaseVaultAdapterImplementation", ""),
        "BaseVaultAdapter": addrs.get("BaseVaultAdapter", ""),
    },
    "config": {
        "usdcSource": "Circle testnet USDC",
        "protocolFeeBps": 400,
        "swapFeeTier": 500,
        "initialEthPrice": "2500e8",
        "initialBtcPrice": "90000e8",
        "priceDeviationThresholdBps": 1000,
        "cctpDomain": 6,
    },
}

path = f"{root}/deployments-base-sepolia-circle-usdc.json"
with open(path, "w") as f:
    json.dump(deployment, f, indent=2)
    f.write("\n")

print(f"Wrote {path}")
PY

mkdir -p abis
for contract in AddressBook Controller MarginPool OTokenFactory Oracle Whitelist BatchSettler OToken BaseVaultAdapter MockERC20 MockChainlinkFeed MockAavePool MockFundedSwapRouter; do
  if [ -f "out/${contract}.sol/${contract}.json" ]; then
    jq '.abi' "out/${contract}.sol/${contract}.json" > "abis/${contract}.json"
  fi
done

verify_contract() {
  local name="$1"
  local path="$2"
  local addr
  addr="$(get_addr "$name")"
  if [[ -z "$addr" ]]; then
    echo "Skipping $name verification: no address"
    return
  fi
  forge verify-contract \
    --rpc-url "$BASE_SEPOLIA_RPC_URL" \
    --verifier blockscout \
    --verifier-url "$BLOCKSCOUT_URL" \
    "$addr" \
    "$path" || true
}

verify_contract LETH "src/mocks/MockERC20.sol:MockERC20"
verify_contract LBTC "src/mocks/MockERC20.sol:MockERC20"
verify_contract MockChainlinkFeedETH "src/mocks/MockChainlinkFeed.sol:MockChainlinkFeed"
verify_contract MockChainlinkFeedBTC "src/mocks/MockChainlinkFeed.sol:MockChainlinkFeed"
verify_contract MockAavePool "src/mocks/MockAavePool.sol:MockAavePool"
verify_contract MockFundedSwapRouter "src/mocks/MockFundedSwapRouter.sol:MockFundedSwapRouter"
verify_contract AddressBook "src/core/AddressBook.sol:AddressBook"
verify_contract Controller "src/core/Controller.sol:Controller"
verify_contract MarginPool "src/core/MarginPool.sol:MarginPool"
verify_contract OTokenFactory "src/core/OTokenFactory.sol:OTokenFactory"
verify_contract Oracle "src/core/Oracle.sol:Oracle"
verify_contract Whitelist "src/core/Whitelist.sol:Whitelist"
verify_contract BatchSettler "src/core/BatchSettler.sol:BatchSettler"
verify_contract BaseVaultAdapterImplementation "src/adapters/BaseVaultAdapter.sol:BaseVaultAdapter"

echo "Base Sepolia Circle USDC deployment complete"
echo "USDC: $BASE_SEPOLIA_USDC"
echo "Deployment JSON: $ROOT_DIR/deployments-base-sepolia-circle-usdc.json"

rm -f "$LOG_FILE" "$ADDR_FILE"
