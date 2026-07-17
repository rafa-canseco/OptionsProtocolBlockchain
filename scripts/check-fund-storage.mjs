import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(
  new URL("../node_modules/@openzeppelin/upgrades-core/dist/cli/cli.js", import.meta.url),
);
const source = "test/fund/harness/StorageLayoutHarnesses.sol";
const reference = `${source}:FundVaultStorageHarnessV1`;

const cases = [
  ["FundVaultStorageHarnessV2", true],
  ["FundVaultStorageHarnessBadType", false],
  ["FundVaultStorageHarnessRemovedNamespace", false],
];

for (const [contractName, shouldPass] of cases) {
  const result = spawnSync(
    process.execPath,
    [
      cli,
      "validate",
      "out/build-info",
      "--contract",
      `${source}:${contractName}`,
      "--reference",
      reference,
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
