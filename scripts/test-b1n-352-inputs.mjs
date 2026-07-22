import test from "node:test";
import assert from "node:assert/strict";
import {
  linkAdapterRuntime,
  linkOperationsRuntime,
  sha256Hex,
  validateDocument
} from "./prepare-b1n-352-inputs.mjs";

test("links both approved library references at their exact offsets", () => {
  const artifact = {
    deployedBytecode: {
      object: `0x6000${"_".repeat(40)}6001${"_".repeat(40)}6002${"0".repeat(64)}6003${"0".repeat(64)}6004`,
      linkReferences: {
        "src/fund/libraries/CspFundAdapterOperations.sol": {
          CspFundAdapterOperations: [{start: 2, length: 20}, {start: 24, length: 20}]
        }
      },
      immutableReferences: {
        self: [{start: 46, length: 32}, {start: 80, length: 32}]
      }
    }
  };
  const address = "1234567890123456789012345678901234567890";
  const implementation = "abcdefabcdefabcdefabcdefabcdefabcdefabcd";
  const paddedImplementation = implementation.padStart(64, "0");
  assert.equal(
    linkAdapterRuntime(artifact, `0x${address}`, `0x${implementation}`),
    `6000${address}6001${address}6002${paddedImplementation}6003${paddedImplementation}6004`
  );
});

test("rejects a partially described linked runtime", () => {
  const artifact = {
    deployedBytecode: {
      object: `0x6000${"_".repeat(40)}6001${"_".repeat(40)}6002${"0".repeat(64)}6003${"0".repeat(64)}`,
      linkReferences: {
        "src/fund/libraries/CspFundAdapterOperations.sol": {
          CspFundAdapterOperations: [{start: 2, length: 20}]
        }
      },
      immutableReferences: {
        self: [{start: 46, length: 32}, {start: 80, length: 32}]
      }
    }
  };
  assert.throws(
    () => linkAdapterRuntime(
      artifact,
      "0x1234567890123456789012345678901234567890",
      "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
    ),
    /exactly two/
  );
});

test("patches both pre-linked adapter address immutables", () => {
  const operations = "1234567890123456789012345678901234567890";
  const artifact = {
    deployedBytecode: {
      object: `0x6000${operations}6001${"0".repeat(64)}6002${"0".repeat(64)}6003`,
      linkReferences: {},
      immutableReferences: {
        self: [{start: 24, length: 32}, {start: 58, length: 32}]
      }
    }
  };
  const implementation = "abcdefabcdefabcdefabcdefabcdefabcdefabcd";
  const padded = implementation.padStart(64, "0");
  assert.equal(
    linkAdapterRuntime(artifact, `0x${operations}`, `0x${implementation}`),
    `6000${operations}6001${padded}6002${padded}6003`
  );
});

test("patches the deployed library self-address immutable", () => {
  const artifact = {
    deployedBytecode: {
      object: `0x6000${"0".repeat(64)}6001`,
      immutableReferences: {
        library_deploy_address: [{start: 2, length: 32}]
      }
    }
  };
  const address = "1234567890123456789012345678901234567890";
  assert.equal(
    linkOperationsRuntime(artifact, `0x${address}`),
    `6000${address.padStart(64, "0")}6001`
  );
});

test("uses SHA-256 over the exact approved file bytes", () => {
  assert.equal(sha256Hex("B1N-352\n"), "0x0a14357b5115d2f31b924bddc17bd1bf623b4d21cab8d771b5478a35f99cd762");
  assert.notEqual(sha256Hex("B1N-352"), sha256Hex("B1N-352\n"));
});

test("template accepts only the declared environment key set", () => {
  const document = {
    schemaVersion: "1.0.0",
    issue: "B1N-352",
    network: {name: "base-sepolia", chainId: 84532},
    approval: {status: "NOT_APPROVED"},
    source: {gitCommit: "TO_BE_FILLED", solc: "0.8.24", optimizerRuns: 200, viaIr: true},
    policy: {artifact: "B1N-346", sha256: "TO_BE_FILLED"},
    environment: {UNDECLARED: "value"}
  };
  assert.throws(() => validateDocument(document, {requireApproval: false}), /unrecognized environment keys/);
});
