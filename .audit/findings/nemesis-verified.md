# N E M E S I S — Verified Findings (Post-Operator-Role Audit)

**Date:** 2026-03-08
**Commit:** `fix/access-control-operator-roles` branch (post-operator fix)
**Auditor:** Nemesis (Feynman + State Inconsistency iterative loop)

## Scope

- **Language:** Solidity 0.8.24
- **Modules analyzed:** AddressBook, BatchSettler, Controller, MarginPool, Oracle, OToken, OTokenFactory, Whitelist
- **Functions analyzed:** 62 external/public functions
- **Coupled state pairs mapped:** 18
- **Mutation paths traced:** 34
- **Nemesis loop iterations:** 3 (Pass 1 Feynman → Pass 2 State → Pass 3 Feynman targeted)

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Severity | Verdict |
|----|--------|-------------|-------------|----------|---------|
| NM-001 | Cross-feed P1→P2→P3 | mmOTokenBal ↔ settler aggregate bal | emergencyWithdrawVault | HIGH | TRUE POS |
| NM-002 | Feynman-only | Oracle deviation config | setExpiryPrice | LOW | TRUE POS |
| NM-003 | State-only | vault.shortAmount ghost | emergencyWithdrawVault | LOW | TRUE POS |
| NM-004 | Feynman-only | setPartialPauser(0) | setPartialPauser | LOW | TRUE POS |
| NM-005 | State-only | Product whitelist unused | — | INFO | TRUE POS |
| NM-006 | State-only | No oToken de-whitelist | — | INFO | TRUE POS |

---

## Verified Findings (TRUE POSITIVES only)

### NM-001: Emergency Withdrawal Cross-Vault Double-Claim via Aggregate Balance Check

**Severity:** HIGH
**Source:** Cross-feed — Feynman Pass 1 exposed the aggregate check assumption, State Pass 2 mapped the coupled pair gap, Feynman Pass 3 constructed the exploit sequence.
**Verification:** Deep code trace + manual scenario walkthrough

**Coupled Pair:**
- State A: `BatchSettler.mmOTokenBalance[mm][oToken]` — per-MM ledger
- State B: `OToken.balanceOf(batchSettler)` — aggregate token balance

**Invariant:** `sum(mmOTokenBalance[*][oToken]) == OToken.balanceOf(settler)`

**Root Cause:** `Controller.emergencyWithdrawVault()` at line 329 checks the **aggregate** `ot.balanceOf(settler)` against a single vault's `vault.shortAmount`. Because oTokens are fungible, the aggregate balance includes oTokens from ALL vaults for that series. When one vault's MM has already had its oTokens redeemed, the aggregate balance still includes other vaults' oTokens, masking the redemption.

**Breaking Operation:** `Controller.emergencyWithdrawVault()` at `Controller.sol:307`

```solidity
// Line 324-329 — THE BUG
uint256 settlerBal = ot.balanceOf(settler);  // AGGREGATE balance
if (settlerBal < vault.shortAmount) revert OTokensAlreadyRedeemed();
```

**Trigger Sequence:**

```
Setup:
  Vault A (Alice): shortAmount=100e8, collateral=100e18 WETH, vaultMM=MM1
  Vault B (Bob):   shortAmount=100e8, collateral=100e18 WETH, vaultMM=MM2
  BatchSettler holds 200e8 oTokens total
  mmOTokenBalance[MM1]=100e8, mmOTokenBalance[MM2]=100e8
  MarginPool holds 200e18 WETH

Step 1: Option expires ITM (call, strike=3000, price=4000)
Step 2: Oracle.setExpiryPrice() sets price

Step 3: operatorRedeemForMM(MM1, [oToken], [100e8])
  → mmOTokenBalance[MM1] = 0
  → ctrl.redeem() burns 100e8 from settler (settler now has 100e8)
  → Binary payout: 100e8 * 1e10 = 100e18 WETH
  → MarginPool sends 100e18 WETH → settler → MM1
  → MarginPool now has 100e18 WETH

Step 4: Owner calls setSystemFullyPaused(true)

Step 5: Alice calls emergencyWithdrawVault(1)
  → settlerBal = ot.balanceOf(settler) = 100e8  (Bob's tokens!)
  → 100e8 >= 100e8 = vault.shortAmount → CHECK PASSES
  → Burns 100e8 from settler → settler has 0
  → clearMMBalanceForVault: mm=MM1, balance=0, toClear=0 (no-op)
  → MarginPool.transferToUser(WETH, Alice, 100e18)
  → MarginPool now has 0 WETH

Step 6: Bob calls emergencyWithdrawVault(1)
  → settlerBal = 0 < 100e8 → revert OTokensAlreadyRedeemed
  → Bob's 100e18 WETH is LOST
```

