# B1N-139: Security Audit Round 2 -- Cross-Reference Report

Three independent scans, findings deduplicated and triaged.

## Sources

| Source | Tool | Mode | Duration |
|---|---|---|---|
| Pashov Agent | solidity-auditor | DEEP (full + adversarial on BatchSettler) | ~5 min |
| NEMESIS Agent | nemesis-auditor | Full pipeline (background) | ~6.5 min |
| NEMESIS Main | nemesis-auditor | Full pipeline (foreground, manual) | inline |

---

## B1N-136 Regression Check (all sources agree)

| # | Previous Finding | Status |
|---|---|---|
| 1 | Undercollateralized minting via repeated mintOtoken | FIXED (Controller.sol L178) |
| 2 | Chainlink staleness check missing | FIXED (Oracle.sol L104-107, L146-149) |
| 3 | Missing deadline on Uniswap swap | PERSISTS as INFORMATIONAL |
| 4 | Fee-on-transfer accounting | PERSISTS as INFORMATIONAL |
| 5 | Emergency withdrawal unbacked claims | PARTIALLY MITIGATED (gap remains) |

---

## Cross-Reference Matrix

| Finding | Pashov | NEMESIS BG | NEMESIS Main | Consensus Severity | Action |
|---|---|---|---|---|---|
| Emergency withdrawal pool insolvency | -- | NM-001 MED | NM-002 LOW | **MEDIUM** | Fix before deploy |
| Premature expiry price locking | -- | NM-002 MED | -- | **MEDIUM** | Fix before deploy |
| _calculatePayout binary payout | #3 [85] "bug" | FP-5 eliminated | SOUND (by design) | **FALSE POSITIVE** | No action |
| No withdrawCollateral function | -- | -- | NM-006 LOW | **LOW** | Fix (easy) |
| L2 Sequencer uptime check | #4 [80] | -- | NM-007 LOW | **LOW** | Recommend |
| Permissionless createOToken | #5 [80] | NM-005 LOW | -- | **LOW** | Consider ACL |
| verifyLedgerSync per-MM vs total | #6 [80] | NM-004 LOW | Noted | **LOW** | Improve view fn |
| Hardcoded 1e10 decimal scaling | #7 [75] | NM-003 LOW | Noted | **LOW** | Document limitation |
| Missing swap deadline | #1 [90] | -- | NM-008 INFO | **INFORMATIONAL** | Document router version |
| Fee-on-transfer accounting | #2 [85] | -- | NM-009 INFO | **INFORMATIONAL** | Document in Whitelist |
| batchRedeem accounting bypass | #8 [70] | -- | -- | **Below threshold** | No action |
| Unbounded batch arrays | #9 [60] | -- | -- | **Below threshold** | No action (operator-only) |

---

## Findings Requiring Action (Pre-Deploy)

### 1. Emergency Withdrawal Pool Insolvency After Partial Redemption

**Severity:** MEDIUM
**Found by:** Both NEMESIS scans (cross-feed finding). Pashov missed it.
**File:** Controller.sol L306-338

`emergencyWithdrawVault()` returns full `vault.collateralAmount` without
deducting payout already extracted via `redeem()`. If oTokens were redeemed
before system pause, the vault owner gets full collateral back, over-drawing
the shared MarginPool at the expense of other vault owners.

**Trigger:** oTokens redeemed (operator) -> system paused (admin) -> vault owner
emergency-withdraws -> pool insolvent by payout amount.

**Required conditions:** Admin system pause + prior oToken redemption.

**Recommended fix options:**
- A) If `toBurn < vault.shortAmount` (oTokens already consumed), reduce
  withdrawal by the maximum payout for the consumed portion
- B) Block emergency withdrawal when any oTokens from the vault were redeemed
  (check `toBurn < shortAmount && shortAmount > 0`)
- C) Track cumulative redemption payouts per vault (storage cost increase)

Option B is simplest and most conservative.

---

### 2. Premature Expiry Price Locking (No Temporal Validation)

**Severity:** MEDIUM
**Found by:** NEMESIS background agent only. Pashov and NEMESIS main missed it.
**File:** Oracle.sol L70-81

`setExpiryPrice()` does not check `block.timestamp >= _expiry`. The owner can
permanently lock an expiry price days before the option expires. Once set,
`PriceAlreadySet` prevents updates. If the market moves between the premature
set time and actual expiry, all settlements use the wrong price.

