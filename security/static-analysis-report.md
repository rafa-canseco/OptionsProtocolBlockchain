# Static Analysis Report — B1N-83

**Date:** 2026-02-27
**Tools:** Slither v0.10.x (101 detectors), Aderyn v0.1.9 (63 detectors)
**Scope:** All 8 core contracts in `src/core/`
**Contracts analyzed:** AddressBook, BatchSettler, Controller, MarginPool, OToken, OTokenFactory, Oracle, Whitelist

---

## Summary

| Severity | Found | Fixed | False Positive | Documented |
|----------|-------|-------|----------------|------------|
| High | 3 | 0 | 3 | 0 |
| Medium | 5 | 0 | 3 | 2 |
| Low | 5 | 2 | 0 | 3 |
| Informational | 3 categories | 0 | 3 | 0 |

**Zero critical/high findings remaining.** All high-severity detections are false positives with clear justification.

---

## High Severity

### H-1: arbitrary-send-erc20 (FALSE POSITIVE)

**Detector:** `arbitrary-send-erc20`
**Locations:**
- `BatchSettler._redeemSingle()` — `IERC20(oToken).safeTransferFrom(caller, ...)`
- `BatchSettler._redeemAndSwap()` — `IERC20(oToken).safeTransferFrom(operator, ...)`
- `MarginPool.transferToPool()` — `IERC20(_asset).safeTransferFrom(_from, ...)`

**Verdict:** False positive. All three are access-controlled:
- `_redeemSingle`: `caller` is always `msg.sender` from `batchRedeem()` (L387)
- `_redeemAndSwap`: `operator` is a storage variable, called within `nonReentrant` + flash loan callback with `initiator == address(this)` check
- `transferToPool`: has `onlyController` modifier; Controller passes `msg.sender` (L120)

Slither cannot trace data flow across function boundaries. No action needed.

---

## Medium Severity

### M-1: reentrancy-balance (FALSE POSITIVE)

**Detector:** `reentrancy-balance`
**Location:** `BatchSettler._redeemAndSwap()` (L451-489)

Reads `collateralBefore` balance, calls `ctrl.redeem()` (external), then checks received amount.

**Verdict:** False positive. The entire physical redeem flow is guarded by `nonReentrant`. The `executeOperation` callback validates `msg.sender == aavePool` and `initiator == address(this)`. No reentrancy path exists.

### M-2: uninitialized-state (FALSE POSITIVE)

**Detector:** `uninitialized-state`
**Location:** `Controller.vaults` (L38)

**Verdict:** False positive. `vaults` is a mapping — Solidity mappings are implicitly initialized. Access is gated by `_getVault()` which checks `_vaultId > 0 && _vaultId <= vaultCount[_owner]`.

### M-3: incorrect-equality (DOCUMENTED)

**Detector:** `incorrect-equality`
**Location:** `BatchSettler._redeemAndSwap()` — `collateralReceived == 0` (L467)

**Verdict:** Intentional design. If redeem returns zero collateral, the option is OTM and physical delivery should not proceed. Strict equality is correct here — any non-zero amount means collateral was received. The `RedeemReturnedZero` error provides a clear revert reason.

### M-4: reentrancy-no-eth (FALSE POSITIVE)

**Detector:** `reentrancy-no-eth`
**Location:** `OTokenFactory.createOToken()` — writes `getOToken[paramsHash]` after `oToken.init()` (L91)

**Verdict:** False positive. The `init()` call targets a freshly deployed contract (via CREATE2) that uses the `initializer` modifier — it can only be called once. No reentrancy path exists.

### M-5: Oracle Chainlink staleness (DOCUMENTED — NOT A SLITHER FINDING)

**Location:** `Oracle.getPrice()` (L91-99)

The function calls `latestRoundData()` but only uses `answer`, ignoring `updatedAt` and `answeredInRound`. This means stale prices could be returned if the Chainlink feed stops updating.

**Mitigation:** `getPrice()` is only used for live price display (frontend/backend bots). Settlement uses `expiryPrice` which is set explicitly by the operator. Impact is limited to showing stale live prices, not affecting settlement correctness. For mainnet, consider adding a staleness threshold parameter if `getPrice` is ever used in settlement paths.

---

## Low Severity

### L-1: unused-return (NO ACTION)

**Locations:**
- `BatchSettler.executeOrder()` — ignores third return from `ECDSA.tryRecover()` (padding byte, not needed)
- `Oracle.getPrice()` — ignores Chainlink staleness fields (see M-5 above)