**Consequence:**
- Alice extracts 100e18 WETH (full collateral) despite her MM's oTokens being fully redeemed (payout already sent from MarginPool)
- MarginPool drained of 200e18 WETH total: 100e18 to MM1 (redeem) + 100e18 to Alice (emergency)
- Bob cannot withdraw his 100e18 WETH — funds stolen from his vault
- Net: one vault owner profits at another's expense through cross-vault accounting gap

**Preconditions:**
1. Multiple vaults exist for the same oToken series
2. Partial or full redemption of one vault's MM oTokens occurs (option must be expired + ITM)
3. System gets fully paused AFTER the redemption
4. The vault owner whose MM was redeemed calls emergencyWithdrawVault

**Fix:**

Replace the aggregate balance check with a per-MM balance check. The MM's `mmOTokenBalance` accurately tracks whether oTokens attributed to that MM have been redeemed:

```solidity
// BEFORE (line 324-329):
uint256 settlerBal = ot.balanceOf(settler);
if (settlerBal < vault.shortAmount) revert OTokensAlreadyRedeemed();

// AFTER:
address mm = IBatchSettler(settler).vaultMM(msg.sender, _vaultId);
uint256 mmBal = IBatchSettler(settler).mmOTokenBalance(mm, vault.shortOtoken);
if (mmBal < vault.shortAmount) revert OTokensAlreadyRedeemed();
```

This check is conservative: if an MM has oTokens from multiple vaults and some were redeemed, the check blocks ALL that MM's vaults from emergency withdrawal (since we can't determine which vault's oTokens were redeemed due to fungibility). This is the safe behavior — it prevents over-extraction from MarginPool at the cost of potentially blocking some legitimate withdrawals.

For the `mm == address(0)` (pre-migration vault) case, add a fallback to the aggregate check or skip the check entirely, since pre-migration vaults have no MM attribution.

---

### NM-002: Oracle Price Deviation Validation Disabled by Default

**Severity:** LOW
**Source:** Feynman-only (Category 4: Assumptions)
**Verification:** Code trace

**Feynman Question:** "What is implicitly trusted about the operator when calling setExpiryPrice?"

**Issue:** `Oracle._validatePriceDeviation()` returns immediately without validation in two cases:
1. `priceDeviationThresholdBps == 0` (default after initialization)
2. `priceFeed[_asset] == address(0)` (no Chainlink feed configured)

```solidity
// Oracle.sol:152-157
function _validatePriceDeviation(address _asset, uint256 _price) internal view {
    uint256 threshold = priceDeviationThresholdBps;
    if (threshold == 0) return;           // DEFAULT — NO VALIDATION
    address feed = priceFeed[_asset];
    if (feed == address(0)) return;       // NO FEED — NO VALIDATION
```

**Consequence:** The operator (hot wallet bot) can submit ANY expiry price without Chainlink cross-validation until the owner explicitly configures the threshold and price feed. If the operator key is compromised, there are no on-chain guardrails.

**Mitigation:** Owner must set `priceDeviationThresholdBps` (e.g., 1000 = 10%) and `priceFeed[asset]` for every traded asset BEFORE mainnet launch. Consider requiring non-zero threshold in `initialize()`.

---

### NM-003: vault.shortAmount Not Zeroed After Emergency Withdrawal

**Severity:** LOW
**Source:** State-only (Pair 1 gap)
**Verification:** Code trace

**Issue:** `Controller.emergencyWithdrawVault()` burns oTokens from the settler and marks the vault as settled, but never zeros `vault.shortAmount` or `vault.collateralAmount`. These become ghost records.

```solidity
// Controller.sol:307-342
// Burns oTokens (line 331), sets vaultSettled (line 338),
// transfers collateral (line 340), but:
// - vault.shortAmount remains unchanged
// - vault.collateralAmount remains unchanged
```

**Impact:** LOW — The `vaultSettled` flag prevents any further operations on the vault, so the ghost data is not exploitable. However, off-chain systems reading `getVault()` may display stale data.

**Fix (optional):** Add `vault.shortAmount = 0; vault.collateralAmount = 0;` before the settlement flag is set.

---

### NM-004: setPartialPauser Accepts address(0)

**Severity:** LOW
**Source:** Feynman-only (Category 3: Consistency)
**Verification:** Code trace

**Feynman Question:** "WHY does setOperator validate against address(0) but setPartialPauser doesn't?"

**Issue:** `Controller.setPartialPauser()` at line 273 accepts `address(0)`, which effectively disables the partial pauser role. Only the owner can then toggle partial pause.

```solidity
// Controller.sol:273-276
function setPartialPauser(address _pauser) external onlyOwner {
    emit PartialPauserUpdated(partialPauser, _pauser);
    partialPauser = _pauser;  // No zero-address check
}
```

