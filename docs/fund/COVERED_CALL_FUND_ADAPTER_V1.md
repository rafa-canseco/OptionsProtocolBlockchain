# Covered Call Fund Adapter v1

## Accounting contract

The Covered Call Fund is ETH-in/ETH-out. WETH is the sole on-chain accounting,
deposit, and shareholder-redemption asset.

USDC received as option premium or physical-delivery strike proceeds is transient
strategy inventory. It must be normalized to WETH before any normal redemption
can return assets to the fund. A normal or in-kind shareholder exit never returns
USDC.

An emergency strategy exit may quarantine unresolved USDC in the authorized
emergency escrow. This is an operational recovery path, not a mixed shareholder
claim.

## Contracts

- `CoveredCallFundAdapter`: upgradeable strategy boundary owned by one fund.
- `CoveredCallFundAdapterOperations`: linked execution module for settlement,
  onboarding checks, and bounded USDC-to-WETH normalization.
- `CoveredCallFundValuator`: immutable WETH-denominated valuation policy.
- `ICoveredCallFundAdapter`: allocator and backend ABI.
- `ICoveredCallFundValuator`: signed option-liability observation ABI.

`interfaceVersion()` returns `1` on both adapter and valuator.

## Allocator calls

### Open a covered call

Call:

```solidity
allocate(weth, collateral, abi.encode(OpenPositionData))
```

`OpenPositionData` contains the signed `BatchSettler.Quote`, maker signature,
8-decimal oToken amount, and 18-decimal WETH collateral.

The adapter accepts only call series with:

- WETH underlying
- USDC strike asset
- WETH collateral
- expiry, strike, premium, utilization, position count, and collateral within
  configured bounds

An open is fail-closed unless the adapter is authorized for physical delivery
and every required v1 protocol endpoint and whitelist entry is configured.

### Settle

Call:

```solidity
deallocate(targetValue, minWethOut, abi.encode(DeallocateData({
    action: DeallocateAction.Settle,
    positionId: positionId,
    amount: 0,
    minAmountOut: 0
})))
```

For an OTM expiry, one call closes the position and restores WETH collateral.

For an ITM expiry, the first call moves the position to
`AwaitingPhysicalDelivery`. After the BatchSettler operator completes physical
delivery, a second call records the called-away USDC. If delivery remains
incomplete after `settlementDefaultDelay`, the second call uses the WETH fallback
and pays the market maker the rounded-up intrinsic value in WETH.

### Normalize USDC

After all positions are terminal, call:

```solidity
deallocate(targetValue, minWethOut, abi.encode(DeallocateData({
    action: DeallocateAction.NormalizeUsdc,
    positionId: 0,
    amount: usdcAmount,
    minAmountOut: minimumWethOut
})))
```

The minimum must be at least the oracle-derived policy floor. The swap is capped
by `maxUsdcPerSwap`, bounded by `maxSwapSlippageBps`, and reconciled from observed
token balance deltas. The adapter can return WETH to the fund in the same call
once no active position or accounted USDC remains.

### Return idle WETH

Use `DeallocateAction.ReturnIdle`. It succeeds only when every position is
terminal and accounted USDC is zero.

### In-kind and emergency exits

`deallocateInKind` returns one asset only: WETH. It rejects unresolved USDC.

`emergencyExit` may transfer both accounted WETH and accounted USDC to the
authorized emergency escrow after all positions are terminal.

## Lifecycle

```text
None -> Open
Open -> SettledOtm
Open -> AwaitingPhysicalDelivery -> CalledAway
Open -> AwaitingPhysicalDelivery -> CashFallback
```

Terminal positions cannot be settled twice. New positions cannot open while
transient accounted USDC remains unresolved.

## Backend event contract

- `PositionOpened`: persist `positionId`, protocol vault, oToken, market maker,
  amount, collateral, premium, and lifecycle hash.
- `PositionTransitioned`: update lifecycle and record WETH/USDC/MM payout deltas.
- `UsdcNormalized`: record transient USDC consumed and WETH produced.
- `AccountingAssetsReturned`: record WETH returned to the fund.
- `UnaccountedAssetIsolated`: flag token donations excluded from fund accounting.
- `RawAssetsRecovered`: distinguish WETH-only in-kind recovery from emergency
  quarantine with its `emergency` flag.
- `AdapterConfigUpdated`: invalidate cached execution bounds.

Backends should reconcile event state against `adapterState()`, `position(id)`,
and `positionStateHash()`. The state hash includes raw WETH/USDC balances, so an
unexpected donation invalidates previously signed valuation observations without
adding the donation to NAV.

## Valuation

All `FundTypes.PositionValue` amounts are WETH-denominated:

- `grossAssets`: accounted idle WETH, accounted USDC converted at fresh spot,
  and locked WETH collateral
- `liabilities`: conservative signed option liability with configured buffer
- `liquidAccountingAssets`: nonzero only when no active position and no
  accounted USDC remain
- `baseExitCost`: signed close cost plus conservative USDC normalization cost

Pre-expiry active positions require the configured quorum of unique approved
observers, including at least one observer other than the position market maker.
The valuator rejects stale spot data, stale or mismatched observations, ledger
inconsistency, accounting deficits, and pending physical delivery.
