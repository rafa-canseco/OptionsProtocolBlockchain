#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_DIR"

UPGRADES_CLI="node_modules/@openzeppelin/upgrades-core/dist/cli/cli.js"
BUILD_INFO_DIR="out/build-info"

node "$UPGRADES_CLI" validate "$BUILD_INFO_DIR" \
  --contract src/fund/WheelCoordinatorAdapter.sol:WheelCoordinatorAdapter
node "$UPGRADES_CLI" validate "$BUILD_INFO_DIR" \
  --contract src/fund/WheelCspChildLane.sol:WheelCspChildLane
node "$UPGRADES_CLI" validate "$BUILD_INFO_DIR" \
  --contract src/fund/WheelCoveredCallChildLane.sol:WheelCoveredCallChildLane
node "$UPGRADES_CLI" validate "$BUILD_INFO_DIR" \
  --contract src/fund/WheelCoveredCallFundAdapter.sol:WheelCoveredCallFundAdapter \
  --unsafeAllow external-library-linking,missing-initializer
