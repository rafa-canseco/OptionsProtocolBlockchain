import { readFile } from "node:fs/promises";

const expected = new Map([
  ["@openzeppelin/contracts", "5.5.0"],
  ["@openzeppelin/contracts-upgradeable", "5.5.0"],
  ["@openzeppelin/foundry-upgrades", "0.4.1"],
  ["@openzeppelin/upgrades-core", "1.45.0"],
]);

for (const [name, version] of expected) {
  const packageJson = JSON.parse(
    await readFile(new URL(`../node_modules/${name}/package.json`, import.meta.url)),
  );
  if (packageJson.version !== version) {
    throw new Error(`${name}: expected ${version}, found ${packageJson.version}`);
  }
}

console.log("contract dependencies match pinned versions");