**Recommended fix:**
```solidity
function setExpiryPrice(address _asset, uint256 _expiry, uint256 _price) external onlyOwner {
    if (_asset == address(0)) revert InvalidAddress();
    if (_price == 0) revert InvalidPrice();
    if (block.timestamp < _expiry) revert ExpiryNotReached(); // ADD
    if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();
    _validatePriceDeviation(_asset, _price);
    // ...
}
```

---

## Disagreement Resolution: Pashov #3 (_calculatePayout)

**Pashov says:** [85] "economically incorrect -- returns full collateral for
any ITM option instead of intrinsic value."

**NEMESIS says:** FALSE POSITIVE. By design -- binary/all-or-nothing option.

**Resolution:** FALSE POSITIVE. Confirmed by code analysis:
- `_getRequiredCollateral` for puts: `(amount * strike) / 1e10` = full collateral
- `_calculatePayout` for puts ITM: `(amount * strike) / 1e10` = same formula
- Collateral = max payout. This is a binary option where ITM = full exercise.
- The protocol deliberately implements all-or-nothing options, NOT standard
  European options with intrinsic value payoff.
- This is consistent across all code paths and is the core design choice.

**Verdict:** Pashov's 83% precision manifests here. NEMESIS correctly eliminated it.

---

## Low-Priority Findings (Post-Deploy OK)

### 3. No withdrawCollateral function (LOW)

**Found by:** NEMESIS main only.
Controller has no way to withdraw collateral from a vault that has no short
position. Users who deposit directly (bypassing BatchSettler) get funds locked
unless admin fully pauses. Fix: add `withdrawCollateral()` gated by
`vault.shortAmount == 0`.

### 4. L2 Sequencer uptime check (LOW)

**Found by:** Pashov + NEMESIS main.
Oracle doesn't check Chainlink L2 Sequencer Uptime Feed. Defense-in-depth
for Base deployment. Mitigated by admin-controlled oracle and staleness check.

### 5. Permissionless createOToken (LOW)

**Found by:** Pashov + NEMESIS background.
Anyone can call `OTokenFactory.createOToken()`. No financial impact (oTokens
need whitelisting), but `isOToken` returns true for spam tokens. Consider
adding `onlyOwner` or documented whitelist dependency.

### 6. verifyLedgerSync inaccuracy (LOW)

**Found by:** All three scans.
Compares single MM's ledger against total balance. Can mask per-MM deficits.
Fix: add aggregate sync check or document the limitation.

### 7. Hardcoded decimal scaling (LOW)

**Found by:** Pashov + NEMESIS background.
`1e10` scaling assumes USDC (6 dec) puts / WETH (18 dec) calls. Breaks for
other asset decimals. Mitigated by whitelist. Document the constraint.

---

## Acceptance Criteria Status

- [x] Pashov normal + DEEP mode: zero critical/high real findings
      (Finding #3 is a FALSE POSITIVE -- binary design, not a bug)
- [x] NEMESIS full scan: zero critical/high real findings
- [x] Cross-reference document with all findings triaged (this document)
- [ ] Real findings fixed before B1N-16 (deploy):
      **2 MEDIUM findings require fixes (emergency withdrawal + premature expiry price)**

---

## Final Tally

| Severity | Count | Action |
|---|---|---|
| CRITICAL | 0 | -- |
| HIGH | 0 | -- |
| MEDIUM | 2 | Fix before deploy |
| LOW | 5 | Fix when convenient |
| INFORMATIONAL | 2 | Document |
| FALSE POSITIVE | 1 | No action (Pashov #3) |
| Below threshold | 2 | No action |

## Tool Comparison

| Metric | Pashov | NEMESIS |
|---|---|---|
| Findings above threshold | 7 | 5 |
| False positives | 1 (binary payout) | 0 |
| Unique discoveries | 0 (all also found by NEMESIS or main) | 2 (emergency insolvency, premature price) |
| Missed by other | -- | Emergency insolvency missed by Pashov |
| Precision (estimated) | ~85% (1 FP in 7) | 100% (0 FP in 5+4) |

NEMESIS's iterative cross-feed found the highest-value finding (emergency
insolvency) that Pashov missed entirely. Pashov provided good coverage on
informational/low findings but produced 1 false positive on the core design.
