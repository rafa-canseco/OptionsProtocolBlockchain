# B1N-352 Base Sepolia deployment handoff

Status: **local artifacts only; no Base Sepolia deployment has been authorized or executed**.

This directory is the versioned handoff root for the first tokenized ETH/USDC CSP Fund deployment. Do not replace `null` manifest fields with assumed addresses. Populate them only from Foundry broadcast receipts and read-only reconciliation.

## Authorization gates

Before any command is run with `--broadcast`:

1. B1N-346 must provide an approved, versioned policy artifact and go decision.
2. `PreflightB1N352BaseSepolia` must confirm the selected V1 wiring, WETH/USDC product configuration, and `custodiedRedemptionOnly() == true`.
3. The approved AddressBook, Controller proxy, BatchSettler proxy, implementation addresses, and implementation
   codehashes must be supplied as expected values. Preflight and deployment fail before any broadcast if the live
   baseline differs.
4. A separate user approval is required before adding `--broadcast`, onboarding the adapter, or activating StrategyManager.
5. V1 onboarding additionally requires an approved smart-contract owner flow capable of checking the pinned baseline
   and invoking `setPhysicalDeliveryVault` atomically. The legacy direct-broadcast script is disabled and fails closed.

## Local checks

```bash
forge fmt --check
forge build
forge test --offline --match-path test/fund/B1N352Deployment.t.sol -vv
forge test --offline --match-path test/fund/StrategyAssetEscrow.t.sol -vv
./scripts/export-b1n-352-abis.sh
```

Read-only Base Sepolia preflight, once environment addresses are supplied:

```bash
forge script script/fund/PreflightB1N352BaseSepolia.s.sol:PreflightB1N352BaseSepolia \
  --rpc-url "$BASE_SEPOLIA_RPC_URL"
```

Deployment and governance scripts are deliberately split into phases. Every multi-operation schedule or execution is
one `FundAccessManager.multicall` transaction; scripts preflight the complete batch and refuse partial schedules:

1. `DeployTokenizedCspFundBaseSepolia`
2. `ScheduleB1N352Access` / wait 72h / `ExecuteB1N352Access`
3. `ScheduleB1N352Policy` / wait 24h / `ExecuteB1N352Policy` — strategy remains inactive
4. `PrepareB1N352AtomicOnboarding` — read-only baseline and calldata preparation; the approved owner flow performs
   the sole V1 mutation atomically. `OnboardB1N352Adapter` is intentionally disabled.
5. `ScheduleB1N352Activation` / wait 24h / `ExecuteB1N352Activation`. Activation calls only
   `resumeAllocation(adapter)`, so it cannot restore caps reduced by the guardian while waiting.
6. Wait until the access execution timestamp plus `AccessManager.minSetback()` (five days), then run
   `ReconcileB1N352Deployment`.

With access scheduled at T+0 and executed at T+72h, its `setTargetAdminDelay` changes do not become effective until
T+192h (approximately day 8). Policy execution around day 4 and activation around day 5 can still proceed under their
own delays, but strict reconciliation intentionally fails until the adapter and both strategy escrows report the final
target admin delay.

`ReconcileB1N352Deployment` is the final gate and always requires the adapter onboarded and the strategy active. Use
`ReconcileB1N352IntermediateDeployment` for explicit read-only inspection of a pre-onboarding or pre-activation state.
The final gate also verifies the exact registered adapter, role-member and configured-selector sets, every role admin
and guardian, open targets, full delays, factory bindings, and codehashes for the access manager, NAV verifier, claim
escrow, and linked adapter operations library.

Running any script without `--broadcast` is a simulation. Do not add `--broadcast` until the separate authorization recorded in B1N-352.

## Artifacts

- `manifest.template.json`: proxy, implementation, immutable, linked-library, config, and V1 hash schema.
- `access-manager-matrix.json`: effective role IDs, member execution delays, grant delays, and selector mapping.
- `transactions.template.json`: ordered transaction ledger.
- `reconciliation.template.json`: state and balance checkpoints.
- `events.json`: generated event ABI handoff.
- `abis/`: generated clean ABI arrays.
- `verification.md`: Blockscout verification checklist.
- `b1n352.env.example`: complete, secret-free environment variable inventory.
