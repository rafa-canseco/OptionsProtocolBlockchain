#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "B1N-419 canonicalization generator fixture failed: $*" >&2
  exit 1
}

for command_name in jq cast shasum mktemp rg; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing fixture command: $command_name"
done

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$project_dir"
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT

real_cast=$(command -v cast)
source_commit=1111111111111111111111111111111111111111
deployment_id=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
runtime_code=0x6000
runtime_codehash=$($real_cast keccak "$runtime_code")

address_for() {
  printf '0x%040x' "$1"
}

hash_for() {
  printf '0x%064x' "$1"
}

addresses_jsonl="$fixture_dir/addresses.jsonl"
: >"$addresses_jsonl"
for index in $(seq 1 42); do
  jq -cn --arg address "$(address_for "$index")" '$address' >>"$addresses_jsonl"
done
jq -s . "$addresses_jsonl" >"$fixture_dir/addresses.json"

# The address mapping follows the real deployment shape: implementations are deployed first,
# the factory constructor deploys its helper, and createFund deploys the core fund proxies.
jq -n --arg sourceCommit "$source_commit" --arg deploymentId "$deployment_id" \
  --arg codehash "$runtime_codehash" --slurpfile addresses "$fixture_dir/addresses.json" '
  $addresses[0] as $a |
  {schemaVersion: "1.0.0", issue: "B1N-419", status: "UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS",
   deploymentStatus: "UNCONFIRMED", handoffReady: false, sourceCommit: $sourceCommit,
   deploymentId: $deploymentId, network: {name: "base-sepolia", chainId: 84532},
   factory: $a[6], factoryCodehash: $codehash,
   accessManagerDeployer: $a[34], accessManagerDeployerCodehash: $codehash,
   vaultImplementation: $a[0], vaultImplementationCodehash: $codehash,
   shareImplementation: $a[1], shareImplementationCodehash: $codehash,
   accountingImplementation: $a[2], accountingImplementationCodehash: $codehash,
   flowImplementation: $a[3], flowImplementationCodehash: $codehash,
   strategyImplementation: $a[4], strategyImplementationCodehash: $codehash,
   navVerifier: $a[5], vault: $a[36], vaultProxyCodehash: $codehash,
   share: $a[37], shareProxyCodehash: $codehash,
   accounting: $a[38], accountingProxyCodehash: $codehash,
   flow: $a[39], flowProxyCodehash: $codehash,
   strategy: $a[40], strategyProxyCodehash: $codehash,
   claimEscrow: $a[41], accessManager: $a[35],
   coordinatorImplementation: $a[10], coordinatorImplementationCodehash: $codehash,
   coordinator: $a[11], coordinatorProxyCodehash: $codehash,
   metaWheelValuator: $a[9],
   cspAdapterImplementation: $a[12], cspAdapterImplementationCodehash: $codehash,
   cspLaneImplementation: $a[13], cspLaneImplementationCodehash: $codehash,
   cspValuator: $a[7], cspValuatorCodehash: $codehash,
   coveredCallAdapterImplementation: $a[14], coveredCallAdapterImplementationCodehash: $codehash,
   coveredCallLaneImplementation: $a[15], coveredCallLaneImplementationCodehash: $codehash,
   coveredCallValuator: $a[8], coveredCallValuatorCodehash: $codehash,
   inKindEscrow: $a[32], emergencyEscrow: $a[33],
   cspLanes: $a[16:20], cspLaneCodehashes: [$codehash, $codehash, $codehash, $codehash],
   cspAdapters: $a[20:24], cspAdapterCodehashes: [$codehash, $codehash, $codehash, $codehash],
   coveredCallLanes: $a[24:28],
   coveredCallLaneCodehashes: [$codehash, $codehash, $codehash, $codehash],
   coveredCallAdapters: $a[28:32],
   coveredCallAdapterCodehashes: [$codehash, $codehash, $codehash, $codehash],
   contracts: {
     fundVault: {proxy: $a[36], implementation: $a[0], implementationCodehash: $codehash},
     fundShare: {proxy: $a[37], implementation: $a[1], implementationCodehash: $codehash},
     fundAccounting: {proxy: $a[38], implementation: $a[2], implementationCodehash: $codehash},
     fundFlowManager: {proxy: $a[39], implementation: $a[3], implementationCodehash: $codehash},
     strategyManager: {proxy: $a[40], implementation: $a[4], implementationCodehash: $codehash},
     wheelCoordinator: {proxy: $a[11], implementation: $a[10], implementationCodehash: $codehash},
     claimEscrow: {address: $a[41], codehash: $codehash},
     accessManager: {address: $a[35], codehash: $codehash},
     metaWheelValuator: {address: $a[9], codehash: $codehash},
     navReportVerifier: {address: $a[5], codehash: $codehash}
   }}
