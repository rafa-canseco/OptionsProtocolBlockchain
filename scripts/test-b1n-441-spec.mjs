import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import Ajv2020 from "ajv/dist/2020.js";
import {
  ABI_SELECTION_KEY,
  BASE_SEPOLIA_LBTC_ADDRESS,
  BASE_SEPOLIA_LBTC_RUNTIME_CODEHASH,
  LBTC_TEST_ONLY_DISCLOSURE,
  computeManifestContentIdentity,
  validateActivationTransition,
  validateManifestSemantics,
} from "./validate-b1n-441-manifest.mjs";

const fixturePath = "deployments/specifications/b1n-441/lbtc8-base-sepolia.predeploy.json";
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"));
const schema = JSON.parse(readFileSync(fixture.source.schema.path, "utf8"));
const adapterAbi = JSON.parse(readFileSync(fixture.abi.adapter.artifact.path, "utf8"));
const wheelAbi = JSON.parse(readFileSync(fixture.abi.wheel.artifact.path, "utf8"));
const ajv = new Ajv2020({ allErrors: true, strict: false });
const validateManifest = ajv.compile(schema);

function sha256Pin(path) {
  return `sha256:${createHash("sha256").update(readFileSync(path)).digest("hex")}`;
}

function abiNames(abi, type) {
  return new Set(abi.filter((entry) => entry.type === type).map((entry) => entry.name));
}

function clone(value) {
  return structuredClone(value);
}

function refreshContentIdentity(value) {
  value.manifestContentIdentity = computeManifestContentIdentity(value);
  return value;
}

function expectSchemaValid(value) {
  assert.equal(validateManifest(value), true, JSON.stringify(validateManifest.errors, null, 2));
}

function expectManifestValid(value) {
  expectSchemaValid(value);
  assert.equal(validateManifestSemantics(value), true);
}

function expectSemanticInvalid(value, pattern) {
  refreshContentIdentity(value);
  expectSchemaValid(value);
  assert.throws(() => validateManifestSemantics(value), pattern);
}

function expectSchemaInvalid(value, keyword) {
  assert.equal(validateManifest(value), false, "mutated manifest unexpectedly passed schema validation");
  if (keyword) {
    assert(
      validateManifest.errors.some((error) => error.keyword === keyword),
      `expected ${keyword} error, got ${JSON.stringify(validateManifest.errors)}`,
    );
  }
}

function fakeHex(byteLength, nibble) {
  return `0x${nibble.repeat(byteLength * 2)}`;
}

function deployedFixture({ activationAuthorized = false } = {}) {
  const value = clone(fixture);
  value.manifestId = "b1n-441-lbtc8-base-sepolia-deployed-inactive-2";
  value.manifestRevision = 2;
  value.supersedes = {
    manifestId: fixture.manifestId,
    manifestRevision: fixture.manifestRevision,
    manifestContentIdentity: fixture.manifestContentIdentity,
  };
  value.status = "DEPLOYED";
  value.consumerReady = true;
  value.activationAuthorized = activationAuthorized;
  value.identity.deploymentId = fakeHex(32, "1");
  value.assets.underlying.address = BASE_SEPOLIA_LBTC_ADDRESS;
  value.assets.underlying.runtimeCodehash = BASE_SEPOLIA_LBTC_RUNTIME_CODEHASH;
  value.assets.settlement.address = fakeHex(20, "4");
  value.assets.settlement.runtimeCodehash = fakeHex(32, "5");
  value.deployment.deploymentId = value.identity.deploymentId;
  value.deployment.validFromBlock = 123;
  value.deployment.contracts = [
    {
      name: "CspFundAdapterV2",
      kind: "PROXY",
      address: fakeHex(20, "6"),
      proxyRuntimeCodehash: fakeHex(32, "7"),
      implementation: fakeHex(20, "8"),
      implementationRuntimeCodehash: fakeHex(32, "9"),
      codeIdentity: fakeHex(32, "9"),
      interfaceRole: "OPTIONS_ADAPTER",
      interfaceContractName: "IAssetNeutralOptionsAdapterV2",
      abiArtifact: clone(value.abi.adapter.artifact),
      interfaceVersion: 2,
      validFromBlock: 123,
    },
    {
      name: "WheelCoordinatorV2",
      kind: "IMMUTABLE",
      address: fakeHex(20, "a"),
      runtimeCodehash: fakeHex(32, "b"),
      codeIdentity: fakeHex(32, "b"),
      interfaceRole: "WHEEL_COORDINATOR",
      interfaceContractName: "IAssetNeutralWheelV2",
      abiArtifact: clone(value.abi.wheel.artifact),
      interfaceVersion: 2,
      validFromBlock: 123,
    },
  ];
  value.deployment.canonicalReceipts = [
    {
      transactionHash: fakeHex(32, "c"),
      blockNumber: 123,
      blockHash: fakeHex(32, "d"),
      status: 1,
    },
  ];
  value.source.activationAuthorizationArtifact = activationAuthorized
    ? {
        path: "deployments/base-sepolia/b1n-449/activation-approval.json",
        sha256: `sha256:${"e".repeat(64)}`,
      }
    : null;
  return refreshContentIdentity(value);
}

