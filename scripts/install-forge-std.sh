#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPOSITORY_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
DESTINATION="$REPOSITORY_ROOT/lib/forge-std"
REPOSITORY_URL="https://github.com/foundry-rs/forge-std.git"
COMMIT="bf647bd6046f2f7da30d0c2bf435e5c76a780c1b"
VERSION="1.16.2"
TREE_SHA256="f7228426b1ca533bfbe4f86b269c2bd6f5d84f4323bf1290ee2d6218c2de1e99"
MODE="${1:-install}"

[[ "$MODE" == "install" || "$MODE" == "--check" ]] || {
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 2
}

tree_sha256() {
  (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
}

if [[ -f "$DESTINATION/src/Test.sol" && -f "$DESTINATION/package.json" ]] \
  && node -e 'const p=require(process.argv[1]); process.exit(p.version === process.argv[2] ? 0 : 1)' \
    "$DESTINATION/package.json" "$VERSION" \
  && [[ "$(tree_sha256 "$DESTINATION")" == "$TREE_SHA256" ]]; then
  printf 'forge-std: pinned version %s content verified\n' "$VERSION"
  exit 0
fi

if [[ "$MODE" == "--check" ]]; then
  printf 'forge-std: missing or content does not match the pinned dependency\n' >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || {
  printf 'forge-std: git is required\n' >&2
  exit 1
}

temporary="$(mktemp -d "${TMPDIR:-/tmp}/forge-std.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

git -C "$temporary" init -q
git -C "$temporary" remote add origin "$REPOSITORY_URL"
git -C "$temporary" fetch -q --depth 1 origin "$COMMIT"
git -C "$temporary" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$temporary" rev-parse HEAD)" == "$COMMIT" ]] || {
  printf 'forge-std: fetched revision does not match pin\n' >&2
  exit 1
}
[[ "$(node -p 'require(process.argv[1]).version' "$temporary/package.json")" == "$VERSION" ]] || {
  printf 'forge-std: package version does not match pin\n' >&2
  exit 1
}

rm -rf "$temporary/.git"
[[ "$(tree_sha256 "$temporary")" == "$TREE_SHA256" ]] || {
  printf 'forge-std: fetched content digest does not match pin\n' >&2
  exit 1
}
mkdir -p "$REPOSITORY_ROOT/lib"
rm -rf "$DESTINATION"
mv "$temporary" "$DESTINATION"
trap - EXIT
printf 'forge-std: installed version %s at pinned commit %s\n' "$VERSION" "$COMMIT"
