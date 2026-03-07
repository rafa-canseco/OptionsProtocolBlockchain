# N E M E S I S -- Verified Findings (Consolidated)

> Dual-pass audit: NEMESIS background agent + NEMESIS main pipeline.
> Findings cross-referenced and deduplicated below.

## Scope

- **Language:** Solidity 0.8.24
- **Framework:** Foundry
- **Modules analyzed:** 11 files (8 contracts + 3 interfaces)
  - `src/core/Controller.sol`
  - `src/core/BatchSettler.sol`
  - `src/core/MarginPool.sol`
  - `src/core/Oracle.sol`
  - `src/core/OToken.sol`
  - `src/core/OTokenFactory.sol`
  - `src/core/AddressBook.sol`
  - `src/core/Whitelist.sol`
  - `src/interfaces/IFlashLoanSimple.sol`
  - `src/interfaces/IMarginVault.sol`
  - `src/interfaces/ISwapRouter.sol`
- **Functions analyzed:** 52
- **Coupled state pairs mapped:** 7
- **Mutation paths traced:** 18
- **Nemesis loop iterations:** 4 (2 Feynman + 2 State)

---

## Nemesis Map (Phase 1 Cross-Reference)

| Function | Writes A | Writes B | A-B Pair | Sync Status |
|---|---|---|---|---|
| `depositCollateral` | vault.collateralAmount | MarginPool (transferToPool) | vault-pool | SYNCED |
| `settleVault` | vaultSettled=true | MarginPool (transferToUser) | settled-return | SYNCED (vault amounts not zeroed but gated) |
| `redeem` | (none on vault) | MarginPool (transferToUser) + OToken burn | - | N/A |
| `emergencyWithdrawVault` | vaultSettled=true | MarginPool (transferToUser) + burn + mmBal clear | settled-return-mmBal | **GAP** (NM-001) |
| `executeOrder` | quoteState, mmOTokenBalance | vault via Controller | quote-mmBal-vault | SYNCED |
| `_redeemForMM` | mmOTokenBalance -= | Controller.redeem (burns oToken) | mmBal-oTokenBal | SYNCED |
| `clearMMBalanceForVault` | mmOTokenBalance -= | (burn is separate in Controller) | mmBal-oTokenBal | SYNCED (burn precedes clear) |

---

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Severity | Confidence | Verdict |
|----|--------|-------------|-------------|----------|------------|---------|
| NM-001 | Feynman-State Cross-feed | vault.collateralAmount - pool balance | emergencyWithdrawVault | MEDIUM | HIGH | TRUE POSITIVE |
| NM-002 | Feynman-only | expiryPrice - expiryPriceSet | setExpiryPrice | MEDIUM | HIGH | TRUE POSITIVE |
| NM-003 | Feynman-only | collateral decimals - payout math | _calculatePayout / _getRequiredCollateral | LOW | HIGH | TRUE POSITIVE |
| NM-004 | State-only | mmOTokenBalance (per-MM) - actual balance (total) | verifyLedgerSync | LOW | MEDIUM | TRUE POSITIVE |
| NM-005 | Feynman-only | - | createOToken | LOW | HIGH | TRUE POSITIVE |

---

## Verified Findings (TRUE POSITIVES)

### NM-001: Emergency Withdrawal Pool Insolvency After Partial Redemption

**Severity:** MEDIUM
**Confidence:** HIGH
**Source:** Feynman-State Cross-feed (Pass 1 suspect -> Pass 2 gap -> Pass 3 confirmation)

**Coupled Pair:** `vault.collateralAmount` (Controller storage) <-> actual MarginPool ERC20 balance
**Invariant:** Sum of unreturned collateral across all unsettled vaults <= MarginPool balance

**Feynman Question that exposed it:**
> "WHY does `emergencyWithdrawVault` return `vault.collateralAmount` (L315) without checking if any oTokens from this vault were already redeemed?"

