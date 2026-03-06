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

---

## Delta Report — B1N-122 (2026-03-05)

**Tools:** Slither v0.11.5 (101 detectors), security profile forge test
**Scope:** Delta review on code changed since B1N-83/B1N-124

### Result: Zero new critical/high findings on core contracts

Re-run produced 6 High, 9 Medium, 30 Low, 160 Informational.
Comparing to B1N-83:

- **+1 High:** `arbitrary-send-erc20` in `MockAavePool` (mock only,
  not deployed). No action.
- **+2 reclassified:** `reentrancy-balance` and `uninitialized-state`
  moved from Medium to High by Slither version. Same FPs as B1N-83.
- **+1 Medium:** `locked-ether` in `MockSwapRouter` (mock only).
- **+4 Medium:** `unused-return` in OZ library internals. Not our code.

All core contract findings identical to B1N-83.

### Invariants (security profile)

All 301 tests passed (5 invariants at 1000 runs / 100,000 calls each):

- `invariant_poolCoversObligations`
- `invariant_poolBalanceMatchesDeposits`
- `invariant_oTokenSupplyMatchesMinted`
- `invariant_vaultCountConsistent`
- `invariant_batchRedeemNeverRevertsCompletely`

### Fork Tests (Base mainnet, block 42733000)

9/9 tests passed against real Aave V3, Uniswap V3, Chainlink, WETH,
USDC on Base mainnet:

- Premium delivery: user receives 48 USDC net, treasury 2 USDC fee
- OTM PUT: full USDC collateral returned
- OTM CALL: full WETH collateral returned
- ITM PUT physical delivery: exact 1e18 WETH to user via flash loan
- ITM CALL physical delivery: exact 1800e6 USDC to user via flash loan
- Surplus USDC goes to MM (operator), not user
- ITM PUT redeem: MM receives full collateral
- Flash loan callback rejects unauthorized callers

### Deploy Script Fixes (Deploy.s.sol)

1. `SWAP_FEE_TIER` default changed from 500 to 3000 (0.3% pool)
2. Added `_configureOracleSafety()` — sets `priceDeviationThresholdBps`
   (default 1000 = 10%) and `maxOracleStaleness` (default 3600 = 1h)
3. Added `controller.setPartialPauser(operator)` for circuit breaker
4. Removed hardcoded "Base Sepolia" references from NatSpec/logs
5. Fork test `swapFeeTier` updated from 500 to 3000