' >"$fixture_dir/manifest.json"

top_level_contract_names=(
  FundVault FundShare FundAccounting FundFlowManager StrategyManager NavReportVerifier
  B1N419ZeroDelayMetaWheelFundFactory CspFundValuatorV2 CoveredCallFundValuatorV2
  MetaWheelValuator WheelCoordinatorAdapter ERC1967Proxy CspFundAdapter WheelCspChildLane
  WheelCoveredCallFundAdapter WheelCoveredCallChildLane
  ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy
  ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy ERC1967Proxy
  StrategyAssetEscrow StrategyAssetEscrow
)
[[ "${#top_level_contract_names[@]}" == "34" ]] || die "fixture top-level contract name count"

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

constructor_arguments_json() {
  local contract_name=$1
  case "$contract_name" in
    B1N419ZeroDelayMetaWheelFundFactory)
      jq -cn --arg owner "$(address_for 200)" '[$owner]'
      ;;
    CspFundValuatorV2|CoveredCallFundValuatorV2)
      jq -cn --arg oracle "$(address_for 200)" \
        --arg feeds "[$(address_for 201), $(address_for 202)]" \
        '[$oracle, "8", "3600", "120", "2", $feeds]'
      ;;
    MetaWheelValuator)
      jq -cn --arg a "$(address_for 200)" --arg b "$(address_for 201)" \
        --arg c "$(address_for 202)" --arg d "$(address_for 203)" \
        --arg e "$(address_for 204)" '[$a, $b, $c, $d, $e, "8", "3600", "100"]'
      ;;
    ERC1967Proxy)
      jq -cn --arg implementation "$(address_for 1)" '[$implementation, "0x"]'
      ;;
    StrategyAssetEscrow)
      jq -cn --arg strategy "$(address_for 37)" --arg manager "$(address_for 36)" \
        --arg salt "$(hash_for 999)" '[$strategy, $manager, $salt]'
      ;;
    *) printf '%s\n' '[]' ;;
  esac
}

encode_arguments() {
  local contract_name=$1
  local arguments_json=$2
  local signature arguments_tsv
  signature=$(constructor_signature "$contract_name")
  if [[ -z "$signature" ]]; then
    printf '%s' '0x'
    return
  fi
  arguments_tsv=$(jq -r '@tsv' <<<"$arguments_json")
  local -a arguments=()
  IFS=$'\t' read -r -a arguments <<<"$arguments_tsv"
  "$real_cast" abi-encode "$signature" "${arguments[@]}"
}

deploy_transactions="$fixture_dir/deploy-transactions.jsonl"
rpc_transactions="$fixture_dir/rpc-transactions.jsonl"
: >"$deploy_transactions"
: >"$rpc_transactions"

append_rpc_transaction() {
  local transaction_id=$1
  local input=$2
  jq -cn --arg key "$(hash_for "$transaction_id")" --arg hash "$(hash_for "$transaction_id")" \
    --arg input "$input" '{key: $key, value: {hash: $hash, input: $input, to: null}}' \
    >>"$rpc_transactions"
}

factory_constructor_additional=$(jq -cn \
  --arg address "$(address_for 35)" \
  '[{transactionType: "CREATE", contractName: "FundAccessManagerDeployer", address: $address,
     initCode: "0x6000"}]')

for index in $(seq 0 33); do
  transaction_id=$((index + 1))
  contract_name=${top_level_contract_names[$index]}
  arguments_json=$(constructor_arguments_json "$contract_name")
  encoded_arguments=$(encode_arguments "$contract_name" "$arguments_json")
  init_code="0x6000${encoded_arguments#0x}"
  additional='[]'
  if [[ "$transaction_id" == "7" ]]; then
    additional=$factory_constructor_additional
  fi
  jq -cn --arg contractName "$contract_name" --arg address "$(address_for "$transaction_id")" \
    --arg hash "$(hash_for "$transaction_id")" --arg input "$init_code" \
    --argjson arguments "$arguments_json" --argjson additional "$additional" '
    {transactionType: "CREATE", contractName: $contractName, contractAddress: $address,
     hash: $hash, arguments: $arguments, additionalContracts: $additional,
     transaction: {input: $input}}
  ' >>"$deploy_transactions"
  append_rpc_transaction "$transaction_id" "$init_code"