### L-2: events-maths (FIXED)

**Locations:**
- `BatchSettler.setProtocolFeeBps()` — missing event for fee change
- `BatchSettler.setSwapFeeTier()` — missing event for tier change

**Fix:** Added `ProtocolFeeBpsUpdated` and `SwapFeeTierUpdated` events with old/new values.

### L-3: events-access (NO ACTION)

**Location:** `OToken.init()` — no event for controller assignment

**Verdict:** OToken is deployed once per series via OTokenFactory. The controller is set at init and never changes. The factory emits `OTokenCreated` which includes the oToken address. Low value to add another event.

### L-4: missing-zero-check (NO ACTION)

**Location:** `OToken.init()` — parameters `_underlying`, `_strikeAsset` not zero-checked

**Verdict:** OToken is only created by OTokenFactory, which validates all parameters before deployment. Direct init calls are prevented by the `initializer` modifier after first call.

---

## Informational

### I-1: naming-convention (NO ACTION)

All contracts use underscore-prefixed parameters (`_asset`, `_owner`, etc.). This is a deliberate project convention and consistent across all contracts.

### I-2: unused-state — `__gap` arrays (NO ACTION)

All upgradeable contracts have `uint256[N] private __gap` arrays. These are intentional UUPS upgrade storage gaps per OpenZeppelin best practices.

### I-3: immutable-states (NO ACTION)

`OToken._creator` could be declared `immutable`. OToken is non-upgradeable and deployed per series, so gas savings are minimal (~2,100 gas on reads). Not worth changing deployed contract pattern.

---

## Upgradeability Check

Ran `slither-check-upgradeability` on Controller. Result: 1 informational finding — "needs to be initialized by Controller.initialize()". This is expected UUPS behavior. No upgradeability issues detected.

---

## Aderyn Results

Ran Aderyn v0.1.9 (63 detectors). Full report saved to `report.md`.

### Aderyn Highs (all triaged)

| # | Finding | Verdict |
|---|---------|---------|
| H-1 | Arbitrary `from` in transferFrom (6 instances) | FALSE POSITIVE — same as Slither H-1, all access-controlled |
| H-2 | Unprotected initializer (OToken.init) | FALSE POSITIVE — protected by `OnlyCreator` + `AlreadyInitialized` guards (L52-54). Aderyn doesn't recognize custom init patterns. |
| H-3 | Uninitialized state (BatchSettler.batchNonce) | FALSE POSITIVE — uint256 defaults to 0, which is correct initial value |
| H-4 | Contract locks Ether (MockSwapRouter) | N/A — mock contract, not deployed to production |

### Aderyn Lows (actionable fixes applied)

| # | Finding | Action |
|---|---------|--------|
| L-1 | Centralization risk (31 owner functions) | DOCUMENTED — inherent to protocol design. Owner is multisig pre-mainnet. |
| L-2 | Missing address(0) checks (OToken.init) | NO ACTION — factory validates params before deployment |
| L-3 | public → external (5 functions) | NO ACTION — `physicalRedeem` is public intentionally (called by batchPhysicalRedeem). OToken name/symbol/decimals are ERC20 overrides. |
| L-4 | Magic literals (1e10, 10000) | NO ACTION — decimal scaling constants are clearer as literals in this codebase |
| L-5 | Missing indexed event fields (17 events) | NO ACTION — indexing adds gas cost. Core events (OrderExecuted, VaultSettled) already index the right fields. |
| L-6 | nonReentrant modifier should come first | **FIXED** — reordered `physicalRedeem` modifiers to `nonReentrant onlyOperator` |
| L-7 | Empty block (_authorizeUpgrade) | NO ACTION — standard UUPS pattern, authorization is via onlyOwner modifier |
| L-8 | Large literals → scientific notation | NO ACTION — 10000 as BPS denominator is conventional |
| L-9 | Unused custom error (AssetNotWhitelisted) | **FIXED** — removed from OTokenFactory |

---

## Fixes Applied

1. **BatchSettler**: Added `ProtocolFeeBpsUpdated` and `SwapFeeTierUpdated` events (Slither L-2)
2. **BatchSettler**: Reordered `physicalRedeem` modifiers — `nonReentrant` before `onlyOperator` (Aderyn L-6)
3. **OTokenFactory**: Removed unused `AssetNotWhitelisted` error (Aderyn L-9)

All 242 tests pass after fixes.
