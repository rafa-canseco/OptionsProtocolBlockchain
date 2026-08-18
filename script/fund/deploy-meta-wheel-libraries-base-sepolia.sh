#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "B1N-419 library prephase blocked: $*" >&2
  exit 1
}

for command_name in jq cast forge git shasum; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

expected_broadcaster=0x42cB85203838DD9708ED548DC4f815130E8F7e74

: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL is required}"
: "${B1N419_LIBRARY_BROADCASTER:?B1N419_LIBRARY_BROADCASTER is required}"
: "${B1N419_LIBRARY_DRAFT_PATH:?B1N419_LIBRARY_DRAFT_PATH is required}"
: "${B1N419_LIBRARY_SIDECAR_PATH:?B1N419_LIBRARY_SIDECAR_PATH is required}"

mode=${B1N419_LIBRARY_MODE:-simulate}
[[ "$mode" == "simulate" || "$mode" == "fork-broadcast" || "$mode" == "broadcast" ]] \
  || die "mode must be simulate, fork-broadcast, or broadcast"
[[ "$B1N419_LIBRARY_DRAFT_PATH" != *template.json ]] || die "draft path cannot be a template"
[[ "$B1N419_LIBRARY_SIDECAR_PATH" != *template.json ]] || die "sidecar path cannot be a template"
[[ "$B1N419_LIBRARY_DRAFT_PATH" != "$B1N419_LIBRARY_SIDECAR_PATH" ]] || die "draft and sidecar paths must differ"
[[ ! -e "$B1N419_LIBRARY_DRAFT_PATH" ]] || die "draft path already exists"
[[ ! -e "$B1N419_LIBRARY_SIDECAR_PATH" ]] || die "sidecar path already exists"
[[ "$B1N419_LIBRARY_BROADCASTER" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid broadcaster"
[[ "$B1N419_LIBRARY_BROADCASTER" != "0x0000000000000000000000000000000000000000" ]] \
  || die "zero broadcaster"
[[ "$(tr '[:upper:]' '[:lower:]' <<<"$B1N419_LIBRARY_BROADCASTER")" \
  == "$(tr '[:upper:]' '[:lower:]' <<<"$expected_broadcaster")" ]] \
  || die "library broadcaster is not the approved B1N-419 bootstrap identity"
[[ "$(cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL")" == "84532" ]] || die "RPC is not Base Sepolia"

source_commit=$(git rev-parse HEAD)
[[ "$source_commit" =~ ^[0-9a-fA-F]{40}$ ]] || die "source commit is not full"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die "source tree must be clean and committed"
export B1N419_LIBRARY_SOURCE_COMMIT=$source_commit
export B1N419_LIBRARY_BROADCASTER B1N419_LIBRARY_DRAFT_PATH

for argument in "$@"; do
  case "$argument" in
    --broadcast|--broadcast=*|--resume|--resume=*|--rpc-url|--rpc-url=*|--fork-url|--fork-url=*|--sender|--sender=*)
      die "orchestrator owns dangerous or identity flag: $argument"
      ;;
  esac
done

if [[ "$mode" == "broadcast" ]]; then
  client_version=$(cast rpc web3_clientVersion --rpc-url "$BASE_SEPOLIA_RPC_URL" | jq -r '.')
  client_version_lower=$(tr '[:upper:]' '[:lower:]' <<<"$client_version")
  [[ "$client_version_lower" != *anvil* && "$client_version_lower" != *hardhat* ]] \
    || die "live mode rejects local development RPC clients"
  if cast rpc anvil_nodeInfo --rpc-url "$BASE_SEPOLIA_RPC_URL" >/dev/null 2>&1; then
    die "live mode rejects Anvil RPC methods"
  fi
  [[ "${B1N419_LIBRARY_BROADCAST_APPROVAL:-}" == "APPROVED_B1N419_BASE_SEPOLIA_LIBRARY_PREPHASE" ]] \
    || die "explicit Base Sepolia library approval is missing"
  [[ "${B1N419_LIBRARY_APPROVED_SOURCE_COMMIT:-}" == "$source_commit" ]] \
    || die "approved source commit mismatch"
elif [[ "$mode" == "fork-broadcast" ]]; then
  [[ "$B1N419_LIBRARY_DRAFT_PATH" == *fork* && "$B1N419_LIBRARY_SIDECAR_PATH" == *fork* ]] \
    || die "fork-broadcast artifacts require visibly fork-only paths"
  client_version=$(cast rpc web3_clientVersion --rpc-url "$BASE_SEPOLIA_RPC_URL" | jq -r '.')
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"$client_version")" == *anvil* ]] || die "fork-broadcast RPC is not Anvil"
  anvil_info=$(cast rpc anvil_nodeInfo --rpc-url "$BASE_SEPOLIA_RPC_URL") \
    || die "fork-broadcast RPC does not expose anvil_nodeInfo"
  jq -e '.forkConfig != null' <<<"$anvil_info" >/dev/null || die "Anvil is not backed by a fork"
fi

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT

forge_arguments=(
  forge script
  script/fund/DeployMetaWheelLibrariesBaseSepolia.s.sol:DeployMetaWheelLibrariesBaseSepolia
  --sig "deployLibraries()"
  --rpc-url "$BASE_SEPOLIA_RPC_URL"
)
if [[ "$mode" == "broadcast" || "$mode" == "fork-broadcast" ]]; then
  forge_arguments+=(--broadcast --slow)
fi
forge_arguments+=("$@")
"${forge_arguments[@]}"

[[ -f "$B1N419_LIBRARY_DRAFT_PATH" ]] || die "Solidity deployment draft was not written"

expected_artifacts='[
  "src/fund/libraries/CspFundAdapterOperations.sol:CspFundAdapterOperations",
  "src/fund/libraries/CoveredCallFundAdapterOperations.sol:CoveredCallFundAdapterOperations",
  "src/fund/libraries/ManagedStrategyOperations.sol:ManagedStrategyOperations",
  "src/fund/libraries/WheelManagedOperationDispatcher.sol:WheelManagedOperationDispatcher",
  "src/fund/libraries/WheelCoordinatorPositionOperations.sol:WheelCoordinatorPositionOperations"
]'
jq -e --arg commit "$source_commit" --arg broadcaster "$B1N419_LIBRARY_BROADCASTER" \
  --argjson expected "$expected_artifacts" '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and
  .sourceCommit == $commit and .chainId == 84532 and
  (.broadcaster | ascii_downcase) == ($broadcaster | ascii_downcase) and
  .orderedArtifacts == $expected and
  (.linkedLibraries | length) == 5 and
  ([.linkedLibraries[] | ascii_downcase] | unique | length) == 5 and
  all(.linkedLibraries[]; test("^0x[0-9a-fA-F]{40}$") and
      ascii_downcase != "0x0000000000000000000000000000000000000000") and
  (.linkedLibraryCodehashes | length) == 5 and
  all(.linkedLibraryCodehashes[]; test("^0x[0-9a-fA-F]{64}$") and
      ascii_downcase != "0x0000000000000000000000000000000000000000000000000000000000000000")