done

fund_access_manager_args=$($real_cast abi-encode 'constructor(address)' "$(address_for 200)")
internal_proxy_args=$($real_cast abi-encode 'constructor(address,bytes)' "$(address_for 1)" 0x)
claim_escrow_args=$($real_cast abi-encode 'constructor(address,address)' \
  "$(address_for 200)" "$(address_for 201)")

create_fund_additional=$(jq -cn \
  --arg accessManager "$(address_for 36)" --arg accessManagerInit "0x6000${fund_access_manager_args#0x}" \
  --arg vault "$(address_for 37)" --arg share "$(address_for 38)" \
  --arg accounting "$(address_for 39)" --arg flow "$(address_for 40)" \
  --arg strategy "$(address_for 41)" --arg proxyInit "0x6000${internal_proxy_args#0x}" \
  --arg claimEscrow "$(address_for 42)" --arg claimInit "0x6000${claim_escrow_args#0x}" '
  [{transactionType: "CREATE", contractName: "FundAccessManager", address: $accessManager,
    initCode: $accessManagerInit},
   {transactionType: "CREATE2", contractName: "ERC1967Proxy", address: $vault, initCode: $proxyInit},
   {transactionType: "CREATE2", contractName: "ERC1967Proxy", address: $share, initCode: $proxyInit},
   {transactionType: "CREATE2", contractName: "ERC1967Proxy", address: $accounting, initCode: $proxyInit},
   {transactionType: "CREATE2", contractName: "ERC1967Proxy", address: $flow, initCode: $proxyInit},
   {transactionType: "CREATE2", contractName: "ERC1967Proxy", address: $strategy, initCode: $proxyInit},
   {transactionType: "CREATE2", contractName: "ClaimEscrow", address: $claimEscrow, initCode: $claimInit}]
')

for transaction_id in $(seq 35 108); do
  if [[ "$transaction_id" == "35" ]]; then
    jq -cn --arg hash "$(hash_for "$transaction_id")" --arg factory "$(address_for 7)" \
      --argjson additional "$create_fund_additional" '
      {transactionType: "CALL", contractName: "B1N419ZeroDelayMetaWheelFundFactory",
       contractAddress: $factory, hash: $hash, arguments: [], additionalContracts: $additional,
       transaction: {input: "0x1234"}}
    ' >>"$deploy_transactions"
  else
    jq -cn --arg hash "$(hash_for "$transaction_id")" '
      {transactionType: "CALL", contractName: null, contractAddress: null, hash: $hash,
       arguments: [], additionalContracts: [], transaction: {input: "0x1234"}}
    ' >>"$deploy_transactions"
  fi
done
jq -n --arg commit "${source_commit:0:7}" --slurpfile transactions "$deploy_transactions" '
  {chain: 84532, commit: $commit, pending: [], transactions: $transactions, receipts: []}
' >"$fixture_dir/deploy.json"

make_phase_broadcast() {
  local first_id=$1
  local count=$2
  local path=$3
  local records="$fixture_dir/phase-transactions.jsonl"
  : >"$records"
  for transaction_id in $(seq "$first_id" "$((first_id + count - 1))"); do
    jq -cn --arg hash "$(hash_for "$transaction_id")" '
      {transactionType: "CALL", contractName: null, contractAddress: null, hash: $hash,
       additionalContracts: [], transaction: {input: "0x1234"}}
    ' >>"$records"
  done
  jq -n --arg commit "${source_commit:0:7}" --slurpfile transactions "$records" '
    {chain: 84532, commit: $commit, pending: [], transactions: $transactions, receipts: []}
  ' >"$path"
}

make_phase_broadcast 200 1 "$fixture_dir/rotation.json"
make_phase_broadcast 201 4 "$fixture_dir/configuration.json"
make_phase_broadcast 205 8 "$fixture_dir/managed-register.json"
make_phase_broadcast 213 1 "$fixture_dir/managed-pause.json"
make_phase_broadcast 214 8 "$fixture_dir/onboarding.json"

library_artifacts=(
  src/fund/libraries/CspFundAdapterOperations.sol:CspFundAdapterOperations
  src/fund/libraries/CoveredCallFundAdapterOperations.sol:CoveredCallFundAdapterOperations
  src/fund/libraries/ManagedStrategyOperations.sol:ManagedStrategyOperations
  src/fund/libraries/WheelManagedOperationDispatcher.sol:WheelManagedOperationDispatcher
  src/fund/libraries/WheelCoordinatorPositionOperations.sol:WheelCoordinatorPositionOperations
)
library_transactions="$fixture_dir/library-transactions.jsonl"
library_records="$fixture_dir/library-records.jsonl"
: >"$library_transactions"
: >"$library_records"
for index in $(seq 0 4); do
  transaction_id=$((300 + index))
  address=$(address_for "$((101 + index))")
  artifact=${library_artifacts[$index]}
  contract_name=${artifact##*:}
  jq -cn --arg contractName "$contract_name" --arg address "$address" \
    --arg hash "$(hash_for "$transaction_id")" '
    {transactionType: "CREATE", contractName: $contractName, contractAddress: $address,
     hash: $hash, arguments: [], additionalContracts: [], transaction: {input: "0x6000"}}
  ' >>"$library_transactions"
  jq -cn --argjson index "$index" --arg artifact "$artifact" --arg address "$address" \
    --arg runtimeCodehash "$runtime_codehash" --arg transactionHash "$(hash_for "$transaction_id")" \
    --arg blockHash "$(hash_for "$((1005 + index))")" --argjson blockNumber "$((5 + index))" '
    {index: $index, artifact: $artifact, address: $address, runtimeCodehash: $runtimeCodehash,
     receipt: {transactionHash: $transactionHash, blockHash: $blockHash,
       blockNumber: $blockNumber, status: 1}}
  ' >>"$library_records"
  append_rpc_transaction "$transaction_id" 0x6000
done
jq -n --arg commit "${source_commit:0:7}" --slurpfile transactions "$library_transactions" '
  {chain: 84532, commit: $commit, pending: [], transactions: $transactions, receipts: []}
' >"$fixture_dir/libraries.json"
jq -n --arg sourceCommit "$source_commit" --slurpfile libraries "$library_records" '
  {schemaVersion: "1.0.0", issue: "B1N-419", status: "CONFIRMED_CANONICAL_RECEIPTS",
   deploymentStatus: "DEPLOYED", handoffReady: true, sourceCommit: $sourceCommit,
   network: {name: "base-sepolia", chainId: 84532, environmentKind: "live"},
   exactRelinkVerified: true, orderedLibraries: $libraries}
' >"$fixture_dir/library-evidence.json"

rpc_receipts="$fixture_dir/rpc-receipts.jsonl"
: >"$rpc_receipts"
append_receipt() {
  local transaction_id=$1
  local block_number=$2
  local contract_address=${3:-}
  jq -cn --arg key "$(hash_for "$transaction_id")" --arg transactionHash "$(hash_for "$transaction_id")" \
    --arg blockHash "$(hash_for "$((block_number + 1000))")" --arg contractAddress "$contract_address" \
    --arg blockNumber "0x$(printf '%x' "$block_number")" '
    {key: $key, value: {transactionHash: $transactionHash, blockHash: $blockHash,
      blockNumber: $blockNumber, status: "0x1",
      contractAddress: (if $contractAddress == "" then null else $contractAddress end)}}
  ' >>"$rpc_receipts"
}

for transaction_id in $(seq 1 108); do
  contract_address=
  if [[ "$transaction_id" -le 34 ]]; then contract_address=$(address_for "$transaction_id"); fi
  append_receipt "$transaction_id" "$((transaction_id + 9))" "$contract_address"
done
append_receipt 200 130
for transaction_id in $(seq 201 204); do append_receipt "$transaction_id" "$((transaction_id - 70))"; done
for transaction_id in $(seq 205 212); do append_receipt "$transaction_id" "$((transaction_id - 70))"; done
append_receipt 213 143
for transaction_id in $(seq 214 221); do append_receipt "$transaction_id" "$((transaction_id - 70))"; done
for transaction_id in $(seq 300 304); do
  append_receipt "$transaction_id" "$((transaction_id - 295))" "$(address_for "$((transaction_id - 199))")"
done

factory_trace=$(jq -cn --arg address "$(address_for 35)" \
  '{type: "CREATE", calls: [{type: "CREATE", to: $address, input: "0x6000"}]}')
create_fund_trace=$(jq -cn --argjson deployments "$create_fund_additional" '
  {type: "CALL", calls: [$deployments[] | {type: .transactionType, to: .address, input: .initCode}]}
')
jq -n --argjson chainId 84532 --argjson latestBlock 170 \
  --slurpfile receipts "$rpc_receipts" --slurpfile transactions "$rpc_transactions" \
  --arg factoryHash "$(hash_for 7)" --arg createFundHash "$(hash_for 35)" \
  --argjson factoryTrace "$factory_trace" --argjson createFundTrace "$create_fund_trace" '
  {chainId: $chainId, latestBlock: $latestBlock,
   receipts: ($receipts | from_entries), transactions: ($transactions | from_entries),
   traces: {($factoryHash): $factoryTrace, ($createFundHash): $createFundTrace}}
' >"$fixture_dir/rpc.json"

mkdir -p "$fixture_dir/bin"
mock_cast="$fixture_dir/bin/cast"
cat >"$mock_cast" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  chain-id)
    jq -r '.chainId' "$B1N419_RPC_FIXTURE_PATH"
    ;;
  block-number)
    jq -r '.latestBlock' "$B1N419_RPC_FIXTURE_PATH"
    ;;
  rpc)
    if [[ "$2" == "web3_clientVersion" ]]; then
      printf '"fixture-live-rpc"\n'
    elif [[ "$2" == "anvil_nodeInfo" ]]; then
      exit 1
    elif [[ "$2" == "--raw" && "$3" == "debug_traceTransaction" ]]; then
      transaction_hash=$(jq -r '.[0] | ascii_downcase' <<<"$4")
      jq -ce --arg tx "$transaction_hash" '.traces[$tx]' "$B1N419_RPC_FIXTURE_PATH"
    else
      exit 2
    fi
    ;;
  receipt)
    transaction_hash=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    jq -ce --arg tx "$transaction_hash" '.receipts[$tx]' "$B1N419_RPC_FIXTURE_PATH"
    ;;
  tx)
    transaction_hash=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    jq -ce --arg tx "$transaction_hash" '.transactions[$tx]' "$B1N419_RPC_FIXTURE_PATH"
    ;;
  code)
    printf '0x6000\n'
    ;;
  keccak)
    "$REAL_CAST" keccak "$2"
    ;;
  abi-encode)
    shift
    "$REAL_CAST" abi-encode "$@"
    ;;
  *)
    echo "unsupported mock cast command: $*" >&2
    exit 2
    ;;
