#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "script/fund/verify-meta-wheel-source-runtime.mjs" ]] || {
  echo "unexpected node entrypoint: ${1:-}" >&2
  exit 1
}
shift

check_path=
core_build_info_path=
library_build_info_path=
while (($#)); do
  case "$1" in
    --check)
      check_path=${2:-}
      shift 2
      ;;
    --core-build-info)
      core_build_info_path=${2:-}
      shift 2
      ;;
    --library-build-info)
      library_build_info_path=${2:-}
      shift 2
      ;;
    --inventory | --rpc-url | --confirmation-block | --source-commit | --deployment-id | \
      --unconfirmed-manifest-sha256 | --solc)
      [[ -n "${2:-}" ]] || {
        echo "missing value for node option: $1" >&2
        exit 1
      }
      shift 2
      ;;
    *)
      echo "unexpected node option: $1" >&2
      exit 1
      ;;
  esac
done

[[ -n "$check_path" && -f "$check_path" ]] || {
  echo "missing source/runtime evidence check path" >&2
  exit 1
}
[[ -n "$core_build_info_path" && -f "$core_build_info_path" ]] || {
  echo "missing core build-info path" >&2
  exit 1
}
[[ -n "$library_build_info_path" && -f "$library_build_info_path" ]] || {
  echo "missing library build-info path" >&2
  exit 1
}

echo "B1N-419 exact source/runtime evidence reproduced: $check_path"
