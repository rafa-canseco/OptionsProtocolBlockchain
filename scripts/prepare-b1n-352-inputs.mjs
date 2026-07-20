import {createHash} from "node:crypto";
import {readFileSync} from "node:fs";
import {resolve} from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const ADAPTER_ARTIFACT = "out/CspFundAdapter.sol/CspFundAdapter.json";
const OPERATIONS_ARTIFACT = "out/CspFundAdapterOperations.sol/CspFundAdapterOperations.json";
const OPERATIONS_LIBRARY = "CspFundAdapterOperations";

export const REQUIRED_ENVIRONMENT_KEYS = [
  "FUND_PHASE_SCHEDULER",
  "FUND_V1_ADDRESS_BOOK",
  "FUND_ACCOUNTING_ASSET",
  "FUND_WETH",
  "FUND_ADAPTER_SWAP_ROUTER",
  "FUND_ADAPTER_SWAP_FEE_TIER",
  "FUND_FACTORY_OWNER",
  "FUND_IMPLEMENTATION_VERSION",
  "FUND_COMPATIBILITY_VERSION",
  "FUND_DEPLOYMENT_SALT",
  "FUND_NAME",
  "FUND_SYMBOL",
  "FUND_ADMIN",
  "FUND_UPGRADER",
  "FUND_ACCOUNTING_OPERATOR",
  "FUND_ALLOCATOR",
  "FUND_PROCESSOR",
  "FUND_CURATOR",
  "FUND_GUARDIAN",
  "FUND_MINIMUM_IDLE_BPS",
  "FUND_NAV_ACTIVATION_DELAY_BLOCKS",
  "FUND_MAX_SNAPSHOT_AGE_BLOCKS",
  "FUND_MAX_NAV_WINDOW_LENGTH_BLOCKS",
  "FUND_MANAGEMENT_FEE_WAD",
  "FUND_PERFORMANCE_FEE_BPS",
  "FUND_MAX_MANAGEMENT_FEE_BPS",
  "FUND_MAX_PERFORMANCE_FEE_BPS",
  "FUND_MAX_ACCRUAL_INTERVAL_SECONDS",
  "FUND_CRYSTALLIZATION_PERIOD_SECONDS",
  "FUND_FEE_RECIPIENT",
  "FUND_NAV_REPORTERS",
  "FUND_NAV_REPORTER_THRESHOLD",
  "FUND_NAV_REPORTER_SET_VERSION",
  "FUND_MAX_EXIT_FEE_BPS",
  "FUND_MAX_WINDOW_OUTFLOW_BPS",
  "FUND_CSP_MIN_EXPIRY_DELAY_SECONDS",
  "FUND_CSP_MAX_EXPIRY_DELAY_SECONDS",
  "FUND_CSP_SETTLEMENT_DEFAULT_DELAY_SECONDS",
  "FUND_CSP_MIN_PREMIUM_BPS",
  "FUND_CSP_MAX_SWAP_SLIPPAGE_BPS",
  "FUND_CSP_MAX_OPEN_POSITIONS",
  "FUND_CSP_MIN_STRIKE",
  "FUND_CSP_MAX_STRIKE",
  "FUND_CSP_MAX_COLLATERAL_PER_POSITION",
  "FUND_CSP_MAX_WETH_PER_SWAP",
  "FUND_CSP_SPOT_FEED",
  "FUND_CSP_SPOT_FEED_DECIMALS",
  "FUND_CSP_MAX_SPOT_STALENESS_SECONDS",
  "FUND_CSP_MAX_OBSERVATION_WINDOW_BLOCKS",
  "FUND_CSP_OBSERVATION_QUORUM",
  "FUND_CSP_LIABILITY_BUFFER_BPS",
  "FUND_CSP_APPROVED_OBSERVERS",
  "FUND_CSP_ADAPTER_INTERFACE_VERSION",
  "FUND_STRATEGY_MAX_ALLOCATION_BPS",
  "FUND_STRATEGY_MAX_LOSS_BPS",
  "FUND_STRATEGY_COOLDOWN_SECONDS",
  "FUND_STRATEGY_ABSOLUTE_CAP",
  "FUND_CSP_ADAPTER_OPERATIONS",
  "FUND_CSP_ADAPTER_OPERATIONS_CODEHASH",
  "FUND_CSP_ADAPTER_IMPLEMENTATION_CODEHASH",
  "FUND_EXPECTED_V1_ADDRESS_BOOK",
  "FUND_EXPECTED_V1_ADDRESS_BOOK_IMPLEMENTATION",
  "FUND_EXPECTED_V1_ADDRESS_BOOK_CODEHASH",
  "FUND_EXPECTED_V1_ADDRESS_BOOK_OWNER",
  "FUND_EXPECTED_V1_ADDRESS_BOOK_PENDING_OWNER",
  "FUND_EXPECTED_V1_CONTROLLER_PROXY",
  "FUND_EXPECTED_V1_CONTROLLER_IMPLEMENTATION",
  "FUND_EXPECTED_V1_CONTROLLER_CODEHASH",
  "FUND_EXPECTED_V1_CONTROLLER_OWNER",
  "FUND_EXPECTED_V1_CONTROLLER_PENDING_OWNER",
  "FUND_EXPECTED_V1_MARGIN_POOL_PROXY",
  "FUND_EXPECTED_V1_MARGIN_POOL_IMPLEMENTATION",
  "FUND_EXPECTED_V1_MARGIN_POOL_CODEHASH",
  "FUND_EXPECTED_V1_OTOKEN_FACTORY_PROXY",
  "FUND_EXPECTED_V1_OTOKEN_FACTORY_IMPLEMENTATION",
  "FUND_EXPECTED_V1_OTOKEN_FACTORY_CODEHASH",
  "FUND_EXPECTED_V1_ORACLE_PROXY",
  "FUND_EXPECTED_V1_ORACLE_IMPLEMENTATION",
  "FUND_EXPECTED_V1_ORACLE_CODEHASH",
  "FUND_EXPECTED_V1_ORACLE_OWNER",
  "FUND_EXPECTED_V1_ORACLE_PENDING_OWNER",
  "FUND_EXPECTED_V1_WHITELIST_PROXY",
  "FUND_EXPECTED_V1_WHITELIST_IMPLEMENTATION",
  "FUND_EXPECTED_V1_WHITELIST_CODEHASH",
  "FUND_EXPECTED_V1_WHITELIST_OWNER",
  "FUND_EXPECTED_V1_WHITELIST_PENDING_OWNER",
  "FUND_EXPECTED_V1_BATCH_SETTLER_PROXY",
  "FUND_EXPECTED_V1_BATCH_SETTLER_IMPLEMENTATION",
  "FUND_EXPECTED_V1_BATCH_SETTLER_CODEHASH",
  "FUND_EXPECTED_V1_BATCH_SETTLER_OWNER",
  "FUND_EXPECTED_V1_BATCH_SETTLER_PENDING_OWNER"
];

