# Static Analysis Report — b1nary Options Protocol

**Date:** 2026-02-28
**Tools:** Slither v0.11.5 (101 detectors), Aderyn v0.1.9 (63 detectors)
**Scope:** All 8 core contracts in `src/core/`
**Delta from:** B1N-83 (initial audit), after B1N-99 + B1N-101

## Result: Zero new critical/high findings

Changes from B1N-83:
- betaMode findings removed (function deleted in B1N-99)
- New `setPartialPauser` missing-zero-check (low, intentional)
- New `emergencyWithdrawVault` reentrancy-events (informational)
- New `Controller.mintOtoken` timestamp (expected — expiry check)

## High Severity (3 — All False Positives)

### H-1: arbitrary-send-erc20 (3 instances)

Slither flags `safeTransferFrom` with non-`msg.sender` `from`.

| Location | Justification |
|----------|---------------|
| `BatchSettler._redeemSingle` | operator-only; `from` = caller |
| `BatchSettler._redeemAndSwap` | operator-only; `from` = operator |
| `MarginPool.transferToPool` | controller-only; `from` = vault owner |

**Verdict:** All false positives. Access control prevents arbitrary
callers.

## Medium Severity (4 — 3 FP, 1 documented)

### M-1: reentrancy-balance (FP)

`_redeemAndSwap` balance delta pattern. `ctrl.redeem` is
non-reentrant. False positive.

### M-2: uninitialized-state (FP)

`Controller.vaults` mapping. Solidity mappings implicitly initialized.

### M-3: incorrect-equality (documented)

`collateralReceived == 0` in `_redeemAndSwap`. Intentional — OTM
options return 0 collateral, skip swap.

### M-4: reentrancy-no-eth (FP)

`OTokenFactory.createOToken` state after `init()`. `init()` has
initializer guard, no re-init possible.

## Low Severity (7 — no action needed)

### L-1: unused-return (2 instances)

ECDSA padding byte + Chainlink non-answer fields. Expected.

### L-2: events-maths (2 instances)

`setProtocolFeeBps`/`setSwapFeeTier` missing events. Events were
added in B1N-83 on main but not carried to dev. Will be resolved on
merge.

### L-3: events-access (1 instance)

`OToken.init` controller write. Factory emits `OTokenCreated`.

### L-4: missing-zero-check (5 instances, 1 new)

4 × OToken.init params (factory validates). 1 × **NEW:**
`Controller.setPartialPauser` — intentional, `address(0)` revokes
the role.

### L-5: naming-convention

Underscore prefix is project convention. Consistent.

### L-6: calls-loop (3 instances)

Batch operations by design. Try/catch on each item.

### L-7: nonReentrant ordering

`physicalRedeem` modifier order. No security impact.

## Informational (5)

### I-1: unused-state (__gap arrays)

UUPS storage gaps. Required by upgrade pattern.

### I-2: immutable-states (OToken._creator)

~2,100 gas savings, not worth audit risk.

### I-3: reentrancy-events (8 instances, includes new emergencyWithdrawVault)

Events after external calls. State mutations happen before calls;
events are cosmetic.

### I-4: timestamp (6 instances, includes new mintOtoken expiry check)

Block timestamp for deadlines/expiries. Expected for options protocol.

### I-5: cyclomatic-complexity (1 instance)

`_executePhysicalRedeem` = 12. Inherent to PUT+CALL physical delivery.

## Aderyn-Specific (4 High, 9 Low)

All Aderyn "High" findings are false positives matching Slither H-1
through M-2 above. See triage there. Aderyn Low findings match
Slither L-1 through L-7.

## Fixes Applied (B1N-100)

1. **Restored expiry check** in `Controller.mintOtoken` —
   `if (block.timestamp >= oToken.expiry()) revert OptionExpired()`
   regression from B1N-99 betaMode removal.

2. **Updated access control invariant** — `setBetaMode` replaced with
   `setPartialPauser` in `tryUnauthorizedCall`.