esac
MOCK
chmod +x "$mock_cast"

run_generator() {
  local evidence_output=$1
  local inventory_output=$2
  B1N419_CAST_BIN="$mock_cast" \
  B1N419_RPC_FIXTURE_PATH="${B1N419_FIXTURE_RPC_PATH:-$fixture_dir/rpc.json}" \
  REAL_CAST="$real_cast" \
  BASE_SEPOLIA_RPC_URL=https://fixture.invalid \
  B1N419_MANIFEST_PATH="$fixture_dir/manifest.json" \
  B1N419_LIBRARY_EVIDENCE_PATH="$fixture_dir/library-evidence.json" \
  B1N419_CANONICALIZATION_EVIDENCE_OUTPUT="$evidence_output" \
  B1N419_VERIFICATION_INVENTORY_OUTPUT="$inventory_output" \
  B1N419_DEPLOY_BROADCAST_PATH="${B1N419_FIXTURE_DEPLOY_PATH:-$fixture_dir/deploy.json}" \
  B1N419_ROTATION_BROADCAST_PATH="$fixture_dir/rotation.json" \
  B1N419_CONFIGURATION_BROADCAST_PATH="$fixture_dir/configuration.json" \
  B1N419_MANAGED_REGISTER_BROADCAST_PATH="$fixture_dir/managed-register.json" \
  B1N419_MANAGED_PAUSE_BROADCAST_PATH="$fixture_dir/managed-pause.json" \
  B1N419_ONBOARDING_BROADCAST_PATH="$fixture_dir/onboarding.json" \
  B1N419_LIBRARY_BROADCAST_PATH="$fixture_dir/libraries.json" \
  script/fund/generate-meta-wheel-canonicalization-evidence.sh
}

