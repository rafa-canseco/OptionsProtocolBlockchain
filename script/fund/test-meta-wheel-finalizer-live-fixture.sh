#!/usr/bin/env bash
# shellcheck disable=SC2129
set -euo pipefail

for command_name in jq cast shasum python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "missing fixture command: $command_name" >&2
    exit 1
  }
done

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_dir"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

real_cast=$(command -v cast)
source_commit=1111111111111111111111111111111111111111
deployment_id=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bootstrap=0x097Bfce6f1Fd87DaA4B5f74e230eC60729eb6425
settler_owner=0x376a4c54623fe24D0Ffc1032D0b6CcC03A32fd7D
curator=0x0000000000000000000000000000000000000050
guardian=0x0000000000000000000000000000000000000051
batch_settler=0x000000000000000000000000000000000000005a
runtime_code=0x6000
runtime_codehash=$($real_cast keccak "$runtime_code")

address_for() {
  printf '0x%040x' "$1"
}

hash_for() {
  printf '0x%064x' "$1"
}

receipt_json() {
  local id=$1
  local block=$2
  jq -cn --arg transactionHash "$(hash_for "$id")" --arg blockHash "$(hash_for "$((block + 1000))")" \
    --argjson blockNumber "$block" \
    '{transactionHash: $transactionHash, blockHash: $blockHash, blockNumber: $blockNumber, status: 1}'
}

inventory_names=(
  factory accessManagerDeployer vaultImplementation shareImplementation accountingImplementation
  flowImplementation strategyImplementation navVerifier vault share accounting flow strategy claimEscrow accessManager
  coordinatorImplementation coordinator metaWheelValuator cspAdapterImplementation cspLaneImplementation cspValuator
  coveredCallAdapterImplementation coveredCallLaneImplementation coveredCallValuator inKindEscrow emergencyEscrow
  cspLane0 cspLane1 cspLane2 cspLane3 cspAdapter0 cspAdapter1 cspAdapter2 cspAdapter3
  coveredCallLane0 coveredCallLane1 coveredCallLane2 coveredCallLane3
  coveredCallAdapter0 coveredCallAdapter1 coveredCallAdapter2 coveredCallAdapter3
)
inventory_jsonl="$fixture_dir/inventory.jsonl"
: >"$inventory_jsonl"
inventory_index=0
for contract_name in "${inventory_names[@]}"; do
  address=$(address_for "$((inventory_index + 1))")
  block=$((inventory_index + 10))
  jq -cn --arg contract "$contract_name" --arg address "$address" --arg runtimeCodehash "$runtime_codehash" \
    --arg transactionHash "$(hash_for "$block")" --arg blockHash "$(hash_for "$((block + 1000))")" \
    --argjson blockNumber "$block" \
    '{contract: $contract, address: $address, runtimeCodehash: $runtimeCodehash,
      transactionHash: $transactionHash, blockHash: $blockHash, blockNumber: $blockNumber, status: 1}' \
    >>"$inventory_jsonl"
  inventory_index=$((inventory_index + 1))
done
jq -s . "$inventory_jsonl" >"$fixture_dir/inventory.json"

factory=$(address_for 1)
access_manager_deployer=$(address_for 2)
vault_implementation=$(address_for 3)
share_implementation=$(address_for 4)
accounting_implementation=$(address_for 5)
flow_implementation=$(address_for 6)
strategy_implementation=$(address_for 7)
nav_verifier=$(address_for 8)
vault=$(address_for 9)
share=$(address_for 10)
accounting=$(address_for 11)
flow=$(address_for 12)
strategy=$(address_for 13)
claim_escrow=$(address_for 14)
access_manager=$(address_for 15)
coordinator_implementation=$(address_for 16)
coordinator=$(address_for 17)
meta_wheel_valuator=$(address_for 18)
csp_adapter_implementation=$(address_for 19)
csp_lane_implementation=$(address_for 20)
csp_valuator=$(address_for 21)
covered_call_adapter_implementation=$(address_for 22)
covered_call_lane_implementation=$(address_for 23)
covered_call_valuator=$(address_for 24)
in_kind_escrow=$(address_for 25)
emergency_escrow=$(address_for 26)

