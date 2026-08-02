# B1N-419 Meta Wheel Base Sepolia deployment

This directory is a testnet-only deployment scaffold. Nothing in it authorizes a mainnet transaction. The
Meta Wheel is deployed as a fresh USDC Fund and never upgrades or registers either standalone CSP or standalone
Covered Call proxy.

## Current status

- The scaffold is frozen to the final managed-strategy ABI but remains **not approved for live broadcast**.
- `deployment-inputs.template.json` is not an approved artifact and contains blocking placeholders.
- `manifest.template.json` is the fail-closed backend contract; every deployment/block/receipt placeholder rejects
  registry ingestion.
- `canonicalization-evidence.template.json` is a separate receipt sidecar and is paired to the manifest by the full
  `sourceCommit`, non-zero `deploymentId`, and SHA-256 of the unconfirmed manifest.
- `library-prephase.template.json` is a second, independent sidecar for the five deployments that must precede the
  Fund deployment block window. A fork artifact always remains noncanonical.
- `deployment-pins.template.json` enumerates the only human/governance inputs. The approved deployment JSON is
  generated deterministically; editing `deployment-inputs.template.json` by hand is not an accepted workflow.
- Deployment, authority rotation, inactive strategy configuration, managed lane setup, child onboarding and
  activation are separate phases.
- The parent remains deposit/redemption paused and the coordinator strategy remains inactive through handoff.
- Bootstrap pauses each child lane through its explicit `GUARDIAN_ROLE`. The coordinator is temporarily unpaused,
  but has no registered lanes, no configured strategy and no funds, so it has no useful execution route.
- The approved Base Sepolia library/core/bootstrap broadcaster is the dedicated B1N-419 signer
  `0x42cB85203838DD9708ED548DC4f815130E8F7e74`. Fee recipient and the current `BatchSettler` onboarding owner are
  `0x376a4c54623fe24D0Ffc1032D0b6CcC03A32fd7D`; this identity cannot be a bootstrap/final role, observer or NAV
  reporter, and the generator and finalizer reject any such overlap.
- The local signer recovery map uses ignored keystore `.secrets/b1n-419/base-sepolia-meta-wheel-broadcaster` and
  macOS Keychain service `b1nary-b1n-419-base-sepolia-broadcaster-v1`, account `rafa`. No password or private key
  belongs in this repository or in deployment evidence.
- The four observer inputs are domain-separated: `[0,1]` are the complete CSP set and `[2,3]` are the complete
  Covered Call set, with quorum 2 in each valuator and no cross-authorization. The two NAV reporters are a separate
  exact set with threshold 2.

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

`DeployMetaWheelLibrariesBaseSepolia.run()` always reverts. The only supported entrypoint is orchestrated by
`script/fund/deploy-meta-wheel-libraries-base-sepolia.sh`, whose default mode is `simulate`; it invokes the five
CREATEs against a current Base Sepolia fork, emits a `SIMULATED_NONCANONICAL` sidecar and performs a clean rebuild
with the five generated `--libraries` arguments. Live mode additionally requires the exact approval phrase and an
approved full source commit, and then RPC-reconciles every receipt and runtime code hash before emitting canonical
library evidence. Supplying `--broadcast`, `--resume`, RPC or sender flags directly is rejected.

The final ABI fixes the lane bootstrap order. The coordinator must first be registered in `StrategyManager` with
`active: false`. Only then may `registerLane` or coordinator pausing execute through the
`StrategyManager` managed-operation wrappers and `WheelManagedOperationDispatcher`. Here, “pausing” means the
coordinator's `pauseAllocations`; child lanes retain their explicit guardian selector policy. Never authorize or
invoke coordinator selectors from an EOA or bot. Approval requires proving the legacy direct-selector coordinator
bootstrap path is absent.

## Deterministic fork inputs and rehearsal

Start one persistent Anvil fork pinned to the reviewed Base Sepolia block with chain id `84532`. On that same RPC:

1. Set `B1N419_LIBRARY_MODE=fork-broadcast`, fork-only draft/sidecar paths, the dedicated library broadcaster and
   `BASE_SEPOLIA_RPC_URL` equal to the Anvil URL; run
   `script/fund/deploy-meta-wheel-libraries-base-sepolia.sh --unlocked`. The wrapper proves `anvil_nodeInfo` has a
   fork configuration and marks all receipts `SIMULATED_NONCANONICAL`.
2. Fill and approve a non-template `deployment-pins.json` with approval `APPROVED_BASE_SEPOLIA_DRY_RUN`, the full
   source commit, dependency/standalone pins, one bootstrap account, seven distinct final role accounts, four
   mutually distinct option observers and two NAV reporters. All six valuation keys must also be distinct from
   every role account and from the fee recipient/settler owner. Run `generate-meta-wheel-approved-inputs.sh` with
   `B1N419_INPUT_MODE=dry-run`; it verifies
   live fork code, implementation slots, library order/code hashes and writes both sorted JSON and its SHA-256.
3. Run `rehearse-meta-wheel-base-sepolia.sh` with that same Anvil URL as `B1N419_FORK_RPC_URL`. It broadcasts locally
   (never live) and executes build, upgrade checks, tests, preflight, bootstrap, reconciliation, role rotation,
   inactive configuration, exactly eight managed registrations, managed pause, onboarding and final read-only
   reconciliation. The same five `--libraries` bindings are supplied to every Foundry invocation, and the linked
   unit suite runs with `--fork-url` so those five deployed libraries exist in its EVM. It ends by
   proving the canonical finalizer rejects the Anvil RPC.

For live inputs, repeat library deployment only after separate approval with `B1N419_LIBRARY_MODE=broadcast`, then
run the generator with `B1N419_INPUT_MODE=live` and pins approval `APPROVED_BASE_SEPOLIA_LIVE`. Live mode and the
canonical finalizer both reject Anvil/Hardhat clients and `anvil_nodeInfo`.