run_generator "$fixture_dir/evidence.json" "$fixture_dir/inventory.json" >"$fixture_dir/success.log"
jq -e --arg manifestDigest "0x$(shasum -a 256 "$fixture_dir/manifest.json" | awk '{print $1}')" '
  .approval == "APPROVED_CANONICALIZATION" and
  .unconfirmedManifestSha256 == $manifestDigest and
  .network.deploymentBlocks == {fundFirst: 10, fundLast: 117} and
  .network.confirmationBlock == 170 and
  (.canonicalReceipts | length) == 108 and
  (.phaseReceipts.bootstrapDeployment | length) == 108 and
  (.phaseReceipts.finalRoleRotation | length) == 1 and
  (.phaseReceipts.inactiveCoordinatorConfiguration | length) == 4 and
  (.phaseReceipts.managedLaneSetup | length) == 9 and
  (.phaseReceipts.childAdapterOnboarding | length) == 8 and
  (.contractReceipts | length) == 42 and
  ([.contractReceipts[].address | ascii_downcase] | unique | length) == 42 and
  .contractActivationBlocks.fundVault == {implementationValidFromBlock: 10, validFromBlock: 44} and
  .contractActivationBlocks.wheelCoordinator == {implementationValidFromBlock: 20, validFromBlock: 21} and
  .contractActivationBlocks.navReportVerifier.validFromBlock == 15 and
  .reconciliation.finalReconciliationBlock == 170 and
  .verification.exactSourceRuntimeBytecodeVerified == false and
  .verification.coreBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.libraryBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.coreStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.libraryStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000000" and
  .verification.addressCount == 0 and .verification.artifactCount == 0
