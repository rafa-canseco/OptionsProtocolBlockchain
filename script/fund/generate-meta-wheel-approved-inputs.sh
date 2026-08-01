#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "B1N-419 approved-input generation blocked: $*" >&2
  exit 1
}

for command_name in jq cast git shasum; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL is required}"
: "${B1N419_DEPLOYMENT_PINS_PATH:?B1N419_DEPLOYMENT_PINS_PATH is required}"
: "${B1N419_LIBRARY_EVIDENCE_PATH:?B1N419_LIBRARY_EVIDENCE_PATH is required}"
: "${B1N419_APPROVED_INPUTS_OUTPUT:?B1N419_APPROVED_INPUTS_OUTPUT is required}"
: "${B1N419_APPROVED_INPUTS_DIGEST_OUTPUT:?B1N419_APPROVED_INPUTS_DIGEST_OUTPUT is required}"

mode=${B1N419_INPUT_MODE:-dry-run}
[[ "$mode" == "dry-run" || "$mode" == "live" ]] || die "mode must be dry-run or live"
template_path=deployments/base-sepolia/b1n-419/deployment-inputs.template.json
[[ -f "$template_path" && -f "$B1N419_DEPLOYMENT_PINS_PATH" && -f "$B1N419_LIBRARY_EVIDENCE_PATH" ]] \
  || die "template, pins, or library evidence is missing"
[[ "$B1N419_DEPLOYMENT_PINS_PATH" != *template.json ]] || die "template pins are never approved"
[[ ! -e "$B1N419_APPROVED_INPUTS_OUTPUT" && ! -e "$B1N419_APPROVED_INPUTS_DIGEST_OUTPUT" ]] \
  || die "approved output or digest already exists"
[[ "$(cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL")" == "84532" ]] || die "wrong chain id"

source_commit=$(git rev-parse HEAD)
[[ "$source_commit" =~ ^[0-9a-fA-F]{40}$ ]] || die "invalid source commit"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "source tree must be clean and committed"

if [[ "$mode" == "live" ]]; then
  required_approval=APPROVED_BASE_SEPOLIA_LIVE
  required_status=CONFIRMED_CANONICAL_RECEIPTS
  required_environment=live
  client_version=$(cast rpc web3_clientVersion --rpc-url "$BASE_SEPOLIA_RPC_URL" | jq -r '.')
  client_version_lower=$(tr '[:upper:]' '[:lower:]' <<<"$client_version")
  [[ "$client_version_lower" != *anvil* && "$client_version_lower" != *hardhat* ]] \
    || die "live inputs reject local RPC clients"
  if cast rpc anvil_nodeInfo --rpc-url "$BASE_SEPOLIA_RPC_URL" >/dev/null 2>&1; then
    die "live inputs reject Anvil"
  fi
else
  required_approval=APPROVED_BASE_SEPOLIA_DRY_RUN
  required_status=SIMULATED_NONCANONICAL
  required_environment=anvil-fork
  anvil_info=$(cast rpc anvil_nodeInfo --rpc-url "$BASE_SEPOLIA_RPC_URL") || die "dry-run inputs require Anvil"
  jq -e '.forkConfig != null' <<<"$anvil_info" >/dev/null || die "Anvil is not fork-backed"
fi

jq -e --arg approval "$required_approval" --arg commit "$source_commit" '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and .approval == $approval and
  .sourceCommit == $commit and .network.name == "base-sepolia" and .network.chainId == 84532 and
  (.bootstrapBroadcaster | test("^0x[0-9a-fA-F]{40}$") and
    ascii_downcase != "0x0000000000000000000000000000000000000000") and
  .factoryOwner == .finalRoles.admin and
  ([.finalRoles[], .bootstrapBroadcaster, .approvedObservers[], .navReporters[]] | length) == 14 and
  ([.finalRoles[], .bootstrapBroadcaster, .approvedObservers[], .navReporters[] | ascii_downcase] | unique | length)
    == 14 and
  (.approvedObservers | length) == 4 and (.navReporters | length) == 2 and
  all([.finalRoles[], .bootstrapBroadcaster, .feeRecipient, .approvedObservers[], .navReporters[]][];
    test("^0x[0-9a-fA-F]{40}$") and ascii_downcase != "0x0000000000000000000000000000000000000000") and
  all(.dependencies[]; test("^0x[0-9a-fA-F]{40}$") and
    ascii_downcase != "0x0000000000000000000000000000000000000000") and
  all(.standalone[]; test("^0x[0-9a-fA-F]{40}$") or test("^0x[0-9a-fA-F]{64}$")) and
  all(.standalone[]; ascii_downcase != "0x0000000000000000000000000000000000000000" and
    ascii_downcase != "0x0000000000000000000000000000000000000000000000000000000000000000")
' "$B1N419_DEPLOYMENT_PINS_PATH" >/dev/null || die "pins are incomplete, overlapping, or unapproved"

jq -e --arg status "$required_status" --arg environment "$required_environment" --arg commit "$source_commit" '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and .status == $status and
  .sourceCommit == $commit and .network.chainId == 84532 and .network.environmentKind == $environment and
  .exactRelinkVerified == true and (.orderedLibraries | length) == 5 and
  all(.orderedLibraries[]; .receipt.status == 1)
' "$B1N419_LIBRARY_EVIDENCE_PATH" >/dev/null || die "library evidence does not match mode/source"

for address in $(jq -r '.dependencies[]' "$B1N419_DEPLOYMENT_PINS_PATH"); do
  [[ "$(cast code "$address" --rpc-url "$BASE_SEPOLIA_RPC_URL")" != "0x" ]] || die "dependency has no code: $address"
done
for index in 0 1 2 3 4; do
  address=$(jq -r --argjson index "$index" '.orderedLibraries[$index].address' "$B1N419_LIBRARY_EVIDENCE_PATH")
  expected=$(jq -r --argjson index "$index" '.orderedLibraries[$index].runtimeCodehash' \
    "$B1N419_LIBRARY_EVIDENCE_PATH")
  actual=$(cast codehash "$address" --rpc-url "$BASE_SEPOLIA_RPC_URL")
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$actual")" == "$(tr '[:upper:]' '[:lower:]' <<<"$expected")" ]] \
    || die "library codehash drift at index $index"
