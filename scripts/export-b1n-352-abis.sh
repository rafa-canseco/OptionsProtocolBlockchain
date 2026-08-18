#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$repo_root/deployments/base-sepolia/b1n-352/v1/abis"
events_file="$repo_root/deployments/base-sepolia/b1n-352/v1/events.json"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

contracts=(
  FundVault
  FundShare
  FundAccounting
  FundFlowManager
  StrategyManager
  ClaimEscrow
  FundAccessManager
  FundAccessManagerDeployer
  NavReportVerifier
  FundFactory
  CspFundAdapter
  CspFundValuator
  StrategyAssetEscrow
)

mkdir -p "$output_dir"
rm -f "$output_dir/AccessManager.json"

for contract_name in "${contracts[@]}"; do
  artifact="$repo_root/out/$contract_name.sol/$contract_name.json"
  if [[ ! -f "$artifact" ]]; then
    echo "Missing artifact: $artifact" >&2
    exit 1
  fi
  jq '.abi' "$artifact" > "$output_dir/$contract_name.json"
  jq --arg contract "$contract_name" '[
    .abi[]
    | select(.type == "event")
    | {
        contract: $contract,
        name,
        anonymous,
        inputs: [.inputs[] | {name, type: .internalType, indexed}]
      }
  ]' "$artifact" > "$tmp_dir/$contract_name.events.json"
done

jq -s 'add | sort_by(.contract, .name)' "$tmp_dir"/*.events.json > "$events_file"

echo "Exported ${#contracts[@]} ABIs to $output_dir"
echo "Exported event catalog to $events_file"
