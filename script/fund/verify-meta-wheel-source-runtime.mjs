#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EXPECTED_CHAIN_ID = 84_532;
const EXPECTED_CORE_SOURCE_COUNT = 316;
const EXPECTED_LIBRARY_SOURCE_COUNT = 170;
const EXPECTED_ADDRESS_COUNT = 47;
const EXPECTED_ARTIFACT_COUNT = 25;
const EXPECTED_PRIMARY_ARTIFACT_COUNT = 20;
const EXPECTED_LIBRARY_ARTIFACT_COUNT = 5;
const EXPECTED_ORIGIN_COUNTS = {
  coreBroadcast: 34,
  createFundTrace: 7,
  factoryConstructorTrace: 1,
  libraryBroadcast: 5,
};
const EXPECTED_SOLC_VERSION = "0.8.24+commit.e11b9ed9";
const VERIFICATION_METHOD = "SOLC_STANDARD_JSON_RPC_EXACT_V2";
const TOP_LEVEL_ORIGINS = new Set(["coreBroadcast", "libraryBroadcast"]);
const INTERNAL_ORIGINS = new Set(["createFundTrace", "factoryConstructorTrace"]);
const HEX_32 = /^0x[0-9a-fA-F]{64}$/;
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const MASK_64 = (1n << 64n) - 1n;
const KECCAK_ROUNDS = [
  0x0000000000000001n,
  0x0000000000008082n,
  0x800000000000808an,
  0x8000000080008000n,
  0x000000000000808bn,
  0x0000000080000001n,
  0x8000000080008081n,
  0x8000000000008009n,
  0x000000000000008an,
  0x0000000000000088n,
  0x0000000080008009n,
  0x000000008000000an,
  0x000000008000808bn,
  0x800000000000008bn,
  0x8000000000008089n,
  0x8000000000008003n,
  0x8000000000008002n,
  0x8000000000000080n,
  0x000000000000800an,
  0x800000008000000an,
  0x8000000080008081n,
  0x8000000000008080n,
  0x0000000080000001n,
  0x8000000080008008n,
];
const KECCAK_ROTATIONS = [
  [0, 36, 3, 41, 18],
  [1, 44, 10, 45, 2],
  [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56],
  [27, 20, 39, 8, 14],
];

function fail(message) {
  throw new Error(`B1N-419 source/runtime verification blocked: ${message}`);
}

function strip0x(value) {
  return typeof value === "string" && value.startsWith("0x") ? value.slice(2) : value;
}

function normalizeHex(value, label) {
  if (typeof value !== "string") fail(`${label} must be hex`);
  const normalized = strip0x(value).toLowerCase();
  if (normalized.length % 2 !== 0 || /[^0-9a-f]/.test(normalized)) fail(`${label} must be even-length hex`);
  return normalized;
}

function normalizeAddress(value, label) {
  if (typeof value !== "string" || !ADDRESS.test(value) || /^0x0{40}$/i.test(value)) {
    fail(`${label} must be a non-zero address`);
  }
  return value.toLowerCase();
}

function bytes32(value, label) {
  if (typeof value !== "string" || !HEX_32.test(value) || /^0x0{64}$/i.test(value)) {
    fail(`${label} must be non-zero bytes32`);
  }
  return value.toLowerCase();
}

function sha256(buffer) {
  return `0x${crypto.createHash("sha256").update(buffer).digest("hex")}`;
}

function rotateLeft64(value, shift) {
  if (shift === 0) return value & MASK_64;
  const amount = BigInt(shift);
  return ((value << amount) | (value >> (64n - amount))) & MASK_64;
}

function keccakPermutation(state) {
  for (const roundConstant of KECCAK_ROUNDS) {
    const columns = new Array(5).fill(0n);
    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) columns[x] ^= state[x + 5 * y];
    }
    const deltas = new Array(5);
    for (let x = 0; x < 5; x += 1) {
      deltas[x] = columns[(x + 4) % 5] ^ rotateLeft64(columns[(x + 1) % 5], 1);
    }
    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) state[x + 5 * y] = (state[x + 5 * y] ^ deltas[x]) & MASK_64;
    }

    const rotated = new Array(25).fill(0n);
    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) {
        const newX = y;
        const newY = (2 * x + 3 * y) % 5;
        rotated[newX + 5 * newY] = rotateLeft64(state[x + 5 * y], KECCAK_ROTATIONS[x][y]);
      }
    }
    for (let x = 0; x < 5; x += 1) {
      for (let y = 0; y < 5; y += 1) {
        state[x + 5 * y] =
          (rotated[x + 5 * y] ^ ((~rotated[((x + 1) % 5) + 5 * y]) & rotated[((x + 2) % 5) + 5 * y])) &
          MASK_64;
      }
    }
    state[0] = (state[0] ^ roundConstant) & MASK_64;
  }
}

