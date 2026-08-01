# B1N-419 Meta Wheel Base Sepolia deployment

This directory is a testnet-only deployment scaffold. Nothing in it authorizes a mainnet transaction. The
Meta Wheel is deployed as a fresh USDC Fund and never upgrades or registers either standalone CSP or standalone
Covered Call proxy.

## Current status

- The scaffold is intentionally **not approved for broadcast** while the managed-strategy ABI is still changing.
- `deployment-inputs.template.json` is not an approved artifact and contains blocking placeholders.
- `manifest.template.json` is the fail-closed backend contract; every deployment/block/receipt placeholder rejects
  registry ingestion.
- `canonicalization-evidence.template.json` is a separate receipt sidecar and is paired to the manifest by the full
  `sourceCommit`, non-zero `deploymentId`, and SHA-256 of the unconfirmed manifest.
- Deployment, authority rotation, inactive strategy configuration, managed lane setup, child onboarding and
  activation are separate phases.
- The parent remains deposit/redemption paused and the coordinator strategy remains inactive through handoff.

## Rebase gate for the final ABI

Before producing approved inputs, rebase on the final B1N-414/B1N-415 commit and bind every external library in
this order:

1. `CspFundAdapterOperations`
2. `CoveredCallFundAdapterOperations`
3. `ManagedStrategyOperations`
4. `WheelManagedOperationDispatcher`
5. `WheelCoordinatorPositionOperations`

Each address and runtime code hash belongs in `LINKED_LIBRARIES` and `LINKED_LIBRARY_CODEHASHES`. Libraries must be
deployed first, then the entire source must be rebuilt with exact `--libraries` bindings before deploying
`StrategyManager`, child adapters or the coordinator. The deployment manifest records the ordered bindings.

The final ABI changes the lane bootstrap order. The coordinator must first be registered in `StrategyManager` with
`active: false`. Only then may `registerLane`, lane pausing or coordinator pausing execute through the
`StrategyManager` managed-operation wrappers and `WheelManagedOperationDispatcher`. Never authorize or invoke the
coordinator's direct selectors from an EOA or bot. The final rebase must remove the legacy direct-selector bootstrap
path before this scaffold can be approved for broadcast.

## Safe phase order

1. Run `forge clean && forge build` and `script/fund/validate-meta-wheel-upgrades.sh` with the final link map.
2. Copy the template to an approved input file, replace every placeholder, pin standalone implementation slots and
   code hashes from the same fork block, and record its SHA-256 digest.
3. Run the read-only preflight with `--sig preflight()`.
4. Run `DeployMetaWheelBaseSepolia` against a current Base Sepolia fork **without** `--broadcast`.
5. Reconcile the generated manifest with `ReconcileMetaWheelBootstrap`.
6. Only after review, broadcast bootstrap using the existing Base Sepolia credential through an ignored Foundry
   keystore/account. Bootstrap roles may temporarily share that address because the whole deployment is paused.
   Scripts take only
   `B1N419_BROADCASTER`; they never read or print a raw private key.
7. Run `RotateMetaWheelRolesBaseSepolia`, then `ReconcileMetaWheelFinalRoles`. Final admin, upgrader, accounting,
   allocator, processor, curator and guardian accounts must be distinct; the bootstrap address is revoked.
8. Run the curator configuration phase first. It binds reporters, the independent Meta Wheel valuator, the
   coordinator strategy with `active: false`, and exit escrows.
9. Run the managed lane setup phase through the four `StrategyManager` operation-class wrappers. Register and pause
   lanes/coordinator only through those wrappers; do not use direct target selectors.
10. Run child onboarding from the current `BatchSettler` owner. This mutates only the eight fresh adapter
   authorization entries and rechecks standalone proxy baselines before and after.
11. Activation remains a separate QA gate after backend NAV reconciliation and two-cycle fork simulation.

No script in this scaffold resumes deposits or opens a position.

## Backend handoff contract

The deploy script always writes `status: UNCONFIRMED_REQUIRES_CANONICAL_RECEIPTS`,
`deploymentStatus: UNCONFIRMED` and `handoffReady: false`. The canonical artifact follows backend contract version
`1.0.0` and contains:

- `network.deploymentBlocks.fundFirst/fundLast` and successful `canonicalReceipts[]` binding both boundaries;
- USDC, WETH and the swap router;
- the six core/coordinator proxy bindings with implementation activation blocks and code hashes;
- immutable claim escrow, access manager, Meta Wheel valuator and NAV verifier bindings;
- unchanged V1 boundary entries, all five linked libraries, four standalone proxy baselines and seven final roles;
- exact 2% AUM, 10% HWM performance and 10% gross-premium fee policy; and
- all backend readiness flags true except `mainnetAuthorized`, which must remain false.

`canonicalReceipts[]` is deliberately limited to receipts inside `fundFirst..fundLast`, as required by the backend
parser. Receipts for role rotation, inactive configuration, managed lane setup, onboarding and every fresh contract
live in the paired `canonicalization-evidence.json` sidecar. They are evidence, not backend deployment truth.
Phase receipts use the canonical `{transactionHash, blockNumber, blockHash, status: 1}` shape. Each
`contractReceipts[]` entry adds `contract`, `address` and `runtimeCodehash`; the finalizer requires exact one-to-one
coverage of the fresh core, coordinator, valuator, lane, adapter, escrow and five-library inventory.

## Canonical finalization

`script/fund/finalize-meta-wheel-manifest.sh` never broadcasts. It fails closed unless:

1. the sidecar is explicitly approved and its manifest digest, `sourceCommit` and `deploymentId` match;
2. RPC receipts, block hashes, success statuses, contract coverage and runtime code hashes all match;
3. the coordinator was configured inactive before managed lane setup, with all phase receipts ordered;
4. Blockscout verification and bootstrap/final-role/standalone reconciliation are complete;
5. `ReconcileMetaWheelCanonical` passes against live Base Sepolia state; and
6. the candidate is accepted by the backend's exact `parse_fund_deployment` implementation.

Only after every gate passes does it write a new file with `status: CONFIRMED_CANONICAL_RECEIPTS`,
`deploymentStatus: DEPLOYED` and `handoffReady: true`. It refuses to overwrite the unconfirmed or an existing
canonical artifact. Required environment variables are:

```text
BASE_SEPOLIA_RPC_URL
B1N419_MANIFEST_PATH
B1N419_CANONICALIZATION_EVIDENCE_PATH
B1N419_CANONICAL_MANIFEST_PATH
B1N419_APPROVED_INPUTS_PATH
B1N419_APPROVED_INPUTS_SHA256
B1N419_BACKEND_ROOT
B1N419_BACKEND_PYTHON (optional; defaults to python3)
```

A fork/dry-run manifest and sidecar can never be used as deployment truth. No address, block or receipt may be
copied from fork output.
