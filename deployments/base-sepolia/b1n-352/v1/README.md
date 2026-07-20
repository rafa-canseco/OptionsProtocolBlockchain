# B1N-352 Base Sepolia deployment handoff

Status: **local artifacts only; no Base Sepolia deployment has been authorized or executed**.

This directory is the versioned handoff root for the first tokenized ETH/USDC CSP Fund deployment. Do not replace `null` manifest fields with assumed addresses. Populate them only from Foundry broadcast receipts and read-only reconciliation.

## Authorization gates

Before any command is run with `--broadcast`:

1. B1N-346 must provide an approved, versioned policy artifact and go decision.
2. `PreflightB1N352BaseSepolia` must confirm the selected V1 wiring, WETH/USDC product configuration, and `custodiedRedemptionOnly() == true`.
3. The approved proxy, implementation, and implementation codehash for AddressBook, Controller, MarginPool,
   OTokenFactory, Oracle, Whitelist, and BatchSettler must be supplied as expected values. The approved current and
   pending owners are also mandatory for AddressBook, Controller, Oracle, Whitelist, and BatchSettler. MarginPool and
   OTokenFactory inherit their authority from AddressBook, so their wiring is pinned instead of inventing duplicate
   owner checks. Preflight and deployment fail before any broadcast if any live V1 component differs.
4. A separate user approval is required before adding `--broadcast`, onboarding the adapter, or activating StrategyManager.
5. V1 onboarding additionally requires an approved smart-contract owner flow capable of checking the pinned baseline
   and invoking `setPhysicalDeliveryVault` atomically. The legacy direct-broadcast script is disabled and fails closed.
6. The exact SHA-256 of `deployment-inputs.approved.json` must be recorded outside that file in the B1N-352 approval
   and copied into the manifest. Every Base Sepolia script recomputes it before doing any work.

## Approved input workflow

`deployment-inputs.approved.template.json` is the single non-secret source for deployment configuration, the B1N-346
policy digest, V1 baselines and ownership, the planned linked-library address, and both expected runtime codehashes.
Scripts parse those values directly from the digest-bound JSON; the generated `.env` contains only its path and digest,
so it cannot diverge into a second configuration source. Populate numeric configuration values as JSON numbers and
address lists as JSON arrays.

1. Copy the template to a versioned `deployment-inputs.approved.json`, populate it from the approved source commit and
   B1N-346 artifact, and obtain the planned `CspFundAdapterOperations` address from a no-broadcast simulation.
2. Run `npm run b1n352:inputs:derive -- <approved-json>`. Copy the two derived hashes back into the JSON. The adapter
   derivation patches both exact Foundry link references with the approved library address before hashing.
3. Set `approval.status` to `APPROVED`, record approver/time, calculate the exact-file SHA-256, and record that digest
   separately in Linear and `manifest.json`. Changing even whitespace invalidates the digest.
4. Run `npm run b1n352:inputs:check -- <approved-json> <approved-sha256>`. This verifies the source tree against the
   approved commit, compiler settings, complete library linkage, both runtime hashes, and the external digest.
5. Generate the non-secret environment with
   `node scripts/prepare-b1n-352-inputs.mjs env <approved-json> <approved-sha256>`. Add RPC URL and private key only in
   the operator's secret environment.

## Local checks

```bash
forge fmt --check
forge build
forge test --offline --match-path test/fund/B1N352Deployment.t.sol -vv
forge test --offline --match-path test/fund/StrategyAssetEscrow.t.sol -vv
npm run b1n352:inputs:test
npm run b1n352:inputs:template
./scripts/export-b1n-352-abis.sh
```

Read-only Base Sepolia preflight, once environment addresses are supplied:

```bash
forge script script/fund/PreflightB1N352BaseSepolia.s.sol:PreflightB1N352BaseSepolia \
  --rpc-url "$BASE_SEPOLIA_RPC_URL"
```

