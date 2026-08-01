# Meta Wheel V2 — executable contract boundary

Canonical product specification: `docs/v2/META_WHEEL_ARCHITECTURE.md` in the
workspace root. This tracked contracts copy freezes the implementation boundary
used by B1N-414 and B1N-415.

## Custody topology

```text
USDC FundVault
  -> WheelCoordinatorAdapter
       -> bounded dedicated WheelCspChildLane instances
       -> bounded dedicated WheelCoveredCallChildLane instances
```

The coordinator is the only authorized child-lane controller. Existing
standalone CSP and Covered Call funds, adapters, proxies, shares, fees and
positions are never registered or modified.

The initial version supports four CSP and four Covered Call lanes, at most one
active option and one assignment lot per lane. Different tranches can run in
different legs concurrently. Adding multi-lot packing requires a later policy
and contract version.

If a child handoff returns USDC and WETH together, the WETH remains on the
original tranche and the exact USDC becomes a new sibling `PendingCsp` tranche.
The original tranche has `pendingUsdc == 0`, so the WETH can reopen a call while
the sibling independently enters a CSP lane.

## State machines

```text
PendingCsp -> CspOpen -> CspSettling
  -> PendingCsp (OTM)
  -> WethTransition (assigned)

WethTransition -> CallOpen -> CallSettling
  -> WethTransition (OTM/WETH returned)
  -> PendingCsp (called away to USDC)
```

Each transition is bound to the coordinator chain ID, address, tranche, state
nonce, lane and rolling position hash. Both coordinator and lane record the
transition hash before assets can be reused. Every handoff reconciles receiver
balance deltas and child shares.

## Assignment lot invariant

An assignment creates an immutable origin record with the exact observed WETH,
origin CSP lane/position and literal 8-decimal oToken strike. Only
`remainingWeth` and status change later.

For every Covered Call opening:

```text
requiredFloor8 = literalAssignmentStrike8 + floorBufferUsd8
callStrike8 >= requiredFloor8
```

The coordinator and dedicated Covered Call lane both enforce the check. Premium
income, average basis and keeper input cannot reduce the literal floor. There is
no normal or privileged path that sells transition WETH below it. If no valid
quote exists, WETH remains idle and redemptions wait for safe USDC liquidity.

## Accounting and NAV

Coordinator accounting includes only USDC/WETH physically in transition
custody. Child shares leave the transition domain before a lane opens and are
removed before the basket re-enters coordinator custody. Donations remain
unaccounted.

`MetaWheelValuator` accepts one hash/share-bound child valuation input per
active lane. It invokes the immutable canonical CSP or Covered Call valuator on
the lane's adapter, adds only exact accounted idle lane balances, converts WETH
components to USDC, and then adds coordinator USDC plus conservative
spot-valued transition WETH. Reporter-supplied gross assets, liabilities or
exit costs are never trusted. Child option liabilities already present in the
canonical child value are not duplicated. The report must use the current
block, exact lane position hashes and the full active lane set.

Canonical lane input ABI:

```text
LaneValuation(
  address lane,
  uint64 snapshotBlock,
  uint256 childShares,
  bytes32 positionHash,
  bytes valuationData
)
```

Parent FundAccounting is the sole authority for the 2% AUM and 10% HWM
performance fees. Dedicated children are configured with zero management and
performance fees. BatchSettler charges the gross-premium protocol fee once.

Upgrade validation is reproducible after `forge clean && forge build` with
`script/fund/validate-meta-wheel-upgrades.sh`. The Wheel Covered Call adapter
reuses its inherited initializer; its added ERC-7201 namespace contains only an
empty-by-default replay-protection mapping.

## Redemptions and recovery

Normal StrategyManager deallocation returns only pending/reserved USDC. It
cannot force a WETH sale. `deallocateInKind` is disabled for normal parent
redemptions. Emergency recovery may move raw USDC/WETH in kind to the governed
escrow only when no child lane has active shares; it never swaps WETH or weakens
the strike floor.

## Canonical reads

- `summary()`
- `tranche(uint256)`
- `assignmentLot(uint256)`
- `positionStateHash()`
- `policyHash()`
- `floorBufferUsd8()`
- `laneCaps()`
- `registeredLaneCount()` / `registeredLaneAt(uint256)`

## Canonical events

- `WheelTrancheQueued`
- `WheelSiblingTrancheQueued`
- `WheelTrancheOpened`
- `WheelPremiumAccrued`
- `WheelTrancheSettlementAdvanced`
- `WheelChildHandoff`
- `WheelAssignmentLotCreated`
- `WheelCoveredCallFloorEnforced`
- `WheelLotStatusChanged`
- `WheelRedemptionReserveChanged`
