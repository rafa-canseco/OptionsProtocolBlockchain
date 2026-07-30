# B1N-394 Base Sepolia coordinated V2 upgrade

This runbook is testnet-only. It upgrades the live CSP and Covered Call Fund V2 proxies without
rewriting proxy storage and applies the B1N-393 fee policy.

## Safety model

The execution phase uses one `AccessManager.multicall` per fund. Each multicall:

1. pauses deposits, redemptions, and allocation;
2. upgrades the adapter before `StrategyManager`;
3. upgrades `FundAccounting`, `FundFlowManager`, and `StrategyManager`;
4. rebinds the replacement valuator in accounting and strategy configuration; and
5. configures 2% annual management fee and 10% performance fee without resetting the existing
   high-water mark.

The execution script leaves both funds paused. A separate finalizer requires a NAV whose snapshot
block is at or after the mined upgrade block before it can reopen deposits, redemptions, or
allocation. No permanent backend rollover stop is required.

The shared `CspBatchSettler.protocolFeeBps` is changed from 400 to 1,000. This also changes the V1
manual order path that uses the same settler.

## Required gates

- B1N-392 must be merged into `staging` at the exact source commit used for deployment.
- Run `forge clean && forge build` and all Fund V2 and storage-layout tests.
- Rehearse at the latest Base Sepolia block while both live positions are still open.
- Deploy fresh CSP and Covered Call operations libraries, then bind their exact addresses with
  `--libraries` when compiling/deploying the adapter implementations.
- Record implementation addresses, runtime code hashes, library bindings, deployment transactions,
  and blocks before touching a proxy.
- The broadcaster must hold immediate upgrader, adapter-upgrader, guardian, and curator roles in
  both access managers and must own the shared settler.
- If the broadcaster is rotated, grant and verify those roles and transfer settler ownership to the
  replacement address before deployment; revoke the legacy address only after the replacement
  authority has been reconciled on-chain.
- The backend NAV worker and both fair-value observation pipelines must be ready for the replacement
  valuator code.
- Rotate the exposed legacy signing credential before broadcast. Supply the replacement through a
  Foundry keystore/account or hardware wallet; these scripts never read a raw private key.

## Phases

1. Deploy the two operations libraries with `forge create`.
2. Run `DeployB1N394Implementations` with the new `--libraries` bindings. This phase does not touch
   proxies.
3. Populate the implementation environment fields and dry-run `ExecuteB1N394Upgrade` against the
   exact current block.
4. Broadcast `ExecuteB1N394Upgrade` only if the dry-run and state-drift check match. Record the mined
   block and the two pre-upgrade NAV nonces.
5. Wait for the normal reporter to commit a NAV for each fund whose snapshot block is at or after
   the upgrade block.
6. Dry-run and broadcast `FinalizeB1N394Upgrade`. Its on-chain preconditions fail closed if either
   NAV is stale, the fees differ, the adapter interface is not v2, or any expected binding differs.
7. Reconcile ERC-1967 implementation slots, roles, positions, Controller vaults, adapter ledgers,
   allocations, NAVs, fee recipients, high-water marks, treasury, and the shared premium fee.

No command in this directory authorizes a mainnet transaction.
