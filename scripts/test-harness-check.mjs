import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = fileURLToPath(new URL("../", import.meta.url));
const harnessScript = path.join(repositoryRoot, "scripts/harness-check.sh");
const forkManifest = path.join(repositoryRoot, "scripts/harness-fork-paths.txt");

async function makeMockCommands(
  baseForgeVersion = "forge Version: 1.6.0-v1.1.0\nCommit SHA: 6130ccf6af0b3399777aee3876486e2ba9ebb38f",
) {
  const directory = await mkdtemp(path.join(tmpdir(), "blockchain-harness-"));
  const log = path.join(directory, "commands.log");
  const command = `#!/usr/bin/env bash\nset -eu\nprintf '%s' \"$(basename \"$0\")\" >> \"$HARNESS_COMMAND_LOG\"\nfor argument in \"$@\"; do printf '\\t%s' \"$argument\" >> \"$HARNESS_COMMAND_LOG\"; done\nprintf '\\n' >> \"$HARNESS_COMMAND_LOG\"\n`;

  for (const name of ["node", "npm", "forge"]) {
    const commandPath = path.join(directory, name);
    await writeFile(commandPath, command);
    await chmod(commandPath, 0o755);
  }
  const baseForgePath = path.join(directory, "base-forge");
  await writeFile(
    baseForgePath,
    `${command}\nif [[ "\${1:-}" == "--version" ]]; then cat <<'EOF'\n${baseForgeVersion}\nEOF\nfi\n`,
  );
  await chmod(baseForgePath, 0o755);
  return { directory, log };
}

function runHarness(mode, mocks, environment = {}) {
  const env = { ...process.env, ...environment };
  delete env.BASE_RPC_URL;
  delete env.BASE_SEPOLIA_RPC_URL;
  Object.assign(env, environment, {
    HARNESS_COMMAND_LOG: mocks.log,
    PATH: `${mocks.directory}:${process.env.PATH}`,
  });
  return spawnSync("/bin/bash", [harnessScript, mode], {
    cwd: tmpdir(),
    env,
    encoding: "utf8",
  });
}

async function commandLines(log) {
  try {
    return (await readFile(log, "utf8")).trim().split("\n").filter(Boolean);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

test("invalid mode is rejected with usage", () => {
  const result = spawnSync("/bin/bash", [harnessScript, "unexpected"], {
    cwd: tmpdir(),
    encoding: "utf8",
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /usage: .* <doctor\|fast\|full>/);
});

test("fast is offline and excludes fork, fuzz, and invariant work", async (context) => {
  const mocks = await makeMockCommands();
  context.after(() => rm(mocks.directory, { recursive: true, force: true }));

  const result = runHarness("fast", mocks);
  assert.equal(result.status, 0, result.stderr);
  const lines = await commandLines(mocks.log);
  const forgeTests = lines.filter((line) => line.startsWith("forge\ttest\t"));
  assert.equal(forgeTests.length, 1);
  assert.match(forgeTests[0], /\t--offline(?:\t|$)/);
  assert.match(forgeTests[0], /\t--no-match-path\t\{\*Fork\*\.t\.sol,\*Storage\*\.t\.sol\}/);
  assert.match(forgeTests[0], /\t--no-match-contract\t\.\*\(Fuzz\|Invariant\)\.\*/);
  assert.match(forgeTests[0], /\t--no-match-test\t\^testFuzz/);
  assert.doesNotMatch(forgeTests[0], /--fork-url/);
  assert.ok(lines.includes("node\tscripts/check-contract-deps.mjs"));
  assert.ok(lines.includes("node\t--test\tscripts/test-harness-check.mjs"));
});

test("full fails closed before tests when either required RPC variable is absent", async (context) => {
  const mocks = await makeMockCommands();
  context.after(() => rm(mocks.directory, { recursive: true, force: true }));

  for (const environment of [
    {},
    { BASE_RPC_URL: "mock://base-mainnet" },
    { BASE_SEPOLIA_RPC_URL: "mock://base-sepolia" },
  ]) {
    await rm(mocks.log, { force: true });
    const result = runHarness("full", mocks, environment);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /requires (BASE_RPC_URL|BASE_SEPOLIA_RPC_URL)/);
    const lines = await commandLines(mocks.log);
    assert.equal(lines.some((line) => line.startsWith("forge\ttest\t")), false);
    assert.equal(lines.some((line) => line.startsWith("forge\tbuild\t")), false);
  }
});

test("full runs storage, the security profile, and every explicit Base fork suite", async (context) => {
  const mocks = await makeMockCommands();
  context.after(() => rm(mocks.directory, { recursive: true, force: true }));

  const result = runHarness("full", mocks, {
    BASE_RPC_URL: "mock://base-mainnet",
    BASE_SEPOLIA_RPC_URL: "mock://base-sepolia",
  });
  assert.equal(result.status, 0, result.stderr);

  const lines = await commandLines(mocks.log);
  assert.ok(lines.includes("forge\tbuild\t--offline\t--force"));
  assert.ok(lines.includes("node\tscripts/check-fund-storage.mjs"));
  assert.ok(
    lines.some(
      (line) =>
        line.startsWith("forge\ttest\t--offline\t--no-match-path\t*Fork*.t.sol") &&
        !line.includes("--fork-url"),
    ),
  );

  const manifest = await readFile(forkManifest, "utf8");
  const rows = manifest
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"))
    .map((line) => line.split(/\s+/));
  const forkCommands = lines.filter(
    (line) =>
      (line.startsWith("forge\ttest\t") || line.startsWith("base-forge\ttest\t")) &&
      line.includes("\t--fork-url\t"),
  );
  assert.equal(forkCommands.length, rows.length);

  for (const [chain, suite, block] of rows) {
    const rpc = chain === "base-mainnet" ? "mock://base-mainnet" : "mock://base-sepolia";
    const invocation = forkCommands.find((line) => line.includes(`\t--match-path\t${suite}\t`));
    assert.ok(invocation, `missing fork invocation for ${suite}`);
    assert.ok(invocation.includes(`\t--fork-url\t${rpc}`));
    if (block) assert.ok(invocation.includes(`\t--fork-block-number\t${block}`));
    if (
      suite === "test/fund/B1N491AerodromeRouteFork.t.sol" ||
      suite === "test/fund/B1N495SettlementRouteQualificationFork.t.sol" ||
      suite === "test/AerodromeSlipstreamAdapterFork.t.sol"
    ) {
      assert.ok(invocation.startsWith("base-forge\ttest\t"));
    } else {
      assert.ok(invocation.startsWith("forge\ttest\t"));
    }
  }
});

test("Aerodrome native-token forks fail closed on an unpinned Base Foundry build", async (context) => {
  const mocks = await makeMockCommands("forge Version: 1.6.0-v1.1.0\nCommit SHA: wrong");
  context.after(() => rm(mocks.directory, { recursive: true, force: true }));

  const result = runHarness("full", mocks, {
    BASE_RPC_URL: "mock://base-mainnet",
    BASE_SEPOLIA_RPC_URL: "mock://base-sepolia",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /base-foundryup --install v1\.1\.0/);
  const lines = await commandLines(mocks.log);
  assert.ok(lines.includes("base-forge\t--version"));
  assert.equal(lines.some((line) => line.startsWith("base-forge\ttest\t")), false);
});