test("predeployment fixture genuinely validates and is inert/Base Sepolia specific", () => {
  expectManifestValid(fixture);
  assert.equal(schema.additionalProperties, false);
  assert.equal(schema.properties.schemaVersion.const, "2.0.0");
  assert.equal(fixture.schemaVersion, "2.0.0");
  assert.equal(fixture.status, "PREDEPLOYMENT");
  assert.equal(fixture.consumerReady, false);
  assert.equal(fixture.activationAuthorized, false);
  assert.equal(fixture.source.activationAuthorizationArtifact, null);
  assert.equal(fixture.identity.chainName, "base-sepolia");
  assert.equal(fixture.identity.chainId, 84532);
  assert.equal(fixture.identity.interfaceVersion, 2);
  assert.equal(fixture.identity.deploymentId, null);
  assert.equal(fixture.assets.underlying.address, BASE_SEPOLIA_LBTC_ADDRESS);
  assert.equal(fixture.assets.settlement.address, null);
  assert.equal(fixture.deployment.deploymentId, null);
  assert.equal(fixture.deployment.validFromBlock, null);
  assert.deepEqual(fixture.deployment.contracts, []);
  assert.deepEqual(fixture.deployment.canonicalReceipts, []);
  assert.deepEqual(fixture.assets.supportedDecimalTuple, [8, 8, 8, 6]);
  assert.equal(fixture.assets.underlying.symbol, "LBTC");
  assert.equal(fixture.assets.underlying.decimals, 8);
  assert.deepEqual(fixture.assets.underlying.testAssetDisclosure, LBTC_TEST_ONLY_DISCLOSURE);
  assert.equal(fixture.assets.settlement.symbol, "USDC");
  assert.equal(fixture.assets.settlement.decimals, 6);
  assert.equal(fixture.assets.underlying.runtimeCodehash, BASE_SEPOLIA_LBTC_RUNTIME_CODEHASH);
  assert.equal(fixture.assets.settlement.runtimeCodehash, null);
  assert.equal(fixture.assets.settlement.testAssetDisclosure, null);
});

test("deployed manifests validate only with exact role/ABI bindings", () => {
  const deployed = deployedFixture();
  expectManifestValid(deployed);
  assert.equal(deployed.compatibility.abiSelectionKey, ABI_SELECTION_KEY);

  const missingRole = clone(deployed);
  delete missingRole.deployment.contracts[0].interfaceRole;
  expectSchemaInvalid(missingRole, "required");

  const crossedAbi = clone(deployed);
  crossedAbi.deployment.contracts[0].abiArtifact = clone(deployed.abi.wheel.artifact);
  expectSchemaInvalid(crossedAbi, "const");

  const forgedAbiHash = clone(deployed);
  forgedAbiHash.deployment.contracts[0].abiArtifact.sha256 = `sha256:${"f".repeat(64)}`;
  expectSchemaInvalid(forgedAbiHash, "const");
});

test("schema rejects chain, decimal tuple, and zero deployed identity mutations", () => {
  const wrongChain = deployedFixture();
  wrongChain.identity.chainId = 8453;
  expectSchemaInvalid(wrongChain, "const");

  const wrongDecimals = deployedFixture();
  wrongDecimals.assets.underlying.decimals = 9;
  expectSchemaInvalid(wrongDecimals, "const");

  const inconsistentTuple = deployedFixture();
  inconsistentTuple.assets.supportedDecimalTuple = [8, 18, 8, 6];
  expectSchemaInvalid(inconsistentTuple, "const");

  const missingAssetAddress = deployedFixture();
  missingAssetAddress.assets.underlying.address = null;
  expectSchemaInvalid(missingAssetAddress);

  const zeroAssetCodehash = deployedFixture();
  zeroAssetCodehash.assets.underlying.runtimeCodehash = fakeHex(32, "0");
  expectSchemaInvalid(zeroAssetCodehash, "pattern");

  const zeroAddress = deployedFixture();
  zeroAddress.deployment.contracts[0].address = fakeHex(20, "0");
  expectSchemaInvalid(zeroAddress, "pattern");

  const zeroCodehash = deployedFixture();
  zeroCodehash.deployment.contracts[0].proxyRuntimeCodehash = fakeHex(32, "0");
  expectSchemaInvalid(zeroCodehash, "pattern");
});