function fail(message) {
  throw new Error(`B1N-352 inputs: ${message}`);
}

export function sha256Hex(contents) {
  return `0x${createHash("sha256").update(contents).digest("hex")}`;
}

function normalizeHex(value, bytes, label) {
  if (typeof value !== "string") fail(`${label} must be a hex string`);
  const normalized = value.toLowerCase().replace(/^0x/, "");
  if (!new RegExp(`^[0-9a-f]{${bytes * 2}}$`).test(normalized)) fail(`${label} must be ${bytes} bytes`);
  return normalized;
}

function run(command, args) {
  const result = spawnSync(command, args, {encoding: "utf8"});
  if (result.status !== 0) fail(`${command} ${args.join(" ")} failed: ${result.stderr.trim()}`);
  return result.stdout.trim();
}

function keccak(bytecode) {
  return run("cast", ["keccak", `0x${bytecode}`]).toLowerCase();
}

function deployedBytecode(artifact, label) {
  const object = artifact?.deployedBytecode?.object;
  if (typeof object !== "string" || object.length === 0) fail(`${label} deployed bytecode is missing`);
  return object.replace(/^0x/, "");
}

export function linkAdapterRuntime(artifact, operationsAddress) {
  let runtime = deployedBytecode(artifact, "adapter");
  const address = normalizeHex(operationsAddress, 20, "FUND_CSP_ADAPTER_OPERATIONS");
  const allReferences = [];
  const operationsReferences = [];
  for (const [source, contracts] of Object.entries(artifact.deployedBytecode.linkReferences ?? {})) {
    for (const [contract, references] of Object.entries(contracts)) {
      for (const reference of references) {
        const enriched = {...reference, source, contract};
        allReferences.push(enriched);
        if (contract === OPERATIONS_LIBRARY) operationsReferences.push(enriched);
      }
    }
  }
  if (allReferences.length !== 2 || operationsReferences.length !== 2) {
    fail("adapter must contain exactly two CspFundAdapterOperations runtime link references");
  }
  for (const reference of operationsReferences) {
    if (reference.length !== 20) fail("adapter library link reference must be 20 bytes");
    const start = reference.start * 2;
    runtime = `${runtime.slice(0, start)}${address}${runtime.slice(start + 40)}`;
  }
  if (!/^[0-9a-f]+$/i.test(runtime)) fail("adapter runtime remains partially unlinked");
  return runtime.toLowerCase();
}