**State Mapper gap that confirmed it:**
> `emergencyWithdrawVault` writes `vaultSettled = true` and transfers full `vault.collateralAmount`, but no mutation path subtracts prior redemption payouts from the vault's tracked collateral.

**Breaking Operation:** `Controller.emergencyWithdrawVault()` at `Controller.sol:L306-338`
- Returns full `vault.collateralAmount` to the vault writer
- Does NOT account for oTokens from this vault that were already redeemed (payout already extracted from pool)

**Trigger Sequence:**
```
1. User executes order via BatchSettler -> vault created with collateral C, oTokens minted
2. Option expires, oracle price set (option is ITM)
3. Operator calls operatorRedeemForMM -> MM receives payout P from MarginPool
4. Owner pauses system (setSystemFullyPaused(true))
5. Vault writer calls emergencyWithdrawVault -> receives full C from MarginPool
6. Pool has paid out P + C but only received C as deposit
7. Pool is insolvent by amount P
8. Other vault writers calling settleVault or redeemers calling redeem will revert
```

**Consequence:**
- MarginPool becomes insolvent by the amount of prior redemptions
- Subsequent settlements and redemptions for other users will fail (safeTransfer reverts on insufficient balance)
- Impact is bounded by the sum of redemptions that occurred before the pause

**Masking Code:**
```solidity
// Controller.sol L324 -- defensive clamp hides that not all oTokens may be burnable
uint256 toBurn = vault.shortAmount < settlerBal ? vault.shortAmount : settlerBal;
```

**Verification Evidence:**
- `emergencyWithdrawVault` L315: `uint256 amount = vault.collateralAmount;` -- reads original deposit, never decremented
- `emergencyWithdrawVault` L335: `MarginPool(...).transferToUser(asset, msg.sender, amount);` -- transfers full amount
- `redeem()` L231: `MarginPool(...).transferToUser(payoutAsset, msg.sender, payout);` -- prior redemptions already extracted payout from the same pool
- No code path links redemption payouts back to specific vaults

**Mitigating Factors:**
- Requires `systemFullyPaused = true` (admin action only)
- Requires partial redemption to have occurred before the pause
- Affected pool insolvency is bounded by redeemed payout amounts

**Fix:**
```solidity
// Option A: Track redeemed amounts per vault and subtract from emergency withdrawal
// Option B: In emergencyWithdrawVault, calculate remaining collateral as:
//   collateralToReturn = vault.collateralAmount - _calculatePayout(oToken, redeemedAmount, expiryPrice)
// Option C: Block emergency withdrawal if any oTokens from the vault have been redeemed
//   (check settlerBal < vault.shortAmount as a signal)
```

---

### NM-002: Premature Expiry Price Locking Without Temporal Validation

**Severity:** MEDIUM
**Confidence:** HIGH
**Source:** Feynman-only (Pass 1, Category 5 boundary check)

**Breaking Operation:** `Oracle.setExpiryPrice()` at `Oracle.sol:L70-81`

**Description:**
`setExpiryPrice` does not validate that `block.timestamp >= _expiry`. The owner can set expiry prices for future expiries. Once set, `expiryPriceSet = true` and `PriceAlreadySet` prevents any update. If the price is set hours or days before actual expiry, the locked price may diverge significantly from the actual market price at expiry time, especially in volatile markets.

**Trigger Sequence:**
```
1. Oracle owner calls setExpiryPrice(WETH, fridayExpiry, 2500e8) on Wednesday
2. WETH price moves to 3000 by Friday 08:00 UTC
3. Price is permanently locked at 2500 -- cannot be updated
4. All settlements use the stale price
5. Put buyers profit unfairly / call buyers lose unfairly
```

**Consequence:**
- Incorrect settlement prices for all options with that expiry
- Financial loss for one side of every affected option
- Deviation bounds help but may allow significant error if set loosely (e.g., 20% threshold)