**Impact:** LOW — Owner can still toggle pause directly. This is likely acceptable behavior (disable partial pauser by setting to 0) but inconsistent with other setter patterns in the codebase.

---

### NM-005: Product Whitelist Feature Is Dead Code

**Severity:** INFO
**Source:** State-only (Pair 9 observation)
**Verification:** Code trace + grep

**Issue:** `Whitelist.sol` has `whitelistProduct()` and `isProductWhitelisted()` functions, but nothing in the protocol calls `isProductWhitelisted()` during oToken creation or vault operations. The factory auto-whitelists oTokens via `whitelistOToken()`, and the Controller only checks `isWhitelistedOToken()`.

The product whitelist is a defense-in-depth feature that is not wired into the system.

---

### NM-006: No Mechanism to De-Whitelist oTokens

**Severity:** INFO
**Source:** State-only (Pair 9 observation)
**Verification:** Code trace

**Issue:** `Whitelist.whitelistOToken()` sets `isWhitelistedOToken[oToken] = true` but there is no function to set it back to `false`. Once whitelisted, an oToken remains whitelisted forever.

**Impact:** If an oToken is created with incorrect parameters, it cannot be de-whitelisted. The partial pause mechanism can block new positions but cannot target specific oTokens.

---

## Nemesis Loop Discovery Path

```
Pass 1 (Feynman — full):
  → Flagged emergencyWithdrawVault line 329 as SUSPECT
    Q: "WHY does this check aggregate balanceOf instead of per-vault?"
    Q: "What assumption does settlerBal >= vault.shortAmount encode?"
    Answer: It assumes no oTokens from THIS vault have been redeemed.
    But aggregate balance includes oTokens from OTHER vaults → masking.
  → Flagged Oracle deviation bypass as LOW finding
  → Flagged setPartialPauser(0) inconsistency

Pass 2 (State — full, enriched by Pass 1):
  → Mapped Pair 2: mmOTokenBalance ↔ OToken.balanceOf(settler)
  → Traced all mutation points — found clearMMBalanceForVault only
    updates ONE side (ledger), caller handles the other (burn)
  → Cross-referenced with Feynman suspect: the aggregate check at
    line 329 is the ROOT of the coupled pair gap
  → Mapped Pair 1: vault.shortAmount ghost record
  → Flagged product whitelist as dead code

Pass 3 (Feynman targeted — on Pass 2 gaps):
  → Re-interrogated emergencyWithdrawVault with full state context:
    Q: "Can an attacker CHOOSE a sequence to exploit the gap?"
    → YES: constructed the 6-step trigger sequence (NM-001)
    Q: "Does the aggregate check mask partial redemption?"
    → YES: Bob's oTokens validate Alice's vault
  → Verified with exact arithmetic: MarginPool drains to 0
  → Proposed fix: per-MM balance check instead of aggregate

CONVERGED: Pass 4 (State) produced no new findings.
```

## False Positives Eliminated

| Candidate | Why Eliminated |
|-----------|---------------|
| quoteState fill advanced before mint | Solidity reverts entire tx on mint failure; fill counter rolls back atomically |
| clearMMBalanceForVault one-sided mutation | By design — burn happens in caller (Controller). If clearMMBalanceForVault fails, entire emergencyWithdrawVault tx reverts |
| vault.collateralAmount not zeroed after settle | vaultSettled flag prevents all re-operations; ghost data not actionable |
| EIP-712 replay on chain fork | _domainSeparator recomputes on chain ID change (line 186-188) |
| Flash loan callback manipulation | msg.sender == aavePool + initiator == address(this) checks sufficient; aavePool is owner-set |
| OToken.transfer from settler by third party | No approvals granted; only code in settler controls token movement |
| cancelQuote/cancelQuotes inconsistency | By design — documented in NatSpec. Single reverts on dup, batch skips |

## Summary

- **Total functions analyzed:** 62
- **Coupled state pairs mapped:** 18
- **Nemesis loop iterations:** 3
- **Raw findings (pre-verification):** 0 C | 1 H | 0 M | 4 L/INFO
- **Feedback loop discoveries:** 1 (NM-001 — found ONLY via Feynman→State→Feynman cross-feed)
- **After verification:** 6 TRUE POSITIVE | 0 FALSE POSITIVE | 0 DOWNGRADED
- **Final: 0 CRITICAL | 1 HIGH | 0 MEDIUM | 2 LOW | 2 INFO**

---

## Recommendation Priority

1. **NM-001 (HIGH):** Fix the aggregate balance check in `emergencyWithdrawVault` before mainnet launch. Replace `ot.balanceOf(settler) >= vault.shortAmount` with a per-MM `mmOTokenBalance` check.
2. **NM-002 (LOW):** Set `priceDeviationThresholdBps` and `priceFeed` for all traded assets before mainnet launch.
3. **NM-003–006:** Address at convenience; not blocking for mainnet.