' "$B1N419_LIBRARY_DRAFT_PATH" >/dev/null || die "invalid Solidity library draft"

bindings=()
linker_arguments=()
for index in 0 1 2 3 4; do
  artifact=$(jq -r --argjson index "$index" '.orderedArtifacts[$index]' "$B1N419_LIBRARY_DRAFT_PATH")
  address=$(jq -r --argjson index "$index" '.linkedLibraries[$index]' "$B1N419_LIBRARY_DRAFT_PATH")
  bindings+=("$artifact:$address")
  linker_arguments+=(--libraries "$artifact:$address")
done
linker_json=$(printf '%s\n' "${bindings[@]}" | jq -R . | jq -s .)

records_file="$temporary_dir/library-records.jsonl"
: >"$records_file"
if [[ "$mode" == "broadcast" || "$mode" == "fork-broadcast" ]]; then
  run_file="broadcast/DeployMetaWheelLibrariesBaseSepolia.s.sol/84532/deployLibraries-latest.json"
  [[ -f "$run_file" ]] || die "Foundry broadcast receipt file is missing"
  transaction_rows=()
  while IFS= read -r transaction_row; do
    transaction_rows+=("$transaction_row")
  done < <(jq -r '.transactions[] | select(.transactionType == "CREATE") | [.contractAddress, .hash] | @tsv' "$run_file")
  [[ "${#transaction_rows[@]}" == "5" ]] || die "broadcast did not contain exactly five CREATE transactions"

  for index in 0 1 2 3 4; do
    artifact=$(jq -r --argjson index "$index" '.orderedArtifacts[$index]' "$B1N419_LIBRARY_DRAFT_PATH")
    address=$(jq -r --argjson index "$index" '.linkedLibraries[$index]' "$B1N419_LIBRARY_DRAFT_PATH")
    expected_codehash=$(jq -r --argjson index "$index" '.linkedLibraryCodehashes[$index]' \
      "$B1N419_LIBRARY_DRAFT_PATH")
    IFS=$'\t' read -r broadcast_address transaction_hash <<<"${transaction_rows[$index]}"
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$broadcast_address")" \
      == "$(tr '[:upper:]' '[:lower:]' <<<"$address")" ]] || die "CREATE order/address mismatch at index $index"
    receipt=$(cast receipt "$transaction_hash" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json) \
      || die "receipt unavailable for $transaction_hash"
    status=$(cast to-dec "$(jq -r '.status' <<<"$receipt")")
    block_number=$(cast to-dec "$(jq -r '.blockNumber' <<<"$receipt")")
    block_hash=$(jq -r '.blockHash' <<<"$receipt")
    receipt_contract=$(jq -r '.contractAddress' <<<"$receipt")
    [[ "$status" == "1" && "$block_number" -gt 0 ]] || die "failed library receipt at index $index"
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$receipt_contract")" \
      == "$(tr '[:upper:]' '[:lower:]' <<<"$address")" ]] || die "receipt contract mismatch at index $index"
    runtime_code=$(cast code "$address" --rpc-url "$BASE_SEPOLIA_RPC_URL")
    [[ "$runtime_code" != "0x" ]] || die "missing runtime code at $address"
    actual_codehash=$(cast keccak "$runtime_code")
    [[ "$(tr '[:upper:]' '[:lower:]' <<<"$actual_codehash")" \
      == "$(tr '[:upper:]' '[:lower:]' <<<"$expected_codehash")" ]] || die "runtime codehash mismatch at index $index"
    jq -cn --argjson index "$index" --arg artifact "$artifact" --arg address "$address" \
      --arg codehash "$expected_codehash" --arg tx "$transaction_hash" --arg blockHash "$block_hash" \
      --argjson blockNumber "$block_number" --argjson status "$status" '
      {index: $index, artifact: $artifact, address: $address, runtimeCodehash: $codehash,
       receipt: {transactionHash: $tx, blockHash: $blockHash, blockNumber: $blockNumber, status: $status}}
    ' >>"$records_file"
  done
