# B1N-394 Base Sepolia coordinated V2 upgrade

This runbook is testnet-only. It upgrades the live CSP and Covered Call Fund V2 proxies without
rewriting proxy storage and applies the B1N-393 fee policy.

## Execution status

Completed on Base Sepolia on 2026-07-31 UTC. The deployed state is recorded in
`execution-record.json`.

- CSP and Covered Call use the audited B1N-392 implementations.
- A one-shot `FundAccounting` reinitializer reconciled the V2 adapter position-hash domain at the
  unchanged component nonce. Positions, allocation, idle assets, committed NAV, share supply, fee
  high-water marks, and pause state were preserved.
- Both V2 valuators expose the legacy `liabilityBufferBps() == 0` policy getter required by the
  staging reporter. This changes no valuation arithmetic or storage.
- The reporter committed post-upgrade NAVs for both funds before the finalizer reopened them.
- Deposits, redemptions, and allocation are active and both execution locks are clear.
- Governance, NAV reporting, and transaction operation now use three distinct credentials. The
  retired signer has no role in either AccessManager, is not a NAV reporter, is not a connected
  core owner/operator, treasury recipient, or whitelisted market maker, and has no remaining USDC,
  WETH, CSP-share, or Covered-Call-share balance.
- The immutable-owner test router was replaced across both adapters and the shared BatchSettler.
  The replacement router and Oracle use the same Base Sepolia Chainlink feed already pinned by both
  V2 valuators. The legacy router and test feed are disconnected. Both adapter configurations
  retain the same risk limits, fee tiers, position hashes, and manager positions hashes.
- Railway staging is healthy and has confirmed NAV reports signed by reporter-set version 2.

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

## Post-execution implementation set

| Component | Implementation / contract |
| --- | --- |
| FundAccounting, both proxies | `0xF50FFFB05B554082d73B5cdce54199856b42B291` |
| FundFlowManager, both proxies | `0xfc80b881f282EFC91B06fF5Fdb7F24F19D835d32` |
| StrategyManager, both proxies | `0xe8b39130E2aB6A8FfeCAc29e86A7A8092F2A953F` |
| CSP adapter implementation | `0x7D641877ED4E2c5f5ccb00727a4f7b43c28ad996` |
| Covered Call adapter implementation | `0x4e5154F49920d7BcE3953FC75a99d7A2831711C9` |
| CSP valuator | `0x8ecBA81832a9B6Bb07cd41bd098CaE3b883d5A17` |
| Covered Call valuator | `0x720e50472eb7AB5e4D57A54D6610Cb3f4A29d023` |
| Base Sepolia test swap router | `0x0Cd738d1F80FaDBbF6171280eD01Cfa33F8E17b3` |
| Shared ETH/USD feed | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` |

## Authority split

| Purpose | Address | Access |
| --- | --- | --- |
| Governance | `0x376a4c54623fe24D0Ffc1032D0b6CcC03A32fd7D` | Admin, upgrader, curator, guardian, adapter-upgrader; core/factory ownership; fee recipient |
| NAV reporter | `0x4EF525Ca8B42580782A12229df210eC8eee49E7b` | Reporter-set version 2 only |
| Operator | `0xEa99E3C48D68D1614d6454643135FD93e5cD18cE` | Core operator/partial-pauser and CSP accounting/allocator/processor roles |

The governance credential is stored in the ignored `.secrets/` keystore directory with its
password in the local macOS Keychain. Reporter and operator credentials are also backed by local
encrypted keystores; their active staging values are stored in Railway. No private key is recorded
in this directory.
