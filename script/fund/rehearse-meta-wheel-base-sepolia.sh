#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "B1N-419 fork rehearsal blocked: $*" >&2
  exit 1
}

for command_name in jq cast forge git shasum rg; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

: "${B1N419_FORK_RPC_URL:?B1N419_FORK_RPC_URL is required}"
: "${B1N419_APPROVED_INPUTS_PATH:?B1N419_APPROVED_INPUTS_PATH is required}"
: "${B1N419_APPROVED_INPUTS_SHA256:?B1N419_APPROVED_INPUTS_SHA256 is required}"
: "${B1N419_LIBRARY_EVIDENCE_PATH:?B1N419_LIBRARY_EVIDENCE_PATH is required}"
: "${B1N419_MANIFEST_PATH:?B1N419_MANIFEST_PATH is required}"
: "${B1N419_BACKEND_ROOT:?B1N419_BACKEND_ROOT is required for the negative finalizer gate}"
export B1N419_APPROVED_INPUTS_PATH B1N419_APPROVED_INPUTS_SHA256 B1N419_LIBRARY_EVIDENCE_PATH
export B1N419_MANIFEST_PATH B1N419_BACKEND_ROOT
export B1N419_MIN_BROADCASTER_BALANCE_WEI=${B1N419_MIN_BROADCASTER_BALANCE_WEI:-1}

rpc_url=$B1N419_FORK_RPC_URL
expected_bootstrap=0x42cB85203838DD9708ED548DC4f815130E8F7e74
expected_settler_owner=0x376a4c54623fe24D0Ffc1032D0b6CcC03A32fd7D
[[ "$(cast chain-id --rpc-url "$rpc_url")" == "84532" ]] || die "Anvil fork chain id must be 84532"
client_version=$(cast rpc web3_clientVersion --rpc-url "$rpc_url" | jq -r '.')
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$client_version")" == *anvil* ]] || die "RPC is not Anvil"
anvil_info=$(cast rpc anvil_nodeInfo --rpc-url "$rpc_url") || die "anvil_nodeInfo unavailable"
jq -e '.forkConfig != null' <<<"$anvil_info" >/dev/null || die "Anvil is not fork-backed"
[[ "$B1N419_MANIFEST_PATH" == *fork* ]] || die "manifest path must be visibly fork-only"
[[ ! -e "$B1N419_MANIFEST_PATH" ]] || die "fork manifest path already exists"
[[ "$B1N419_APPROVED_INPUTS_PATH" != *template.json ]] || die "template input is never deployable"

B1N419_SOURCE_COMMIT=$(git rev-parse HEAD)
export B1N419_SOURCE_COMMIT B1N419_EXECUTION_CONTEXT=FORK_REHEARSAL
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "source tree must be clean and committed"
jq -e --arg commit "$B1N419_SOURCE_COMMIT" '
  .approval == "APPROVED_BASE_SEPOLIA_DRY_RUN" and .environment.SOURCE_COMMIT == $commit and
  (.environment.APPROVED_OBSERVERS | length) == 4 and (.environment.NAV_REPORTERS | length) == 2
' "$B1N419_APPROVED_INPUTS_PATH" >/dev/null || die "approved fork inputs mismatch"
actual_digest="0x$(shasum -a 256 "$B1N419_APPROVED_INPUTS_PATH" | awk '{print $1}')"
[[ "$actual_digest" == "$B1N419_APPROVED_INPUTS_SHA256" ]] || die "approved input digest mismatch"
jq -e --arg commit "$B1N419_SOURCE_COMMIT" '
  .status == "SIMULATED_NONCANONICAL" and .handoffReady == false and
  .network.environmentKind == "anvil-fork" and .sourceCommit == $commit and
  .exactRelinkVerified == true and (.orderedLibraries | length) == 5
' "$B1N419_LIBRARY_EVIDENCE_PATH" >/dev/null || die "fork library evidence mismatch"

link_arguments=()
for index in 0 1 2 3 4; do
  artifact=$(jq -r --argjson index "$index" '.orderedLibraries[$index].artifact' "$B1N419_LIBRARY_EVIDENCE_PATH")
  address=$(jq -r --argjson index "$index" '.orderedLibraries[$index].address' "$B1N419_LIBRARY_EVIDENCE_PATH")
  input_address=$(jq -r --argjson index "$index" '.environment.LINKED_LIBRARIES[$index]' \
    "$B1N419_APPROVED_INPUTS_PATH")
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$address")" == "$(tr '[:upper:]' '[:lower:]' <<<"$input_address")" ]] \
    || die "input/library link mismatch at index $index"
  link_arguments+=(--libraries "$artifact:$address")
done

impersonate() {
  local account=$1
  cast rpc anvil_impersonateAccount "[\"$account\"]" --raw --rpc-url "$rpc_url" >/dev/null
  cast rpc anvil_setBalance "[\"$account\",\"0x56bc75e2d63100000\"]" --raw --rpc-url "$rpc_url" >/dev/null
}

run_read_only() {
  local target=$1
  local signature=$2
  local broadcaster=$3
  B1N419_BROADCASTER=$broadcaster forge script "$target" --sig "$signature" --rpc-url "$rpc_url" \
    "${link_arguments[@]}"
}