done

implementation_slot=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
for prefix in CSP_VAULT CSP_ADAPTER CC_VAULT CC_ADAPTER; do
  proxy=$(jq -r --arg key "${prefix}_PROXY" '.standalone[$key]' "$B1N419_DEPLOYMENT_PINS_PATH")
  implementation=$(jq -r --arg key "${prefix}_IMPLEMENTATION" '.standalone[$key]' \
    "$B1N419_DEPLOYMENT_PINS_PATH")
  expected_codehash=$(jq -r --arg key "${prefix}_IMPLEMENTATION_CODEHASH" '.standalone[$key]' \
    "$B1N419_DEPLOYMENT_PINS_PATH")
  actual_implementation=$(cast parse-bytes32-address \
    "$(cast storage "$proxy" "$implementation_slot" --rpc-url "$BASE_SEPOLIA_RPC_URL")")
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$actual_implementation")" \
    == "$(tr '[:upper:]' '[:lower:]' <<<"$implementation")" ]] || die "$prefix implementation drift"
  actual_codehash=$(cast codehash "$implementation" --rpc-url "$BASE_SEPOLIA_RPC_URL")
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$actual_codehash")" \
    == "$(tr '[:upper:]' '[:lower:]' <<<"$expected_codehash")" ]] || die "$prefix codehash drift"
