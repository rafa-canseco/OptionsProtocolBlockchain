#!/usr/bin/env bash
set -euo pipefail

real_cast=${B1N419_FIXTURE_REAL_CAST:?}
evidence=${B1N419_FIXTURE_EVIDENCE:?}
libraries=${B1N419_FIXTURE_LIBRARIES:?}
transactions=${B1N419_FIXTURE_TRANSACTIONS:?}

case "${1:-}" in
  chain-id)
    echo 84532
    ;;
  rpc)
    if [[ "${2:-}" == "web3_clientVersion" ]]; then
      echo '"base-sepolia-fixture/v1"'
    else
      exit 1
    fi
    ;;
  receipt)
    jq -cn --slurpfile evidence "$evidence" --slurpfile libraries "$libraries" --arg tx "$2" '
      ([
        $evidence[0].canonicalReceipts[],
        $evidence[0].phaseReceipts[][],
        $evidence[0].contractReceipts[],
        $libraries[0].orderedLibraries[].receipt
      ] | unique_by(.transactionHash)
        | map(select((.transactionHash | ascii_downcase) == ($tx | ascii_downcase)))[0]) as $receipt |
      if $receipt == null then error("unknown fixture receipt") else
        {transactionHash: $receipt.transactionHash, blockHash: $receipt.blockHash,
         blockNumber: $receipt.blockNumber, status: $receipt.status}
      end
    '
    ;;
  tx)
    jq -ce --arg tx "$2" '.[$tx]' "$transactions"
    ;;
  code)
    echo 0x6000
    ;;
  block-number)
    echo 65
    ;;
  call)
    echo 9
    ;;
  keccak|sig|calldata-decode|abi-decode|abi-encode|calldata|to-dec)
    exec "$real_cast" "$@"
    ;;
  *)
    echo "unsupported fixture cast command: $*" >&2
    exit 1
    ;;
esac
