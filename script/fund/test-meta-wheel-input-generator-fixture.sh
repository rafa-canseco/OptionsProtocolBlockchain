#!/usr/bin/env bash
set -euo pipefail

for command_name in jq cast shasum rg; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "missing generator fixture command: $command_name" >&2
    exit 1
  }
done

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_dir"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

real_cast=$(command -v cast)
source_commit=1111111111111111111111111111111111111111
bootstrap=0x42cB85203838DD9708ED548DC4f815130E8F7e74
settler_owner=0x376a4c54623fe24D0Ffc1032D0b6CcC03A32fd7D
runtime_codehash=$($real_cast keccak 0x6000)

address_for() {
  printf '0x%040x' "$1"
}

hash_for() {
  printf '0x%064x' "$1"
}

dependencies=$(jq -n \
  --arg ADDRESS_BOOK "$(address_for 1)" --arg CONTROLLER "$(address_for 2)" \
  --arg BATCH_SETTLER "$(address_for 3)" --arg MARGIN_POOL "$(address_for 4)" \
  --arg ORACLE "$(address_for 5)" --arg OTOKEN_FACTORY "$(address_for 6)" \
  --arg WHITELIST "$(address_for 7)" --arg USDC "$(address_for 8)" \
  --arg WETH "$(address_for 9)" --arg SWAP_ROUTER "$(address_for 10)" \
  --arg SPOT_FEED "$(address_for 11)" '$ARGS.named')