library_artifacts=(
  src/fund/libraries/CspFundAdapterOperations.sol:CspFundAdapterOperations
  src/fund/libraries/CoveredCallFundAdapterOperations.sol:CoveredCallFundAdapterOperations
  src/fund/libraries/ManagedStrategyOperations.sol:ManagedStrategyOperations
  src/fund/libraries/WheelManagedOperationDispatcher.sol:WheelManagedOperationDispatcher
  src/fund/libraries/WheelCoordinatorPositionOperations.sol:WheelCoordinatorPositionOperations
)
library_jsonl="$fixture_dir/libraries.jsonl"
: >"$library_jsonl"
for index in 0 1 2 3 4; do
  library_address=$(address_for "$((101 + index))")
  block=$((index + 1))
  receipt=$(receipt_json "$block" "$block")
  jq -cn --argjson index "$index" --arg artifact "${library_artifacts[$index]}" \
    --arg address "$library_address" --arg runtimeCodehash "$runtime_codehash" --argjson receipt "$receipt" \
    '{index: $index, artifact: $artifact, address: $address, runtimeCodehash: $runtimeCodehash, receipt: $receipt}' \
    >>"$library_jsonl"
done
jq -n --arg sourceCommit "$source_commit" --arg broadcaster "$bootstrap" \
  --slurpfile records "$library_jsonl" '
  {schemaVersion: "1.0.0", issue: "B1N-419", status: "CONFIRMED_CANONICAL_RECEIPTS",
   deploymentStatus: "DEPLOYED", handoffReady: true, sourceCommit: $sourceCommit,
   network: {name: "base-sepolia", chainId: 84532, environmentKind: "live"},
   broadcaster: $broadcaster, orderedLibraries: $records, exactRelinkVerified: true}
' >"$fixture_dir/libraries.json"

jq -n --arg sourceCommit "$source_commit" --arg bootstrap "$bootstrap" --arg feeRecipient "$settler_owner" \
  --arg curator "$curator" --arg guardian "$guardian" --arg batchSettler "$batch_settler" \
  --slurpfile libraries "$fixture_dir/libraries.json" '
  {approval: "APPROVED_BASE_SEPOLIA_LIVE", environment: {
    SOURCE_COMMIT: $sourceCommit, BATCH_SETTLER: $batchSettler, FEE_RECIPIENT: $feeRecipient,
    ROLE_ADMIN: $bootstrap, ROLE_UPGRADER: $bootstrap, ROLE_ACCOUNTING: $bootstrap,
    ROLE_ALLOCATOR: $bootstrap, ROLE_PROCESSOR: $bootstrap, ROLE_CURATOR: $bootstrap, ROLE_GUARDIAN: $bootstrap,
    FINAL_ROLE_CURATOR: $curator, FINAL_ROLE_GUARDIAN: $guardian,
    APPROVED_OBSERVERS: [
      "0x0000000000000000000000000000000000000046", "0x0000000000000000000000000000000000000047",
      "0x0000000000000000000000000000000000000048", "0x0000000000000000000000000000000000000049"],
    NAV_REPORTERS: ["0x000000000000000000000000000000000000004a", "0x000000000000000000000000000000000000004b"],
    LINKED_LIBRARIES: [$libraries[0].orderedLibraries[].address]
  }}
' >"$fixture_dir/inputs.json"
inputs_digest="0x$(shasum -a 256 "$fixture_dir/inputs.json" | awk '{print $1}')"