export function keccak256Hex(value) {
  const input = Buffer.isBuffer(value) ? value : Buffer.from(normalizeHex(value, "keccak input"), "hex");
  const rate = 136;
  const paddedLength = Math.ceil((input.length + 1) / rate) * rate;
  const padded = Buffer.alloc(paddedLength);
  input.copy(padded);
  padded[input.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const state = new Array(25).fill(0n);
  for (let offset = 0; offset < padded.length; offset += rate) {
    for (let lane = 0; lane < rate / 8; lane += 1) {
      state[lane] ^= padded.readBigUInt64LE(offset + lane * 8);
    }
    keccakPermutation(state);
  }
  const output = Buffer.alloc(32);
  for (let lane = 0; lane < 4; lane += 1) output.writeBigUInt64LE(state[lane], lane * 8);
  return `0x${output.toString("hex")}`;
}

function splitArtifact(artifact) {
  if (typeof artifact !== "string") fail("inventory artifact must be a string");
  const separator = artifact.lastIndexOf(":");
  if (separator <= 0 || separator === artifact.length - 1) fail(`invalid artifact FQN: ${artifact}`);
  return [artifact.slice(0, separator), artifact.slice(separator + 1)];
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function parseJson(pathname, label) {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(pathname, "utf8"));
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
  return parsed;
}

function compilerVersion(solcPath) {
  const result = spawnSync(solcPath, ["--version"], { encoding: "utf8" });
  if (result.status !== 0) fail(`solc --version failed: ${(result.stderr || "").trim()}`);
  const match = result.stdout.match(/Version:\s*([^\s]+)/);
  if (!match || !match[1].startsWith(EXPECTED_SOLC_VERSION)) {
    fail(`solc must be ${EXPECTED_SOLC_VERSION}`);
  }
  return EXPECTED_SOLC_VERSION;
}

function targetOutputSelection(artifacts, sourceNames) {
  const selection = Object.fromEntries(sourceNames.map((source) => [source, { "": ["ast"] }]));
  const contractOutputs = [
    "abi",
    "metadata",
    "evm.bytecode.object",
    "evm.bytecode.linkReferences",
    "evm.deployedBytecode.object",
    "evm.deployedBytecode.linkReferences",
    "evm.deployedBytecode.immutableReferences",
  ];
  for (const artifact of artifacts) {
    const [source, contract] = splitArtifact(artifact);
    selection[source][contract] = contractOutputs;
  }
  return selection;
}

function validateBuildInput(buildInfo, expectedSourceCount, profile) {
  if (buildInfo.solcVersion !== "0.8.24") fail(`${profile} build-info solcVersion must be 0.8.24`);
  if (
    buildInfo.solcLongVersion !== undefined &&
    buildInfo.solcLongVersion !== "0.8.24" &&
    !String(buildInfo.solcLongVersion).startsWith(EXPECTED_SOLC_VERSION)
  ) {
    fail(`${profile} build-info solcLongVersion must bind ${EXPECTED_SOLC_VERSION}`);
  }
  const input = buildInfo.input;
  if (!input || input.language !== "Solidity" || !input.sources || !input.settings) {
    fail(`${profile} build-info input is incomplete`);
  }
  const sourceNames = Object.keys(input.sources);
  if (sourceNames.length !== expectedSourceCount) {
    fail(`${profile} build-info must retain exactly ${expectedSourceCount} sources`);
  }
  if (sourceNames.some((source) => typeof input.sources[source]?.content !== "string")) {
    fail(`every ${profile} build-info source must retain literal content`);
  }
  const { settings } = input;
  if (
    settings.viaIR !== true ||
    settings.evmVersion !== "cancun" ||
    settings.optimizer?.enabled !== true ||
    settings.optimizer?.runs !== 200 ||
    settings.metadata?.bytecodeHash !== "ipfs" ||
    settings.metadata?.appendCBOR !== true ||
    settings.metadata?.useLiteralContent !== false
  ) {
    fail(`${profile} build-info compiler settings do not match the approved viaIR deployment profile`);
  }
  return { input, sourceNames };
}

export function compileExactTargets(buildInfo, artifacts, solcPath, expectedSourceCount, profile) {
  const { input, sourceNames } = validateBuildInput(buildInfo, expectedSourceCount, profile);
  const standardInput = {
    language: input.language,
    sources: input.sources,
    settings: {
      ...input.settings,
      outputSelection: targetOutputSelection(artifacts, sourceNames),
    },
  };
  const serializedInput = JSON.stringify(standardInput);
  const result = spawnSync(solcPath, ["--standard-json"], {
    input: serializedInput,
    encoding: "utf8",
    maxBuffer: 1024 * 1024 * 1024,
  });
  if (result.status !== 0) fail(`solc compilation failed: ${(result.stderr || "").trim()}`);
  const firstBrace = result.stdout.indexOf("{");
  if (firstBrace === -1) fail("solc did not return Standard JSON output");
  let output;
  try {
    output = JSON.parse(result.stdout.slice(firstBrace));
  } catch (error) {
    fail(`solc returned invalid JSON: ${error.message}`);
  }
  const errors = (output.errors ?? []).filter((entry) => entry.severity === "error");
  if (errors.length > 0) fail(`solc returned ${errors.length} compilation error(s)`);
  return {
    output,
    standardInput,
    standardInputSha256: sha256(serializedInput),
    compilerOutputSha256: sha256(stableJson(output)),
  };
}

function configuredLibraryCount(buildInfo) {
  const configured = buildInfo.input.settings.libraries;
  if (!configured || typeof configured !== "object" || Array.isArray(configured)) return null;
  return Object.values(configured).flatMap((contracts) => Object.keys(contracts ?? {})).length;
}

function validateInventory(inventory, coreBuildInfo, libraryBuildInfo) {
  if (!Array.isArray(inventory) || inventory.length !== EXPECTED_ADDRESS_COUNT) {
    fail(`inventory must contain exactly ${EXPECTED_ADDRESS_COUNT} addresses`);
  }
  const addresses = new Set();
  const coreArtifacts = new Set();
  const libraryArtifacts = new Set();
  const originCounts = Object.fromEntries(Object.keys(EXPECTED_ORIGIN_COUNTS).map((origin) => [origin, 0]));
  for (const [index, item] of inventory.entries()) {
    if (!item || typeof item !== "object") fail(`inventory[${index}] must be an object`);
    const address = normalizeAddress(item.address, `inventory[${index}].address`);
    if (addresses.has(address)) fail(`duplicate inventory address: ${address}`);
    addresses.add(address);
    const [source, contract] = splitArtifact(item.artifact);
    const libraryArtifact = source.includes("/libraries/");
    const expectedBuildInfo = libraryArtifact ? libraryBuildInfo : coreBuildInfo;
    const expectedOrigin = libraryArtifact ? "libraryBroadcast" : null;
    if (!expectedBuildInfo.input.sources[source] || !expectedBuildInfo.output?.contracts?.[source]?.[contract]) {
      fail(`artifact is absent from exact ${libraryArtifact ? "library" : "core"} build-info: ${item.artifact}`);
    }
    if ((expectedOrigin && item.origin !== expectedOrigin) || (!expectedOrigin && item.origin === "libraryBroadcast")) {
      fail(`artifact build profile does not match creation origin at ${address}`);
    }
    (libraryArtifact ? libraryArtifacts : coreArtifacts).add(item.artifact);
    bytes32(item.transactionHash, `inventory[${index}].transactionHash`);
    const creationCode = normalizeHex(item.creationCode, `inventory[${index}].creationCode`);
    const initCode = normalizeHex(item.initCode, `inventory[${index}].initCode`);
    const constructorArgs = normalizeHex(item.constructorArgs, `inventory[${index}].constructorArgs`);
    const creationCodeHash = bytes32(item.creationCodeHash, `inventory[${index}].creationCodeHash`);
    const initCodeHash = bytes32(item.initCodeHash, `inventory[${index}].initCodeHash`);
    const constructorArgsHash = bytes32(item.constructorArgsHash, `inventory[${index}].constructorArgsHash`);
    if (keccak256Hex(item.constructorArgs) !== constructorArgsHash) {
      fail(`constructor args hash mismatch at ${address}`);
    }
    if (keccak256Hex(item.creationCode) !== creationCodeHash) {
      fail(`creation code hash mismatch at ${address}`);
    }
    if (keccak256Hex(item.initCode) !== initCodeHash) {
      fail(`init code hash mismatch at ${address}`);
    }
    if (initCode !== `${creationCode}${constructorArgs}`) {
      fail(`init code does not equal creation code plus constructor args at ${address}`);
    }
    bytes32(item.runtimeCodehash, `inventory[${index}].runtimeCodehash`);
    if (!TOP_LEVEL_ORIGINS.has(item.origin) && !INTERNAL_ORIGINS.has(item.origin)) {
      fail(`unsupported creation origin at ${address}: ${item.origin}`);
    }
    originCounts[item.origin] += 1;
    if (item.creationKind !== "CREATE" && item.creationKind !== "CREATE2") {
      fail(`unsupported creation kind at ${address}: ${item.creationKind}`);
    }
  }
  const artifacts = new Set([...coreArtifacts, ...libraryArtifacts]);
  if (artifacts.size !== EXPECTED_ARTIFACT_COUNT) {
    fail(`inventory must contain exactly ${EXPECTED_ARTIFACT_COUNT} unique artifacts`);
  }
  for (const [origin, expected] of Object.entries(EXPECTED_ORIGIN_COUNTS)) {
    if (originCounts[origin] !== expected) {
      fail(`inventory origin ${origin} must contain exactly ${expected} deployments`);
    }
  }
  const libraries = [...libraryArtifacts].sort();
  if (libraries.length !== EXPECTED_LIBRARY_ARTIFACT_COUNT) {
    fail(`inventory must contain exactly ${EXPECTED_LIBRARY_ARTIFACT_COUNT} library artifacts`);
  }
  if (coreArtifacts.size !== EXPECTED_PRIMARY_ARTIFACT_COUNT) {
    fail(`inventory must contain exactly ${EXPECTED_PRIMARY_ARTIFACT_COUNT} primary artifacts`);
  }
  const configuredLibraries = coreBuildInfo.input.settings.libraries;
  if (configuredLibraryCount(coreBuildInfo) !== libraries.length) {
    fail("core build-info must contain the exact five-library link map");
  }
  if (configuredLibraryCount(libraryBuildInfo) !== 0) {
    fail("library build-info must contain an empty library link map");
  }
  for (const artifact of libraries) {
    const [source, contract] = splitArtifact(artifact);
    const item = inventory.find((candidate) => candidate.artifact === artifact);
    const configured = configuredLibraries[source]?.[contract];
    if (!configured || normalizeAddress(configured, `settings.libraries.${artifact}`) !== item.address.toLowerCase()) {
      fail(`core linked library address mismatch for ${artifact}`);
    }
  }
  return {
    artifacts: [...artifacts].sort(),
    coreArtifacts: [...coreArtifacts].sort(),
    libraryArtifacts: libraries,
  };
}

function exactArtifact(output, buildInfo, artifact) {
  const [source, contract] = splitArtifact(artifact);
  const compiled = output.contracts?.[source]?.[contract];
  const original = buildInfo.output?.contracts?.[source]?.[contract];
  if (!compiled || !original) fail(`missing compiled artifact: ${artifact}`);
  const comparisons = [
    [compiled.evm?.bytecode?.object, original.evm?.bytecode?.object, "creation bytecode"],
    [compiled.evm?.deployedBytecode?.object, original.evm?.deployedBytecode?.object, "runtime template"],
    [compiled.metadata, original.metadata, "metadata"],
  ];
  for (const [actual, expected, label] of comparisons) {
    const matches = label === "metadata" ? actual === expected : normalizeHex(actual, label) === normalizeHex(expected, label);
    if (!matches) fail(`${label} changed under target-only outputSelection for ${artifact}`);
  }
  return compiled;
}

function findAstNodeById(value, id) {
  if (!value || typeof value !== "object") return null;
  if (value.id === id) return value;
  for (const child of Object.values(value)) {
    const found = findAstNodeById(child, id);
    if (found) return found;
  }
  return null;
}

function immutableAstNode(output, referenceId) {
  for (const source of Object.values(output.sources ?? {})) {
    const found = findAstNodeById(source.ast, Number(referenceId));
    if (found) return found;
  }
  return null;
}

function normalizedIdentifier(value) {
  return value.replaceAll("_", "").toLowerCase();
}

function constructorWord(compiled, constructorArgs, immutableName) {
  const constructor = compiled.abi.find((entry) => entry.type === "constructor");
  if (!constructor) return null;
  const name = normalizedIdentifier(immutableName);
  const index = constructor.inputs.findIndex((input) => normalizedIdentifier(input.name) === name);
  if (index === -1) return null;
  const type = constructor.inputs[index].type;
  if (!/^(address|bool|bytes([1-9]|[12][0-9]|3[0-2])|u?int([0-9]+)?)$/.test(type)) {
    fail(`immutable ${immutableName} uses unsupported constructor type ${type}`);
  }
  const args = normalizeHex(constructorArgs, "constructor args");
  const word = args.slice(index * 64, (index + 1) * 64);
  if (word.length !== 64) fail(`constructor args do not contain immutable ${immutableName}`);
  return word;
}

function inventoryAddress(inventory, predicate, label) {
  const matches = inventory.filter((item) => predicate(item.artifact));
  if (matches.length !== 1) fail(`inventory must identify exactly one ${label}`);
  return matches[0].address.toLowerCase().slice(2).padStart(64, "0");
}

function immutableWord({ referenceId, output, compiled, item, inventory }) {
  if (referenceId === "library_deploy_address") return item.address.toLowerCase().slice(2).padStart(64, "0");
  const node = immutableAstNode(output, referenceId);
  if (!node?.name) fail(`cannot resolve immutable AST id ${referenceId} for ${item.artifact}`);
  const constructorValue = constructorWord(compiled, item.constructorArgs, node.name);
  if (constructorValue) return constructorValue;
  if (node.name === "__self") return item.address.toLowerCase().slice(2).padStart(64, "0");
  if (node.name === "accessManagerDeployer") {
    return inventoryAddress(inventory, (artifact) => artifact.endsWith("FundAccessManagerDeployer.sol:FundAccessManagerDeployer"), "access manager deployer");
  }
  if (node.name === "FUND_FACTORY") {
    return inventoryAddress(inventory, (artifact) => artifact.endsWith("B1N419ZeroDelayMetaWheelFundFactory.sol:B1N419ZeroDelayMetaWheelFundFactory"), "Fund factory");
  }
  if (node.name === "usdcDecimals") return 6n.toString(16).padStart(64, "0");
  fail(`immutable ${node.name} has no approved B1N-419 derivation`);
}

function patchRuntime({ template, actual, output, compiled, item, inventory }) {
  let expected = normalizeHex(template, `${item.artifact} runtime template`);
  const observed = normalizeHex(actual, `${item.address} RPC runtime`);
  if (expected.length !== observed.length) fail(`runtime length mismatch at ${item.address}`);
  const references = compiled.evm?.deployedBytecode?.immutableReferences ?? {};
  for (const [referenceId, locations] of Object.entries(references)) {
    const word = immutableWord({ referenceId, output, compiled, item, inventory });
    for (const location of locations) {
      if (!Number.isInteger(location.start) || location.length !== 32) {
        fail(`unsupported immutable location for ${item.artifact}`);
      }
      const begin = location.start * 2;
      const end = begin + location.length * 2;
      if (observed.slice(begin, end) !== word) fail(`immutable ${referenceId} mismatch at ${item.address}`);
      expected = `${expected.slice(0, begin)}${word}${expected.slice(end)}`;
    }
  }
  if (expected !== observed) fail(`exact runtime bytecode mismatch at ${item.address}`);
  return `0x${expected}`;
}

async function rpcBatch(url, calls) {
  const results = new Map();
  for (let offset = 0; offset < calls.length; offset += 20) {
    let pending = calls.slice(offset, offset + 20);
    for (let attempt = 0; attempt < 5 && pending.length > 0; attempt += 1) {
      const response = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(pending.map((call) => ({ jsonrpc: "2.0", ...call }))),
      });
      if (!response.ok) fail(`RPC HTTP ${response.status}`);
      const body = await response.json();
      const entries = Array.isArray(body) ? body : [body];
      const retryIds = new Set();
      for (const entry of entries) {
        if (entry.error) retryIds.add(entry.id);
        else results.set(entry.id, entry.result);
      }
      pending = pending.filter((call) => retryIds.has(call.id));
      if (pending.length > 0) await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** attempt));
    }
    if (pending.length > 0) fail(`RPC failed for ${pending.length} request(s)`);
  }
  if (results.size !== calls.length) fail("RPC batch response is incomplete");
  return results;
}

