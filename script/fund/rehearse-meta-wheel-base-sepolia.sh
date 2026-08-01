#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL is required}"
: "${B1N419_APPROVED_INPUTS_PATH:?B1N419_APPROVED_INPUTS_PATH is required}"
: "${B1N419_APPROVED_INPUTS_SHA256:?B1N419_APPROVED_INPUTS_SHA256 is required}"
: "${B1N419_BROADCASTER:?B1N419_BROADCASTER is required}"
: "${B1N419_MANIFEST_PATH:?B1N419_MANIFEST_PATH is required}"
: "${B1N419_MIN_BROADCASTER_BALANCE_WEI:?B1N419_MIN_BROADCASTER_BALANCE_WEI is required}"
B1N419_SOURCE_COMMIT="$(git rev-parse HEAD)"
export B1N419_SOURCE_COMMIT

if [[ "$(cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL")" != "84532" ]]; then
  echo "B1N419: RPC is not Base Sepolia" >&2
  exit 1
fi

if [[ "$B1N419_APPROVED_INPUTS_PATH" == *template.json ]]; then
  echo "B1N419: template input is never deployable" >&2
  exit 1
fi

actual_digest="$(shasum -a 256 "$B1N419_APPROVED_INPUTS_PATH" | awk '{print "0x" $1}')"
if [[ "$actual_digest" != "$B1N419_APPROVED_INPUTS_SHA256" ]]; then
  echo "B1N419: approved input digest mismatch" >&2
  exit 1
fi

# Forward explicit forge flags (notably every --libraries binding) as an argument array.
forge clean
forge build "$@"
script/fund/validate-meta-wheel-upgrades.sh
forge test --match-path test/fund/B1N419MetaWheelDeployment.t.sol "$@"
forge script script/fund/PreflightMetaWheelBaseSepolia.s.sol:PreflightMetaWheelBaseSepolia \
  --sig "preflight()" --rpc-url "$BASE_SEPOLIA_RPC_URL" "$@"
forge script script/fund/DeployMetaWheelBaseSepolia.s.sol:DeployMetaWheelBaseSepolia \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" "$@"
forge script script/fund/ReconcileMetaWheelBootstrap.s.sol:ReconcileMetaWheelBootstrap \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" "$@"

echo "B1N419 dry-run complete; no transaction was broadcast"
