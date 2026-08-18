#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "B1N-419 canonicalization evidence blocked: $*" >&2
  exit 1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

to_decimal() {
  local value=$1
  if [[ "$value" == 0x* ]]; then
    printf '%d' "$((value))"
  else
    printf '%d' "$value"
  fi
}

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_dir"

cast_bin=${B1N419_CAST_BIN:-cast}
for command_name in jq shasum mktemp "$cast_bin"; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

bind_source_runtime_evidence() {
  : "${B1N419_MANIFEST_PATH:?B1N419_MANIFEST_PATH is required in binding mode}"
  : "${B1N419_CANONICALIZATION_EVIDENCE_PATH:?B1N419_CANONICALIZATION_EVIDENCE_PATH is required in binding mode}"
  : "${B1N419_VERIFICATION_INVENTORY_PATH:?B1N419_VERIFICATION_INVENTORY_PATH is required in binding mode}"
  : "${B1N419_CANONICALIZATION_EVIDENCE_OUTPUT:?B1N419_CANONICALIZATION_EVIDENCE_OUTPUT is required in binding mode}"

  local manifest_path=$B1N419_MANIFEST_PATH
  local preliminary_path=$B1N419_CANONICALIZATION_EVIDENCE_PATH
  local source_runtime_path=$B1N419_SOURCE_RUNTIME_EVIDENCE_PATH
  local inventory_path=$B1N419_VERIFICATION_INVENTORY_PATH
  local output_path=$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT
  [[ -f "$manifest_path" ]] || die "unconfirmed manifest not found"
  [[ -f "$preliminary_path" ]] || die "preliminary canonicalization evidence not found"
  [[ -f "$source_runtime_path" ]] || die "source/runtime evidence not found"
  [[ -f "$inventory_path" ]] || die "verification inventory not found"
  [[ "$output_path" != *template.json ]] || die "binding output cannot overwrite a template"
  [[ "$output_path" != "$preliminary_path" ]] || die "binding output cannot overwrite preliminary evidence"
  [[ "$output_path" != "$source_runtime_path" ]] || die "binding output cannot overwrite source/runtime evidence"
  [[ "$output_path" != "$inventory_path" ]] || die "binding output cannot overwrite verification inventory"
  [[ ! -e "$output_path" ]] || die "output already exists"

  jq -e '
    .schemaVersion == "1.0.0" and .issue == "B1N-419" and
    .approval == "APPROVED_CANONICALIZATION" and
    .network.name == "base-sepolia" and .network.chainId == 84532 and
    .network.environmentKind == "live" and .network.confirmationBlock > 0 and
    (.canonicalReceipts | length) == 108 and (.contractReceipts | length) == 42 and
    .verification.exactSourceRuntimeBytecodeVerified == false and
    .verification.sourceRuntimeEvidenceSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
    .verification.coreBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
    .verification.libraryBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
    .verification.coreStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
    .verification.libraryStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
    .verification.inventorySha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
    .verification.addressCount == 0 and .verification.artifactCount == 0
  ' "$preliminary_path" >/dev/null || die "preliminary canonicalization evidence is not pending exact verification"

  jq -e '
    .schemaVersion == "1.0.0" and .issue == "B1N-419" and
    .status == "UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS" and
    .deploymentStatus == "UNCONFIRMED" and .handoffReady == false and
    (.sourceCommit | test("^[0-9a-fA-F]{40}$")) and
    (.deploymentId | test("^0x[0-9a-fA-F]{64}$"))
  ' "$manifest_path" >/dev/null || die "binding manifest is not the unconfirmed B1N-419 artifact"

  local source_commit deployment_id manifest_digest confirmation_block inventory_digest source_runtime_digest
  source_commit=$(jq -r '.sourceCommit' "$manifest_path")
  deployment_id=$(jq -r '.deploymentId | ascii_downcase' "$manifest_path")
  manifest_digest="0x$(shasum -a 256 "$manifest_path" | awk '{print $1}')"
  confirmation_block=$(jq -r '.network.confirmationBlock' "$preliminary_path")
  inventory_digest="0x$(shasum -a 256 "$inventory_path" | awk '{print $1}')"
  source_runtime_digest="0x$(shasum -a 256 "$source_runtime_path" | awk '{print $1}')"

  jq -e --arg source "$source_commit" --arg deploymentId "$deployment_id" \
    --arg manifestDigest "$(lower "$manifest_digest")" '
    .sourceCommit == $source and
    (.deploymentId | ascii_downcase) == $deploymentId and
    (.unconfirmedManifestSha256 | ascii_downcase) == $manifestDigest
  ' "$preliminary_path" >/dev/null || die "preliminary evidence does not bind the exact unconfirmed manifest"

  jq -e --arg source "$source_commit" --arg deploymentId "$deployment_id" \
    --arg manifestDigest "$manifest_digest" --arg inventoryDigest "$inventory_digest" \
    --argjson confirmationBlock "$confirmation_block" '
    .schemaVersion == "1.0.0" and .issue == "B1N-419" and
    .method == "SOLC_STANDARD_JSON_RPC_EXACT_V2" and
    .exactSourceRuntimeBytecodeVerified == true and .sourceCommit == $source and
    (.deploymentId | ascii_downcase) == $deploymentId and
    (.unconfirmedManifestSha256 | ascii_downcase) == $manifestDigest and
    .network.name == "base-sepolia" and .network.chainId == 84532 and
    .network.confirmationBlock == $confirmationBlock and
    (.coreBuildInfoSha256 | test("^0x[0-9a-fA-F]{64}$") and . != "0x0000000000000000000000000000000000000000000000000000000000000000") and
    (.libraryBuildInfoSha256 | test("^0x[0-9a-fA-F]{64}$") and . != "0x0000000000000000000000000000000000000000000000000000000000000000") and
    (.coreStandardJsonInputSha256 | test("^0x[0-9a-fA-F]{64}$") and . != "0x0000000000000000000000000000000000000000000000000000000000000000") and
    (.libraryStandardJsonInputSha256 | test("^0x[0-9a-fA-F]{64}$") and . != "0x0000000000000000000000000000000000000000000000000000000000000000") and
    (.inventorySha256 | ascii_downcase) == ($inventoryDigest | ascii_downcase) and
    .addressCount == 47 and .artifactCount == 25 and
    .compiler.version == "0.8.24+commit.e11b9ed9" and
    .compiler.coreSourceCount == 316 and .compiler.librarySourceCount == 170 and
    .compiler.coreTargetArtifactCount == 20 and .compiler.libraryTargetArtifactCount == 5 and
    .compiler.targetArtifactCount == 25 and .compiler.fullSourceSetsRetained == true and
    .compiler.targetOnlyOutputSelection == true and
    .inventory.sha256 == .inventorySha256 and
    .inventory.addressCount == 47 and .inventory.artifactCount == 25 and
    .summary.creationVerified == 47 and .summary.compiledRuntimeVerified == 47 and
    .summary.rpcRuntimeVerified == 47 and .summary.exactCompiledArtifactMatches == 25 and
    .summary.exactRpcRuntimeMatches == 47 and .summary.exactTopLevelCreationMatches == 39 and
    .summary.traceDerivedInternalCreationsRecompiled == 8 and
    (.records | type == "array" and length == 47) and
    ([.records[].address | ascii_downcase] | unique | length) == 47 and
    all(.records[];
      (.transactionHash | test("^0x[0-9a-fA-F]{64}$")) and
      (.runtimeCodehash | test("^0x[0-9a-fA-F]{64}$")) and
      .sourceCreationBytecodeMatch == true and .sourceRuntimeBytecodeMatch == true and
      .rpcRuntimeBytecodeMatch == true)
  ' "$source_runtime_path" >/dev/null || die "source/runtime evidence does not bind the preliminary evidence and inventory"

  jq -n -e --slurpfile sourceRuntime "$source_runtime_path" --slurpfile inventory "$inventory_path" '
    def normalized: {
      address: (.address | ascii_downcase),
      transactionHash: (.transactionHash | ascii_downcase),
      runtimeCodehash: (.runtimeCodehash | ascii_downcase)
    };
    ([$sourceRuntime[0].records[] | normalized] | sort_by(.address)) ==
    ([$inventory[0][] | normalized] | sort_by(.address))
  ' >/dev/null || die "source/runtime records do not match the exact verification inventory"

  binding_dir=
  candidate=
  binding_dir=$(mktemp -d)
  trap 'rm -rf "$binding_dir"' EXIT
  candidate="$binding_dir/canonicalization-evidence.json"
  jq --arg sourceRuntimeDigest "$source_runtime_digest" --slurpfile sourceRuntime "$source_runtime_path" '
    .verification = {
      exactSourceRuntimeBytecodeVerified: true,
      sourceRuntimeEvidenceSha256: $sourceRuntimeDigest,
      coreBuildInfoSha256: $sourceRuntime[0].coreBuildInfoSha256,
      libraryBuildInfoSha256: $sourceRuntime[0].libraryBuildInfoSha256,
      coreStandardJsonInputSha256: $sourceRuntime[0].coreStandardJsonInputSha256,
      libraryStandardJsonInputSha256: $sourceRuntime[0].libraryStandardJsonInputSha256,
      inventorySha256: $sourceRuntime[0].inventorySha256,
      addressCount: $sourceRuntime[0].addressCount,
      artifactCount: $sourceRuntime[0].artifactCount
    }
  ' "$preliminary_path" >"$candidate"
  jq -e --arg sourceRuntimeDigest "$source_runtime_digest" --arg inventoryDigest "$inventory_digest" \
    --slurpfile sourceRuntime "$source_runtime_path" '
    .verification.exactSourceRuntimeBytecodeVerified == true and
    (.verification.sourceRuntimeEvidenceSha256 | ascii_downcase) == ($sourceRuntimeDigest | ascii_downcase) and
    .verification.coreBuildInfoSha256 == $sourceRuntime[0].coreBuildInfoSha256 and
    .verification.libraryBuildInfoSha256 == $sourceRuntime[0].libraryBuildInfoSha256 and
    .verification.coreStandardJsonInputSha256 == $sourceRuntime[0].coreStandardJsonInputSha256 and
    .verification.libraryStandardJsonInputSha256 == $sourceRuntime[0].libraryStandardJsonInputSha256 and
    (.verification.inventorySha256 | ascii_downcase) == ($inventoryDigest | ascii_downcase) and
    .verification.addressCount == 47 and .verification.artifactCount == 25
  ' "$candidate" >/dev/null || die "bound canonicalization evidence failed final shape checks"

  mkdir -p "$(dirname "$output_path")"
  mv "$candidate" "$output_path"
  local output_digest
  output_digest="0x$(shasum -a 256 "$output_path" | awk '{print $1}')"
  echo "B1N-419 source/runtime-bound canonicalization evidence written: $output_path"
  echo "B1N-419 source/runtime-bound evidence SHA-256: $output_digest"
}