jq -n --arg schemaVersion "1.0.0" --arg issue "B1N-419" --arg sourceCommit "$source_commit" \
  --arg deploymentId "$deployment_id" --arg factory "$factory" --arg accessManagerDeployer "$access_manager_deployer" \
  --arg vaultImplementation "$vault_implementation" --arg shareImplementation "$share_implementation" \
  --arg accountingImplementation "$accounting_implementation" --arg flowImplementation "$flow_implementation" \
  --arg strategyImplementation "$strategy_implementation" --arg navVerifier "$nav_verifier" --arg vault "$vault" \
  --arg share "$share" --arg accounting "$accounting" --arg flow "$flow" --arg strategy "$strategy" \
  --arg claimEscrow "$claim_escrow" --arg accessManager "$access_manager" \
  --arg coordinatorImplementation "$coordinator_implementation" --arg coordinator "$coordinator" \
  --arg metaWheelValuator "$meta_wheel_valuator" --arg cspAdapterImplementation "$csp_adapter_implementation" \
  --arg cspLaneImplementation "$csp_lane_implementation" --arg cspValuator "$csp_valuator" \
  --arg coveredCallAdapterImplementation "$covered_call_adapter_implementation" \
  --arg coveredCallLaneImplementation "$covered_call_lane_implementation" \
  --arg coveredCallValuator "$covered_call_valuator" --arg inKindEscrow "$in_kind_escrow" \
  --arg emergencyEscrow "$emergency_escrow" --arg codehash "$runtime_codehash" \
  --slurpfile libraries "$fixture_dir/libraries.json" --slurpfile inventory "$fixture_dir/inventory.json" '
  {schemaVersion: $schemaVersion, issue: $issue, status: "UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS",
   deploymentStatus: "UNCONFIRMED", handoffReady: false, sourceCommit: $sourceCommit,
   deploymentId: $deploymentId, network: {name: "base-sepolia", chainId: 84532,
     deploymentBlocks: {fundFirst: 0, fundLast: 0}}, canonicalReceipts: [],
   factory: $factory, accessManagerDeployer: $accessManagerDeployer,
   vaultImplementation: $vaultImplementation, shareImplementation: $shareImplementation,
   accountingImplementation: $accountingImplementation, flowImplementation: $flowImplementation,
   strategyImplementation: $strategyImplementation, navVerifier: $navVerifier,
   vault: $vault, share: $share, accounting: $accounting, flow: $flow, strategy: $strategy,
   claimEscrow: $claimEscrow, accessManager: $accessManager,
   coordinatorImplementation: $coordinatorImplementation, coordinator: $coordinator,
   metaWheelValuator: $metaWheelValuator, cspAdapterImplementation: $cspAdapterImplementation,
   cspLaneImplementation: $cspLaneImplementation, cspValuator: $cspValuator,
   coveredCallAdapterImplementation: $coveredCallAdapterImplementation,
   coveredCallLaneImplementation: $coveredCallLaneImplementation,
   coveredCallValuator: $coveredCallValuator, inKindEscrow: $inKindEscrow, emergencyEscrow: $emergencyEscrow,
   cspLanes: ($inventory[0][26:30] | map(.address)),
   cspAdapters: ($inventory[0][30:34] | map(.address)),
   coveredCallLanes: ($inventory[0][34:38] | map(.address)),
   coveredCallAdapters: ($inventory[0][38:42] | map(.address)),
   linkedLibraries: [$libraries[0].orderedLibraries[].address],
   linkedLibraryCodehashes: [$libraries[0].orderedLibraries[].runtimeCodehash],
   contracts: {
     fundVault: {proxy: $vault, implementation: $vaultImplementation},
     fundShare: {proxy: $share, implementation: $shareImplementation},
     fundAccounting: {proxy: $accounting, implementation: $accountingImplementation},
     fundFlowManager: {proxy: $flow, implementation: $flowImplementation},
     strategyManager: {proxy: $strategy, implementation: $strategyImplementation},
     wheelCoordinator: {proxy: $coordinator, implementation: $coordinatorImplementation},
     claimEscrow: {address: $claimEscrow, codehash: $codehash},
     accessManager: {address: $accessManager, codehash: $codehash},
     metaWheelValuator: {address: $metaWheelValuator, codehash: $codehash},
     navReportVerifier: {address: $navVerifier, codehash: $codehash}
   }, readiness: {}, assets: {}, v1Boundary: {}, policy: {}, finalRoles: {}, standaloneBaselines: {}}