Deployment and governance scripts are deliberately split into phases. Every multi-operation schedule, cancellation,
or execution is one `FundAccessManager.multicall` transaction; scripts preflight the complete batch and refuse partial
schedules:

1. `DeployTokenizedCspFundBaseSepolia`
2. `ScheduleB1N352Access` / wait 72h / `ExecuteB1N352Access`
3. `ScheduleB1N352Policy` / wait 24h / `ExecuteB1N352Policy` — strategy remains inactive
4. `PrepareB1N352AtomicOnboarding` — read-only baseline and calldata preparation; the approved owner flow performs
   the sole V1 mutation atomically. `OnboardB1N352Adapter` is intentionally disabled.
5. `ScheduleB1N352Activation` / record the emitted `FUND_SCHEDULED_ALLOCATION_PAUSE_NONCE` / wait 24h /
   `ExecuteB1N352Activation`. Activation calls only `resumeAllocation(adapter, scheduledPauseNonce)`, so it cannot
   restore caps reduced by the guardian and cannot override a later guardian pause or emergency exit.
6. Wait until the access execution timestamp plus `AccessManager.minSetback()` (five days), then run
   `ReconcileB1N352Deployment`.

Each normal schedule and execute command is idempotent after the complete expected phase state is present. A normal
schedule refuses any phase whose operation IDs have already been executed or canceled. If a guardian cancels one or
more operations, use the matching `RestartB1N352*` command: one atomic multicall cancels every remaining live schedule
and reschedules the complete phase with incremented nonces. Use `CancelB1N352Access`, `CancelB1N352Policy`, or
`CancelB1N352Activation` only to abort a phase without restarting it. Set `FUND_PHASE_SCHEDULER` in the approved-input
JSON to the address that originally scheduled the phase. Normal schedule, execute, and restart commands require
`PRIVATE_KEY` to derive that same address, which binds nonce history to one operator. A standalone cancel may instead
use a guardian/admin key.
Activation cancel/execute additionally use the recorded `FUND_SCHEDULED_ALLOCATION_PAUSE_NONCE`. If a guardian pause
or emergency exit increments it, execution fails closed; `RestartB1N352Activation` atomically cancels the old operation
and schedules one bound to the current nonce. That restart is an explicit new activation decision after the pause.

With access scheduled at T+0 and executed at T+72h, its `setTargetAdminDelay` changes do not become effective until
T+192h (approximately day 8). Policy execution around day 4 and activation around day 5 can still proceed under their
own delays, but strict reconciliation intentionally fails until the adapter and both strategy escrows report the final
target admin delay.

`ReconcileB1N352Deployment` is the final gate and always requires the adapter onboarded and the strategy active. Use
`ReconcileB1N352IntermediateDeployment` for explicit read-only inspection of a pre-onboarding or pre-activation state.
The final gate also verifies the approved-input digest, all five independent V1 ownership domains, the exact registered
adapter, role-member and configured-selector sets, every role admin
and guardian, open targets, full delays, factory bindings, and codehashes for the access manager, NAV verifier, claim
escrow, linked adapter operations library, and the complete linked adapter implementation runtime bytecode. The last
check covers every library link reference, not merely one embedded address occurrence. The expected hash is derived
before broadcast from the approved build and planned library address; deployment output is only an actual-value receipt.

Running any script without `--broadcast` is a simulation. Do not add `--broadcast` until the separate authorization recorded in B1N-352.

## Artifacts

- `manifest.template.json`: proxy, implementation, immutable, linked-library, config, and V1 hash schema.
- `deployment-inputs.approved.template.json`: single-source approved deployment inputs and release trust anchors.
- `access-manager-matrix.json`: effective role IDs, member execution delays, grant delays, and selector mapping.
- `transactions.template.json`: ordered transaction ledger.
- `reconciliation.template.json`: state and balance checkpoints.
- `events.json`: generated event ABI handoff.
- `abis/`: generated clean ABI arrays.
- `verification.md`: Blockscout verification checklist.
- `b1n352.env.example`: complete, secret-free environment variable inventory.