**Mitigating Factors:**
- Owner is trusted (centralization assumption)
- `_validatePriceDeviation` provides a sanity bound against Chainlink
- Deviation threshold can be set tight (e.g., 100 bps)
- In practice, the oracle bot would only set prices after expiry

**Fix:**
```solidity
function setExpiryPrice(address _asset, uint256 _expiry, uint256 _price) external onlyOwner {
    if (_asset == address(0)) revert InvalidAddress();
    if (_price == 0) revert InvalidPrice();
    if (block.timestamp < _expiry) revert ExpiryNotReached(); // ADD THIS CHECK
    if (expiryPriceSet[_asset][_expiry]) revert PriceAlreadySet();
    // ...
}
```

---

### NM-003: Hardcoded Decimal Scaling Assumes Specific Asset Pairs

**Severity:** LOW
**Confidence:** HIGH
**Source:** Feynman-only (Pass 1, Category 4 assumption analysis)

**Breaking Operation:** `Controller._getRequiredCollateral()` and `Controller._calculatePayout()` at `Controller.sol:L250-268`

**Description:**
Both functions use a hardcoded `1e10` scaling factor that assumes:
- Put options: collateral is a 6-decimal token (USDC). Formula: `(amount_8dec * strike_8dec) / 1e10 = result_6dec`
- Call options: collateral is an 18-decimal token (WETH). Formula: `amount_8dec * 1e10 = result_18dec`

If the protocol ever supports collateral with different decimal counts (e.g., WBTC with 8 decimals for calls, or DAI with 18 decimals for puts), the math produces incorrect required collateral and payouts.

**Consequence:**
- Wrong collateral requirements (either massively over-collateralized or under-collateralized)
- Wrong payout amounts at settlement/redemption
- For WBTC (8 dec) as call collateral: requires `1e8 * 1e10 = 1e18` which is 10 billion WBTC -- effectively impossible to fill

**Mitigating Factors:**
- Whitelist restricts which assets can be used
- Current deployment only uses USDC and WETH (correct decimals)
- Extending to new assets requires explicit admin whitelisting

**Fix:**
```solidity
// Read collateral decimals dynamically:
uint8 colDecimals = IERC20Metadata(oToken.collateralAsset()).decimals();
// Adjust scaling factor based on actual decimals
```

---

### NM-004: verifyLedgerSync Provides Per-MM View Against Total Balance

**Severity:** LOW (Informational)
**Confidence:** MEDIUM
**Source:** State-only (Pass 2, monitoring function analysis)

**Breaking Operation:** `BatchSettler.verifyLedgerSync()` at `BatchSettler.sol:L678-686`

**Description:**
`verifyLedgerSync` compares one MM's ledger balance against the total oToken balance held by BatchSettler. If MMs A and B each have ledger balance of 60, but BatchSettler only holds 100 total oTokens, each individual check returns `inSync = true` (100 >= 60), but the aggregate is insolvent (60 + 60 = 120 > 100).

**Consequence:**
- Monitoring tools relying on this function may fail to detect aggregate ledger insolvency
- No direct financial impact -- this is a view function

**Fix:**
```solidity
// Add a function that checks aggregate sync across all MMs for a given oToken,
// or document that callers must sum across all MMs and compare to actual balance.
```

---

### NM-005: Permissionless OToken Creation (Unbounded Array Growth)

**Severity:** LOW (Informational)
**Confidence:** HIGH
**Source:** Feynman-only (Pass 1, Category 5 boundary check)

**Breaking Operation:** `OTokenFactory.createOToken()` at `OTokenFactory.sol:L53-87`

**Description:**
`createOToken` has no access control. Anyone can create oTokens. While created oTokens require whitelisting to be usable, the `oTokens` array grows without bound. An attacker could spam oToken creation, growing the array. This has no direct security impact but increases contract storage costs.

**Consequence:**
- Unbounded `oTokens` array growth from spam
- `getOTokensLength()` returns inflated count
- No financial impact -- unused oTokens are inert without whitelisting