' >"$fixture_dir/manifest.json"

manifest_digest="0x$(shasum -a 256 "$fixture_dir/manifest.json" | awk '{print $1}')"
receipt_json 200 52 >"$fixture_dir/rotation.json"
receipt_json 201 53 >"$fixture_dir/configuration.json"
receipt_json 211 63 >"$fixture_dir/onboarding.json"
managed_jsonl="$fixture_dir/managed.jsonl"
: >"$managed_jsonl"
for index in 0 1 2 3 4 5 6 7 8; do
  receipt_json "$((202 + index))" "$((54 + index))" >>"$managed_jsonl"
done
jq -s . "$managed_jsonl" >"$fixture_dir/managed.json"

jq -n --arg sourceCommit "$source_commit" --arg deploymentId "$deployment_id" \
  --arg manifestDigest "$manifest_digest" --slurpfile inventory "$fixture_dir/inventory.json" \
  --slurpfile rotation "$fixture_dir/rotation.json" --slurpfile configuration "$fixture_dir/configuration.json" \
  --slurpfile managed "$fixture_dir/managed.json" --slurpfile onboarding "$fixture_dir/onboarding.json" '
  ($inventory[0] | map({transactionHash, blockHash, blockNumber, status})) as $bootstrap |
  {schemaVersion: "1.0.0", issue: "B1N-419", approval: "APPROVED_CANONICALIZATION",
   sourceCommit: $sourceCommit, deploymentId: $deploymentId, unconfirmedManifestSha256: $manifestDigest,
   network: {name: "base-sepolia", chainId: 84532, environmentKind: "live",
     deploymentBlocks: {fundFirst: 10, fundLast: 51}, confirmationBlock: 65},
   verification: {blockscoutVerificationComplete: true},
   reconciliation: {bootstrapReconciled: true, finalRolesReconciled: true,
     standaloneBaselinesUnchanged: true, managedWrappersOnly: true,
     coordinatorConfiguredInactiveBeforeManagedLaneSetup: true, finalReconciliationBlock: 64},
   canonicalReceipts: $bootstrap,
   phaseReceipts: {bootstrapDeployment: $bootstrap, finalRoleRotation: $rotation,
     inactiveCoordinatorConfiguration: $configuration, managedLaneSetup: $managed[0],
     childAdapterOnboarding: $onboarding},
   contractReceipts: $inventory[0],
   contractActivationBlocks: {
     fundVault: {implementationValidFromBlock: 12, validFromBlock: 18},
     fundShare: {implementationValidFromBlock: 13, validFromBlock: 19},
     fundAccounting: {implementationValidFromBlock: 14, validFromBlock: 20},
     fundFlowManager: {implementationValidFromBlock: 15, validFromBlock: 21},
     strategyManager: {implementationValidFromBlock: 16, validFromBlock: 22},
     wheelCoordinator: {implementationValidFromBlock: 25, validFromBlock: 26},
     claimEscrow: {validFromBlock: 23}, accessManager: {validFromBlock: 24},
     metaWheelValuator: {validFromBlock: 27}, navReportVerifier: {validFromBlock: 17}}
  }
' >"$fixture_dir/evidence.json"

transactions_jsonl="$fixture_dir/transactions.jsonl"
: >"$transactions_jsonl"
jq -c --arg from "$bootstrap" --arg to "$factory" '.[] | {key: .transactionHash, value: {from: $from, to: $to, input: "0x"}}' \
  "$fixture_dir/inventory.json" >>"$transactions_jsonl"
jq -cn --arg key "$(hash_for 200)" --arg from "$bootstrap" --arg to "$access_manager" \
  '{key: $key, value: {from: $from, to: $to, input: "0x"}}' >>"$transactions_jsonl"