async function readRpcState(rpcUrl, inventory, confirmationBlock) {
  const chain = await rpcBatch(rpcUrl, [{ id: "chain", method: "eth_chainId", params: [] }]);
  if (Number.parseInt(chain.get("chain"), 16) !== EXPECTED_CHAIN_ID) fail("RPC is not Base Sepolia");
  const blockTag = `0x${confirmationBlock.toString(16)}`;
  const codeCalls = inventory.map((item, index) => ({
    id: `code-${index}`,
    method: "eth_getCode",
    params: [item.address, blockTag],
  }));
  const code = await rpcBatch(rpcUrl, codeCalls);
  const topLevel = inventory
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => TOP_LEVEL_ORIGINS.has(item.origin));
  const transactionCalls = topLevel.map(({ item, index }) => ({
    id: `tx-${index}`,
    method: "eth_getTransactionByHash",
    params: [item.transactionHash],
  }));
  const transactions = await rpcBatch(rpcUrl, transactionCalls);
  return { code, transactions };
}

function validateOptions(options) {
  const sourceCommit = String(options.sourceCommit ?? "");
  if (!/^[0-9a-fA-F]{40}$/.test(sourceCommit)) fail("sourceCommit must be a full git commit");
  const deploymentId = bytes32(options.deploymentId, "deploymentId");
  const unconfirmedManifestSha256 = bytes32(
    options.unconfirmedManifestSha256,
    "unconfirmedManifestSha256",
  );
  const confirmationBlock = Number(options.confirmationBlock);
  if (!Number.isSafeInteger(confirmationBlock) || confirmationBlock <= 0) fail("confirmationBlock must be positive");
  if (
    !options.coreBuildInfoPath ||
    !options.libraryBuildInfoPath ||
    !options.inventoryPath ||
    !options.rpcUrl ||
    !options.solcPath
  ) {
    fail("core build-info, library build-info, inventory, RPC URL, and solc path are required");
  }
  return {
    sourceCommit: sourceCommit.toLowerCase(),
    deploymentId,
    unconfirmedManifestSha256,
    confirmationBlock,
  };
}