**Mitigating Factors:**
- Each creation deploys a new contract (gas cost ~500k+), making spam expensive
- Whitelist gates all usage
- Array is append-only, no iteration in contracts

---

## Feedback Loop Discoveries

**NM-001** is the primary feedback loop discovery. It was found through the iterative back-and-forth:

1. **Feynman Pass 1** flagged the defensive ternary clamp in `emergencyWithdrawVault` (L324) as SUSPECT and questioned why `vault.collateralAmount` is never decremented.
2. **State Pass 2** mapped the coupled pair `vault.collateralAmount <-> MarginPool balance` and found that `emergencyWithdrawVault` updates `vaultSettled` but does not account for prior pool outflows from redemptions.
3. **Feynman Pass 3** re-interrogated: "WHY doesn't emergency withdraw check if oTokens were already redeemed?" and confirmed the assumption violation: the developer assumed `systemFullyPaused` prevents all redemptions, but redemptions can occur BEFORE the pause.
4. **State Pass 4** confirmed no other coupled pairs share this root cause.

Neither auditor alone would have surfaced this with full confidence. Feynman alone would have noted the suspect clamp but might not have traced the pool balance coupling. State Mapper alone would have noted the gap but might not have identified the pre-pause redemption scenario.

## False Positives Eliminated

| ID | Initial Finding | Reason for Elimination |
|----|----------------|----------------------|
| FP-1 | `settleVault` doesn't zero `vault.collateralAmount/shortAmount` | Gated by `vaultSettled` check -- stale values are unreachable |
| FP-2 | `redeem()` doesn't check `vaultSettled` | By design -- redemption is vault-agnostic, pool solvency ensured by full collateralization |
| FP-3 | `_redeemSingle` and `_physicalRedeemSingle` are `external` | Protected by `msg.sender == address(this)` check |
| FP-4 | Multiple vaults writing same oToken could drain pool | Full collateralization ensures pool holds sum of all payouts |
| FP-5 | Binary option payout (full collateral or zero) seems wrong | Intentional design -- confirmed by `_getRequiredCollateral == _calculatePayout` for ITM |
| FP-6 | `setExpiryPrice` could front-run settlement | Settlement checks `block.timestamp >= expiry` independently |

## Additional Findings (Main Pipeline -- not in background agent)

### NM-006: No withdrawCollateral Function in Controller

**Severity:** LOW
**Source:** Feynman (Category 5: Boundaries)
**Verification:** Code trace

**Description:**
Controller has no `withdrawCollateral()` function. If a user deposits collateral
via `depositCollateral()` but never calls `mintOtoken()`, the collateral is
permanently locked. `settleVault()` requires `vault.shortOtoken != address(0)`
(calls `OToken(vault.shortOtoken).expiry()` which reverts on address(0)).
`emergencyWithdrawVault()` requires `systemFullyPaused`.

**Trigger Sequence:**
1. User calls `Controller.depositCollateral(user, vaultId, USDC, 100e6)`
2. Decides not to mint -- no `withdrawCollateral()` exists
3. `settleVault()` reverts (no shortOtoken)
4. `emergencyWithdrawVault()` reverts (system not paused)

**Mitigating Factors:** Normal flow uses BatchSettler.executeOrder() which does
deposit+mint atomically. Direct Controller use is uncommon.

**Fix:** Add `withdrawCollateral()` gated by `vault.shortAmount == 0`.

---

### NM-007: No L2 Sequencer Uptime Check in Oracle

**Severity:** LOW
**Source:** Feynman (Category 4: Assumptions)
**Verification:** Code trace

**Description:**
`Oracle._validatePriceDeviation()` and `getPrice()` call Chainlink
`latestRoundData()` without checking the L2 Sequencer Uptime Feed.
On Base (Optimistic Rollup), stale prices during sequencer outage could
pass the deviation check.

Note: Chainlink staleness check IS implemented (maxOracleStaleness). FIXED
from B1N-136. This is the remaining gap.