test("approved LBTC identity and test-only disclosure fail closed on mutation", () => {
  const reorderedDisclosure = clone(fixture);
  reorderedDisclosure.assets.underlying.testAssetDisclosure = {
    networkScope: "BASE_SEPOLIA_ONLY",
    mintAccess: "UNRESTRICTED_ANY_CALLER",
    backingClaim: "NONE",
    contractType: "VERIFIED_MOCK_ERC20",
    consumerLabel: "LBTC_TEST_ONLY",
  };
  refreshContentIdentity(reorderedDisclosure);
  expectManifestValid(reorderedDisclosure);

  const wrongPredeployAddress = clone(fixture);
  wrongPredeployAddress.assets.underlying.address = fakeHex(20, "2");
  expectSchemaInvalid(wrongPredeployAddress, "const");

  const wrongDeployedAddress = deployedFixture();
  wrongDeployedAddress.assets.underlying.address = fakeHex(20, "2");
  expectSemanticInvalid(wrongDeployedAddress, /approved Base Sepolia mock/);

  const wrongPredeployCodehash = clone(fixture);
  wrongPredeployCodehash.assets.underlying.runtimeCodehash = fakeHex(32, "3");
  expectSchemaInvalid(wrongPredeployCodehash, "const");

  const wrongDeployedCodehash = deployedFixture();
  wrongDeployedCodehash.assets.underlying.runtimeCodehash = fakeHex(32, "3");
  expectSemanticInvalid(wrongDeployedCodehash, /approved verified MockERC20/);

  const wrongDecimals = clone(fixture);
  wrongDecimals.assets.underlying.decimals = 18;
  expectSchemaInvalid(wrongDecimals, "const");

  const productionBackedClaim = clone(fixture);
  productionBackedClaim.assets.underlying.testAssetDisclosure.backingClaim = "PRODUCTION_BACKED";
  expectSchemaInvalid(productionBackedClaim, "const");
  refreshContentIdentity(productionBackedClaim);
  assert.throws(
    () => validateManifestSemantics(productionBackedClaim),
    /test-only, unbacked, unrestricted-mint disclosure/,
  );

  const misleadingSymbol = clone(fixture);
  misleadingSymbol.assets.underlying.symbol = "cbBTC";
  expectSchemaInvalid(misleadingSymbol, "const");
  refreshContentIdentity(misleadingSymbol);
  assert.throws(() => validateManifestSemantics(misleadingSymbol), /labeled LBTC, never cbBTC/);
});

test("semantic validation binds one address to one role and exact code identity", () => {
  const deployed = deployedFixture();

  const dualRole = clone(deployed.deployment.contracts[1]);
  dualRole.address = deployed.deployment.contracts[0].address;
  deployed.deployment.contracts.push(dualRole);
  expectSemanticInvalid(deployed, /bound more than once/);

  const wrongProxyIdentity = deployedFixture();
  wrongProxyIdentity.deployment.contracts[0].codeIdentity = fakeHex(32, "f");
  expectSemanticInvalid(wrongProxyIdentity, /codeIdentity/);

  const wrongImmutableIdentity = deployedFixture();
  wrongImmutableIdentity.deployment.contracts[1].codeIdentity = fakeHex(32, "f");
  expectSemanticInvalid(wrongImmutableIdentity, /codeIdentity/);
});

test("semantic validation binds identity and deployment IDs", () => {
  const mismatch = deployedFixture();
  mismatch.deployment.deploymentId = fakeHex(32, "f");
  expectSemanticInvalid(mismatch, /deploymentId must equal/);
});

test("activation requires a new immutable revision linked to exact predecessor content", () => {
  const deployedInactive = deployedFixture();
  expectManifestValid(deployedInactive);

  const deployedActive = deployedFixture({ activationAuthorized: true });
  deployedActive.manifestId = "b1n-441-lbtc8-base-sepolia-active-3";
  deployedActive.manifestRevision = deployedInactive.manifestRevision + 1;
  deployedActive.supersedes = {
    manifestId: deployedInactive.manifestId,
    manifestRevision: deployedInactive.manifestRevision,
    manifestContentIdentity: deployedInactive.manifestContentIdentity,
  };
  refreshContentIdentity(deployedActive);
  expectManifestValid(deployedActive);
  assert.equal(validateActivationTransition(deployedInactive, deployedActive), true);

  const sameIdentity = clone(deployedActive);
  sameIdentity.manifestId = deployedInactive.manifestId;
  refreshContentIdentity(sameIdentity);
  assert.throws(() => validateActivationTransition(deployedInactive, sameIdentity), /new manifestId/);

  const wrongPredecessor = clone(deployedActive);
  wrongPredecessor.supersedes.manifestContentIdentity = `sha256:${"f".repeat(64)}`;
  refreshContentIdentity(wrongPredecessor);
  assert.throws(
    () => validateActivationTransition(deployedInactive, wrongPredecessor),
    /exact predecessor content identity/,
  );

  const missingApproval = clone(deployedActive);
  missingApproval.source.activationAuthorizationArtifact = null;
  refreshContentIdentity(missingApproval);
  expectSchemaInvalid(missingApproval);

  const predeployActive = clone(fixture);
  predeployActive.activationAuthorized = true;
  refreshContentIdentity(predeployActive);
  expectSchemaInvalid(predeployActive, "const");
});