if [[ -n "${B1N419_SOURCE_RUNTIME_EVIDENCE_PATH:-}" ]]; then
  bind_source_runtime_evidence
  exit 0
fi

: "${BASE_SEPOLIA_RPC_URL:?BASE_SEPOLIA_RPC_URL is required}"
: "${B1N419_MANIFEST_PATH:?B1N419_MANIFEST_PATH is required}"
: "${B1N419_CANONICALIZATION_EVIDENCE_OUTPUT:?B1N419_CANONICALIZATION_EVIDENCE_OUTPUT is required}"
: "${B1N419_LIBRARY_EVIDENCE_PATH:?B1N419_LIBRARY_EVIDENCE_PATH is required}"
: "${B1N419_VERIFICATION_INVENTORY_OUTPUT:?B1N419_VERIFICATION_INVENTORY_OUTPUT is required}"

deploy_broadcast=${B1N419_DEPLOY_BROADCAST_PATH:-broadcast/DeployMetaWheelBaseSepolia.s.sol/84532/run-latest.json}
rotation_broadcast=${B1N419_ROTATION_BROADCAST_PATH:-broadcast/RotateMetaWheelRolesBaseSepolia.s.sol/84532/run-latest.json}
configuration_broadcast=${B1N419_CONFIGURATION_BROADCAST_PATH:-broadcast/ConfigureMetaWheelBaseSepolia.s.sol/84532/run-latest.json}
managed_register_broadcast=${B1N419_MANAGED_REGISTER_BROADCAST_PATH:-broadcast/SetupMetaWheelManagedLanesBaseSepolia.s.sol/84532/registerLanes-latest.json}
managed_pause_broadcast=${B1N419_MANAGED_PAUSE_BROADCAST_PATH:-broadcast/SetupMetaWheelManagedLanesBaseSepolia.s.sol/84532/pauseCoordinator-latest.json}
onboarding_broadcast=${B1N419_ONBOARDING_BROADCAST_PATH:-broadcast/OnboardMetaWheelChildrenBaseSepolia.s.sol/84532/run-latest.json}
library_broadcast=${B1N419_LIBRARY_BROADCAST_PATH:-broadcast/DeployMetaWheelLibrariesBaseSepolia.s.sol/84532/deployLibraries-latest.json}
minimum_confirmations=${B1N419_MIN_CONFIRMATIONS:-12}

[[ "$minimum_confirmations" =~ ^[0-9]+$ ]] || die "minimum confirmations must be a non-negative integer"
[[ -f "$B1N419_MANIFEST_PATH" ]] || die "unconfirmed manifest not found"
[[ -f "$B1N419_LIBRARY_EVIDENCE_PATH" ]] || die "library evidence not found"
[[ "$B1N419_MANIFEST_PATH" != *template.json ]] || die "template manifest is not canonical input"
[[ "$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT" != *template.json ]] || die "output cannot overwrite a template"
[[ "$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT" != "$B1N419_MANIFEST_PATH" ]] || die "output cannot overwrite manifest"
[[ "$B1N419_VERIFICATION_INVENTORY_OUTPUT" != *template.json ]] || die "inventory output cannot overwrite a template"
[[ "$B1N419_VERIFICATION_INVENTORY_OUTPUT" != "$B1N419_MANIFEST_PATH" ]] || die "inventory cannot overwrite manifest"
[[ "$B1N419_VERIFICATION_INVENTORY_OUTPUT" != "$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT" ]] \
  || die "inventory and evidence outputs must differ"
[[ ! -e "$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT" ]] || die "output already exists"
[[ ! -e "$B1N419_VERIFICATION_INVENTORY_OUTPUT" ]] || die "inventory output already exists"

for broadcast_path in "$deploy_broadcast" "$rotation_broadcast" "$configuration_broadcast" \
  "$managed_register_broadcast" "$managed_pause_broadcast" "$onboarding_broadcast" "$library_broadcast"; do
  [[ -f "$broadcast_path" ]] || die "broadcast not found: $broadcast_path"
done