' "$fixture_dir/evidence.json" >/dev/null || die "successful evidence has unexpected shape"

jq -e '
  length == 47 and ([.[].address | ascii_downcase] | unique | length) == 47 and
  ([.[].artifact] | unique | length) == 25 and
  ([.[] | select(.origin == "coreBroadcast")] | length) == 34 and
  ([.[] | select(.origin == "factoryConstructorTrace")] | length) == 1 and
  ([.[] | select(.origin == "createFundTrace")] | length) == 7 and
  ([.[] | select(.origin == "libraryBroadcast")] | length) == 5
' "$fixture_dir/inventory.json" >/dev/null || die "verification inventory has unexpected counts"

while IFS=$'\t' read -r constructor_args constructor_args_hash creation_code creation_code_hash \
  init_code init_code_hash; do
  [[ "$($real_cast keccak "$constructor_args")" == "$constructor_args_hash" ]] \
    || die "constructor argument hash mismatch"
  [[ "$($real_cast keccak "$creation_code")" == "$creation_code_hash" ]] \
    || die "creation code hash mismatch"
  [[ "$($real_cast keccak "$init_code")" == "$init_code_hash" ]] \
    || die "initcode hash mismatch"
done < <(jq -r '.[] | [.constructorArgs, .constructorArgsHash, .creationCode,
  .creationCodeHash, .initCode, .initCodeHash] | @tsv' "$fixture_dir/inventory.json")

inventory_digest="0x$(shasum -a 256 "$fixture_dir/inventory.json" | awk '{print $1}')"
manifest_digest="0x$(shasum -a 256 "$fixture_dir/manifest.json" | awk '{print $1}')"
jq -n --arg sourceCommit "$source_commit" --arg deploymentId "$deployment_id" \
  --arg manifestDigest "$manifest_digest" --arg coreBuildInfoSha256 "$(hash_for 801)" \
  --arg libraryBuildInfoSha256 "$(hash_for 802)" \
  --arg coreStandardJsonInputSha256 "$(hash_for 803)" \
  --arg libraryStandardJsonInputSha256 "$(hash_for 804)" \
  --arg inventorySha256 "$inventory_digest" \
  --slurpfile inventory "$fixture_dir/inventory.json" '
  {schemaVersion: "1.0.0", issue: "B1N-419", method: "SOLC_STANDARD_JSON_RPC_EXACT_V2",
   exactSourceRuntimeBytecodeVerified: true, sourceCommit: $sourceCommit,
   deploymentId: $deploymentId, unconfirmedManifestSha256: $manifestDigest,
   coreBuildInfoSha256: $coreBuildInfoSha256, libraryBuildInfoSha256: $libraryBuildInfoSha256,
   coreStandardJsonInputSha256: $coreStandardJsonInputSha256,
   libraryStandardJsonInputSha256: $libraryStandardJsonInputSha256,
   inventorySha256: $inventorySha256, addressCount: 47, artifactCount: 25,
   network: {name: "base-sepolia", chainId: 84532, confirmationBlock: 170},
   compiler: {version: "0.8.24+commit.e11b9ed9", coreSourceCount: 316,
     librarySourceCount: 170, coreTargetArtifactCount: 20, libraryTargetArtifactCount: 5,
     targetArtifactCount: 25, fullSourceSetsRetained: true, targetOnlyOutputSelection: true},
   inventory: {sha256: $inventorySha256, addressCount: 47, artifactCount: 25,
     primaryArtifactCount: 20, libraryArtifactCount: 5},
   summary: {creationVerified: 47, compiledRuntimeVerified: 47, rpcRuntimeVerified: 47,
     exactCompiledArtifactMatches: 25, exactRpcRuntimeMatches: 47,
     exactTopLevelCreationMatches: 39, traceDerivedInternalCreationsRecompiled: 8},
   records: [$inventory[0][] | {
     address, transactionHash, runtimeCodehash,
     sourceCreationBytecodeMatch: true, sourceRuntimeBytecodeMatch: true,
     rpcRuntimeBytecodeMatch: true
   }]}
