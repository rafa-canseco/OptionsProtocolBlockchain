#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { buildEvidence, keccak256Hex } from "./verify-meta-wheel-source-runtime.mjs";

const CORE_SOURCE_COUNT = 316;
const LIBRARY_SOURCE_COUNT = 170;
const PRIMARY_ARTIFACT_COUNT = 20;
const LIBRARY_ARTIFACT_COUNT = 5;
const ADDRESS_COUNT = 47;

function address(index) {
  return `0x${index.toString(16).padStart(40, "0")}`;
}

function bytes32(index) {
  return `0x${index.toString(16).padStart(64, "0")}`;
}

function artifactDefinition(index, library) {
  const contract = library ? `FixtureLibrary${index}` : `FixtureContract${index}`;
  const source = library
    ? `src/fund/libraries/${contract}.sol`
    : `src/fund/${contract}.sol`;
  return { artifact: `${source}:${contract}`, contract, source, library };
}

function contractOutput({ index, immutableKind }) {
  let runtime = "6000";
  let immutableReferences = {};
  let abi = [{ type: "constructor", inputs: [], stateMutability: "nonpayable" }];
  if (immutableKind === "self") {
    runtime = "00".repeat(32);
    immutableReferences = { 1: [{ start: 0, length: 32 }] };
  } else if (immutableKind === "owner") {
    runtime = "00".repeat(32);
    immutableReferences = { 2: [{ start: 0, length: 32 }] };
    abi = [
      {
        type: "constructor",
        inputs: [{ name: "owner_", type: "address", internalType: "address" }],
        stateMutability: "nonpayable",
      },
    ];
  } else if (immutableKind === "library") {
    runtime = "00".repeat(32);
    immutableReferences = { library_deploy_address: [{ start: 0, length: 32 }] };
  }
  return {
    abi,
    metadata: JSON.stringify({ compiler: { version: "0.8.24" }, fixture: index }),
    evm: {
      bytecode: { object: `60${index.toString(16).padStart(2, "0")}6000`, linkReferences: {} },
      deployedBytecode: { object: runtime, linkReferences: {}, immutableReferences },
    },
  };
}

