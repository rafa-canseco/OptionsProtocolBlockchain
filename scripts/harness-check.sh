#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
FORK_MANIFEST="$SCRIPT_DIR/harness-fork-paths.txt"
MODE="${1:-}"

usage() {
  printf 'usage: %s <doctor|fast|extended|full>\n' "$0" >&2
}

fail() {
  printf 'harness: %s\n' "$*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

validate_fork_manifest() {
  local chain path block extra
  local listed_paths=""
  local actual_paths
  local duplicate_paths

  [[ -f "$FORK_MANIFEST" ]] || fail "missing fork manifest: scripts/harness-fork-paths.txt"

  while read -r chain path block extra; do
    [[ -z "${chain:-}" || "$chain" == \#* ]] && continue
    [[ "$chain" == "base-mainnet" || "$chain" == "base-sepolia" ]] ||
      fail "invalid fork chain in manifest: $chain"
    [[ -n "${path:-}" && -z "${extra:-}" ]] ||
      fail "invalid fork manifest row for chain $chain"
    [[ "$path" == test/*Fork*.t.sol && -f "$REPOSITORY_ROOT/$path" ]] ||
      fail "fork manifest path is missing or not a fork suite: $path"
    if [[ -n "${block:-}" && ! "$block" =~ ^[0-9]+$ ]]; then
      fail "fork block must be numeric for $path"
    fi
    listed_paths+="$path"$'\n'
  done < "$FORK_MANIFEST"

  listed_paths="$(printf '%s' "$listed_paths" | sed '/^$/d' | LC_ALL=C sort)"
  duplicate_paths="$(printf '%s\n' "$listed_paths" | uniq -d)"
  [[ -z "$duplicate_paths" ]] || fail "duplicate fork manifest path: $duplicate_paths"

  actual_paths="$(cd "$REPOSITORY_ROOT" && find test -type f -name '*Fork*.t.sol' | LC_ALL=C sort)"
  if [[ "$listed_paths" != "$actual_paths" ]]; then
    printf 'harness: fork manifest does not match the repository fork suites\n' >&2
    diff -u <(printf '%s\n' "$listed_paths") <(printf '%s\n' "$actual_paths") >&2 || true
    exit 1
  fi
}

run_doctor() {
  local required_file

  for required_command in node npm forge; do
    require_command "$required_command"
  done

  for required_file in \
    package.json \
    package-lock.json \
    foundry.toml \
    remappings.txt \
    scripts/check-contract-deps.mjs \
    scripts/check-fund-storage.mjs \
    scripts/harness-check.sh \
    scripts/test-harness-check.mjs \
    lib/forge-std/src/Test.sol \
    node_modules/@openzeppelin/contracts/package.json \
    node_modules/@openzeppelin/contracts-upgradeable/package.json \
    node_modules/@openzeppelin/foundry-upgrades/package.json \
    node_modules/@openzeppelin/upgrades-core/package.json; do
    [[ -f "$REPOSITORY_ROOT/$required_file" ]] ||
      fail "missing prerequisite: $required_file (run npm ci --ignore-scripts && npm run deps:foundry)"
  done

  node -e 'const major = Number(process.versions.node.split(".")[0]); if (major < 20) process.exit(1)' ||
    fail "Node.js 20 or newer is required"
  "$SCRIPT_DIR/install-forge-std.sh" --check ||
    fail "forge-std content does not match the pinned dependency (run npm run deps:foundry)"
  validate_fork_manifest
  printf 'harness: doctor passed\n'
}

run_fast() {
  run_doctor
  (
    cd "$REPOSITORY_ROOT"
    node scripts/check-contract-deps.mjs
    node --test scripts/test-harness-check.mjs
    npm_config_offline=true forge test \
      --offline \
      --no-match-path '{*Fork*.t.sol,*Storage*.t.sol}' \
      --no-match-contract '.*(Fuzz|Invariant).*' \
      --no-match-test '^(testFuzz|test_fuzz|invariant_)'
    npm_config_offline=true forge test \
      --offline \
      --no-match-path '{*Fork*.t.sol,*Storage*.t.sol}' \
      --match-contract '.*(Fuzz|Invariant).*' \
      --no-match-test '^(testFuzz|test_fuzz|invariant_)'
    run_storage_checks
  )
  printf 'harness: fast passed (deterministic offline unit/specification suites)\n'
}

require_rpc_environment() {
  [[ -n "${BASE_RPC_URL:-}" ]] ||
    fail "harness:extended requires BASE_RPC_URL for explicit Base mainnet forks"
  [[ -n "${BASE_SEPOLIA_RPC_URL:-}" ]] ||
    fail "harness:extended requires BASE_SEPOLIA_RPC_URL for explicit Base Sepolia forks"
}

require_base_forge() {
  local version
  command -v base-forge >/dev/null 2>&1 ||
    fail "Aerodrome native-token forks require Base Foundry v1.1.0 (install: base-foundryup --install v1.1.0)"
  version="$(base-forge --version 2>&1)" ||
    fail "Aerodrome native-token forks require Base Foundry v1.1.0 (install: base-foundryup --install v1.1.0)"
  grep -Fxq 'forge Version: 1.6.0-v1.1.0' <<<"$version" &&
    grep -Fxq 'Commit SHA: 6130ccf6af0b3399777aee3876486e2ba9ebb38f' <<<"$version" ||
    fail "Aerodrome native-token forks require Base Foundry v1.1.0 commit 6130ccf6af0b3399777aee3876486e2ba9ebb38f (install: base-foundryup --install v1.1.0)"
}

run_fork_evidence() {
  local chain="$1" path="$2" block="${3:-}" rpc_url runner="forge"
  if [[ "$chain" == "base-mainnet" ]]; then
    rpc_url="$BASE_RPC_URL"
  else
    rpc_url="$BASE_SEPOLIA_RPC_URL"
  fi
  if [[ "$path" == "test/fund/B1N491AerodromeRouteFork.t.sol" || "$path" == "test/AerodromeSlipstreamAdapterFork.t.sol" ]]; then
    require_base_forge
    runner="base-forge"
  fi

  printf 'harness: fork chain=%s suite=%s runner=%s\n' "$chain" "$path" "$runner"
  if [[ -n "$block" ]]; then
    npm_config_offline=true "$runner" test --offline --match-path "$path" \
      --fork-url "$rpc_url" --fork-block-number "$block"
  else
    npm_config_offline=true "$runner" test --offline --match-path "$path" \
      --fork-url "$rpc_url"
  fi
}

run_fork_suites() {
  local chain path block extra
  run_fork_evidence base-mainnet test/fund/B1N491AerodromeRouteFork.t.sol 50400001
  while read -r chain path block extra; do
    [[ -z "${chain:-}" || "$chain" == \#* ]] && continue
    [[ "$path" == "test/fund/B1N491AerodromeRouteFork.t.sol" ]] && continue
    run_fork_evidence "$chain" "$path" "${block:-}"
  done < "$FORK_MANIFEST"
}

run_extended() {
  require_rpc_environment
  (
    cd "$REPOSITORY_ROOT"
    FOUNDRY_PROFILE=security npm_config_offline=true forge test \
      --offline \
      --no-match-path '*Fork*.t.sol' \
      --match-test '^(testFuzz|test_fuzz|invariant_)'
    run_fork_suites
  )
  printf 'harness: extended passed (security fuzz/invariant, Base mainnet and Base Sepolia forks)\n'
}

run_storage_checks() {
  local storage_out="out/harness-storage"
  local storage_cache="cache/harness-storage"
  local storage_test_out="out/harness-storage-tests"
  local storage_test_cache="cache/harness-storage-tests"
  (
    cd "$REPOSITORY_ROOT"
    FOUNDRY_SRC=test/fund/harness \
      FOUNDRY_TEST=test/fund/harness \
      FOUNDRY_SCRIPT=test/fund/harness \
      FOUNDRY_OUT="$storage_out" \
      FOUNDRY_CACHE_PATH="$storage_cache" \
      npm_config_offline=true forge build --offline --force
    STORAGE_BUILD_INFO_DIR="$storage_out/build-info" node scripts/check-fund-storage.mjs
    FOUNDRY_OUT="$storage_test_out" \
      FOUNDRY_CACHE_PATH="$storage_test_cache" \
      npm_config_offline=true forge test --offline \
      --match-path '*Storage*.t.sol' \
      --no-match-path '*Fork*.t.sol' \
      --no-match-test '^(testFuzz|test_fuzz|invariant_)'
  )
}

run_full() {
  require_rpc_environment
  run_fast
  run_extended
  printf 'harness: full passed (fast, storage, and extended evidence)\n'
}

case "$MODE" in
  doctor) run_doctor ;;
  fast) run_fast ;;
  extended) run_extended ;;
  full) run_full ;;
  *) usage; exit 2 ;;
esac