export async function buildEvidence(options, dependencies = {}) {
  const { sourceCommit, deploymentId, unconfirmedManifestSha256, confirmationBlock } = validateOptions(options);
  const coreBuildInfoBytes = fs.readFileSync(options.coreBuildInfoPath);
  const libraryBuildInfoBytes = fs.readFileSync(options.libraryBuildInfoPath);
  const inventoryBytes = fs.readFileSync(options.inventoryPath);
  const coreBuildInfo = JSON.parse(coreBuildInfoBytes);
  const libraryBuildInfo = JSON.parse(libraryBuildInfoBytes);
  const inventory = JSON.parse(inventoryBytes);
  validateBuildInput(coreBuildInfo, EXPECTED_CORE_SOURCE_COUNT, "core");
  validateBuildInput(libraryBuildInfo, EXPECTED_LIBRARY_SOURCE_COUNT, "library");
  const { artifacts, coreArtifacts, libraryArtifacts } = validateInventory(
    inventory,
    coreBuildInfo,
    libraryBuildInfo,
  );
  const solcVersion = (dependencies.compilerVersion ?? compilerVersion)(options.solcPath);
  const compileTargets = dependencies.compileExactTargets ?? compileExactTargets;
  const compiledCore = compileTargets(
    coreBuildInfo,
    coreArtifacts,
    options.solcPath,
    EXPECTED_CORE_SOURCE_COUNT,
    "core",
  );
  const compiledLibraries = compileTargets(
    libraryBuildInfo,
    libraryArtifacts,
    options.solcPath,
    EXPECTED_LIBRARY_SOURCE_COUNT,
    "library",
  );
  const compiledByArtifact = new Map(
    [
      ...coreArtifacts.map((artifact) => [
        artifact,
        { compiled: exactArtifact(compiledCore.output, coreBuildInfo, artifact), output: compiledCore.output },
      ]),
      ...libraryArtifacts.map((artifact) => [
        artifact,
        {
          compiled: exactArtifact(compiledLibraries.output, libraryBuildInfo, artifact),
          output: compiledLibraries.output,
        },
      ]),
    ],
  );
  const rpcState = dependencies.rpcState
    ? await dependencies.rpcState(inventory, confirmationBlock)
    : await readRpcState(options.rpcUrl, inventory, confirmationBlock);

  const records = [];
  let topLevelMatches = 0;
  let internalTraceDerived = 0;
  for (const [index, rawItem] of inventory.entries()) {
    const item = { ...rawItem, address: rawItem.address.toLowerCase() };
    const compiledBundle = compiledByArtifact.get(item.artifact);
    const compiledArtifact = compiledBundle.compiled;
    const compiledCreationCode = `0x${normalizeHex(compiledArtifact.evm.bytecode.object, "creation bytecode")}`;
    if (normalizeHex(compiledCreationCode, "compiled creation code") !== normalizeHex(item.creationCode, "inventory creation code")) {
      fail(`exact source creation code mismatch at ${item.address}`);
    }
    const creationBytecode = `${compiledCreationCode}${normalizeHex(item.constructorArgs, "constructor args")}`;
    if (normalizeHex(creationBytecode, "compiled init code") !== normalizeHex(item.initCode, "inventory init code")) {
      fail(`exact trace-derived init code mismatch at ${item.address}`);
    }
    const actualRuntime = rpcState.code.get(`code-${index}`);
    if (typeof actualRuntime !== "string" || actualRuntime === "0x") fail(`no runtime code at ${item.address}`);
    const patchedRuntime = patchRuntime({
      template: compiledArtifact.evm.deployedBytecode.object,
      actual: actualRuntime,
      output: compiledBundle.output,
      compiled: compiledArtifact,
      item,
      inventory,
    });
    const runtimeCodehash = keccak256Hex(patchedRuntime);
    if (runtimeCodehash !== item.runtimeCodehash.toLowerCase()) fail(`inventory runtime codehash mismatch at ${item.address}`);

    let creationEvidence;
    if (TOP_LEVEL_ORIGINS.has(item.origin)) {
      const transaction = rpcState.transactions.get(`tx-${index}`);
      if (!transaction || transaction.to !== null) fail(`expected top-level creation transaction at ${item.address}`);
      if (normalizeHex(transaction.input, "transaction input") !== normalizeHex(creationBytecode, "creation bytecode")) {
        fail(`exact top-level creation bytecode mismatch at ${item.address}`);
      }
      creationEvidence = "TOP_LEVEL_TRANSACTION_INPUT_EXACT";
      topLevelMatches += 1;
    } else {
      creationEvidence = "TRACE_DERIVED_CONSTRUCTOR_ARGS_RECOMPILED";
      internalTraceDerived += 1;
    }
    records.push({
      address: item.address,
      artifact: item.artifact,
      transactionHash: item.transactionHash.toLowerCase(),
      creationKind: item.creationKind,
      creationEvidence,
      constructorArgsHash: item.constructorArgsHash.toLowerCase(),
      creationBytecodeHash: keccak256Hex(creationBytecode),
      runtimeCodehash,
      sourceCreationBytecodeMatch: true,
      sourceRuntimeBytecodeMatch: true,
      rpcRuntimeBytecodeMatch: true,
    });
  }
  records.sort((left, right) => left.address.localeCompare(right.address));

  const coreBuildInfoSha256 = sha256(coreBuildInfoBytes);
  const libraryBuildInfoSha256 = sha256(libraryBuildInfoBytes);
  const coreSettingsSha256 = sha256(stableJson(coreBuildInfo.input.settings));
  const librarySettingsSha256 = sha256(stableJson(libraryBuildInfo.input.settings));
  const inventorySha256 = sha256(inventoryBytes);
  return {
    schemaVersion: "1.0.0",
    issue: "B1N-419",
    method: VERIFICATION_METHOD,
    exactSourceRuntimeBytecodeVerified: true,
    sourceCommit,
    deploymentId,
    unconfirmedManifestSha256,
    coreBuildInfoSha256,
    libraryBuildInfoSha256,
    coreStandardJsonInputSha256: compiledCore.standardInputSha256,
    libraryStandardJsonInputSha256: compiledLibraries.standardInputSha256,
    coreCompilerOutputSha256: compiledCore.compilerOutputSha256,
    libraryCompilerOutputSha256: compiledLibraries.compilerOutputSha256,
    coreSettingsSha256,
    librarySettingsSha256,
    inventorySha256,
    addressCount: inventory.length,
    artifactCount: artifacts.length,
    network: {
      name: "base-sepolia",
      chainId: EXPECTED_CHAIN_ID,
      confirmationBlock,
    },
    compiler: {
      version: solcVersion,
      coreBuildInfoSha256,
      libraryBuildInfoSha256,
      coreStandardJsonInputSha256: compiledCore.standardInputSha256,
      libraryStandardJsonInputSha256: compiledLibraries.standardInputSha256,
      coreCompilerOutputSha256: compiledCore.compilerOutputSha256,
      libraryCompilerOutputSha256: compiledLibraries.compilerOutputSha256,
      coreSettingsSha256,
      librarySettingsSha256,
      coreSourceCount: Object.keys(coreBuildInfo.input.sources).length,
      librarySourceCount: Object.keys(libraryBuildInfo.input.sources).length,
      coreTargetArtifactCount: coreArtifacts.length,
      libraryTargetArtifactCount: libraryArtifacts.length,
      targetArtifactCount: artifacts.length,
      fullSourceSetsRetained: true,
      targetOnlyOutputSelection: true,
    },
    inventory: {
      sha256: inventorySha256,
      addressCount: inventory.length,
      artifactCount: artifacts.length,
      primaryArtifactCount: artifacts.filter((artifact) => !splitArtifact(artifact)[0].includes("/libraries/")).length,
      libraryArtifactCount: artifacts.filter((artifact) => splitArtifact(artifact)[0].includes("/libraries/")).length,
    },
    summary: {
      creationVerified: records.length,
      compiledRuntimeVerified: records.length,
      rpcRuntimeVerified: records.length,
      exactCompiledArtifactMatches: artifacts.length,
      exactRpcRuntimeMatches: records.length,
      exactTopLevelCreationMatches: topLevelMatches,
      traceDerivedInternalCreationsRecompiled: internalTraceDerived,
    },
    records,
  };
}