function fixture() {
  const definitions = [
    ...Array.from({ length: PRIMARY_ARTIFACT_COUNT }, (_, index) => artifactDefinition(index, false)),
    ...Array.from({ length: LIBRARY_ARTIFACT_COUNT }, (_, index) => artifactDefinition(index, true)),
  ];
  const coreDefinitions = definitions.filter((definition) => !definition.library);
  const libraryDefinitions = definitions.filter((definition) => definition.library);
  const coreSources = {};
  for (const definition of definitions) {
    coreSources[definition.source] = { content: "// SPDX-License-Identifier: MIT\npragma solidity 0.8.24;\n" };
  }
  for (let index = definitions.length; index < CORE_SOURCE_COUNT; index += 1) {
    coreSources[`test/fixtures/CoreSource${index}.sol`] = {
      content: "// SPDX-License-Identifier: MIT\npragma solidity 0.8.24;\n",
    };
  }
  const librarySources = Object.fromEntries(
    libraryDefinitions.map((definition) => [
      definition.source,
      { content: "// SPDX-License-Identifier: MIT\npragma solidity 0.8.24;\n" },
    ]),
  );
  for (let index = libraryDefinitions.length; index < LIBRARY_SOURCE_COUNT; index += 1) {
    librarySources[`test/fixtures/LibrarySource${index}.sol`] = {
      content: "// SPDX-License-Identifier: MIT\npragma solidity 0.8.24;\n",
    };
  }
  const coreContracts = {};
  for (const [index, definition] of coreDefinitions.entries()) {
    const immutableKind = index === 0 ? "self" : index === 1 ? "owner" : null;
    coreContracts[definition.source] = {
      [definition.contract]: contractOutput({ index, immutableKind }),
    };
  }
  const libraryContracts = {};
  for (const [index, definition] of libraryDefinitions.entries()) {
    libraryContracts[definition.source] = {
      [definition.contract]: contractOutput({ index: PRIMARY_ARTIFACT_COUNT + index, immutableKind: "library" }),
    };
  }
  const coreOutputSources = Object.fromEntries(
    Object.keys(coreSources).map((source) => [
      source,
      {
        ast: {
          nodeType: "SourceUnit",
          nodes:
            source === definitions[0].source
              ? [{ id: 1, nodeType: "VariableDeclaration", name: "__self" }]
              : source === definitions[1].source
                ? [{ id: 2, nodeType: "VariableDeclaration", name: "OWNER" }]
                : [],
        },
      },
    ]),
  );
  const libraryOutputSources = Object.fromEntries(
    Object.keys(librarySources).map((source) => [
      source,
      { ast: { nodeType: "SourceUnit", nodes: [] } },
    ]),
  );
  const libraries = Object.fromEntries(
    libraryDefinitions.map((definition, index) => [
      definition.source,
      { [definition.contract]: address(1_000 + index) },
    ]),
  );
  const settings = (linkedLibraries) => ({
    evmVersion: "cancun",
    viaIR: true,
    optimizer: { enabled: true, runs: 200 },
    metadata: { appendCBOR: true, bytecodeHash: "ipfs", useLiteralContent: false },
    libraries: linkedLibraries,
    outputSelection: { "*": { "*": ["abi", "metadata", "evm.bytecode.object"] } },
  });
  const coreBuildInfo = {
    solcVersion: "0.8.24",
    solcLongVersion: "0.8.24",
    input: {
      language: "Solidity",
      sources: coreSources,
      settings: settings(libraries),
    },
    output: { contracts: coreContracts, sources: coreOutputSources },
  };
  const libraryBuildInfo = {
    solcVersion: "0.8.24",
    solcLongVersion: "0.8.24",
    input: {
      language: "Solidity",
      sources: librarySources,
      settings: settings({}),
    },
    output: { contracts: libraryContracts, sources: libraryOutputSources },
  };

  const items = definitions.map((definition, index) => ({ definition, duplicateIndex: 0, index }));
  for (let index = 0; items.length < ADDRESS_COUNT; index += 1) {
    items.push({ definition: definitions[2], duplicateIndex: index + 1, index: items.length });
  }
  const owner = address(9_999);
  let primaryCursor = 0;
  const inventory = items.map(({ definition, index }) => {
    const isLibrary = definition.library;
    const origin = isLibrary
      ? "libraryBroadcast"
      : primaryCursor < 34
        ? "coreBroadcast"
        : primaryCursor < 41
          ? "createFundTrace"
          : "factoryConstructorTrace";
    if (!isLibrary) primaryCursor += 1;
    const deployedAddress = isLibrary
      ? libraries[definition.source][definition.contract]
      : address(2_000 + index);
    const constructorArgs = definition === definitions[1] ? `0x${owner.slice(2).padStart(64, "0")}` : "0x";
    const compiled = (isLibrary ? libraryContracts : coreContracts)[definition.source][definition.contract];
    let runtime = compiled.evm.deployedBytecode.object;
    if (definition === definitions[0]) runtime = deployedAddress.slice(2).padStart(64, "0");
    if (definition === definitions[1]) runtime = owner.slice(2).padStart(64, "0");
    if (isLibrary) runtime = deployedAddress.slice(2).padStart(64, "0");
    const creationCode = `0x${compiled.evm.bytecode.object}`;
    const initCode = `${creationCode}${constructorArgs.slice(2)}`;
    return {
      address: deployedAddress,
      artifact: definition.artifact,
      transactionHash: bytes32(3_000 + index),
      creationCode,
      creationCodeHash: keccak256Hex(creationCode),
      initCode,
      initCodeHash: keccak256Hex(initCode),
      constructorArgs,
      constructorArgsHash: keccak256Hex(constructorArgs),
      runtimeCodehash: keccak256Hex(`0x${runtime}`),
      expectedRuntimeCodehash: keccak256Hex(`0x${runtime}`),
      creationKind: index % 2 === 0 ? "CREATE" : "CREATE2",
      origin,
    };
  });
  inventory.sort((left, right) => left.address.localeCompare(right.address));

  const coreCompileResult = {
    output: structuredClone({ contracts: coreContracts, sources: coreOutputSources, errors: [] }),
    standardInput: coreBuildInfo.input,
    standardInputSha256: bytes32(7_001),
    compilerOutputSha256: bytes32(7_002),
  };
  const libraryCompileResult = {
    output: structuredClone({ contracts: libraryContracts, sources: libraryOutputSources, errors: [] }),
    standardInput: libraryBuildInfo.input,
    standardInputSha256: bytes32(7_003),
    compilerOutputSha256: bytes32(7_004),
  };
  const rpcState = {
    code: new Map(),
    transactions: new Map(),
  };
  for (const [index, item] of inventory.entries()) {
    const definition = definitions.find((candidate) => candidate.artifact === item.artifact);
    const compiled = (definition.library ? libraryContracts : coreContracts)[definition.source][definition.contract];
    let runtime = compiled.evm.deployedBytecode.object;
    if (definition === definitions[0]) runtime = item.address.slice(2).padStart(64, "0");
    if (definition === definitions[1]) runtime = owner.slice(2).padStart(64, "0");
    if (definition.library) runtime = item.address.slice(2).padStart(64, "0");
    rpcState.code.set(`code-${index}`, `0x${runtime}`);
    if (item.origin === "coreBroadcast" || item.origin === "libraryBroadcast") {
      rpcState.transactions.set(`tx-${index}`, {
        to: null,
        input: `0x${compiled.evm.bytecode.object}${item.constructorArgs.slice(2)}`,
      });
    }
  }
  return {
    coreBuildInfo,
    libraryBuildInfo,
    coreCompileResult,
    libraryCompileResult,
    inventory,
    rpcState,
  };
}

