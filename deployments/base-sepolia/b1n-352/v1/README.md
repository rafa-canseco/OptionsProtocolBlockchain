# B1N-352 Base Sepolia deployment handoff

Status: **local artifacts only; no Base Sepolia deployment has been authorized or executed**.

This directory is the versioned handoff root for the first tokenized ETH/USDC CSP Fund deployment. Do not replace `null` manifest fields with assumed addresses. Populate them only from Foundry broadcast receipts and read-only reconciliation.

## Authorization gates

Before any command is run with `--broadcast`:

1. B1N-346 must provide an approved, versioned policy artifact and go decision.
2. `PreflightB1N352BaseSepolia` must confirm the selected V1 wiring, WETH/USDC product configuration, and `custodiedRedemptionOnly() == true`.
3. Controller and BatchSettler implementation addresses and codehashes must be captured before any permitted onboarding call.
4. A separate user approval is required before adding `--broadcast`, onboarding the adapter, or activating StrategyManager.

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

Deployment and governance scripts are deliberately split into resumable phases:

1. `DeployTokenizedCspFundBaseSepolia`
2. `ScheduleB1N352Access` / wait 72h / `ExecuteB1N352Access`
3. `ScheduleB1N352Policy` / wait 24h / `ExecuteB1N352Policy` — strategy remains inactive
4. `OnboardB1N352Adapter` — the only permitted V1 mutation
5. `ScheduleB1N352Activation` / wait 24h / `ExecuteB1N352Activation`
6. `ReconcileB1N352Deployment`

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