jq -cn --arg key "$(hash_for 201)" --arg from "$curator" --arg to "$accounting" \
  '{key: $key, value: {from: $from, to: $to, input: "0x"}}' >>"$transactions_jsonl"
for index in 0 1 2 3 4 5 6 7; do
  if [[ "$index" -lt 4 ]]; then
    lane=$(address_for "$((27 + index))")
    kind=1
  else
    lane=$(address_for "$((31 + index))")
    kind=2
  fi
  lane_arguments=$($real_cast abi-encode 'f(address,uint8)' "$lane" "$kind")
  managed_data=$($real_cast abi-encode 'f(uint8,bytes)' 11 "$lane_arguments")
  input=$($real_cast calldata 'executeAdapterConfigurationOperation(address,bytes)' "$coordinator" "$managed_data")
  jq -cn --arg key "$(hash_for "$((202 + index))")" --arg from "$curator" --arg to "$strategy" --arg input "$input" \
    '{key: $key, value: {from: $from, to: $to, input: $input}}' >>"$transactions_jsonl"
done
managed_data=$($real_cast abi-encode 'f(uint8,bytes)' 10 0x)
input=$($real_cast calldata 'executeAdapterGuardianOperation(address,bytes)' "$coordinator" "$managed_data")
jq -cn --arg key "$(hash_for 210)" --arg from "$guardian" --arg to "$strategy" --arg input "$input" \
  '{key: $key, value: {from: $from, to: $to, input: $input}}' >>"$transactions_jsonl"
jq -cn --arg key "$(hash_for 211)" --arg from "$settler_owner" --arg to "$batch_settler" \
  '{key: $key, value: {from: $from, to: $to, input: "0x"}}' >>"$transactions_jsonl"
jq -s 'reduce .[] as $item ({}; .[$item.key] = $item.value)' "$transactions_jsonl" >"$fixture_dir/transactions.json"

mkdir -p "$fixture_dir/bin"
ln -s "$project_dir/test/fixtures/b1n419-finalizer/mock-cast.sh" "$fixture_dir/bin/cast"
ln -s "$project_dir/test/fixtures/b1n419-finalizer/mock-forge.sh" "$fixture_dir/bin/forge"

PATH="$fixture_dir/bin:$PATH" \
PYTHONDONTWRITEBYTECODE=1 \
BASE_SEPOLIA_RPC_URL=https://fixture.invalid \
B1N419_MANIFEST_PATH="$fixture_dir/manifest.json" \
B1N419_CANONICALIZATION_EVIDENCE_PATH="$fixture_dir/evidence.json" \
B1N419_LIBRARY_EVIDENCE_PATH="$fixture_dir/libraries.json" \
B1N419_CANONICAL_MANIFEST_PATH="$fixture_dir/canonical.json" \
B1N419_APPROVED_INPUTS_PATH="$fixture_dir/inputs.json" \
B1N419_APPROVED_INPUTS_SHA256="$inputs_digest" \
B1N419_BACKEND_ROOT="$project_dir/test/fixtures/b1n419-finalizer/backend" \
B1N419_BACKEND_PYTHON=$(command -v python3) \
B1N419_FIXTURE_REAL_CAST="$real_cast" \
B1N419_FIXTURE_EVIDENCE="$fixture_dir/evidence.json" \
B1N419_FIXTURE_LIBRARIES="$fixture_dir/libraries.json" \
B1N419_FIXTURE_TRANSACTIONS="$fixture_dir/transactions.json" \
/bin/bash script/fund/finalize-meta-wheel-manifest.sh

jq -e '.status == "CONFIRMED_CANONICAL_RECEIPTS" and .deploymentStatus == "DEPLOYED" and .handoffReady == true' \
  "$fixture_dir/canonical.json" >/dev/null
echo "B1N-419 Bash 3.2 live finalizer fixture passed"