function validateBuild(artifact, label, approvedSource) {
  const metadata = typeof artifact.metadata === "string" ? JSON.parse(artifact.metadata) : artifact.metadata;
  const version = metadata?.compiler?.version ?? "";
  const settings = metadata?.settings ?? {};
  if (!version.startsWith(approvedSource.solc)) fail(`${label} compiler does not match approved source`);
  if (settings.optimizer?.enabled !== true || settings.optimizer?.runs !== approvedSource.optimizerRuns) {
    fail(`${label} optimizer does not match approved source`);
  }
  if (settings.viaIR !== approvedSource.viaIr) fail(`${label} viaIR does not match approved source`);
}

export function validateDocument(document, {requireApproval = true} = {}) {
  if (document?.schemaVersion !== "1.0.0" || document?.issue !== "B1N-352") fail("invalid schema or issue");
  if (document?.network?.chainId !== 84532 || document?.network?.name !== "base-sepolia") {
    fail("network must be Base Sepolia (84532)");
  }
  if (requireApproval && document?.approval?.status !== "APPROVED") fail("approval status is not APPROVED");
  if (requireApproval && (!document.approval.approvedBy || !document.approval.approvedAt)) {
    fail("approval identity and timestamp are required");
  }
  if (!document?.source?.gitCommit || !document?.source?.solc) fail("approved source is incomplete");
  if (requireApproval && !/^[0-9a-f]{40}$/i.test(document.source.gitCommit)) fail("invalid approved git commit");
  if (document.source.optimizerRuns !== 200 || document.source.viaIr !== true) fail("unexpected build settings");
  if (!document?.policy?.artifact || !document?.policy?.sha256) fail("approved policy binding is incomplete");
  if (requireApproval) normalizeHex(document.policy.sha256, 32, "policy.sha256");
  const environment = document.environment ?? {};
  for (const key of REQUIRED_ENVIRONMENT_KEYS) {
    const value = environment[key];
    if (value === undefined || value === null || value === "" || /^TO_BE_|^FROM_/.test(String(value))) {
      if (requireApproval) fail(`${key} is not populated`);
    }
  }
  for (const key of ["FUND_NAV_REPORTERS", "FUND_CSP_APPROVED_OBSERVERS"]) {
    if (requireApproval && (!Array.isArray(environment[key]) || environment[key].length === 0)) {
      fail(`${key} must be a non-empty array`);
    }
  }
  if (
    requireApproval
    && String(environment.FUND_V1_ADDRESS_BOOK).toLowerCase()
      !== String(environment.FUND_EXPECTED_V1_ADDRESS_BOOK).toLowerCase()
  ) {
    fail("FUND_V1_ADDRESS_BOOK differs from its approved baseline");
  }
  const extras = Object.keys(environment).filter((key) => !REQUIRED_ENVIRONMENT_KEYS.includes(key));
  if (extras.length !== 0) fail(`unrecognized environment keys: ${extras.join(", ")}`);
  return environment;
}

