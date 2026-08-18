#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "rev-parse HEAD")
    echo "${B1N419_FIXTURE_SOURCE_COMMIT:?}"
    ;;
  "status --porcelain")
    ;;
  *)
    echo "unsupported generator fixture git command: $*" >&2
    exit 1
    ;;
esac