else
  for index in 0 1 2 3 4; do
    jq -cn --argjson index "$index" \
      --arg artifact "$(jq -r --argjson index "$index" '.orderedArtifacts[$index]' "$B1N419_LIBRARY_DRAFT_PATH")" \
      --arg address "$(jq -r --argjson index "$index" '.linkedLibraries[$index]' "$B1N419_LIBRARY_DRAFT_PATH")" \
      --arg codehash "$(jq -r --argjson index "$index" '.linkedLibraryCodehashes[$index]' \
        "$B1N419_LIBRARY_DRAFT_PATH")" '
      {index: $index, artifact: $artifact, address: $address, runtimeCodehash: $codehash, receipt: null}
    ' >>"$records_file"
  done
fi

if [[ "$mode" == "broadcast" ]]; then
  status=CONFIRMED_CANONICAL_RECEIPTS
  deployment_status=DEPLOYED
  handoff_ready=true
  network_name=base-sepolia
  environment_kind=live
elif [[ "$mode" == "fork-broadcast" ]]; then
  status=SIMULATED_NONCANONICAL
  deployment_status=SIMULATED
  handoff_ready=false
  network_name=base-sepolia-anvil-fork
  environment_kind=anvil-fork
else
  status=SIMULATED_NONCANONICAL
  deployment_status=SIMULATED
  handoff_ready=false
  network_name=base-sepolia-ephemeral-fork
  environment_kind=ephemeral-fork
fi

jq -s --arg status "$status" --arg deploymentStatus "$deployment_status" --arg commit "$source_commit" \
  --arg broadcaster "$B1N419_LIBRARY_BROADCASTER" --argjson handoffReady "$handoff_ready" \
  --arg networkName "$network_name" --arg environmentKind "$environment_kind" \
  --argjson linkerArguments "$linker_json" '
  {schemaVersion: "1.0.0", issue: "B1N-419", status: $status,
   deploymentStatus: $deploymentStatus, handoffReady: $handoffReady, sourceCommit: $commit,
   network: {name: $networkName, chainId: 84532, environmentKind: $environmentKind}, broadcaster: $broadcaster,
   orderedLibraries: ., linkerArguments: $linkerArguments, exactRelinkVerified: false}
' "$records_file" >"$temporary_dir/sidecar-unlinked.json"

forge clean
forge build "${linker_arguments[@]}"
configured_libraries=$(forge config --json "${linker_arguments[@]}" | jq -c '.libraries')
[[ "$configured_libraries" == "$(jq -c . <<<"$linker_json")" ]] || die "Foundry exact link map mismatch"
jq '.exactRelinkVerified = true' "$temporary_dir/sidecar-unlinked.json" >"$temporary_dir/sidecar-final.json"

jq -e --arg status "$status" --argjson handoffReady "$handoff_ready" '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and .status == $status and
  .handoffReady == $handoffReady and .network.chainId == 84532 and
  (.orderedLibraries | length) == 5 and .exactRelinkVerified == true
' "$temporary_dir/sidecar-final.json" >/dev/null || die "final library sidecar failed schema checks"

mv "$temporary_dir/sidecar-final.json" "$B1N419_LIBRARY_SIDECAR_PATH"
echo "B1N-419 library prephase complete: $status"
echo "Sidecar: $B1N419_LIBRARY_SIDECAR_PATH"
if [[ "$mode" != "broadcast" ]]; then
  echo "No live transaction was broadcast; all addresses and receipts are noncanonical"
fi