' >"$fixture_dir/source-runtime-evidence.json"
source_runtime_digest="0x$(shasum -a 256 "$fixture_dir/source-runtime-evidence.json" | awk '{print $1}')"
B1N419_CAST_BIN="$mock_cast" \
B1N419_MANIFEST_PATH="$fixture_dir/manifest.json" \
B1N419_SOURCE_RUNTIME_EVIDENCE_PATH="$fixture_dir/source-runtime-evidence.json" \
B1N419_CANONICALIZATION_EVIDENCE_PATH="$fixture_dir/evidence.json" \
B1N419_VERIFICATION_INVENTORY_PATH="$fixture_dir/inventory.json" \
B1N419_CANONICALIZATION_EVIDENCE_OUTPUT="$fixture_dir/evidence-bound.json" \
script/fund/generate-meta-wheel-canonicalization-evidence.sh >"$fixture_dir/binding.log"
jq -e --arg sourceRuntimeDigest "$source_runtime_digest" --arg inventoryDigest "$inventory_digest" '
  .verification.exactSourceRuntimeBytecodeVerified == true and
  .verification.sourceRuntimeEvidenceSha256 == $sourceRuntimeDigest and
  .verification.coreBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000321" and
  .verification.libraryBuildInfoSha256 == "0x0000000000000000000000000000000000000000000000000000000000000322" and
  .verification.coreStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000323" and
  .verification.libraryStandardJsonInputSha256 == "0x0000000000000000000000000000000000000000000000000000000000000324" and
  .verification.inventorySha256 == $inventoryDigest and
  .verification.addressCount == 47 and .verification.artifactCount == 25
' "$fixture_dir/evidence-bound.json" >/dev/null || die "bound evidence has unexpected verification fields"

expect_binding_failure() {
  local label=$1
  local source_runtime_path=$2
  local output_path="$fixture_dir/evidence-bound-$label.json"
  local log_path="$fixture_dir/evidence-bound-$label.log"
  if B1N419_CAST_BIN="$mock_cast" \
    B1N419_MANIFEST_PATH="${B1N419_BINDING_MANIFEST_PATH:-$fixture_dir/manifest.json}" \
    B1N419_SOURCE_RUNTIME_EVIDENCE_PATH="$source_runtime_path" \
    B1N419_CANONICALIZATION_EVIDENCE_PATH="$fixture_dir/evidence.json" \
    B1N419_VERIFICATION_INVENTORY_PATH="$fixture_dir/inventory.json" \
    B1N419_CANONICALIZATION_EVIDENCE_OUTPUT="$output_path" \
    script/fund/generate-meta-wheel-canonicalization-evidence.sh >"$log_path" 2>&1; then
    die "binding accepted mismatched $label"
  fi
  rg -q 'source/runtime evidence does not bind' "$log_path" \
    || die "$label mismatch failed for the wrong reason"
}

jq --arg value 2222222222222222222222222222222222222222 '.sourceCommit = $value' \
  "$fixture_dir/source-runtime-evidence.json" >"$fixture_dir/source-runtime-commit.json"
expect_binding_failure commit "$fixture_dir/source-runtime-commit.json"

jq --arg value "$(hash_for 803)" '.deploymentId = $value' \
  "$fixture_dir/source-runtime-evidence.json" >"$fixture_dir/source-runtime-deployment-id.json"
expect_binding_failure deployment-id "$fixture_dir/source-runtime-deployment-id.json"

jq --arg value "$(hash_for 804)" '.unconfirmedManifestSha256 = $value' \
  "$fixture_dir/source-runtime-evidence.json" >"$fixture_dir/source-runtime-manifest-digest.json"