export function deriveApprovedHashes(document, root = process.cwd()) {
  const environment = validateDocument(document, {requireApproval: false});
  const adapter = JSON.parse(readFileSync(resolve(root, ADAPTER_ARTIFACT), "utf8"));
  const operations = JSON.parse(readFileSync(resolve(root, OPERATIONS_ARTIFACT), "utf8"));
  validateBuild(adapter, "adapter", document.source);
  validateBuild(operations, "operations", document.source);
  const operationsRuntime = deployedBytecode(operations, "operations");
  if (!/^[0-9a-f]+$/i.test(operationsRuntime)) fail("operations runtime is not fully linked");
  const linkedAdapterRuntime = linkAdapterRuntime(adapter, environment.FUND_CSP_ADAPTER_OPERATIONS);
  return {
    FUND_CSP_ADAPTER_OPERATIONS_CODEHASH: keccak(operationsRuntime),
    FUND_CSP_ADAPTER_IMPLEMENTATION_CODEHASH: keccak(linkedAdapterRuntime)
  };
}

function loadAndDigest(inputPath, expectedDigest) {
  const raw = readFileSync(inputPath, "utf8");
  const digest = sha256Hex(raw);
  if (expectedDigest && digest !== expectedDigest.toLowerCase()) fail(`digest mismatch: ${digest}`);
  return {raw, digest, document: JSON.parse(raw)};
}

function check(inputPath, expectedDigest) {
  const loaded = loadAndDigest(inputPath, expectedDigest);
  const environment = validateDocument(loaded.document);
  const sourcePaths = ["src", "script/fund", "foundry.toml", "remappings.txt"];
  const sourceDiff = spawnSync(
    "git",
    ["diff", "--quiet", loaded.document.source.gitCommit, "--", ...sourcePaths],
    {encoding: "utf8"}
  );
  if (sourceDiff.status !== 0) fail("current contract and deployment source differs from approved git commit");
  run("forge", ["build", "--offline"]);
  const derived = deriveApprovedHashes(loaded.document);
  for (const [key, value] of Object.entries(derived)) {
    if (String(environment[key]).toLowerCase() !== value) fail(`${key} does not match approved build`);
  }
  return {...loaded, environment, derived};
}

function shellQuote(value) {
  const rendered = Array.isArray(value) ? value.join(",") : String(value);
  return `'${rendered.replaceAll("'", `'"'"'`)}'`;
}

function main() {
  const [command, inputPath, expectedDigest] = process.argv.slice(2);
  if (!command || !inputPath) {
    fail("usage: prepare-b1n-352-inputs.mjs <template|derive|check|env> <json> [sha256]");
  }
  if (command === "template") {
    const loaded = loadAndDigest(inputPath);
    validateDocument(loaded.document, {requireApproval: false});
    console.log(`TEMPLATE_SHA256=${loaded.digest}`);
    return;
  }
  if (command === "derive") {
    const loaded = loadAndDigest(inputPath);
    run("forge", ["build", "--offline"]);
    console.log(JSON.stringify(deriveApprovedHashes(loaded.document), null, 2));
    return;
  }
  if (!expectedDigest) fail(`${command} requires the externally approved SHA-256 digest`);
  const checked = check(inputPath, expectedDigest.toLowerCase());
  if (command === "check") {
    console.log(`APPROVED_INPUTS_SHA256=${checked.digest}`);
    console.log("APPROVED_BUILD_AND_LINKS_OK");
    return;
  }
  if (command === "env") {
    console.log(`FUND_APPROVED_INPUTS_PATH=${shellQuote(resolve(inputPath))}`);
    console.log(`FUND_APPROVED_INPUTS_SHA256=${shellQuote(checked.digest)}`);
    return;
  }
  fail(`unknown command ${command}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) main();
