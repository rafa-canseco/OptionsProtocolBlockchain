import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(
  new URL("../node_modules/@openzeppelin/upgrades-core/dist/cli/cli.js", import.meta.url),
);
const source = "test/fund/harness/StorageLayoutHarnesses.sol";
const cases = [
  ["FundVaultStorageHarnessV1", "FundVaultStorageHarnessV2", true],
  ["FundVaultStorageHarnessV1", "FundVaultStorageHarnessBadType", false],
  ["FundVaultStorageHarnessV1", "FundVaultStorageHarnessRemovedNamespace", false],
  ["StrategyManagerStorageHarnessV1", "StrategyManagerStorageHarnessV2", true],
];

for (const [referenceName, contractName, shouldPass] of cases) {
  const result = spawnSync(
    process.execPath,
    [
      cli,
      "validate",
      "out/build-info",
      "--contract",
      `${source}:${contractName}`,
      "--reference",
      `${source}:${referenceName}`,
      "--requireReference",
    ],
    { encoding: "utf8" },
  );
  const expectedMarker = shouldPass ? "SUCCESS" : "FAILED";
  if ((result.status === 0) !== shouldPass || !result.stdout.includes(expectedMarker)) {
    throw new Error(
      `${contractName}: expected ${expectedMarker}\n${result.stdout}\n${result.stderr}`,
    );
  }
}

console.log("fund storage compatibility checks passed");