standalone=$(jq -n --arg hash "$runtime_codehash" \
  --arg cspVaultProxy "$(address_for 101)" --arg cspVaultImplementation "$(address_for 102)" \
  --arg cspAdapterProxy "$(address_for 103)" --arg cspAdapterImplementation "$(address_for 104)" \
  --arg ccVaultProxy "$(address_for 105)" --arg ccVaultImplementation "$(address_for 106)" \
  --arg ccAdapterProxy "$(address_for 107)" --arg ccAdapterImplementation "$(address_for 108)" '
  {CSP_VAULT_PROXY: $cspVaultProxy, CSP_VAULT_IMPLEMENTATION: $cspVaultImplementation,
   CSP_VAULT_IMPLEMENTATION_CODEHASH: $hash,
   CSP_ADAPTER_PROXY: $cspAdapterProxy, CSP_ADAPTER_IMPLEMENTATION: $cspAdapterImplementation,
   CSP_ADAPTER_IMPLEMENTATION_CODEHASH: $hash,
   CC_VAULT_PROXY: $ccVaultProxy, CC_VAULT_IMPLEMENTATION: $ccVaultImplementation,
   CC_VAULT_IMPLEMENTATION_CODEHASH: $hash,
   CC_ADAPTER_PROXY: $ccAdapterProxy, CC_ADAPTER_IMPLEMENTATION: $ccAdapterImplementation,
   CC_ADAPTER_IMPLEMENTATION_CODEHASH: $hash}
')

jq -n --arg sourceCommit "$source_commit" --arg bootstrap "$bootstrap" \
  --arg feeRecipient "$settler_owner" --argjson dependencies "$dependencies" --argjson standalone "$standalone" '
  {schemaVersion: "1.0.0", issue: "B1N-419", approval: "APPROVED_BASE_SEPOLIA_DRY_RUN",
   sourceCommit: $sourceCommit, network: {name: "base-sepolia", chainId: 84532},
   dependencies: $dependencies, bootstrapBroadcaster: $bootstrap,
   factoryOwner: "0x0000000000000000000000000000000000000020", feeRecipient: $feeRecipient,
   finalRoles: {
     admin: "0x0000000000000000000000000000000000000020",
     upgrader: "0x0000000000000000000000000000000000000021",
     accounting: "0x0000000000000000000000000000000000000022",
     allocator: "0x0000000000000000000000000000000000000023",
     processor: "0x0000000000000000000000000000000000000024",
     curator: "0x0000000000000000000000000000000000000025",
     guardian: "0x0000000000000000000000000000000000000026"},
   approvedObservers: [
     "0x0000000000000000000000000000000000000030",
     "0x0000000000000000000000000000000000000031",
     "0x0000000000000000000000000000000000000032",
     "0x0000000000000000000000000000000000000033"],
   navReporters: [
     "0x0000000000000000000000000000000000000034",
     "0x0000000000000000000000000000000000000035"],
   standalone: $standalone}
' >"$fixture_dir/pins.json"

libraries_jsonl="$fixture_dir/libraries.jsonl"
: >"$libraries_jsonl"
for index in 0 1 2 3 4; do
  jq -cn --argjson index "$index" --arg address "$(address_for "$((200 + index))")" \
    --arg codehash "$runtime_codehash" --arg transactionHash "$(hash_for "$((300 + index))")" '
    {index: $index, artifact: ("fixture/Library" + ($index | tostring) + ".sol:Library" + ($index | tostring)),
     address: $address, runtimeCodehash: $codehash,
     receipt: {transactionHash: $transactionHash, blockHash: $transactionHash, blockNumber: ($index + 1), status: 1}}
  ' >>"$libraries_jsonl"
done
jq -n --arg sourceCommit "$source_commit" --arg broadcaster "$bootstrap" \
  --slurpfile libraries "$libraries_jsonl" '
  {schemaVersion: "1.0.0", issue: "B1N-419", status: "SIMULATED_NONCANONICAL",
   deploymentStatus: "SIMULATED", handoffReady: false, sourceCommit: $sourceCommit,
   network: {name: "base-sepolia", chainId: 84532, environmentKind: "anvil-fork"},
   broadcaster: $broadcaster, orderedLibraries: $libraries, exactRelinkVerified: true}
' >"$fixture_dir/library-evidence.json"

jq -n --arg cspVaultProxy "$(address_for 101)" --arg cspVaultImplementation "$(hash_for 102)" \
  --arg cspAdapterProxy "$(address_for 103)" --arg cspAdapterImplementation "$(hash_for 104)" \
  --arg ccVaultProxy "$(address_for 105)" --arg ccVaultImplementation "$(hash_for 106)" \
  --arg ccAdapterProxy "$(address_for 107)" --arg ccAdapterImplementation "$(hash_for 108)" '
  {($cspVaultProxy): $cspVaultImplementation, ($cspAdapterProxy): $cspAdapterImplementation,
   ($ccVaultProxy): $ccVaultImplementation, ($ccAdapterProxy): $ccAdapterImplementation}
' >"$fixture_dir/proxy-implementations.json"

mkdir -p "$fixture_dir/bin"
ln -s "$project_dir/test/fixtures/b1n419-generator/mock-cast.sh" "$fixture_dir/bin/cast"
ln -s "$project_dir/test/fixtures/b1n419-generator/mock-git.sh" "$fixture_dir/bin/git"

run_generator() {
  local pins=$1
  local output=$2
  local digest=$3
  PATH="$fixture_dir/bin:$PATH" \
  BASE_SEPOLIA_RPC_URL=https://fixture.invalid \
  B1N419_INPUT_MODE=dry-run \
  B1N419_DEPLOYMENT_PINS_PATH="$pins" \
  B1N419_LIBRARY_EVIDENCE_PATH="$fixture_dir/library-evidence.json" \
  B1N419_APPROVED_INPUTS_OUTPUT="$output" \
  B1N419_APPROVED_INPUTS_DIGEST_OUTPUT="$digest" \
  B1N419_FIXTURE_REAL_CAST="$real_cast" \
  B1N419_FIXTURE_SOURCE_COMMIT="$source_commit" \
  B1N419_FIXTURE_SETTLER_OWNER="$settler_owner" \
  B1N419_FIXTURE_RUNTIME_CODEHASH="$runtime_codehash" \
  B1N419_FIXTURE_PROXY_IMPLEMENTATIONS="$fixture_dir/proxy-implementations.json" \
  /bin/bash script/fund/generate-meta-wheel-approved-inputs.sh
}

run_generator "$fixture_dir/pins.json" "$fixture_dir/approved-inputs.json" "$fixture_dir/approved-inputs.sha256"
jq -e --arg feeRecipient "$settler_owner" '
  .approval == "APPROVED_BASE_SEPOLIA_DRY_RUN" and .environment.FEE_RECIPIENT == $feeRecipient
' "$fixture_dir/approved-inputs.json" >/dev/null

assert_overlap_rejected() {
  local name=$1
  local filter=$2
  jq --arg feeRecipient "$settler_owner" "$filter" "$fixture_dir/pins.json" >"$fixture_dir/pins-$name.json"
  if run_generator "$fixture_dir/pins-$name.json" "$fixture_dir/output-$name.json" \
    "$fixture_dir/output-$name.sha256" >"$fixture_dir/$name.log" 2>&1; then
    echo "approved-input generator accepted identity overlap: $name" >&2
    exit 1
  fi
  rg -q 'pins are incomplete, overlapping, or unapproved' "$fixture_dir/$name.log"
}

# shellcheck disable=SC2016
assert_overlap_rejected final-role '.finalRoles.upgrader = $feeRecipient'
# shellcheck disable=SC2016
assert_overlap_rejected observer '.approvedObservers[0] = $feeRecipient'
# shellcheck disable=SC2016
assert_overlap_rejected reporter '.navReporters[0] = $feeRecipient'
echo "B1N-419 approved-input identity-separation fixture passed"
