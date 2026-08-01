#!/usr/bin/env bash
set -euo pipefail

real_cast=${B1N419_FIXTURE_REAL_CAST:?}
settler_owner=${B1N419_FIXTURE_SETTLER_OWNER:?}
runtime_codehash=${B1N419_FIXTURE_RUNTIME_CODEHASH:?}
proxy_implementations=${B1N419_FIXTURE_PROXY_IMPLEMENTATIONS:?}

case "${1:-}" in
  chain-id)
    echo 84532
    ;;
  rpc)
    [[ "${2:-}" == "anvil_nodeInfo" ]] || exit 1
    echo '{"forkConfig":{"jsonRpcUrl":"https://fixture.invalid","blockNumber":1}}'
    ;;
  call)
    echo "$settler_owner"
    ;;
  code)
    echo 0x6000
    ;;
  codehash)
    echo "$runtime_codehash"
    ;;
  storage)
    jq -er --arg proxy "$2" '.[$proxy]' "$proxy_implementations"
    ;;
  parse-bytes32-address)
    exec "$real_cast" "$@"
    ;;
  *)
    echo "unsupported generator fixture cast command: $*" >&2
    exit 1
    ;;
esac
