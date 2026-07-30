# B1N-394 Base Sepolia active-position upgrade rehearsal

## Scope

This rehearsal proves that the Fund V2 changes from B1N-392 can be applied to
the currently deployed CSP and Covered Call proxies without first closing their
active positions. It does not broadcast any transaction.

The fork is pinned to Base Sepolia block `44,811,440`. At that block:

- CSP position `3` is open with `3,142.399992 USDC` of collateral.
- Covered Call position `1` is open with `1.25 WETH` of collateral and
  `2.663309 USDC` of accounted premium.
- Both positions expire at `2026-07-31 08:00 UTC`.
- Both funds have no active redemption processing or execution lock.

The executable evidence is
`test/fund/B1N394ActivePositionUpgradeFork.t.sol`.

## Rehearsed upgrade order

The test deploys new implementations locally on the fork and changes only
fork-local proxy implementation slots:

1. CSP adapter.
2. Covered Call adapter.
3. CSP FundAccounting, FundFlowManager, and StrategyManager.
4. Covered Call FundAccounting, FundFlowManager, and StrategyManager.

Adapters are upgraded before StrategyManager because the new manager requires
`deallocationInterfaceVersion() == 2`.

The production execution must not allow an allocator transaction to interleave
between these incompatible steps. This can be achieved with an atomic execution
bundle or a short execution-level maintenance gate. A permanent backend
rollover stop is not required.

## Preservation assertions

Before and after the implementation changes, the test hashes and compares:

- the complete live adapter position;
- adapter state and risk configuration;
- the Controller margin vault;
- StrategyManager allocation and strategy configuration;
- fund idle assets, committed NAV, and execution lock;
- raw adapter USDC and WETH balances;
- accounting report nonce; and
- pending and claimable redemption totals.

The position tuples and all financial state remain unchanged. The adapter
`positionStateHash()` changes intentionally because B1N-392 adds the
append-only `releasablePrincipal` field to its hash domain. The corresponding
NAV must therefore be replaced after production execution.

## Expiry branches

The rehearsal advances past expiry and covers all relevant terminal outcomes:

1. CSP OTM and Covered Call OTM at `$1,800`.
2. CSP OTM and Covered Call ITM cash fallback at `$2,100`.
3. CSP ITM cash fallback and Covered Call OTM at `$1,600`.

For Covered Call settlement, accounted USDC is normalized back to WETH through
the deployed Base Sepolia mock router. Each branch verifies that:

- the active-position count reaches zero;
- the adapter ledgers are emptied;
- StrategyManager allocation reaches zero through V2 principal-release
  accounting;
- the fund receives the returned accounting asset;
- NAV is invalidated; and
- no execution lock remains.

## Post-expiry rollover

After each terminal branch, the rehearsal:

- whitelists a fork-only market maker;
- creates owner-bound EIP-712 quotes using the deployed isolated
  `CspBatchSettler` domain;
- creates the next put and call series;
- opens CSP position `4`; and
- opens Covered Call position `2`.

This proves that settlement under the upgraded code does not strand principal
or prevent the normal next-position flow.

## Run

```bash
cd blockchain
forge test --match-contract B1N394ActivePositionUpgradeForkTest -vv
```

`BASE_SEPOLIA_RPC_URL` is optional. The test defaults to
`https://sepolia.base.org` and always pins block `44,811,440`.

## Production prerequisites not performed by this rehearsal

- Reconcile the CSP proxy's actual implementation
  `0x0d8AcE03650C5212658d544A4aDe7987f7F3d475` with the stale checked-in
  deployment baseline.
- Validate and deploy the final linked libraries and valuators.
- Execute the upgrade without interleaved allocator transactions.
- Rebind any replaced valuator and submit a fresh NAV.
- Apply and verify the B1N-393 fee configuration.
- Update deployment manifests with the final implementations and code hashes.
