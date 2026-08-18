# Strategy deallocation interface v2

`IFundStrategyAdapter.deallocate` returns two values:

```solidity
(uint256 accountingAssetsOut, uint256 principalReleased)
```

`accountingAssetsOut` must equal the accounting-asset balance delta observed by
the fund. `principalReleased` is bounded by the requested target and may exceed
the observed return only within the strategy's configured `maxLossBps`.
Earnings may leave an adapter without reducing its allocation counter.

Adapters retain `interfaceVersion() == 1` for historical valuator and accounting
compatibility. `deallocationInterfaceVersion() == 2` is the explicit signal for
the two-word return ABI. StrategyManager validates this marker during strategy
configuration and immediately before every normal deallocation.

## Upgrade sequence

For an existing fund:

1. Pause deposits and strategy allocation.
2. Confirm there is no active redemption batch and no active option position.
3. Reconcile adapter assets, StrategyManager allocation counters, and the latest
   position state hash.
4. Upgrade each configured adapter first and verify
   `deallocationInterfaceVersion() == 2`.
5. Upgrade StrategyManager and re-run strategy configuration preflight.
6. Commit a fresh NAV before reopening deposits or allocation.

Do not upgrade StrategyManager ahead of a legacy one-word adapter. A v2 manager
rejects an adapter that does not expose the explicit deallocation ABI marker.