expect_binding_failure manifest-digest "$fixture_dir/source-runtime-manifest-digest.json"

jq '.network.confirmationBlock = 171' \
  "$fixture_dir/source-runtime-evidence.json" >"$fixture_dir/source-runtime-confirmation-block.json"
expect_binding_failure confirmation-block "$fixture_dir/source-runtime-confirmation-block.json"

jq --arg value "$(hash_for 805)" '.inventorySha256 = $value | .inventory.sha256 = $value' \
  "$fixture_dir/source-runtime-evidence.json" >"$fixture_dir/source-runtime-inventory-digest.json"
expect_binding_failure inventory-digest "$fixture_dir/source-runtime-inventory-digest.json"

jq '.fixtureMutation = true' "$fixture_dir/manifest.json" >"$fixture_dir/manifest-mutated.json"
if B1N419_CAST_BIN="$mock_cast" \
  B1N419_MANIFEST_PATH="$fixture_dir/manifest-mutated.json" \
  B1N419_SOURCE_RUNTIME_EVIDENCE_PATH="$fixture_dir/source-runtime-evidence.json" \
  B1N419_CANONICALIZATION_EVIDENCE_PATH="$fixture_dir/evidence.json" \
  B1N419_VERIFICATION_INVENTORY_PATH="$fixture_dir/inventory.json" \
  B1N419_CANONICALIZATION_EVIDENCE_OUTPUT="$fixture_dir/evidence-bound-mutated-manifest.json" \
  script/fund/generate-meta-wheel-canonicalization-evidence.sh \
  >"$fixture_dir/evidence-bound-mutated-manifest.log" 2>&1; then
  die "binding accepted a different unconfirmed manifest"
fi
rg -q 'preliminary evidence does not bind the exact unconfirmed manifest' \
  "$fixture_dir/evidence-bound-mutated-manifest.log" \
  || die "mutated manifest failed for the wrong reason"

if run_generator "$fixture_dir/evidence.json" "$fixture_dir/inventory-overwrite.json" \
  >"$fixture_dir/overwrite.log" 2>&1; then
  die "generator overwrote an existing output"
fi
rg -q 'output already exists' "$fixture_dir/overwrite.log" || die "overwrite failed for the wrong reason"

jq '.transactions[34].additionalContracts = .transactions[34].additionalContracts[0:6]' \
  "$fixture_dir/deploy.json" >"$fixture_dir/deploy-missing-contract.json"
if B1N419_FIXTURE_DEPLOY_PATH="$fixture_dir/deploy-missing-contract.json" \
  run_generator "$fixture_dir/missing-contract-evidence.json" "$fixture_dir/missing-contract-inventory.json" \
  >"$fixture_dir/missing-contract.log" 2>&1; then
  die "generator accepted an incomplete 41-address broadcast inventory"
fi
rg -q 'inventory is not exactly 42' "$fixture_dir/missing-contract.log" \
  || die "missing contract failed for the wrong reason"

jq --arg tx "$(hash_for 200)" '.receipts[$tx].status = "0x0"' \
  "$fixture_dir/rpc.json" >"$fixture_dir/rpc-failed.json"
if B1N419_FIXTURE_RPC_PATH="$fixture_dir/rpc-failed.json" \
  run_generator "$fixture_dir/failed-receipt-evidence.json" "$fixture_dir/failed-receipt-inventory.json" \
  >"$fixture_dir/failed-receipt.log" 2>&1; then
  die "generator accepted a failed canonical receipt"
fi
rg -q 'unsuccessful receipt' "$fixture_dir/failed-receipt.log" \
  || die "failed receipt was rejected for the wrong reason"

jq '.chainId = 1' "$fixture_dir/rpc.json" >"$fixture_dir/rpc-wrong-chain.json"
if B1N419_FIXTURE_RPC_PATH="$fixture_dir/rpc-wrong-chain.json" \
  run_generator "$fixture_dir/wrong-chain-evidence.json" "$fixture_dir/wrong-chain-inventory.json" \
  >"$fixture_dir/wrong-chain.log" 2>&1; then
  die "generator accepted the wrong chain"
fi
rg -q 'RPC is not Base Sepolia' "$fixture_dir/wrong-chain.log" \
  || die "wrong chain was rejected for the wrong reason"

echo "B1N-419 canonicalization evidence generator fixture passed"