function optionValue(args, name, environment, environmentName) {
  const index = args.indexOf(name);
  if (index !== -1) {
    if (!args[index + 1]) fail(`${name} requires a value`);
    return args[index + 1];
  }
  return environment[environmentName];
}

function usage() {
  return `Usage:
  node script/fund/verify-meta-wheel-source-runtime.mjs --output PATH [options]
  node script/fund/verify-meta-wheel-source-runtime.mjs --check PATH [options]

Required options (or environment variables):
  --core-build-info PATH     B1N419_CORE_BUILD_INFO_PATH
  --library-build-info PATH  B1N419_LIBRARY_BUILD_INFO_PATH
  --inventory PATH           B1N419_VERIFICATION_INVENTORY_PATH
  --rpc-url URL              BASE_SEPOLIA_RPC_URL
  --confirmation-block N     B1N419_SOURCE_RUNTIME_CONFIRMATION_BLOCK
  --source-commit COMMIT      B1N419_SOURCE_COMMIT
  --deployment-id BYTES32     B1N419_DEPLOYMENT_ID
  --unconfirmed-manifest-sha256 BYTES32
                               B1N419_UNCONFIRMED_MANIFEST_SHA256
  --solc PATH                 B1N419_SOLC_PATH (default: solc)
  --output PATH               write deterministic evidence
  --check PATH                reproduce and compare existing evidence
`;
}