async function evidenceFor(directory, value, overrides = {}) {
  const coreBuildInfoPath = path.join(directory, "core-build-info.json");
  const libraryBuildInfoPath = path.join(directory, "library-build-info.json");
  const inventoryPath = path.join(directory, "inventory.json");
  fs.writeFileSync(coreBuildInfoPath, JSON.stringify(value.coreBuildInfo));
  fs.writeFileSync(libraryBuildInfoPath, JSON.stringify(value.libraryBuildInfo));
  fs.writeFileSync(inventoryPath, JSON.stringify(value.inventory));
  return buildEvidence(
    {
      coreBuildInfoPath,
      libraryBuildInfoPath,
      inventoryPath,
      rpcUrl: "https://fixture.invalid",
      confirmationBlock: 9_000,
      sourceCommit: "ab".repeat(20),
      deploymentId: bytes32(8_000),
      unconfirmedManifestSha256: bytes32(8_001),
      solcPath: "/fixture/solc",
    },
    {
      compilerVersion: () => "0.8.24+commit.e11b9ed9",
      compileExactTargets: (buildInfo, artifacts, _solcPath, expectedSourceCount, profile) => {
        if (expectedSourceCount === CORE_SOURCE_COUNT) {
          assert.equal(profile, "core");
          assert.equal(Object.keys(buildInfo.input.sources).length, CORE_SOURCE_COUNT);
          assert.equal(artifacts.length, PRIMARY_ARTIFACT_COUNT);
          assert.ok(artifacts.every((artifact) => !artifact.includes("/libraries/")));
          return value.coreCompileResult;
        }
        assert.equal(expectedSourceCount, LIBRARY_SOURCE_COUNT);
        assert.equal(profile, "library");
        assert.equal(Object.keys(buildInfo.input.sources).length, LIBRARY_SOURCE_COUNT);
        assert.equal(artifacts.length, LIBRARY_ARTIFACT_COUNT);
        assert.ok(artifacts.every((artifact) => artifact.includes("/libraries/")));
        return value.libraryCompileResult;
      },
      rpcState: async () => value.rpcState,
      ...overrides,
    },
  );
}

