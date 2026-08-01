#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "B1N-419 finalization blocked: $*" >&2
  exit 1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

expected_bootstrap=0x097Bfce6f1Fd87DaA4B5f74e230eC60729eb6425
expected_settler_owner=0x376a4c54623fe24D0Ffc1032D0b6CcC03A32fd7D
expected_bootstrap_lower=$(lower "$expected_bootstrap")
expected_settler_owner_lower=$(lower "$expected_settler_owner")

for command_name in jq cast forge shasum; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL is required}"
: "${B1N419_MANIFEST_PATH:?B1N419_MANIFEST_PATH is required}"
: "${B1N419_CANONICALIZATION_EVIDENCE_PATH:?B1N419_CANONICALIZATION_EVIDENCE_PATH is required}"
: "${B1N419_LIBRARY_EVIDENCE_PATH:?B1N419_LIBRARY_EVIDENCE_PATH is required}"
: "${B1N419_CANONICAL_MANIFEST_PATH:?B1N419_CANONICAL_MANIFEST_PATH is required}"
: "${B1N419_APPROVED_INPUTS_PATH:?B1N419_APPROVED_INPUTS_PATH is required}"
: "${B1N419_APPROVED_INPUTS_SHA256:?B1N419_APPROVED_INPUTS_SHA256 is required}"
: "${B1N419_BACKEND_ROOT:?B1N419_BACKEND_ROOT is required}"

manifest_path=$B1N419_MANIFEST_PATH
evidence_path=$B1N419_CANONICALIZATION_EVIDENCE_PATH
library_evidence_path=$B1N419_LIBRARY_EVIDENCE_PATH
canonical_path=$B1N419_CANONICAL_MANIFEST_PATH
backend_root=$B1N419_BACKEND_ROOT
backend_python=${B1N419_BACKEND_PYTHON:-python3}
command -v "$backend_python" >/dev/null 2>&1 || die "backend Python executable not found: $backend_python"

[[ -f "$manifest_path" ]] || die "unconfirmed manifest not found"
[[ -f "$evidence_path" ]] || die "canonicalization evidence not found"
[[ -f "$library_evidence_path" ]] || die "library prephase evidence not found"
[[ -f "$backend_root/src/deployment_manifest.py" ]] || die "backend parser not found"
[[ "$manifest_path" != "$canonical_path" ]] || die "canonical output must not overwrite the unconfirmed manifest"
[[ ! -e "$canonical_path" ]] || die "canonical output already exists"

approved_inputs_digest="0x$(shasum -a 256 "$B1N419_APPROVED_INPUTS_PATH" | awk '{print $1}')"
[[ "$(lower "$approved_inputs_digest")" == "$(lower "$B1N419_APPROVED_INPUTS_SHA256")" ]] \
  || die "approved input digest mismatch"