async function main(args = process.argv.slice(2), environment = process.env) {
  if (args.includes("--help")) {
    process.stdout.write(usage());
    return;
  }
  const outputPath = optionValue(args, "--output", environment, "B1N419_SOURCE_RUNTIME_EVIDENCE_OUTPUT");
  const checkPath = optionValue(args, "--check", environment, "B1N419_SOURCE_RUNTIME_EVIDENCE_PATH");
  if ((!outputPath && !checkPath) || (outputPath && checkPath)) fail("choose exactly one of --output or --check");
  const evidence = await buildEvidence({
    coreBuildInfoPath: optionValue(args, "--core-build-info", environment, "B1N419_CORE_BUILD_INFO_PATH"),
    libraryBuildInfoPath: optionValue(
      args,
      "--library-build-info",
      environment,
      "B1N419_LIBRARY_BUILD_INFO_PATH",
    ),
    inventoryPath: optionValue(args, "--inventory", environment, "B1N419_VERIFICATION_INVENTORY_PATH"),
    rpcUrl: optionValue(args, "--rpc-url", environment, "BASE_SEPOLIA_RPC_URL"),
    confirmationBlock: optionValue(
      args,
      "--confirmation-block",
      environment,
      "B1N419_SOURCE_RUNTIME_CONFIRMATION_BLOCK",
    ),
    sourceCommit: optionValue(args, "--source-commit", environment, "B1N419_SOURCE_COMMIT"),
    deploymentId: optionValue(args, "--deployment-id", environment, "B1N419_DEPLOYMENT_ID"),
    unconfirmedManifestSha256: optionValue(
      args,
      "--unconfirmed-manifest-sha256",
      environment,
      "B1N419_UNCONFIRMED_MANIFEST_SHA256",
    ),
    solcPath: optionValue(args, "--solc", environment, "B1N419_SOLC_PATH") ?? "solc",
  });
  if (checkPath) {
    const expected = parseJson(checkPath, "source/runtime evidence");
    if (stableJson(expected) !== stableJson(evidence)) fail("source/runtime evidence does not reproduce exactly");
    process.stdout.write(`B1N-419 exact source/runtime evidence reproduced: ${checkPath}\n`);
    return;
  }
  if (fs.existsSync(outputPath)) fail(`output already exists: ${outputPath}`);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, { flag: "wx" });
  process.stdout.write(`B1N-419 exact source/runtime evidence written: ${outputPath}\n`);
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntrypoint) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