## Safe phase order

1. From a clean final-ABI commit, run the library prephase in its default fork-only mode. Review the ordered
   addresses, code hashes and exact relink result. No simulated address may be copied into approved inputs.
2. After separate approval, run that same prephase in live mode to deploy only the five libraries. Preserve its
   canonical sidecar, then run `script/fund/validate-meta-wheel-upgrades.sh` with the recorded link map.
3. Copy the template to an approved input file, replace every placeholder, pin standalone implementation slots and
   code hashes from the same fork block, and record its SHA-256 digest.
4. Run the read-only preflight with `--sig preflight()`.
5. Run `DeployMetaWheelBaseSepolia` against a current Base Sepolia fork **without** `--broadcast`.
6. Reconcile the generated manifest with `ReconcileMetaWheelBootstrap`.
7. Only after review, broadcast bootstrap using the existing Base Sepolia credential through an ignored Foundry
   keystore/account. Bootstrap roles may temporarily share that address because the whole deployment is paused.
   Scripts take only
   `B1N419_BROADCASTER`; they never read or print a raw private key.
8. Run `RotateMetaWheelRolesBaseSepolia`, then `ReconcileMetaWheelFinalRoles`. Final admin, upgrader, accounting,
   allocator, processor, curator and guardian accounts must be distinct; the bootstrap address is revoked.
9. Run the curator configuration phase first. It binds reporters, the independent Meta Wheel valuator, the
   coordinator strategy with `active: false`, and exit escrows.
10. Run `SetupMetaWheelManagedLanesBaseSepolia.registerLanes()` as final curator, then
   `pauseCoordinator()` as final guardian, and finish with the read-only `reconcileManagedSetup()`. Lane registration
   uses the configuration wrapper and coordinator pause uses the guardian wrapper; do not use coordinator target
   selectors directly.
11. Run child onboarding from the current `BatchSettler` owner. This mutates only the eight fresh adapter
   authorization entries and rechecks standalone proxy baselines before and after.
12. Activation remains a separate QA gate after backend NAV reconciliation and two-cycle fork simulation.

No deployment or handoff script resumes deposits or opens a position; only the separately approved activation gate
can open deposits, and no activation entrypoint opens an options position.

`ActivateMetaWheelBaseSepolia` is deliberately two-phase and opens no position. `prepareActivation()` performs one
atomic curator `AccessManager.multicall` that resumes all child lanes, the coordinator and the StrategyManager while
the Fund remains deposit/redemption paused. This managed operation invalidates NAV by design. ACCOUNTING must then
submit a fresh signed NAV whose `positionsHash` equals the current StrategyManager hash. Only after that does
`openFund()` atomically resume redemptions and deposits. Both phases use separately digested activation approvals;
the open approval binds the canonical manifest, readiness hash, fresh NAV window and all QA flags. Activation
receipts live in `activation-evidence.json`, never by rewriting the canonical deployment manifest.

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
coverage of the fresh core, coordinator, valuator, lane, adapter and escrow inventory. The five earlier library
receipts and runtime code hashes live only in the separately reconciled library-prephase sidecar, because they are
outside `fundFirst..fundLast`.

## Canonical finalization

`script/fund/finalize-meta-wheel-manifest.sh` never broadcasts. It fails closed unless:

1. the sidecar is explicitly approved and its manifest digest, `sourceCommit` and `deploymentId` match; the same
   `deploymentId` must resolve through `FundFactory.deployment(id)` to the exact eight Fund addresses and
   implementation version recorded by the manifest;
2. RPC receipts, block hashes, success statuses, contract coverage and runtime code hashes all match, and all five
   library transactions were sent by the approved `0x42cB…` bootstrap identity;
3. the coordinator was configured inactive before managed lane setup, with all phase receipts ordered;
4. Blockscout verification and bootstrap/final-role/standalone reconciliation are complete;
5. `ReconcileMetaWheelCanonical` passes against live Base Sepolia state, including exact fee/settler ownership,
   complete inactive `StrategyConfig`, minimum idle, exit escrows, all 4+4 lane bounds, covered-call execution
   buffers and every child adapter risk/router configuration; and
6. the candidate is accepted by the backend's exact `parse_fund_deployment` implementation.

Only after every gate passes does it write a new file with `status: CONFIRMED_CANONICAL_RECEIPTS`,
`deploymentStatus: DEPLOYED` and `handoffReady: true`. It refuses to overwrite the unconfirmed or an existing
canonical artifact. Required environment variables are:

```text
BASE_SEPOLIA_RPC_URL
B1N419_MANIFEST_PATH
B1N419_CANONICALIZATION_EVIDENCE_PATH
B1N419_LIBRARY_EVIDENCE_PATH
B1N419_CANONICAL_MANIFEST_PATH
B1N419_APPROVED_INPUTS_PATH
B1N419_APPROVED_INPUTS_SHA256
B1N419_SOURCE_COMMIT
B1N419_EXECUTION_CONTEXT (must be BASE_SEPOLIA_LIVE)
B1N419_BACKEND_ROOT
B1N419_BACKEND_PYTHON (optional; defaults to python3)
```

A fork/dry-run manifest and sidecar can never be used as deployment truth. No address, block or receipt may be
copied from fork output.

The fixtures run the generator identity-overlap gates and the full finalizer under the stock macOS `/bin/bash` 3.2
with deterministic receipts, transactions, linked calldata, negative identity/sender cases and backend parsing:

```text
script/fund/test-meta-wheel-input-generator-fixture.sh
script/fund/test-meta-wheel-finalizer-live-fixture.sh
```