done

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT
jq -S --slurpfile pins "$B1N419_DEPLOYMENT_PINS_PATH" \
  --slurpfile libraries "$B1N419_LIBRARY_EVIDENCE_PATH" '
  $pins[0] as $p | $libraries[0] as $l |
  .approval = $p.approval |
  .environment.SOURCE_COMMIT = $p.sourceCommit |
  .environment += $p.dependencies |
  .environment.FACTORY_OWNER = $p.factoryOwner |
  .environment.FEE_RECIPIENT = $p.feeRecipient |
  .environment.ROLE_ADMIN = $p.bootstrapBroadcaster |
  .environment.ROLE_UPGRADER = $p.bootstrapBroadcaster |
  .environment.ROLE_ACCOUNTING = $p.bootstrapBroadcaster |
  .environment.ROLE_ALLOCATOR = $p.bootstrapBroadcaster |
  .environment.ROLE_PROCESSOR = $p.bootstrapBroadcaster |
  .environment.ROLE_CURATOR = $p.bootstrapBroadcaster |
  .environment.ROLE_GUARDIAN = $p.bootstrapBroadcaster |
  .environment.FINAL_ROLE_ADMIN = $p.finalRoles.admin |
  .environment.FINAL_ROLE_UPGRADER = $p.finalRoles.upgrader |
  .environment.FINAL_ROLE_ACCOUNTING = $p.finalRoles.accounting |
  .environment.FINAL_ROLE_ALLOCATOR = $p.finalRoles.allocator |
  .environment.FINAL_ROLE_PROCESSOR = $p.finalRoles.processor |
  .environment.FINAL_ROLE_CURATOR = $p.finalRoles.curator |
  .environment.FINAL_ROLE_GUARDIAN = $p.finalRoles.guardian |
  .environment.APPROVED_OBSERVERS = $p.approvedObservers |
  .environment.NAV_REPORTERS = $p.navReporters |
  .environment.STANDALONE_CSP_VAULT_PROXY = $p.standalone.CSP_VAULT_PROXY |
  .environment.STANDALONE_CSP_VAULT_IMPLEMENTATION = $p.standalone.CSP_VAULT_IMPLEMENTATION |
  .environment.STANDALONE_CSP_VAULT_IMPLEMENTATION_CODEHASH = $p.standalone.CSP_VAULT_IMPLEMENTATION_CODEHASH |
  .environment.STANDALONE_CSP_ADAPTER_PROXY = $p.standalone.CSP_ADAPTER_PROXY |
  .environment.STANDALONE_CSP_ADAPTER_IMPLEMENTATION = $p.standalone.CSP_ADAPTER_IMPLEMENTATION |
  .environment.STANDALONE_CSP_ADAPTER_IMPLEMENTATION_CODEHASH = $p.standalone.CSP_ADAPTER_IMPLEMENTATION_CODEHASH |
  .environment.STANDALONE_CC_VAULT_PROXY = $p.standalone.CC_VAULT_PROXY |
  .environment.STANDALONE_CC_VAULT_IMPLEMENTATION = $p.standalone.CC_VAULT_IMPLEMENTATION |
  .environment.STANDALONE_CC_VAULT_IMPLEMENTATION_CODEHASH = $p.standalone.CC_VAULT_IMPLEMENTATION_CODEHASH |
  .environment.STANDALONE_CC_ADAPTER_PROXY = $p.standalone.CC_ADAPTER_PROXY |
  .environment.STANDALONE_CC_ADAPTER_IMPLEMENTATION = $p.standalone.CC_ADAPTER_IMPLEMENTATION |
  .environment.STANDALONE_CC_ADAPTER_IMPLEMENTATION_CODEHASH = $p.standalone.CC_ADAPTER_IMPLEMENTATION_CODEHASH |
  .environment.LINKED_LIBRARIES = [$l.orderedLibraries[].address] |
  .environment.LINKED_LIBRARY_CODEHASHES = [$l.orderedLibraries[].runtimeCodehash]
' "$template_path" >"$temporary_dir/approved-inputs.json"

jq -e --arg approval "$required_approval" --arg commit "$source_commit" '
  .approval == $approval and .environment.SOURCE_COMMIT == $commit and
  (.environment.APPROVED_OBSERVERS | length) == 4 and (.environment.NAV_REPORTERS | length) == 2 and
  (.environment.LINKED_LIBRARIES | length) == 5 and
  ([(.. | strings) | select(contains("REQUIRED") or startswith("NOT_APPROVED") or
      . == "0x0000000000000000000000000000000000000000" or
      . == "0x0000000000000000000000000000000000000000000000000000000000000000")] | length) == 0
' "$temporary_dir/approved-inputs.json" >/dev/null || die "generated inputs retain a placeholder"

mv "$temporary_dir/approved-inputs.json" "$B1N419_APPROVED_INPUTS_OUTPUT"
digest="0x$(shasum -a 256 "$B1N419_APPROVED_INPUTS_OUTPUT" | awk '{print $1}')"
printf '%s\n' "$digest" >"$B1N419_APPROVED_INPUTS_DIGEST_OUTPUT"
echo "B1N-419 approved inputs generated deterministically"
echo "Inputs: $B1N419_APPROVED_INPUTS_OUTPUT"
echo "Digest: $B1N419_APPROVED_INPUTS_DIGEST_OUTPUT"