chain_id=$($cast_bin chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL")
[[ "$chain_id" == "84532" ]] || die "RPC is not Base Sepolia"
client_version=$($cast_bin rpc web3_clientVersion --rpc-url "$BASE_SEPOLIA_RPC_URL" | jq -r '.')
client_version_lower=$(lower "$client_version")
[[ "$client_version_lower" != *anvil* && "$client_version_lower" != *hardhat* ]] \
  || die "live evidence rejects a local development RPC"
if $cast_bin rpc anvil_nodeInfo --rpc-url "$BASE_SEPOLIA_RPC_URL" >/dev/null 2>&1; then
  die "live evidence rejects Anvil RPC methods"
fi

jq -e '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and
  .status == "UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS" and
  .deploymentStatus == "UNCONFIRMED" and .handoffReady == false and
  .network.name == "base-sepolia" and .network.chainId == 84532 and
  (.sourceCommit | test("^[0-9a-fA-F]{40}$")) and
  (.deploymentId | test("^0x[0-9a-fA-F]{64}$"))
' "$B1N419_MANIFEST_PATH" >/dev/null || die "manifest is not the unconfirmed live B1N-419 artifact"

source_commit=$(jq -r '.sourceCommit' "$B1N419_MANIFEST_PATH")
deployment_id=$(jq -r '.deploymentId' "$B1N419_MANIFEST_PATH")
manifest_digest="0x$(shasum -a 256 "$B1N419_MANIFEST_PATH" | awk '{print $1}')"

jq -e --arg source "$source_commit" '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and
  .status == "CONFIRMED_CANONICAL_RECEIPTS" and .deploymentStatus == "DEPLOYED" and
  .handoffReady == true and .sourceCommit == $source and .network.chainId == 84532 and
  .network.environmentKind == "live" and .exactRelinkVerified == true and
  (.orderedLibraries | length) == 5 and
  ([.orderedLibraries[].address | ascii_downcase] | unique | length) == 5 and
  ([.orderedLibraries[].artifact] | unique | length) == 5
' "$B1N419_LIBRARY_EVIDENCE_PATH" >/dev/null || die "library evidence is not canonical or source-bound"

validate_broadcast() {
  local path=$1
  local expected_transactions=$2
  local label=$3
  jq -e --arg source "$source_commit" --argjson expected "$expected_transactions" '
    .commit as $commit |
    .chain == 84532 and (.pending | length) == 0 and
    ($commit | type == "string" and length >= 7 and ($source | startswith($commit))) and
    (.transactions | length) == $expected and
    ([.transactions[].hash | ascii_downcase] | length == (unique | length)) and
    all(.transactions[]; (.hash | test("^0x[0-9a-fA-F]{64}$")))
  ' "$path" >/dev/null || die "$label broadcast does not match source, chain, or transaction inventory"
}

validate_broadcast "$deploy_broadcast" 108 bootstrap
validate_broadcast "$rotation_broadcast" 1 final-role-rotation
validate_broadcast "$configuration_broadcast" 4 inactive-configuration
validate_broadcast "$managed_register_broadcast" 8 managed-lane-registration
validate_broadcast "$managed_pause_broadcast" 1 managed-coordinator-pause
validate_broadcast "$onboarding_broadcast" 8 child-onboarding
validate_broadcast "$library_broadcast" 5 library-deployment

artifact_for_contract() {
  case "$1" in
    B1N419ZeroDelayMetaWheelFundFactory)
      printf '%s' 'src/fund/B1N419ZeroDelayMetaWheelFundFactory.sol:B1N419ZeroDelayMetaWheelFundFactory'
      ;;
    ClaimEscrow) printf '%s' 'src/fund/ClaimEscrow.sol:ClaimEscrow' ;;
    CoveredCallFundValuatorV2) printf '%s' 'src/fund/CoveredCallFundValuatorV2.sol:CoveredCallFundValuatorV2' ;;
    CspFundAdapter) printf '%s' 'src/fund/CspFundAdapter.sol:CspFundAdapter' ;;
    CspFundValuatorV2) printf '%s' 'src/fund/CspFundValuatorV2.sol:CspFundValuatorV2' ;;
    ERC1967Proxy) printf '%s' 'node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy' ;;
    FundAccessManager) printf '%s' 'src/fund/FundAccessManager.sol:FundAccessManager' ;;
    FundAccessManagerDeployer) printf '%s' 'src/fund/FundAccessManagerDeployer.sol:FundAccessManagerDeployer' ;;
    FundAccounting) printf '%s' 'src/fund/FundAccounting.sol:FundAccounting' ;;
    FundFlowManager) printf '%s' 'src/fund/FundFlowManager.sol:FundFlowManager' ;;
    FundShare) printf '%s' 'src/fund/FundShare.sol:FundShare' ;;
    FundVault) printf '%s' 'src/fund/FundVault.sol:FundVault' ;;
    MetaWheelValuator) printf '%s' 'src/fund/MetaWheelValuator.sol:MetaWheelValuator' ;;
    NavReportVerifier) printf '%s' 'src/fund/NavReportVerifier.sol:NavReportVerifier' ;;
    StrategyAssetEscrow) printf '%s' 'src/fund/StrategyAssetEscrow.sol:StrategyAssetEscrow' ;;
    StrategyManager) printf '%s' 'src/fund/StrategyManager.sol:StrategyManager' ;;
    WheelCoordinatorAdapter) printf '%s' 'src/fund/WheelCoordinatorAdapter.sol:WheelCoordinatorAdapter' ;;
    WheelCoveredCallChildLane) printf '%s' 'src/fund/WheelCoveredCallChildLane.sol:WheelCoveredCallChildLane' ;;
    WheelCoveredCallFundAdapter) printf '%s' 'src/fund/WheelCoveredCallFundAdapter.sol:WheelCoveredCallFundAdapter' ;;
    WheelCspChildLane) printf '%s' 'src/fund/WheelCspChildLane.sol:WheelCspChildLane' ;;
    *) die "unsupported deployment artifact: $1" ;;
  esac
}

constructor_signature() {
  case "$1" in
    B1N419ZeroDelayMetaWheelFundFactory) printf '%s' 'constructor(address)' ;;
    CspFundValuatorV2|CoveredCallFundValuatorV2)
      printf '%s' 'constructor(address,uint8,uint64,uint64,uint8,address[])'
      ;;
    MetaWheelValuator) printf '%s' 'constructor(address,address,address,address,address,uint8,uint64,uint16)' ;;
    ERC1967Proxy) printf '%s' 'constructor(address,bytes)' ;;
    StrategyAssetEscrow) printf '%s' 'constructor(address,address,bytes32)' ;;
    *) printf '%s' '' ;;
  esac
}

encode_constructor_arguments() {
  local contract_name=$1
  local arguments_json=$2
  local signature argument_count arguments_tsv
  signature=$(constructor_signature "$contract_name")
  argument_count=$(jq 'length' <<<"$arguments_json")
  if [[ -z "$signature" ]]; then
    [[ "$argument_count" == "0" ]] || die "unexpected constructor arguments for $contract_name"
    printf '%s' '0x'
    return
  fi
  arguments_tsv=$(jq -r '@tsv' <<<"$arguments_json")
  local -a arguments=()
  IFS=$'\t' read -r -a arguments <<<"$arguments_tsv"
  [[ "${#arguments[@]}" == "$argument_count" ]] || die "constructor argument parsing failed for $contract_name"
  $cast_bin abi-encode "$signature" "${arguments[@]}"
}

