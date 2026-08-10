import { createHash } from "node:crypto";

export const ABI_SELECTION_KEY =
  "chainId,deploymentId,interfaceFamily,interfaceVersion,address,kind,interfaceRole,abiArtifact.sha256,codeIdentity";
export const BASE_SEPOLIA_LBTC_ADDRESS = "0x39fA11EbBE82699Fd9F79C566D7384064571d2b4";
export const BASE_SEPOLIA_LBTC_RUNTIME_CODEHASH =
  "0x599a6b80cccf2c7082103129c3725529a49d37b569dc0ecc031f0444b0ce0fff";
export const LBTC_TEST_ONLY_DISCLOSURE = Object.freeze({
  consumerLabel: "LBTC_TEST_ONLY",
  contractType: "VERIFIED_MOCK_ERC20",
  backingClaim: "NONE",
  mintAccess: "UNRESTRICTED_ANY_CALLER",
  networkScope: "BASE_SEPOLIA_ONLY",
});

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

export function computeManifestContentIdentity(manifest) {
  const content = structuredClone(manifest);
  delete content.manifestContentIdentity;
  return `sha256:${createHash("sha256").update(JSON.stringify(canonicalize(content))).digest("hex")}`;
}

function invariant(condition, message) {
  if (!condition) throw new Error(message);
}

export function validateManifestSemantics(manifest) {
  invariant(
    manifest.manifestContentIdentity === computeManifestContentIdentity(manifest),
    "manifestContentIdentity does not match canonical manifest content",
  );
  invariant(
    manifest.identity.deploymentId === manifest.deployment.deploymentId,
    "identity.deploymentId must equal deployment.deploymentId",
  );
  invariant(
    manifest.compatibility.abiSelectionKey === ABI_SELECTION_KEY,
    "unsupported abiSelectionKey",
  );

  const underlying = manifest.assets.underlying;
  invariant(underlying.symbol === "LBTC", "approved test underlying must be labeled LBTC, never cbBTC");
  invariant(
    underlying.address?.toLowerCase() === BASE_SEPOLIA_LBTC_ADDRESS.toLowerCase(),
    "LBTC underlying address does not match the approved Base Sepolia mock",
  );
  invariant(underlying.decimals === 8, "LBTC underlying decimals must be exactly 8");
  invariant(
    underlying.runtimeCodehash === BASE_SEPOLIA_LBTC_RUNTIME_CODEHASH,
    "LBTC runtime codehash does not match the approved verified MockERC20",
  );
  invariant(
    JSON.stringify(canonicalize(underlying.testAssetDisclosure)) ===
      JSON.stringify(canonicalize(LBTC_TEST_ONLY_DISCLOSURE)),
    "LBTC must retain its exact test-only, unbacked, unrestricted-mint disclosure",
  );

  const addresses = new Map();
  for (const contract of manifest.deployment.contracts) {
    const address = contract.address.toLowerCase();
    invariant(!addresses.has(address), `contract address ${address} is bound more than once`);
    addresses.set(address, contract.interfaceRole);

    const expectedCodeIdentity =
      contract.kind === "PROXY"
        ? contract.implementationRuntimeCodehash
        : contract.runtimeCodehash;
    invariant(
      contract.codeIdentity === expectedCodeIdentity,
      `${contract.name}.codeIdentity does not match its ${contract.kind} ABI-bearing runtime codehash`,
    );
  }

  if (manifest.status === "PREDEPLOYMENT") {
    invariant(manifest.manifestRevision === 1, "predeployment manifestRevision must be 1");
    invariant(manifest.supersedes === null, "predeployment cannot supersede another manifest");
  } else {
    invariant(manifest.manifestRevision >= 2, "deployed manifestRevision must be at least 2");
    invariant(manifest.supersedes !== null, "deployed manifest must link its predecessor");
    invariant(
      manifest.supersedes.manifestRevision + 1 === manifest.manifestRevision,
      "manifest revision must increment its predecessor by exactly one",
    );
  }

  return true;
}

export function validateActivationTransition(previous, next) {
  validateManifestSemantics(previous);
  validateManifestSemantics(next);
  invariant(previous.status === "DEPLOYED", "activation predecessor must be deployed");
  invariant(previous.activationAuthorized === false, "activation predecessor must be inactive");
  invariant(next.status === "DEPLOYED", "activation successor must be deployed");
  invariant(next.activationAuthorized === true, "activation successor must be active");
  invariant(next.manifestId !== previous.manifestId, "activation must create a new manifestId");
  invariant(
    next.identity.deploymentId === previous.identity.deploymentId,
    "activation must preserve deploymentId",
  );
  invariant(
    next.manifestRevision === previous.manifestRevision + 1,
    "activation must increment manifestRevision",
  );
  invariant(next.supersedes !== null, "activation successor must link its predecessor");
  invariant(
    next.supersedes.manifestId === previous.manifestId &&
      next.supersedes.manifestRevision === previous.manifestRevision &&
      next.supersedes.manifestContentIdentity === previous.manifestContentIdentity,
    "activation successor must bind the exact predecessor content identity",
  );
  return true;
}