chain_id=$(cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL")
[[ "$chain_id" == "84532" ]] || die "RPC is not Base Sepolia"
client_version=$(cast rpc web3_clientVersion --rpc-url "$BASE_SEPOLIA_RPC_URL" | jq -r '.')
client_version_lower=$(lower "$client_version")
[[ "$client_version_lower" != *anvil* && "$client_version_lower" != *hardhat* ]] \
  || die "canonical finalization rejects local development RPC clients"
if cast rpc anvil_nodeInfo --rpc-url "$BASE_SEPOLIA_RPC_URL" >/dev/null 2>&1; then
  die "canonical finalization rejects Anvil RPC methods"
fi

jq -e '
  .schemaVersion == "1.0.0" and
  .issue == "B1N-419" and
  .status == "UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS" and
  .deploymentStatus == "UNCONFIRMED" and
  .handoffReady == false
' "$manifest_path" >/dev/null || die "input manifest is not the unconfirmed B1N-419 artifact"

jq -e '
  .schemaVersion == "1.0.0" and
  .issue == "B1N-419" and
  .approval == "APPROVED_CANONICALIZATION" and
  .network.name == "base-sepolia" and
  .network.chainId == 84532 and
  .network.environmentKind == "live" and
  .verification.blockscoutVerificationComplete == true and
  .reconciliation.bootstrapReconciled == true and
  .reconciliation.finalRolesReconciled == true and
  .reconciliation.standaloneBaselinesUnchanged == true and
  .reconciliation.managedWrappersOnly == true and
  .reconciliation.coordinatorConfiguredInactiveBeforeManagedLaneSetup == true and
  .reconciliation.finalReconciliationBlock > 0
' "$evidence_path" >/dev/null || die "evidence approval, verification, or reconciliation is incomplete"

jq -e '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and
  .status == "CONFIRMED_CANONICAL_RECEIPTS" and .deploymentStatus == "DEPLOYED" and
  .handoffReady == true and .network.name == "base-sepolia" and .network.chainId == 84532 and
  .network.environmentKind == "live" and
  .exactRelinkVerified == true and
  (.orderedLibraries | length) == 5 and
  ([.orderedLibraries[].address | ascii_downcase] | unique | length) == 5 and
  all(.orderedLibraries[];
    (.index | type == "number" and . >= 0 and . < 5) and
    (.artifact | type == "string" and length > 0) and
    (.address | test("^0x[0-9a-fA-F]{40}$")) and
    (.runtimeCodehash | test("^0x[0-9a-fA-F]{64}$")) and
    (.receipt.transactionHash | test("^0x[0-9a-fA-F]{64}$")) and
    (.receipt.blockHash | test("^0x[0-9a-fA-F]{64}$")) and
    (.receipt.blockNumber | type == "number" and . > 0) and .receipt.status == 1)
' "$library_evidence_path" >/dev/null || die "library prephase is not canonical and relinked"

manifest_digest="0x$(shasum -a 256 "$manifest_path" | awk '{print $1}')"
expected_digest=$(jq -r '.unconfirmedManifestSha256' "$evidence_path")
[[ "$(lower "$manifest_digest")" == "$(lower "$expected_digest")" ]] \
  || die "unconfirmed manifest digest mismatch"

manifest_source=$(jq -r '.sourceCommit' "$manifest_path")
evidence_source=$(jq -r '.sourceCommit' "$evidence_path")
library_source=$(jq -r '.sourceCommit' "$library_evidence_path")
manifest_deployment_id=$(jq -r '.deploymentId' "$manifest_path")
evidence_deployment_id=$(jq -r '.deploymentId' "$evidence_path")
[[ "$manifest_source" == "$evidence_source" ]] || die "sourceCommit does not bind the sidecar"
[[ "$manifest_source" == "$library_source" ]] || die "sourceCommit does not bind library evidence"
[[ "$(lower "$manifest_deployment_id")" == "$(lower "$evidence_deployment_id")" ]] \
  || die "deploymentId does not bind the sidecar"
[[ "$manifest_source" =~ ^[0-9a-fA-F]{40}$ ]] || die "sourceCommit is not a full git commit"
[[ "$manifest_deployment_id" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "deploymentId is malformed"
[[ "$manifest_deployment_id" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]] || die "deploymentId is zero"

jq -n -e --slurpfile inputs "$B1N419_APPROVED_INPUTS_PATH" \
  --slurpfile libraries "$library_evidence_path" \
  --arg bootstrap "$expected_bootstrap_lower" --arg settlerOwner "$expected_settler_owner_lower" '
  $inputs[0].environment as $env |
  [$env.FINAL_ROLE_ADMIN, $env.FINAL_ROLE_UPGRADER, $env.FINAL_ROLE_ACCOUNTING,
   $env.FINAL_ROLE_ALLOCATOR, $env.FINAL_ROLE_PROCESSOR, $env.FINAL_ROLE_CURATOR,
   $env.FINAL_ROLE_GUARDIAN, $env.ROLE_ADMIN, $env.FEE_RECIPIENT,
   $env.APPROVED_OBSERVERS[], $env.NAV_REPORTERS[] | ascii_downcase] as $separatedIdentities |
  ($env.ROLE_ADMIN | ascii_downcase) == $bootstrap and
  all([$env.ROLE_UPGRADER, $env.ROLE_ACCOUNTING, $env.ROLE_ALLOCATOR, $env.ROLE_PROCESSOR,
       $env.ROLE_CURATOR, $env.ROLE_GUARDIAN][]; ascii_downcase == $bootstrap) and
  ($env.FEE_RECIPIENT | ascii_downcase) == $settlerOwner and
  ($libraries[0].broadcaster | ascii_downcase) == $bootstrap and
  ($env.APPROVED_OBSERVERS | length) == 4 and
  ([$env.APPROVED_OBSERVERS[] | ascii_downcase] | unique | length) == 4 and
  ($env.NAV_REPORTERS | length) == 2 and
  ([$env.NAV_REPORTERS[] | ascii_downcase] | unique | length) == 2 and
  ($separatedIdentities | length) == 15 and
  ($separatedIdentities | unique | length) == 15 and
  all($separatedIdentities[];
    test("^0x[0-9a-f]{40}$") and . != "0x0000000000000000000000000000000000000000")
' >/dev/null || die "approved identities do not bind inputs and library evidence"
expected_curator=$(jq -r '.environment.FINAL_ROLE_CURATOR | ascii_downcase' "$B1N419_APPROVED_INPUTS_PATH")
expected_guardian=$(jq -r '.environment.FINAL_ROLE_GUARDIAN | ascii_downcase' "$B1N419_APPROVED_INPUTS_PATH")

jq -e --slurpfile libraries "$library_evidence_path" '
  [.linkedLibraries[] | ascii_downcase]
    == [$libraries[0].orderedLibraries[].address | ascii_downcase] and
  [.linkedLibraryCodehashes[] | ascii_downcase]
    == [$libraries[0].orderedLibraries[].runtimeCodehash | ascii_downcase]
' "$manifest_path" >/dev/null || die "manifest library bindings do not match prephase evidence"

jq -n -e --slurpfile evidence "$evidence_path" --slurpfile libraries "$library_evidence_path" '
  [$libraries[0].orderedLibraries[].receipt.transactionHash | ascii_downcase] as $libraryTransactions |
  [$evidence[0].canonicalReceipts[].transactionHash,
   $evidence[0].phaseReceipts[][] .transactionHash,
   $evidence[0].contractReceipts[].transactionHash | ascii_downcase] as $fundTransactions |
  ($libraryTransactions | length) == ($libraryTransactions | unique | length) and
  all($libraryTransactions[]; . as $tx | ($fundTransactions | index($tx)) == null)
' >/dev/null || die "library receipts are duplicated or overlap fund receipts"

for phase_name in bootstrapDeployment finalRoleRotation inactiveCoordinatorConfiguration managedLaneSetup childAdapterOnboarding; do
  jq -e --arg phase "$phase_name" '
    .phaseReceipts[$phase] | type == "array" and length > 0 and
    all(.[]; (.transactionHash | test("^0x[0-9a-fA-F]{64}$")) and
             (.blockHash | test("^0x[0-9a-fA-F]{64}$")) and
             (.blockNumber | type == "number" and . > 0) and .status == 1)
  ' "$evidence_path" \
    >/dev/null || die "missing phase receipts for $phase_name"
done
jq -e '
  [.phaseReceipts[][].transactionHash | ascii_downcase]
  | length == (unique | length)
' "$evidence_path" >/dev/null || die "a transaction receipt is assigned to multiple phases"

jq -e '
  .canonicalReceipts | type == "array" and length > 1 and
  all(.[]; (.transactionHash | test("^0x[0-9a-fA-F]{64}$")) and
           (.blockHash | test("^0x[0-9a-fA-F]{64}$")) and
           (.blockNumber | type == "number" and . > 0) and .status == 1)
' "$evidence_path" >/dev/null || die "canonical deployment receipts are incomplete"

jq -e '
  .contractReceipts | type == "array" and length > 0 and
  (length == ([.[].address | ascii_downcase] | unique | length)) and
  all(.[]; (.contract | type == "string" and length > 0) and
           (.address | test("^0x[0-9a-fA-F]{40}$")) and
           (.runtimeCodehash | test("^0x[0-9a-fA-F]{64}$")) and
           (.transactionHash | test("^0x[0-9a-fA-F]{64}$")) and
           (.blockHash | test("^0x[0-9a-fA-F]{64}$")) and
           (.blockNumber | type == "number" and . > 0) and .status == 1)
' "$evidence_path" >/dev/null || die "contract receipts are incomplete"

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT

jq -c '
  [
    .factory, .accessManagerDeployer,
    .vaultImplementation, .shareImplementation, .accountingImplementation,
    .flowImplementation, .strategyImplementation, .navVerifier,
    .vault, .share, .accounting, .flow, .strategy, .claimEscrow, .accessManager,
    .coordinatorImplementation, .coordinator, .metaWheelValuator,
    .cspAdapterImplementation, .cspLaneImplementation, .cspValuator,
    .coveredCallAdapterImplementation, .coveredCallLaneImplementation, .coveredCallValuator,
    .inKindEscrow, .emergencyEscrow
  ] + .cspLanes + .cspAdapters + .coveredCallLanes + .coveredCallAdapters
  | map(ascii_downcase) | unique | sort
' "$manifest_path" >"$temporary_dir/expected-contracts.json"

jq -c '[.contractReceipts[].address | ascii_downcase] | unique | sort' "$evidence_path" \
  >"$temporary_dir/received-contracts.json"
cmp -s "$temporary_dir/expected-contracts.json" "$temporary_dir/received-contracts.json" \
  || die "contract receipts do not cover the exact fresh deployment inventory"

validate_receipt() {
  local receipt_json=$1
  local expected_tx expected_block expected_block_hash rpc_receipt rpc_status rpc_block rpc_block_hash rpc_tx
  expected_tx=$(jq -r '.transactionHash | ascii_downcase' <<<"$receipt_json")
  expected_block=$(jq -r '.blockNumber' <<<"$receipt_json")
  expected_block_hash=$(jq -r '.blockHash | ascii_downcase' <<<"$receipt_json")
  [[ $(jq -r '.status' <<<"$receipt_json") == "1" ]] || die "receipt $expected_tx is not successful"

  rpc_receipt=$(cast receipt "$expected_tx" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json) \
    || die "receipt $expected_tx is unavailable"
  rpc_status=$(cast to-dec "$(jq -r '.status' <<<"$rpc_receipt")")
  rpc_block=$(cast to-dec "$(jq -r '.blockNumber' <<<"$rpc_receipt")")
  rpc_block_hash=$(jq -r '.blockHash | ascii_downcase' <<<"$rpc_receipt")
  rpc_tx=$(jq -r '.transactionHash | ascii_downcase' <<<"$rpc_receipt")
  [[ "$rpc_status" == "1" && "$rpc_block" == "$expected_block" ]] \
    || die "receipt $expected_tx status or block mismatch"
  [[ "$rpc_block_hash" == "$expected_block_hash" && "$rpc_tx" == "$expected_tx" ]] \
    || die "receipt $expected_tx hash mismatch"
}

jq -c '[.canonicalReceipts[], (.phaseReceipts[] | .[]), .contractReceipts[]] | unique_by(.transactionHash)[]' \
  "$evidence_path" | while IFS= read -r receipt_json; do
    validate_receipt "$receipt_json"
  done

jq -c '.orderedLibraries[].receipt' "$library_evidence_path" | while IFS= read -r receipt_json; do
  validate_receipt "$receipt_json"
done

while IFS= read -r library_record; do
  library_tx=$(jq -r '.receipt.transactionHash' <<<"$library_record")
  library_transaction=$(cast tx "$library_tx" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json)
  library_from=$(jq -r '.from | ascii_downcase' <<<"$library_transaction")
  [[ "$library_from" == "$expected_bootstrap_lower" ]] \
    || die "library sender does not match the approved bootstrap identity: $library_tx"
done < <(jq -c '.orderedLibraries[]' "$library_evidence_path")

require_phase_sender() {
  local phase_name=$1
  local expected_sender=$2
  local phase_receipt phase_tx phase_transaction phase_from
  while IFS= read -r phase_receipt; do
    phase_tx=$(jq -r '.transactionHash' <<<"$phase_receipt")
    phase_transaction=$(cast tx "$phase_tx" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json)
    phase_from=$(jq -r '.from | ascii_downcase' <<<"$phase_transaction")
    [[ "$phase_from" == "$expected_sender" ]] \
      || die "$phase_name sender does not match the approved identity: $phase_tx"
  done < <(jq -c --arg phase "$phase_name" '.phaseReceipts[$phase][]' "$evidence_path")
}

require_phase_sender bootstrapDeployment "$expected_bootstrap_lower"
require_phase_sender finalRoleRotation "$expected_bootstrap_lower"
require_phase_sender inactiveCoordinatorConfiguration "$expected_curator"
require_phase_sender childAdapterOnboarding "$expected_settler_owner_lower"

strategy_manager=$(jq -r '.strategy | ascii_downcase' "$manifest_path")
configuration_selector=$(cast sig 'executeAdapterConfigurationOperation(address,bytes)')
guardian_selector=$(cast sig 'executeAdapterGuardianOperation(address,bytes)')
forbidden_target=$(jq -r '.coordinator | ascii_downcase' "$manifest_path")
while IFS= read -r phase_receipt; do
  phase_tx=$(jq -r '.transactionHash' <<<"$phase_receipt")
  phase_transaction=$(cast tx "$phase_tx" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json)
  phase_to=$(jq -r '(.to // "") | ascii_downcase' <<<"$phase_transaction")
  [[ "$phase_to" != "$forbidden_target" ]] \
    || die "phase transaction invokes a coordinator selector directly: $phase_tx"
done < <(jq -c '.phaseReceipts[][]' "$evidence_path")

managed_receipt_count=$(jq '.phaseReceipts.managedLaneSetup | length' "$evidence_path")
[[ "$managed_receipt_count" == "9" ]] || die "managed lane setup must contain exactly 8 registrations and 1 pause"
expected_lanes=()
while IFS= read -r expected_lane; do
  expected_lanes[${#expected_lanes[@]}]=$expected_lane
done < <(jq -r '.cspLanes[], .coveredCallLanes[] | ascii_downcase' "$manifest_path")
[[ "${#expected_lanes[@]}" == "8" ]] || die "manifest does not contain the exact 4+4 lane order"
managed_index=0
previous_managed_block=0
while IFS= read -r managed_receipt; do
  managed_tx=$(jq -r '.transactionHash' <<<"$managed_receipt")
  managed_block=$(jq -r '.blockNumber' <<<"$managed_receipt")
  [[ "$managed_block" -ge "$previous_managed_block" ]] || die "managed lane receipts are out of order"
  previous_managed_block=$managed_block
  transaction=$(cast tx "$managed_tx" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json)
  transaction_to=$(jq -r '.to | ascii_downcase' <<<"$transaction")
  transaction_from=$(jq -r '.from | ascii_downcase' <<<"$transaction")
  transaction_input=$(jq -r '.input | ascii_downcase' <<<"$transaction")
  transaction_selector=${transaction_input:0:10}
  [[ "$transaction_to" == "$strategy_manager" ]] \
    || die "managed lane setup transaction bypasses StrategyManager: $managed_tx"
  if [[ "$managed_index" -lt 8 ]]; then
    [[ "$transaction_from" == "$expected_curator" ]] \
      || die "lane registration sender is not the approved curator: $managed_tx"
    [[ "$transaction_selector" == "$(lower "$configuration_selector")" ]] \
      || die "lane registration does not use the configuration wrapper: $managed_tx"
    outer=$(cast calldata-decode 'executeAdapterConfigurationOperation(address,bytes)' "$transaction_input" --json)
    [[ "$(jq -r '.[0] | ascii_downcase' <<<"$outer")" == "$forbidden_target" ]] \
      || die "lane registration targets the wrong adapter: $managed_tx"
    managed_data=$(jq -r '.[1]' <<<"$outer")
    managed_operation=$(cast abi-decode --input 'f(uint8,bytes)' "$managed_data" --json)
    [[ "$(jq -r '.[0]' <<<"$managed_operation")" == "11" ]] \
      || die "configuration wrapper does not contain RegisterLane: $managed_tx"
    lane_arguments=$(jq -r '.[1]' <<<"$managed_operation")
    decoded_lane=$(cast abi-decode --input 'f(address,uint8)' "$lane_arguments" --json)
    expected_kind=1
    [[ "$managed_index" -ge 4 ]] && expected_kind=2
    [[ "$(jq -r '.[0] | ascii_downcase' <<<"$decoded_lane")" == "${expected_lanes[$managed_index]}" \
      && "$(jq -r '.[1]' <<<"$decoded_lane")" == "$expected_kind" ]] \
      || die "RegisterLane order, address, or kind mismatch: $managed_tx"
  else
    [[ "$transaction_from" == "$expected_guardian" ]] \
      || die "coordinator pause sender is not the approved guardian: $managed_tx"
    [[ "$transaction_selector" == "$(lower "$guardian_selector")" ]] \
      || die "coordinator pause does not use the guardian wrapper: $managed_tx"
    outer=$(cast calldata-decode 'executeAdapterGuardianOperation(address,bytes)' "$transaction_input" --json)
    [[ "$(jq -r '.[0] | ascii_downcase' <<<"$outer")" == "$forbidden_target" ]] \
      || die "guardian wrapper targets the wrong adapter: $managed_tx"
    managed_data=$(jq -r '.[1]' <<<"$outer")
    managed_operation=$(cast abi-decode --input 'f(uint8,bytes)' "$managed_data" --json)
    [[ "$(jq -r '.[0]' <<<"$managed_operation")" == "10" && "$(jq -r '.[1]' <<<"$managed_operation")" == "0x" ]] \
      || die "guardian wrapper does not contain an empty PauseAllocations: $managed_tx"
  fi
  managed_index=$((managed_index + 1))
done < <(jq -c '.phaseReceipts.managedLaneSetup[]' "$evidence_path")

coordinator_position_nonce=$(cast call "$strategy_manager" 'positionNonce(address)(uint64)' "$forbidden_target" \
  --rpc-url "$BASE_SEPOLIA_RPC_URL")
[[ "$coordinator_position_nonce" == "9" ]] || die "unexpected managed setup position nonce"

while IFS= read -r contract_receipt; do
  contract_address=$(jq -r '.address' <<<"$contract_receipt")
  expected_codehash=$(jq -r '.runtimeCodehash | ascii_downcase' <<<"$contract_receipt")
  runtime_code=$(cast code "$contract_address" --rpc-url "$BASE_SEPOLIA_RPC_URL")
  [[ "$runtime_code" != "0x" ]] || die "no runtime code at $contract_address"
  actual_codehash=$(cast keccak "$runtime_code")
  [[ "$(lower "$actual_codehash")" == "$expected_codehash" ]] \
    || die "runtime codehash mismatch at $contract_address"
done < <(jq -c '.contractReceipts[]' "$evidence_path")

while IFS= read -r library_record; do
  library_address=$(jq -r '.address' <<<"$library_record")
  expected_codehash=$(jq -r '.runtimeCodehash | ascii_downcase' <<<"$library_record")
  runtime_code=$(cast code "$library_address" --rpc-url "$BASE_SEPOLIA_RPC_URL")
  [[ "$runtime_code" != "0x" ]] || die "no runtime code at library $library_address"
  actual_codehash=$(cast keccak "$runtime_code")
  [[ "$(lower "$actual_codehash")" == "$expected_codehash" ]] \
    || die "library runtime codehash mismatch at $library_address"
done < <(jq -c '.orderedLibraries[]' "$library_evidence_path")

fund_first=$(jq -r '.network.deploymentBlocks.fundFirst' "$evidence_path")
fund_last=$(jq -r '.network.deploymentBlocks.fundLast' "$evidence_path")
confirmation_block=$(jq -r '.network.confirmationBlock' "$evidence_path")
latest_block=$(cast block-number --rpc-url "$BASE_SEPOLIA_RPC_URL")
[[ "$fund_first" -gt 0 && "$fund_last" -ge "$fund_first" ]] || die "invalid deployment block window"
[[ "$confirmation_block" -ge "$fund_last" && "$latest_block" -ge "$confirmation_block" ]] \
  || die "deployment receipts have insufficient confirmations"
library_last=$(jq '[.orderedLibraries[].receipt.blockNumber] | max' "$library_evidence_path")
[[ "$library_last" -lt "$fund_first" ]] || die "library prephase did not precede the Fund deployment window"

jq -e --argjson first "$fund_first" --argjson last "$fund_last" '
  all(.canonicalReceipts[]; .blockNumber >= $first and .blockNumber <= $last) and
  (any(.canonicalReceipts[]; .blockNumber == $first)) and
  (any(.canonicalReceipts[]; .blockNumber == $last)) and
  all(.contractReceipts[]; .blockNumber >= $first and .blockNumber <= $last) and
  ([.phaseReceipts.bootstrapDeployment[].transactionHash | ascii_downcase] as $bootstrap |
    all(.canonicalReceipts[]; (.transactionHash | ascii_downcase) as $tx | $bootstrap | index($tx))) and
  ([.phaseReceipts.bootstrapDeployment[].transactionHash | ascii_downcase] as $bootstrap |
    all(.contractReceipts[]; (.transactionHash | ascii_downcase) as $tx | $bootstrap | index($tx)))
' "$evidence_path" >/dev/null || die "deployment receipts do not bind fundFirst/fundLast"

bootstrap_max=$(jq '[.phaseReceipts.bootstrapDeployment[].blockNumber] | max' "$evidence_path")
rotation_min=$(jq '[.phaseReceipts.finalRoleRotation[].blockNumber] | min' "$evidence_path")
rotation_max=$(jq '[.phaseReceipts.finalRoleRotation[].blockNumber] | max' "$evidence_path")
configuration_min=$(jq '[.phaseReceipts.inactiveCoordinatorConfiguration[].blockNumber] | min' "$evidence_path")
configuration_max=$(jq '[.phaseReceipts.inactiveCoordinatorConfiguration[].blockNumber] | max' "$evidence_path")
lane_setup_min=$(jq '[.phaseReceipts.managedLaneSetup[].blockNumber] | min' "$evidence_path")
lane_setup_max=$(jq '[.phaseReceipts.managedLaneSetup[].blockNumber] | max' "$evidence_path")
onboarding_min=$(jq '[.phaseReceipts.childAdapterOnboarding[].blockNumber] | min' "$evidence_path")
onboarding_max=$(jq '[.phaseReceipts.childAdapterOnboarding[].blockNumber] | max' "$evidence_path")
reconciliation_block=$(jq -r '.reconciliation.finalReconciliationBlock' "$evidence_path")
[[ "$bootstrap_max" -lt "$rotation_min" && "$rotation_max" -lt "$configuration_min" ]] \
  || die "bootstrap, role rotation, and configuration receipts are out of order"
[[ "$configuration_max" -lt "$lane_setup_min" && "$lane_setup_max" -lt "$onboarding_min" ]] \
  || die "inactive configuration must precede managed lane setup and onboarding"
[[ "$reconciliation_block" -ge "$onboarding_max" && "$latest_block" -ge "$reconciliation_block" ]] \
  || die "final reconciliation block is stale or precedes onboarding"
[[ "$confirmation_block" -ge "$reconciliation_block" ]] \
  || die "confirmation block precedes final reconciliation"

contract_receipt_block() {
  local address_lower
  address_lower=$(lower "$1")
  jq -r --arg address "$address_lower" '
    [.contractReceipts[] | select((.address | ascii_downcase) == $address)]
    | if length == 1 then .[0].blockNumber else empty end
  ' "$evidence_path"
}

for contract_key in fundVault fundShare fundAccounting fundFlowManager strategyManager wheelCoordinator; do
  implementation_block=$(jq -r --arg key "$contract_key" '.contractActivationBlocks[$key].implementationValidFromBlock' "$evidence_path")
  proxy_block=$(jq -r --arg key "$contract_key" '.contractActivationBlocks[$key].validFromBlock' "$evidence_path")
  [[ "$implementation_block" -ge "$fund_first" && "$implementation_block" -le "$proxy_block" && "$proxy_block" -le "$fund_last" ]] \
    || die "invalid activation blocks for $contract_key"
  proxy_address=$(jq -r --arg key "$contract_key" '.contracts[$key].proxy' "$manifest_path")
  implementation_address=$(jq -r --arg key "$contract_key" '.contracts[$key].implementation' "$manifest_path")
  [[ "$(contract_receipt_block "$proxy_address")" == "$proxy_block" ]] \
    || die "proxy receipt block mismatch for $contract_key"
  [[ "$(contract_receipt_block "$implementation_address")" == "$implementation_block" ]] \
    || die "implementation receipt block mismatch for $contract_key"
done
for contract_key in claimEscrow accessManager metaWheelValuator navReportVerifier; do
  activation_block=$(jq -r --arg key "$contract_key" '.contractActivationBlocks[$key].validFromBlock' "$evidence_path")
  [[ "$activation_block" -ge "$fund_first" && "$activation_block" -le "$fund_last" ]] \
    || die "invalid activation block for $contract_key"
  contract_address=$(jq -r --arg key "$contract_key" '.contracts[$key].address' "$manifest_path")
  [[ "$(contract_receipt_block "$contract_address")" == "$activation_block" ]] \
    || die "receipt block mismatch for $contract_key"
done

export B1N419_MANIFEST_PATH="$manifest_path"
export B1N419_MANIFEST_SHA256="$manifest_digest"
export B1N419_DEPLOYMENT_ID="$manifest_deployment_id"
export B1N419_SOURCE_COMMIT="$manifest_source"
export B1N419_EXECUTION_CONTEXT=BASE_SEPOLIA_LIVE
library_link_arguments=()
while IFS=$'\t' read -r artifact library_address; do
  library_link_arguments+=(--libraries "$artifact:$library_address")
done < <(jq -r '.orderedLibraries[] | [.artifact, .address] | @tsv' "$library_evidence_path")
[[ "${#library_link_arguments[@]}" == "10" ]] || die "exact five-library link map unavailable"
forge script script/fund/ReconcileMetaWheelCanonical.s.sol:ReconcileMetaWheelCanonical \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" --sig "reconcile()" "${library_link_arguments[@]}"

candidate_path="$temporary_dir/manifest.canonical.candidate.json"
jq --slurpfile evidence "$evidence_path" '
  .status = "CONFIRMED_CANONICAL_RECEIPTS"
  | .deploymentStatus = "DEPLOYED"
  | .handoffReady = true
  | .network.deploymentBlocks = $evidence[0].network.deploymentBlocks
  | .canonicalReceipts = $evidence[0].canonicalReceipts
  | reduce ($evidence[0].contractActivationBlocks | keys[]) as $key (.;
      .contracts[$key].validFromBlock = $evidence[0].contractActivationBlocks[$key].validFromBlock
      | if ($evidence[0].contractActivationBlocks[$key] | has("implementationValidFromBlock"))
        then .contracts[$key].implementationValidFromBlock = $evidence[0].contractActivationBlocks[$key].implementationValidFromBlock
        else . end)
  | .readiness.canonicalReceiptsRecorded = true
  | .readiness.blockscoutVerificationComplete = true
  | .readiness.bootstrapReconciled = true
  | .readiness.finalRolesReconciled = true
  | .readiness.standaloneBaselinesUnchanged = true
  | .readiness.backendHandoffReady = true
  | .readiness.mainnetAuthorized = false
' "$manifest_path" >"$candidate_path"

PYTHONPATH="$backend_root" "$backend_python" - "$candidate_path" "$fund_first" <<'PY'
import json
import sys

from src.deployment_manifest import parse_fund_deployment

with open(sys.argv[1], encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)

parse_fund_deployment(
    manifest,
    start_block=int(sys.argv[2]),
    fund_key="base-sepolia:meta-wheel",
    share_symbol="b1WHEEL",
    share_decimals=18,
    accounting_asset_symbol="USDC",
    accounting_asset_decimals=6,
)
PY

mkdir -p "$(dirname "$canonical_path")"
mv "$candidate_path" "$canonical_path"
canonical_digest="0x$(shasum -a 256 "$canonical_path" | awk '{print $1}')"
echo "B1N-419 canonical manifest written: $canonical_path"
echo "B1N-419 canonical manifest SHA-256: $canonical_digest"