split_creation_code() {
  local init_code=$1
  local constructor_arguments=$2
  local init_hex=${init_code#0x}
  local arguments_hex=${constructor_arguments#0x}
  [[ "$init_hex" =~ ^[0-9a-fA-F]+$ && "$arguments_hex" =~ ^[0-9a-fA-F]*$ ]] \
    || die "creation input must be hex"
  [[ ${#init_hex} -ge ${#arguments_hex} ]] || die "constructor arguments exceed initcode"
  if [[ -n "$arguments_hex" ]]; then
    local suffix=${init_hex:$((${#init_hex} - ${#arguments_hex}))}
    [[ "$(lower "$suffix")" == "$(lower "$arguments_hex")" ]] || die "constructor arguments are not initcode suffix"
  fi
  printf '0x%s' "${init_hex:0:$((${#init_hex} - ${#arguments_hex}))}"
}

temporary_dir=$(mktemp -d)
trap 'rm -rf "$temporary_dir"' EXIT

hydrate_broadcast() {
  local broadcast_path=$1
  local destination=$2
  local records="$temporary_dir/receipts.jsonl"
  : >"$records"
  while IFS= read -r expected_transaction; do
    local rpc_receipt rpc_transaction status block_number block_hash contract_address
    rpc_receipt=$($cast_bin receipt "$expected_transaction" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json) \
      || die "receipt unavailable: $expected_transaction"
    rpc_transaction=$(jq -r '.transactionHash | ascii_downcase' <<<"$rpc_receipt")
    status=$(to_decimal "$(jq -r '.status' <<<"$rpc_receipt")")
    block_number=$(to_decimal "$(jq -r '.blockNumber' <<<"$rpc_receipt")")
    block_hash=$(jq -r '.blockHash | ascii_downcase' <<<"$rpc_receipt")
    contract_address=$(jq -r '(.contractAddress // "") | ascii_downcase' <<<"$rpc_receipt")
    [[ "$rpc_transaction" == "$(lower "$expected_transaction")" ]] || die "receipt transaction hash mismatch"
    [[ "$status" == "1" && "$block_number" -gt 0 ]] || die "unsuccessful receipt: $expected_transaction"
    [[ "$block_hash" =~ ^0x[0-9a-f]{64}$ ]] || die "invalid receipt block hash: $expected_transaction"
    [[ -z "$contract_address" || "$contract_address" =~ ^0x[0-9a-f]{40}$ ]] \
      || die "invalid receipt contract address: $expected_transaction"
    jq -cn --arg transactionHash "$rpc_transaction" --arg blockHash "$block_hash" \
      --arg contractAddress "$contract_address" --argjson blockNumber "$block_number" '
      {transactionHash: $transactionHash, blockHash: $blockHash, blockNumber: $blockNumber,
       status: 1, contractAddress: $contractAddress}
    ' >>"$records"
  done < <(jq -r '.transactions[].hash' "$broadcast_path")
  jq -s . "$records" >"$destination"
}

hydrate_broadcast "$deploy_broadcast" "$temporary_dir/bootstrap.full.json"
hydrate_broadcast "$rotation_broadcast" "$temporary_dir/rotation.full.json"
hydrate_broadcast "$configuration_broadcast" "$temporary_dir/configuration.full.json"
hydrate_broadcast "$managed_register_broadcast" "$temporary_dir/managed-register.full.json"
hydrate_broadcast "$managed_pause_broadcast" "$temporary_dir/managed-pause.full.json"
hydrate_broadcast "$onboarding_broadcast" "$temporary_dir/onboarding.full.json"
hydrate_broadcast "$library_broadcast" "$temporary_dir/libraries.full.json"

for phase in bootstrap rotation configuration managed-register managed-pause onboarding libraries; do
  jq '[.[] | {transactionHash, blockHash, blockNumber, status}]' \
    "$temporary_dir/$phase.full.json" >"$temporary_dir/$phase.json"
done
jq -s '.[0] + .[1]' "$temporary_dir/managed-register.json" "$temporary_dir/managed-pause.json" \
  >"$temporary_dir/managed.json"

jq '
  [
    {logicalName: "factory", address: .factory, expectedCodehash: .factoryCodehash},
    {logicalName: "accessManagerDeployer", address: .accessManagerDeployer,
      expectedCodehash: .accessManagerDeployerCodehash},
    {logicalName: "vaultImplementation", address: .vaultImplementation,
      expectedCodehash: .vaultImplementationCodehash},
    {logicalName: "shareImplementation", address: .shareImplementation,
      expectedCodehash: .shareImplementationCodehash},
    {logicalName: "accountingImplementation", address: .accountingImplementation,
      expectedCodehash: .accountingImplementationCodehash},
    {logicalName: "flowImplementation", address: .flowImplementation,
      expectedCodehash: .flowImplementationCodehash},
    {logicalName: "strategyImplementation", address: .strategyImplementation,
      expectedCodehash: .strategyImplementationCodehash},
    {logicalName: "navVerifier", address: .navVerifier,
      expectedCodehash: .contracts.navReportVerifier.codehash},
    {logicalName: "vault", address: .vault, expectedCodehash: .vaultProxyCodehash},
    {logicalName: "share", address: .share, expectedCodehash: .shareProxyCodehash},
    {logicalName: "accounting", address: .accounting, expectedCodehash: .accountingProxyCodehash},
    {logicalName: "flow", address: .flow, expectedCodehash: .flowProxyCodehash},
    {logicalName: "strategy", address: .strategy, expectedCodehash: .strategyProxyCodehash},
    {logicalName: "claimEscrow", address: .claimEscrow,
      expectedCodehash: .contracts.claimEscrow.codehash},
    {logicalName: "accessManager", address: .accessManager,
      expectedCodehash: .contracts.accessManager.codehash},
    {logicalName: "coordinatorImplementation", address: .coordinatorImplementation,
      expectedCodehash: .coordinatorImplementationCodehash},
    {logicalName: "coordinator", address: .coordinator, expectedCodehash: .coordinatorProxyCodehash},
    {logicalName: "metaWheelValuator", address: .metaWheelValuator,
      expectedCodehash: .contracts.metaWheelValuator.codehash},
    {logicalName: "cspAdapterImplementation", address: .cspAdapterImplementation,
      expectedCodehash: .cspAdapterImplementationCodehash},
    {logicalName: "cspLaneImplementation", address: .cspLaneImplementation,
      expectedCodehash: .cspLaneImplementationCodehash},
    {logicalName: "cspValuator", address: .cspValuator, expectedCodehash: .cspValuatorCodehash},
    {logicalName: "coveredCallAdapterImplementation", address: .coveredCallAdapterImplementation,
      expectedCodehash: .coveredCallAdapterImplementationCodehash},
    {logicalName: "coveredCallLaneImplementation", address: .coveredCallLaneImplementation,
      expectedCodehash: .coveredCallLaneImplementationCodehash},
    {logicalName: "coveredCallValuator", address: .coveredCallValuator,
      expectedCodehash: .coveredCallValuatorCodehash},
    {logicalName: "inKindEscrow", address: .inKindEscrow, expectedCodehash: null},
    {logicalName: "emergencyEscrow", address: .emergencyEscrow, expectedCodehash: null}
  ]
  + [range(0; 4) as $i | {logicalName: "cspLane\($i)", address: .cspLanes[$i],
      expectedCodehash: .cspLaneCodehashes[$i]}]
  + [range(0; 4) as $i | {logicalName: "cspAdapter\($i)", address: .cspAdapters[$i],
      expectedCodehash: .cspAdapterCodehashes[$i]}]
  + [range(0; 4) as $i | {logicalName: "coveredCallLane\($i)", address: .coveredCallLanes[$i],
      expectedCodehash: .coveredCallLaneCodehashes[$i]}]
  + [range(0; 4) as $i | {logicalName: "coveredCallAdapter\($i)", address: .coveredCallAdapters[$i],
      expectedCodehash: .coveredCallAdapterCodehashes[$i]}]
' "$B1N419_MANIFEST_PATH" >"$temporary_dir/manifest-inventory.json"

jq -e '
  length == 42 and ([.[].address | ascii_downcase] | unique | length) == 42 and
  all(.[]; (.logicalName | type == "string" and length > 0) and
    (.address | test("^0x[0-9a-fA-F]{40}$")) and
    (.expectedCodehash == null or (.expectedCodehash | test("^0x[0-9a-fA-F]{64}$"))))
' "$temporary_dir/manifest-inventory.json" >/dev/null || die "manifest fresh-contract inventory is not exactly 42"

jq '
  [
    .transactions[] as $transaction |
    (if ($transaction.transactionType == "CREATE" or $transaction.transactionType == "CREATE2") then
       {contract: $transaction.contractName, address: $transaction.contractAddress,
        transactionHash: $transaction.hash, origin: "top-level"}
     else empty end),
    ($transaction.additionalContracts[]? |
       {contract: .contractName, address: .address,
        transactionHash: $transaction.hash, origin: "internal"})
  ]
' "$deploy_broadcast" >"$temporary_dir/broadcast-inventory.json"

jq -e '
  length == 42 and ([.[].address | ascii_downcase] | unique | length) == 42 and
  all(.[]; (.contract | type == "string" and length > 0) and
    (.address | test("^0x[0-9a-fA-F]{40}$")) and
    (.transactionHash | test("^0x[0-9a-fA-F]{64}$")) and
    (.origin == "top-level" or .origin == "internal"))
' "$temporary_dir/broadcast-inventory.json" >/dev/null || die "deployment broadcast fresh-contract inventory is not exactly 42"

jq -c '[.[].address | ascii_downcase] | sort' "$temporary_dir/manifest-inventory.json" \
  >"$temporary_dir/manifest-addresses.json"
jq -c '[.[].address | ascii_downcase] | sort' "$temporary_dir/broadcast-inventory.json" \
  >"$temporary_dir/broadcast-addresses.json"
cmp -s "$temporary_dir/manifest-addresses.json" "$temporary_dir/broadcast-addresses.json" \
  || die "manifest and broadcast contract inventories differ"

latest_block=$($cast_bin block-number --rpc-url "$BASE_SEPOLIA_RPC_URL")
[[ "$latest_block" =~ ^[0-9]+$ && "$latest_block" -gt 0 ]] || die "invalid latest Base Sepolia block"

contract_records="$temporary_dir/contracts.jsonl"
: >"$contract_records"
while IFS=$'\t' read -r contract address transaction_hash origin; do
  manifest_record=$(jq -c --arg address "$(lower "$address")" \
    '.[] | select((.address | ascii_downcase) == $address)' "$temporary_dir/manifest-inventory.json")
  [[ -n "$manifest_record" ]] || die "broadcast contract is absent from manifest: $address"
  expected_codehash=$(jq -r '.expectedCodehash // "" | ascii_downcase' <<<"$manifest_record")
  receipt=$(jq -c --arg tx "$(lower "$transaction_hash")" \
    '.[] | select(.transactionHash == $tx)' "$temporary_dir/bootstrap.full.json")
  [[ -n "$receipt" ]] || die "contract transaction is absent from bootstrap receipts: $address"
  if [[ "$origin" == "top-level" ]]; then
    receipt_contract=$(jq -r '.contractAddress' <<<"$receipt")
    [[ "$receipt_contract" == "$(lower "$address")" ]] || die "top-level receipt contract mismatch: $address"
  fi
  runtime_code=$($cast_bin code "$address" --block "$latest_block" --rpc-url "$BASE_SEPOLIA_RPC_URL")
  [[ "$runtime_code" != "0x" ]] || die "no runtime code at $address"
  runtime_codehash=$($cast_bin keccak "$runtime_code")
  if [[ -n "$expected_codehash" ]]; then
    [[ "$(lower "$runtime_codehash")" == "$expected_codehash" ]] || die "manifest runtime codehash mismatch: $address"
  fi
  jq -cn --arg contract "$contract" --arg address "$address" --arg runtimeCodehash "$runtime_codehash" \
    --argjson receipt "$receipt" '
    {contract: $contract, address: $address, runtimeCodehash: $runtimeCodehash,
     transactionHash: $receipt.transactionHash, blockHash: $receipt.blockHash,
     blockNumber: $receipt.blockNumber, status: $receipt.status}
  ' >>"$contract_records"
done < <(jq -r '.[] | [.contract, .address, .transactionHash, .origin] | @tsv' \
  "$temporary_dir/broadcast-inventory.json")
jq -s . "$contract_records" >"$temporary_dir/contracts.json"

jq -e 'length == 42 and ([.[].address | ascii_downcase] | unique | length) == 42' \
  "$temporary_dir/contracts.json" >/dev/null || die "contract receipts do not cover 42 unique addresses"

fund_runtime_codehash() {
  local address_lower
  address_lower=$(lower "$1")
  jq -r --arg address "$address_lower" '
    [.[] | select((.address | ascii_downcase) == $address)] |
    if length == 1 then .[0].runtimeCodehash else empty end
  ' "$temporary_dir/contracts.json"
}

require_top_level_rpc_input() {
  local transaction_hash=$1
  local expected_input=$2
  local expected_address=$3
  local receipt_file=$4
  local rpc_transaction rpc_input rpc_to receipt_address
  rpc_transaction=$($cast_bin tx "$transaction_hash" --rpc-url "$BASE_SEPOLIA_RPC_URL" --json) \
    || die "transaction unavailable: $transaction_hash"
  rpc_input=$(jq -r '.input | ascii_downcase' <<<"$rpc_transaction")
  rpc_to=$(jq -r '(.to // "") | ascii_downcase' <<<"$rpc_transaction")
  [[ -z "$rpc_to" ]] || die "expected top-level CREATE transaction: $transaction_hash"
  [[ "$rpc_input" == "$(lower "$expected_input")" ]] || die "canonical transaction input mismatch: $transaction_hash"
  receipt_address=$(jq -r --arg tx "$(lower "$transaction_hash")" '
    [.[] | select(.transactionHash == $tx)] | if length == 1 then .[0].contractAddress else empty end
  ' "$receipt_file")
  [[ "$receipt_address" == "$(lower "$expected_address")" ]] || die "CREATE receipt address mismatch: $transaction_hash"
}

inventory_records="$temporary_dir/verification-inventory.jsonl"
: >"$inventory_records"
proxy_creation_code=
while IFS=$'\t' read -r contract address transaction_hash creation_kind init_code arguments_json; do
  artifact=$(artifact_for_contract "$contract")
  constructor_arguments=$(encode_constructor_arguments "$contract" "$arguments_json")
  creation_code=$(split_creation_code "$init_code" "$constructor_arguments")
  [[ "$creation_code" != "0x" ]] || die "empty creation code for $address"
  require_top_level_rpc_input "$transaction_hash" "$init_code" "$address" \
    "$temporary_dir/bootstrap.full.json"
  runtime_codehash=$(fund_runtime_codehash "$address")
  [[ "$runtime_codehash" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "missing fund runtime codehash: $address"
  constructor_arguments_hash=$($cast_bin keccak "$constructor_arguments")
  creation_code_hash=$($cast_bin keccak "$creation_code")
  init_code_hash=$($cast_bin keccak "$init_code")
  if [[ "$contract" == "ERC1967Proxy" && -z "$proxy_creation_code" ]]; then
    proxy_creation_code=$creation_code
  fi
  jq -cn --arg contract "$contract" --arg address "$address" --arg artifact "$artifact" \
    --arg transactionHash "$transaction_hash" --arg creationKind "$creation_kind" \
    --arg creationCode "$creation_code" --arg initCode "$init_code" \
    --arg constructorArgs "$constructor_arguments" --arg constructorArgsHash "$constructor_arguments_hash" \
    --arg creationCodeHash "$creation_code_hash" --arg initCodeHash "$init_code_hash" \
    --arg runtimeCodehash "$runtime_codehash" '
    {contract: $contract, address: $address, artifact: $artifact, origin: "coreBroadcast",
     transactionHash: $transactionHash, creationKind: $creationKind,
     creationCode: $creationCode, creationCodeHash: $creationCodeHash,
     initCode: $initCode, initCodeHash: $initCodeHash,
     constructorArgs: $constructorArgs, constructorArgsHash: $constructorArgsHash,
     runtimeCodehash: $runtimeCodehash}
  ' >>"$inventory_records"
done < <(jq -r '
  .transactions[] |
  select(.transactionType == "CREATE" or .transactionType == "CREATE2") |
  [.contractName, .contractAddress, .hash, .transactionType, .transaction.input, ((.arguments // []) | tojson)] |
  @tsv
' "$deploy_broadcast")
[[ -n "$proxy_creation_code" ]] || die "top-level proxy creation code was not found"

while IFS= read -r internal_transaction; do
  trace_path="$temporary_dir/trace-${internal_transaction#0x}.json"
  trace_params=$(jq -cn --arg transaction "$internal_transaction" \
    '[$transaction, {tracer: "callTracer", timeout: "20s"}]')
  $cast_bin rpc --raw debug_traceTransaction "$trace_params" --rpc-url "$BASE_SEPOLIA_RPC_URL" >"$trace_path" \
    || die "call trace unavailable: $internal_transaction"
  jq -e 'type == "object" and (.error // "") == ""' "$trace_path" >/dev/null \
    || die "invalid call trace: $internal_transaction"
done < <(jq -r '[.transactions[] | select((.additionalContracts | length) > 0) | .hash] | unique[]' \
  "$deploy_broadcast")

while IFS=$'\t' read -r outer_type outer_contract transaction_hash contract address creation_kind init_code; do
  [[ "$outer_contract" == "B1N419ZeroDelayMetaWheelFundFactory" ]] \
    || die "internal deployment has unexpected outer contract: $transaction_hash"
  trace_path="$temporary_dir/trace-${transaction_hash#0x}.json"
  traced_init_code=$(jq -r --arg address "$(lower "$address")" '
    [.. | objects |
      select(((.type // "") == "CREATE" or (.type // "") == "CREATE2") and
        ((.to // "") | ascii_downcase) == $address) | .input] |
    if length == 1 then .[0] else empty end
  ' "$trace_path")
  [[ -n "$traced_init_code" && "$(lower "$traced_init_code")" == "$(lower "$init_code")" ]] \
    || die "trace initcode mismatch for internal deployment: $address"
  case "$contract" in
    FundAccessManagerDeployer)
      constructor_arguments=0x
      creation_code=$init_code
      ;;
    FundAccessManager)
      init_hex=${init_code#0x}
      constructor_arguments="0x${init_hex:$((${#init_hex} - 64))}"
      creation_code=$(split_creation_code "$init_code" "$constructor_arguments")
      ;;
    ClaimEscrow)
      init_hex=${init_code#0x}
      constructor_arguments="0x${init_hex:$((${#init_hex} - 128))}"
      creation_code=$(split_creation_code "$init_code" "$constructor_arguments")
      ;;
    ERC1967Proxy)
      [[ "$(lower "${init_code:0:${#proxy_creation_code}}")" == "$(lower "$proxy_creation_code")" ]] \
        || die "internal proxy creation code differs from top-level artifact"
      creation_code=$proxy_creation_code
      constructor_arguments="0x${init_code:${#proxy_creation_code}}"
      [[ "$constructor_arguments" != "0x" ]] || die "internal proxy constructor arguments are empty"
      ;;
    *) die "unsupported internal deployment artifact: $contract" ;;
  esac
  artifact=$(artifact_for_contract "$contract")
  runtime_codehash=$(fund_runtime_codehash "$address")
  [[ "$runtime_codehash" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "missing internal runtime codehash: $address"
  constructor_arguments_hash=$($cast_bin keccak "$constructor_arguments")
  creation_code_hash=$($cast_bin keccak "$creation_code")
  init_code_hash=$($cast_bin keccak "$init_code")
  if [[ "$outer_type" == "CREATE" ]]; then
    origin=factoryConstructorTrace
  else
    [[ "$outer_type" == "CALL" ]] || die "unsupported internal deployment outer transaction type"
    origin=createFundTrace
  fi
  jq -cn --arg contract "$contract" --arg address "$address" --arg artifact "$artifact" \
    --arg origin "$origin" --arg transactionHash "$transaction_hash" --arg creationKind "$creation_kind" \
    --arg creationCode "$creation_code" --arg initCode "$init_code" \
    --arg constructorArgs "$constructor_arguments" --arg constructorArgsHash "$constructor_arguments_hash" \
    --arg creationCodeHash "$creation_code_hash" --arg initCodeHash "$init_code_hash" \
    --arg runtimeCodehash "$runtime_codehash" '
    {contract: $contract, address: $address, artifact: $artifact, origin: $origin,
     transactionHash: $transactionHash, creationKind: $creationKind,
     creationCode: $creationCode, creationCodeHash: $creationCodeHash,
     initCode: $initCode, initCodeHash: $initCodeHash,
     constructorArgs: $constructorArgs, constructorArgsHash: $constructorArgsHash,
     runtimeCodehash: $runtimeCodehash}
  ' >>"$inventory_records"
done < <(jq -r '
  .transactions[] as $transaction |
  $transaction.additionalContracts[]? |
  [$transaction.transactionType, $transaction.contractName, $transaction.hash,
   .contractName, .address, .transactionType, .initCode] | @tsv
' "$deploy_broadcast")

while IFS=$'\t' read -r artifact address expected_codehash expected_transaction index; do
  broadcast_record=$(jq -c --argjson index "$index" \
    '[.transactions[] | select(.transactionType == "CREATE" or .transactionType == "CREATE2")][$index]' \
    "$library_broadcast")
  [[ -n "$broadcast_record" && "$broadcast_record" != "null" ]] || die "library broadcast record is missing"
  broadcast_address=$(jq -r '.contractAddress | ascii_downcase' <<<"$broadcast_record")
  transaction_hash=$(jq -r '.hash | ascii_downcase' <<<"$broadcast_record")
  creation_kind=$(jq -r '.transactionType' <<<"$broadcast_record")
  init_code=$(jq -r '.transaction.input' <<<"$broadcast_record")
  [[ "$broadcast_address" == "$(lower "$address")" && "$transaction_hash" == "$(lower "$expected_transaction")" ]] \
    || die "library broadcast and canonical evidence differ at index $index"
  require_top_level_rpc_input "$transaction_hash" "$init_code" "$address" \
    "$temporary_dir/libraries.full.json"
  runtime_code=$($cast_bin code "$address" --block "$latest_block" --rpc-url "$BASE_SEPOLIA_RPC_URL")
  [[ "$runtime_code" != "0x" ]] || die "no library runtime code at $address"
  runtime_codehash=$($cast_bin keccak "$runtime_code")
  [[ "$(lower "$runtime_codehash")" == "$(lower "$expected_codehash")" ]] \
    || die "library runtime codehash mismatch: $address"
  constructor_arguments=0x
  creation_code=$init_code
  jq -cn --arg contract "${artifact##*:}" --arg address "$address" --arg artifact "$artifact" \
    --arg transactionHash "$transaction_hash" --arg creationKind "$creation_kind" \
    --arg creationCode "$creation_code" --arg initCode "$init_code" \
    --arg constructorArgs "$constructor_arguments" --arg constructorArgsHash "$($cast_bin keccak "$constructor_arguments")" \
    --arg creationCodeHash "$($cast_bin keccak "$creation_code")" --arg initCodeHash "$($cast_bin keccak "$init_code")" \
    --arg runtimeCodehash "$runtime_codehash" '
    {contract: $contract, address: $address, artifact: $artifact, origin: "libraryBroadcast",
     transactionHash: $transactionHash, creationKind: $creationKind,
     creationCode: $creationCode, creationCodeHash: $creationCodeHash,
     initCode: $initCode, initCodeHash: $initCodeHash,
     constructorArgs: $constructorArgs, constructorArgsHash: $constructorArgsHash,
     runtimeCodehash: $runtimeCodehash}
  ' >>"$inventory_records"
done < <(jq -r '.orderedLibraries[] |
  [.artifact, .address, .runtimeCodehash, .receipt.transactionHash, .index] | @tsv' \
  "$B1N419_LIBRARY_EVIDENCE_PATH")

jq -s 'sort_by(.address | ascii_downcase)' "$inventory_records" >"$temporary_dir/verification-inventory.json"
jq -e '
  length == 47 and ([.[].address | ascii_downcase] | unique | length) == 47 and
  ([.[].artifact] | unique | length) == 25 and
  ([.[] | select(.origin == "coreBroadcast")] | length) == 34 and
  ([.[] | select(.origin == "createFundTrace")] | length) == 7 and
  ([.[] | select(.origin == "factoryConstructorTrace")] | length) == 1 and
  ([.[] | select(.origin == "libraryBroadcast")] | length) == 5 and
  all(.[];
    (.artifact | test("^[^:]+:[^:]+$")) and
    (.address | test("^0x[0-9a-fA-F]{40}$")) and
    (.transactionHash | test("^0x[0-9a-fA-F]{64}$")) and
    (.creationKind == "CREATE" or .creationKind == "CREATE2") and
    (.creationCode | test("^0x[0-9a-fA-F]+$")) and
    (.initCode | test("^0x[0-9a-fA-F]+$")) and
    (.constructorArgs | test("^0x[0-9a-fA-F]*$")) and
    (.constructorArgsHash | test("^0x[0-9a-fA-F]{64}$")) and
    (.creationCodeHash | test("^0x[0-9a-fA-F]{64}$")) and
    (.initCodeHash | test("^0x[0-9a-fA-F]{64}$")) and
    (.runtimeCodehash | test("^0x[0-9a-fA-F]{64}$")))
' "$temporary_dir/verification-inventory.json" >/dev/null \
  || die "verification inventory does not satisfy exact 47/25/34/7/1/5 counts"

phase_bounds=$(jq -n --slurpfile bootstrap "$temporary_dir/bootstrap.json" \
  --slurpfile rotation "$temporary_dir/rotation.json" --slurpfile configuration "$temporary_dir/configuration.json" \
  --slurpfile managed "$temporary_dir/managed.json" --slurpfile onboarding "$temporary_dir/onboarding.json" '
  {bootstrapMin: ([$bootstrap[0][].blockNumber] | min), bootstrapMax: ([$bootstrap[0][].blockNumber] | max),
   rotationMin: ([$rotation[0][].blockNumber] | min), rotationMax: ([$rotation[0][].blockNumber] | max),
   configurationMin: ([$configuration[0][].blockNumber] | min),
   configurationMax: ([$configuration[0][].blockNumber] | max),
   managedMin: ([$managed[0][].blockNumber] | min), managedMax: ([$managed[0][].blockNumber] | max),
   onboardingMin: ([$onboarding[0][].blockNumber] | min), onboardingMax: ([$onboarding[0][].blockNumber] | max)}
')
bootstrap_min=$(jq -r '.bootstrapMin' <<<"$phase_bounds")
bootstrap_max=$(jq -r '.bootstrapMax' <<<"$phase_bounds")
rotation_min=$(jq -r '.rotationMin' <<<"$phase_bounds")
rotation_max=$(jq -r '.rotationMax' <<<"$phase_bounds")
configuration_min=$(jq -r '.configurationMin' <<<"$phase_bounds")
configuration_max=$(jq -r '.configurationMax' <<<"$phase_bounds")
managed_min=$(jq -r '.managedMin' <<<"$phase_bounds")
managed_max=$(jq -r '.managedMax' <<<"$phase_bounds")
onboarding_min=$(jq -r '.onboardingMin' <<<"$phase_bounds")
onboarding_max=$(jq -r '.onboardingMax' <<<"$phase_bounds")
[[ "$bootstrap_max" -lt "$rotation_min" && "$rotation_max" -lt "$configuration_min" ]] \
  || die "bootstrap, rotation, and inactive configuration receipts are out of order"
[[ "$configuration_max" -lt "$managed_min" && "$managed_max" -lt "$onboarding_min" ]] \
  || die "inactive configuration, managed setup, and onboarding receipts are out of order"
[[ "$latest_block" -ge $((onboarding_max + minimum_confirmations)) ]] \
  || die "insufficient confirmations after onboarding"

all_phase_hashes=$(jq -n --slurpfile bootstrap "$temporary_dir/bootstrap.json" \
  --slurpfile rotation "$temporary_dir/rotation.json" --slurpfile configuration "$temporary_dir/configuration.json" \
  --slurpfile managed "$temporary_dir/managed.json" --slurpfile onboarding "$temporary_dir/onboarding.json" '
  [$bootstrap[0][], $rotation[0][], $configuration[0][], $managed[0][], $onboarding[0][] |
    .transactionHash | ascii_downcase]
')
[[ "$(jq 'length' <<<"$all_phase_hashes")" == "$(jq 'unique | length' <<<"$all_phase_hashes")" ]] \
  || die "a transaction receipt is assigned to multiple phases"

receipt_block() {
  local address_lower
  address_lower=$(lower "$1")
  jq -r --arg address "$address_lower" '
    [.[] | select((.address | ascii_downcase) == $address)] |
    if length == 1 then .[0].blockNumber else empty end
  ' "$temporary_dir/contracts.json"
}

vault_implementation_block=$(receipt_block "$(jq -r '.vaultImplementation' "$B1N419_MANIFEST_PATH")")
vault_block=$(receipt_block "$(jq -r '.vault' "$B1N419_MANIFEST_PATH")")
share_implementation_block=$(receipt_block "$(jq -r '.shareImplementation' "$B1N419_MANIFEST_PATH")")
share_block=$(receipt_block "$(jq -r '.share' "$B1N419_MANIFEST_PATH")")
accounting_implementation_block=$(receipt_block "$(jq -r '.accountingImplementation' "$B1N419_MANIFEST_PATH")")
accounting_block=$(receipt_block "$(jq -r '.accounting' "$B1N419_MANIFEST_PATH")")
flow_implementation_block=$(receipt_block "$(jq -r '.flowImplementation' "$B1N419_MANIFEST_PATH")")
flow_block=$(receipt_block "$(jq -r '.flow' "$B1N419_MANIFEST_PATH")")
strategy_implementation_block=$(receipt_block "$(jq -r '.strategyImplementation' "$B1N419_MANIFEST_PATH")")
strategy_block=$(receipt_block "$(jq -r '.strategy' "$B1N419_MANIFEST_PATH")")
coordinator_implementation_block=$(receipt_block "$(jq -r '.coordinatorImplementation' "$B1N419_MANIFEST_PATH")")
coordinator_block=$(receipt_block "$(jq -r '.coordinator' "$B1N419_MANIFEST_PATH")")
claim_escrow_block=$(receipt_block "$(jq -r '.claimEscrow' "$B1N419_MANIFEST_PATH")")
access_manager_block=$(receipt_block "$(jq -r '.accessManager' "$B1N419_MANIFEST_PATH")")
meta_wheel_valuator_block=$(receipt_block "$(jq -r '.metaWheelValuator' "$B1N419_MANIFEST_PATH")")
nav_verifier_block=$(receipt_block "$(jq -r '.navVerifier' "$B1N419_MANIFEST_PATH")")

activation_blocks=$(jq -n \
  --argjson vaultImplementation "$vault_implementation_block" --argjson vault "$vault_block" \
  --argjson shareImplementation "$share_implementation_block" --argjson share "$share_block" \
  --argjson accountingImplementation "$accounting_implementation_block" --argjson accounting "$accounting_block" \
  --argjson flowImplementation "$flow_implementation_block" --argjson flow "$flow_block" \
  --argjson strategyImplementation "$strategy_implementation_block" --argjson strategy "$strategy_block" \
  --argjson coordinatorImplementation "$coordinator_implementation_block" --argjson coordinator "$coordinator_block" \
  --argjson claimEscrow "$claim_escrow_block" --argjson accessManager "$access_manager_block" \
  --argjson metaWheelValuator "$meta_wheel_valuator_block" --argjson navVerifier "$nav_verifier_block" '
  {fundVault: {implementationValidFromBlock: $vaultImplementation, validFromBlock: $vault},
   fundShare: {implementationValidFromBlock: $shareImplementation, validFromBlock: $share},
   fundAccounting: {implementationValidFromBlock: $accountingImplementation, validFromBlock: $accounting},
   fundFlowManager: {implementationValidFromBlock: $flowImplementation, validFromBlock: $flow},
   strategyManager: {implementationValidFromBlock: $strategyImplementation, validFromBlock: $strategy},
   wheelCoordinator: {implementationValidFromBlock: $coordinatorImplementation, validFromBlock: $coordinator},
   claimEscrow: {validFromBlock: $claimEscrow}, accessManager: {validFromBlock: $accessManager},
   metaWheelValuator: {validFromBlock: $metaWheelValuator}, navReportVerifier: {validFromBlock: $navVerifier}}
')

candidate="$temporary_dir/canonicalization-evidence.json"
jq -n --arg sourceCommit "$source_commit" --arg deploymentId "$deployment_id" \
  --arg manifestDigest "$manifest_digest" --argjson fundFirst "$bootstrap_min" \
  --argjson fundLast "$bootstrap_max" --argjson confirmationBlock "$latest_block" \
  --argjson activationBlocks "$activation_blocks" --slurpfile bootstrap "$temporary_dir/bootstrap.json" \
  --slurpfile rotation "$temporary_dir/rotation.json" --slurpfile configuration "$temporary_dir/configuration.json" \
  --slurpfile managed "$temporary_dir/managed.json" --slurpfile onboarding "$temporary_dir/onboarding.json" \
  --slurpfile contracts "$temporary_dir/contracts.json" '
  {schemaVersion: "1.0.0", issue: "B1N-419", approval: "APPROVED_CANONICALIZATION",
   unconfirmedManifestSha256: $manifestDigest, sourceCommit: $sourceCommit, deploymentId: $deploymentId,
   network: {name: "base-sepolia", chainId: 84532, environmentKind: "live",
     confirmationBlock: $confirmationBlock, deploymentBlocks: {fundFirst: $fundFirst, fundLast: $fundLast}},
   canonicalReceipts: $bootstrap[0],
   phaseReceipts: {bootstrapDeployment: $bootstrap[0], finalRoleRotation: $rotation[0],
     inactiveCoordinatorConfiguration: $configuration[0], managedLaneSetup: $managed[0],
     childAdapterOnboarding: $onboarding[0]},
   contractReceipts: $contracts[0], contractActivationBlocks: $activationBlocks,
   reconciliation: {bootstrapReconciled: true, finalRolesReconciled: true,
     standaloneBaselinesUnchanged: true, managedWrappersOnly: true,
     coordinatorConfiguredInactiveBeforeManagedLaneSetup: true,
     finalReconciliationBlock: $confirmationBlock},
   verification: {exactSourceRuntimeBytecodeVerified: false,
     sourceRuntimeEvidenceSha256: "0x0000000000000000000000000000000000000000000000000000000000000000",
     coreBuildInfoSha256: "0x0000000000000000000000000000000000000000000000000000000000000000",
     libraryBuildInfoSha256: "0x0000000000000000000000000000000000000000000000000000000000000000",
     coreStandardJsonInputSha256: "0x0000000000000000000000000000000000000000000000000000000000000000",
     libraryStandardJsonInputSha256: "0x0000000000000000000000000000000000000000000000000000000000000000",
     inventorySha256: "0x0000000000000000000000000000000000000000000000000000000000000000",
     addressCount: 0, artifactCount: 0}}
' >"$candidate"

jq -e --arg digest "$manifest_digest" '
  .schemaVersion == "1.0.0" and .issue == "B1N-419" and
  .approval == "APPROVED_CANONICALIZATION" and .unconfirmedManifestSha256 == $digest and
  .network.chainId == 84532 and .network.environmentKind == "live" and
  (.canonicalReceipts | length) == 108 and
  (.phaseReceipts.finalRoleRotation | length) == 1 and
  (.phaseReceipts.inactiveCoordinatorConfiguration | length) == 4 and
  (.phaseReceipts.managedLaneSetup | length) == 9 and
  (.phaseReceipts.childAdapterOnboarding | length) == 8 and
  (.contractReceipts | length) == 42 and
  ([.contractReceipts[].address | ascii_downcase] | unique | length) == 42 and
  .verification.exactSourceRuntimeBytecodeVerified == false and
  .verification.coreBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.libraryBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.coreStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.libraryStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.addressCount == 0 and .verification.artifactCount == 0
' "$candidate" >/dev/null || die "generated canonicalization evidence failed final shape checks"

mkdir -p "$(dirname "$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT")" \
  "$(dirname "$B1N419_VERIFICATION_INVENTORY_OUTPUT")"
mv "$temporary_dir/verification-inventory.json" "$B1N419_VERIFICATION_INVENTORY_OUTPUT"
mv "$candidate" "$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT"
output_digest="0x$(shasum -a 256 "$B1N419_CANONICALIZATION_EVIDENCE_OUTPUT" | awk '{print $1}')"
inventory_digest="0x$(shasum -a 256 "$B1N419_VERIFICATION_INVENTORY_OUTPUT" | awk '{print $1}')"
echo "B1N-419 canonicalization evidence written: $B1N419_CANONICALIZATION_EVIDENCE_OUTPUT"
echo "B1N-419 canonicalization evidence SHA-256: $output_digest"
echo "B1N-419 verification inventory written: $B1N419_VERIFICATION_INVENTORY_OUTPUT"
echo "B1N-419 verification inventory SHA-256: $inventory_digest"
echo "B1N-419 source/runtime verification remains pending by construction"