**Mitigating Factors:** Admin-controlled oracle. Off-chain bot can check
sequencer before submitting. Low probability on Base.

---

### NM-008: ISwapRouter Interface Omits Deadline Field

**Severity:** INFORMATIONAL
**Source:** Feynman (Category 3: Consistency)

**Description:** Custom `ISwapRouter.ExactOutputSingleParams` has no `deadline`.
Correct if using Uniswap SwapRouter02 (which removed it from struct).
Incorrect if using SwapRouter V1.

**Mitigating Factors:** Operator controls tx timing. Base has no traditional
mempool MEV. Previously flagged in B1N-136.

---

### NM-009: Fee-on-Transfer Tokens Inflate Vault Accounting

**Severity:** INFORMATIONAL
**Source:** Feynman (Category 4: Assumptions)

**Description:** `depositCollateral` records `vault.collateralAmount += _amount`
but MarginPool receives `_amount - fee` for fee-on-transfer tokens. Complementary
to NM-003 (hardcoded scaling) -- both relate to asset compatibility assumptions.

**Mitigating Factors:** Only USDC/WETH whitelisted. Neither has transfer fees.

---

## B1N-136 Regression Check

| # | Previous Finding | Status |
|---|---|---|
| 1 | Undercollateralized minting via repeated mintOtoken | FIXED (L178: cumulative `vault.shortAmount + _amount`) |
| 2 | Chainlink staleness check missing | FIXED (maxOracleStaleness on L104-107, L146-149) |
| 3 | Missing deadline on Uniswap swap | PERSISTS as INFORMATIONAL (NM-008) |
| 4 | Fee-on-transfer token accounting | PERSISTS as INFORMATIONAL (NM-009) |
| 5 | Emergency withdrawal unbacked claims | PARTIALLY MITIGATED (burns + clears; gap = NM-001) |

## Downgraded Findings

None. All findings maintained their initial severity assessment through verification.

## Red Flags Checklist

```
FROM FEYNMAN:
- [x] A guard on funcA that's missing from funcB: emergencyWithdrawVault has
      no check for prior redemptions, unlike normal settleVault which naturally
      accounts for them via payout calculation
- [x] An implicit trust assumption about state: emergencyWithdrawVault assumes
      no redemptions occurred before pause
- [ ] External call with state updates AFTER it: all paths follow CEI
- [ ] Function behaves differently on 2nd call: vaultSettled prevents double-call

FROM STATE MAPPER:
- [x] Function modifies State A but has no writes to coupled State B:
      emergencyWithdrawVault returns full collateral without adjusting for
      prior pool outflows
- [ ] Two similar operations handle coupled state differently: settle and
      emergency withdraw diverge, but settle is correct
- [x] Defensive ternary between coupled values: L324 clamp on toBurn
- [ ] delete/reset of one mapping but not paired mapping: N/A
- [ ] Emergency function bypasses normal state update path: YES (NM-001)

FROM FEEDBACK LOOP:
- [x] Feynman found an ordering concern + State Mapper found a gap in the
      SAME function: emergencyWithdrawVault (NM-001)
- [x] State Mapper found masking code + Feynman explained WHY the invariant
      is broken underneath: L324 clamp masks unbacked oTokens
```

## Summary

- **Total functions analyzed:** 52
- **Coupled state pairs mapped:** 7
- **Nemesis loop iterations:** 4 (2 Feynman + 2 State)
- **Raw findings (pre-verification):** 0 CRITICAL | 1 HIGH | 2 MEDIUM | 5 LOW
- **Feedback loop discoveries:** 1 (NM-001, found ONLY via Feynman-State cross-feed)
- **After verification:** 9 TRUE POSITIVE | 6 FALSE POSITIVE | 0 DOWNGRADED
- **Final: 0 CRITICAL | 0 HIGH | 2 MEDIUM | 5 LOW | 2 INFORMATIONAL**
- **Additional from main pipeline:** NM-006 through NM-009 (not found by background agent)