const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "b1n419-source-runtime-test-"));
try {
  assert.equal(
    keccak256Hex("0x"),
    "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
  );

  const valid = fixture();
  const evidence = await evidenceFor(temporaryDirectory, valid);
  assert.equal(evidence.method, "SOLC_STANDARD_JSON_RPC_EXACT_V2");
  assert.equal(evidence.exactSourceRuntimeBytecodeVerified, true);
  assert.match(evidence.coreBuildInfoSha256, /^0x[0-9a-f]{64}$/);
  assert.match(evidence.libraryBuildInfoSha256, /^0x[0-9a-f]{64}$/);
  assert.match(evidence.coreStandardJsonInputSha256, /^0x[0-9a-f]{64}$/);
  assert.match(evidence.libraryStandardJsonInputSha256, /^0x[0-9a-f]{64}$/);
  assert.match(evidence.coreCompilerOutputSha256, /^0x[0-9a-f]{64}$/);
  assert.match(evidence.libraryCompilerOutputSha256, /^0x[0-9a-f]{64}$/);
  assert.match(evidence.coreSettingsSha256, /^0x[0-9a-f]{64}$/);
  assert.match(evidence.librarySettingsSha256, /^0x[0-9a-f]{64}$/);
  assert.equal("buildInfoSha256" in evidence, false);
  assert.equal("standardJsonInputSha256" in evidence, false);
  assert.match(evidence.inventorySha256, /^0x[0-9a-f]{64}$/);
  assert.equal(evidence.network.confirmationBlock, 9_000);
  assert.equal(evidence.compiler.coreSourceCount, CORE_SOURCE_COUNT);
  assert.equal(evidence.compiler.librarySourceCount, LIBRARY_SOURCE_COUNT);
  assert.equal(evidence.compiler.coreTargetArtifactCount, PRIMARY_ARTIFACT_COUNT);
  assert.equal(evidence.compiler.libraryTargetArtifactCount, LIBRARY_ARTIFACT_COUNT);
  assert.equal(evidence.compiler.targetArtifactCount, 25);
  assert.equal(evidence.compiler.fullSourceSetsRetained, true);
  assert.equal(evidence.compiler.targetOnlyOutputSelection, true);
  assert.equal("buildInfoSha256" in evidence.compiler, false);
  assert.equal("standardJsonInputSha256" in evidence.compiler, false);
  assert.equal("sourceCount" in evidence.compiler, false);
  assert.equal(evidence.inventory.addressCount, ADDRESS_COUNT);
  assert.equal(evidence.inventory.artifactCount, 25);
  assert.equal(evidence.inventory.primaryArtifactCount, 20);
  assert.equal(evidence.inventory.libraryArtifactCount, 5);
  assert.equal(evidence.summary.exactCompiledArtifactMatches, 25);
  assert.equal(evidence.summary.creationVerified, 47);
  assert.equal(evidence.summary.compiledRuntimeVerified, 47);
  assert.equal(evidence.summary.rpcRuntimeVerified, 47);
  assert.equal(evidence.summary.exactRpcRuntimeMatches, 47);
  assert.equal(evidence.summary.exactTopLevelCreationMatches, 39);
  assert.equal(evidence.summary.traceDerivedInternalCreationsRecompiled, 8);
  assert.equal(evidence.records.length, 47);
  assert.ok(
    evidence.records.every(
      (record) =>
        record.sourceCreationBytecodeMatch === true &&
        record.sourceRuntimeBytecodeMatch === true &&
        record.rpcRuntimeBytecodeMatch === true,
    ),
  );

  const reproduced = await evidenceFor(temporaryDirectory, valid);
  assert.deepEqual(reproduced, evidence);

  const badRuntime = fixture();
  badRuntime.rpcState.code.set("code-0", "0x6001");
  await assert.rejects(() => evidenceFor(temporaryDirectory, badRuntime), /runtime length mismatch|runtime bytecode mismatch/);

  const missingSource = fixture();
  delete missingSource.coreBuildInfo.input.sources[Object.keys(missingSource.coreBuildInfo.input.sources).at(-1)];
  await assert.rejects(() => evidenceFor(temporaryDirectory, missingSource), /core build-info must retain exactly 316 sources/);

  const missingLibrarySource = fixture();
  delete missingLibrarySource.libraryBuildInfo.input.sources[
    Object.keys(missingLibrarySource.libraryBuildInfo.input.sources).at(-1)
  ];
  await assert.rejects(
    () => evidenceFor(temporaryDirectory, missingLibrarySource),
    /library build-info must retain exactly 170 sources/,
  );

  const duplicateAddress = fixture();
  duplicateAddress.inventory[1].address = duplicateAddress.inventory[0].address;
  await assert.rejects(() => evidenceFor(temporaryDirectory, duplicateAddress), /duplicate inventory address/);

  const changedCompilation = fixture();
  const firstDefinition = artifactDefinition(0, false);
  changedCompilation.coreCompileResult.output.contracts[firstDefinition.source][firstDefinition.contract].evm.bytecode.object =
    "60016000";
  await assert.rejects(() => evidenceFor(temporaryDirectory, changedCompilation), /creation bytecode changed/);

  const alteredInternalInitCode = fixture();
  const internal = alteredInternalInitCode.inventory.find((item) => item.origin === "createFundTrace");
  internal.initCode = `${internal.initCode}00`;
  internal.initCodeHash = keccak256Hex(internal.initCode);
  await assert.rejects(
    () => evidenceFor(temporaryDirectory, alteredInternalInitCode),
    /init code does not equal creation code plus constructor args/,
  );

  const alteredInternalCreationCode = fixture();
  const internalCreation = alteredInternalCreationCode.inventory.find((item) => item.origin === "factoryConstructorTrace");
  internalCreation.creationCode = `${internalCreation.creationCode}00`;
  internalCreation.creationCodeHash = keccak256Hex(internalCreation.creationCode);
  internalCreation.initCode = `${internalCreation.creationCode}${internalCreation.constructorArgs.slice(2)}`;
  internalCreation.initCodeHash = keccak256Hex(internalCreation.initCode);
  await assert.rejects(
    () => evidenceFor(temporaryDirectory, alteredInternalCreationCode),
    /exact source creation code mismatch/,
  );

  const wrongLibraryLink = fixture();
  const libraryDefinition = artifactDefinition(0, true);
  wrongLibraryLink.coreBuildInfo.input.settings.libraries[libraryDefinition.source][libraryDefinition.contract] = address(55_555);
  await assert.rejects(() => evidenceFor(temporaryDirectory, wrongLibraryLink), /linked library address mismatch/);

  const nonEmptyLibraryLinkMap = fixture();
  nonEmptyLibraryLinkMap.libraryBuildInfo.input.settings.libraries[libraryDefinition.source] = {
    [libraryDefinition.contract]: address(55_555),
  };
  await assert.rejects(
    () => evidenceFor(temporaryDirectory, nonEmptyLibraryLinkMap),
    /library build-info must contain an empty library link map/,
  );

  const changedLibraryCompilation = fixture();
  changedLibraryCompilation.libraryCompileResult.output.contracts[libraryDefinition.source][
    libraryDefinition.contract
  ].evm.bytecode.object = "60016000";
  await assert.rejects(
    () => evidenceFor(temporaryDirectory, changedLibraryCompilation),
    /creation bytecode changed under target-only outputSelection/,
  );

  process.stdout.write("B1N-419 source/runtime verifier fixture passed\n");
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