run_fork_broadcast() {
  local target=$1
  local signature=$2
  local broadcaster=$3
  impersonate "$broadcaster"
  B1N419_BROADCASTER=$broadcaster forge script "$target" --sig "$signature" --rpc-url "$rpc_url" \
    --broadcast --slow --unlocked --sender "$broadcaster" "${link_arguments[@]}"
}

bootstrap=$(jq -r '.environment.ROLE_ADMIN' "$B1N419_APPROVED_INPUTS_PATH")
curator=$(jq -r '.environment.FINAL_ROLE_CURATOR' "$B1N419_APPROVED_INPUTS_PATH")
guardian=$(jq -r '.environment.FINAL_ROLE_GUARDIAN' "$B1N419_APPROVED_INPUTS_PATH")
batch_settler=$(jq -r '.environment.BATCH_SETTLER' "$B1N419_APPROVED_INPUTS_PATH")
settler_owner=$(cast call "$batch_settler" 'owner()(address)' --rpc-url "$rpc_url")
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$bootstrap")" \
  == "$(tr '[:upper:]' '[:lower:]' <<<"$expected_bootstrap")" ]] \
  || die "approved bootstrap identity mismatch"
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$settler_owner")" \
  == "$(tr '[:upper:]' '[:lower:]' <<<"$expected_settler_owner")" ]] \
  || die "BatchSettler onboarding owner mismatch"

script/fund/test-meta-wheel-input-generator-fixture.sh
script/fund/test-meta-wheel-finalizer-live-fixture.sh
forge clean
forge build "${link_arguments[@]}"
script/fund/validate-meta-wheel-upgrades.sh
forge test --match-path test/fund/B1N419MetaWheelDeployment.t.sol --fork-url "$rpc_url" \
  "${link_arguments[@]}"
run_read_only \
  script/fund/PreflightMetaWheelBaseSepolia.s.sol:PreflightMetaWheelBaseSepolia \
  'preflight()' "$bootstrap"
run_fork_broadcast \
  script/fund/DeployMetaWheelBaseSepolia.s.sol:DeployMetaWheelBaseSepolia \
  'run()' "$bootstrap"

export B1N419_MANIFEST_SHA256
B1N419_MANIFEST_SHA256="0x$(shasum -a 256 "$B1N419_MANIFEST_PATH" | awk '{print $1}')"
export B1N419_DEPLOYMENT_ID
B1N419_DEPLOYMENT_ID=$(jq -r '.deploymentId' "$B1N419_MANIFEST_PATH")
[[ "$B1N419_DEPLOYMENT_ID" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "fork deployment id malformed"

run_read_only \
  script/fund/ReconcileMetaWheelBootstrap.s.sol:ReconcileMetaWheelBootstrap \
  'run()' "$bootstrap"
run_fork_broadcast \
  script/fund/RotateMetaWheelRolesBaseSepolia.s.sol:RotateMetaWheelRolesBaseSepolia \
  'run()' "$bootstrap"
run_read_only \
  script/fund/ReconcileMetaWheelFinalRoles.s.sol:ReconcileMetaWheelFinalRoles \
  'run()' "$curator"
run_fork_broadcast \
  script/fund/ConfigureMetaWheelBaseSepolia.s.sol:ConfigureMetaWheelBaseSepolia \
  'run()' "$curator"
run_fork_broadcast \
  script/fund/SetupMetaWheelManagedLanesBaseSepolia.s.sol:SetupMetaWheelManagedLanesBaseSepolia \
  'registerLanes()' "$curator"
run_fork_broadcast \
  script/fund/SetupMetaWheelManagedLanesBaseSepolia.s.sol:SetupMetaWheelManagedLanesBaseSepolia \
  'pauseCoordinator()' "$guardian"
run_read_only \
  script/fund/SetupMetaWheelManagedLanesBaseSepolia.s.sol:SetupMetaWheelManagedLanesBaseSepolia \
  'reconcileManagedSetup()' "$curator"
run_fork_broadcast \
  script/fund/OnboardMetaWheelChildrenBaseSepolia.s.sol:OnboardMetaWheelChildrenBaseSepolia \
  'run()' "$settler_owner"
run_read_only \
  script/fund/ReconcileMetaWheelCanonical.s.sol:ReconcileMetaWheelCanonical \
  'reconcile()' "$curator"

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT
if BASE_SEPOLIA_RPC_URL=$rpc_url \
  B1N419_CANONICALIZATION_EVIDENCE_PATH=deployments/base-sepolia/b1n-419/canonicalization-evidence.template.json \
  B1N419_CANONICAL_MANIFEST_PATH="$temporary_dir/fork-canonical-must-not-exist.json" \
  B1N419_BACKEND_ROOT="$B1N419_BACKEND_ROOT" \
  script/fund/finalize-meta-wheel-manifest.sh >"$temporary_dir/finalizer-negative.log" 2>&1; then
  die "canonical finalizer accepted an Anvil fork"
fi
rg -q 'rejects local development RPC clients|rejects Anvil RPC methods' "$temporary_dir/finalizer-negative.log" \
  || die "canonical finalizer failed for the wrong reason"

echo "B1N-419 persistent Anvil rehearsal complete"
echo "All five library bindings were reused for build, tests, deploy, every phase, and reconciliation"
echo "Canonical finalization correctly rejected the fork; no live transaction was broadcast"