test("all consumer artifacts and policy hash are content pinned", () => {
  assert.equal(fixture.source.schema.sha256, sha256Pin(fixture.source.schema.path));
  assert.equal(
    fixture.source.interfaceSources.adapter.sha256,
    sha256Pin(fixture.source.interfaceSources.adapter.path),
  );
  assert.equal(
    fixture.source.interfaceSources.wheel.sha256,
    sha256Pin(fixture.source.interfaceSources.wheel.path),
  );
  assert.equal(fixture.source.policyArtifact.sha256, sha256Pin(fixture.source.policyArtifact.path));
  assert.equal(
    fixture.source.semanticValidator.sha256,
    sha256Pin(fixture.source.semanticValidator.path),
  );
  assert.equal(fixture.abi.adapter.artifact.sha256, sha256Pin(fixture.abi.adapter.artifact.path));
  assert.equal(fixture.abi.wheel.artifact.sha256, sha256Pin(fixture.abi.wheel.artifact.path));
  assert.equal(
    fixture.identity.policyHash,
    `0x${fixture.source.policyArtifact.sha256.slice("sha256:".length)}`,
  );
});

test("prerequisite gaps are explicit and staging-pinned", () => {
  assert.equal(fixture.source.originStagingCommit, "6cbd32512b8b85c60c23443f3e3f91d7da18cc5f");
  assert.equal(fixture.source.prerequisites["B1N-411"].status, "NOT_PRESENT_ON_ORIGIN_STAGING");
  assert.deepEqual(fixture.source.prerequisites["B1N-411"].commits, []);
  assert.equal(fixture.source.prerequisites["B1N-419"].status, "MERGED_ON_ORIGIN_STAGING");
  assert.deepEqual(fixture.source.prerequisites["B1N-419"].commits, [
    "8e82fdd3c09ae41c5f75ae21d9a9dceb94e4cbd4",
    "f58739fd62cf981e96f9020fa8654dc071e10908",
    "70720568b470a433ec1be1c85b9c8e28c4e2a4f8",
    "6cbd32512b8b85c60c23443f3e3f91d7da18cc5f",
  ]);
});

test("ABIs export only explicit v2 generic-underlying reads, DTOs, and events", () => {
  const functions = abiNames(adapterAbi, "function");
  const events = abiNames(adapterAbi, "event");
  for (const name of [
    "interfaceVersion",
    "underlyingAsset",
    "settlementAsset",
    "assetConfigV2",
    "policyHash",
    "adapterStateV2",
    "positionV2",
  ]) {
    assert(functions.has(name), `missing function ${name}`);
  }
  for (const name of [
    "AssetNeutralPositionOpenedV2",
    "AssetNeutralPositionTransitionedV2",
    "AssetNeutralDustIsolatedV2",
    "AssetNeutralAssetsNormalizedV2",
  ]) {
    assert(events.has(name), `missing event ${name}`);
  }
  assert(!functions.has("weth"));

  const wheelFunctions = abiNames(wheelAbi, "function");
  const wheelEvents = abiNames(wheelAbi, "event");
  for (const name of ["underlyingAsset", "settlementAsset", "summaryV2", "trancheV2", "assignmentLotV2"]) {
    assert(wheelFunctions.has(name), `missing Wheel function ${name}`);
  }
  for (const name of [
    "AssetNeutralWheelChildHandoffV2",
    "AssetNeutralWheelAssignmentLotCreatedV2",
    "AssetNeutralWheelLotStatusChangedV2",
  ]) {
    assert(wheelEvents.has(name), `missing Wheel event ${name}`);
  }
  assert(!wheelFunctions.has("weth"));
  for (const forbidden of ["accountedWeth", "assignedWeth", "wethDelta", "wethAmount", "wethReceived"]) {
    assert(
      !JSON.stringify([adapterAbi, wheelAbi]).includes(`\"${forbidden}\"`),
      `v1 field leaked into v2 ABI: ${forbidden}`,
    );
  }
  assert.equal(fixture.compatibility.wethNamedV1Fields, "VERSION_1_ONLY_DO_NOT_REINTERPRET");
  assert.equal(fixture.compatibility.unknownVersionBehavior, "FAIL_CLOSED");
});
