# N E M E S I S — Verified Findings

## Scope

- **Language:** Solidity 0.8.24
- **Modules analyzed:** AddressBook, BatchSettler, Controller, MarginPool, Oracle, OToken, OTokenFactory, Whitelist
- **Functions analyzed:** 34
- **Coupled state pairs mapped:** 11 (P1-P6 original + P7-P11 discovered)
- **Mutation paths traced:** 42
- **Nemesis loop iterations:** 4 (Pass 1 Feynman full, Pass 2 State full, Pass 3 Feynman targeted, Pass 4 State targeted -- converged)

## Nemesis Map (Phase 1 Cross-Reference)

| Coupled Pair | State A | State B | Invariant |
|---|---|---|---|
| P1 | vault.collateralAmount | MarginPool.balanceOf | sum(collateral) <= pool balance |
| P2 | vault.shortAmount | oToken.totalSupply | sum(shortAmount) = totalSupply |
| P3 | mmOTokenBalance | oToken.balanceOf(settler) | sum(mmBalances) <= actualBalance |
| P4 | vaultSettled | collateral transfer | settled=true BEFORE transfer |
| P5 | quoteState fills | mmOTokenBalance | each fill -> matching increment |
| P6 | vaultMM | mmOTokenBalance | clearMMBalance targets correct MM |
| P7 | pool.balanceOf | pending ITM payouts | pool >= sum(unredeemed ITM payouts) |
| P8 | _calculatePayout | binary protocol type | payout is always 0 or full collateral |
| P9 | systemFullyPaused | MM redemption paths | all redemption blocked when paused |
| P10 | protocolFeeBps | treasury address | feeBps > 0 needs treasury != address(0) |
| P11 | oToken.balanceOf(settler) | sum(mmOTokenBalance) | actual >= sum(ledger) always |

## Verification Summary

| ID | Source | Coupled Pair | Breaking Op | Severity | Verdict |
|----|--------|-------------|-------------|----------|---------|
| NM-001 | Feynman->State (P1->P2) | P1 + P7 | emergencyWithdrawVault | HIGH | TRUE POS |
| NM-002 | State->Feynman (P2->P3) | P2 + P3 + P9 | ctrl.redeem notFullyPaused | MEDIUM | TRUE POS |
| NM-003 | Feynman only | P1 | depositCollateral | MEDIUM | TRUE POS (conditional) |
| NM-004 | Loop P2->P3 masking code | P3 + P6 | clearMMBalanceForVault | MEDIUM | TRUE POS |
| NM-005 | Feynman only | P3 | mmSelfRedeem | LOW | TRUE POS |

## Verified Findings (TRUE POSITIVES only)

---

### Finding NM-001: Emergency withdrawal returns full collateral without deducting ITM value owed to market maker

**Severity:** HIGH
**Source:** Cross-feed Pass 1 (Feynman F-004) -> Pass 2 (State SI-002)
**Verification:** Code trace (Controller.sol L318, L349 vs L204)

**Coupled Pair:** P1 (vault.collateralAmount <-> pool balance) + P7 (pool balance <-> pending ITM payouts)
**Invariant:** Collateral returned to vault writer should exclude ITM payout owed to option buyer

**Feynman Question that exposed it:**
> "WHY does settleVault compute `collateralToReturn = collateralAmount - payout` but emergencyWithdrawVault uses `amount = vault.collateralAmount` (the full amount)?"

**State Mapper gap that confirmed it:**
> settleVault deducts ITM value; emergencyWithdrawVault does not. Parallel path mismatch on P1+P7.

**Breaking Operation:** `Controller.emergencyWithdrawVault` at `Controller.sol:309-352`
- Sets `amount = vault.collateralAmount` (L318) -- full amount, no ITM deduction
- Transfers full amount to vault owner (L349)
- Burns MM's oTokens (L340) and clears MM ledger (L342) -- destroying the MM's claim

**Trigger Sequence:**
1. User writes a put option at strike $2000, deposits $2000 USDC as collateral
2. MM buys the put via executeOrder (oTokens custodied at settler, MM pays premium)
3. ETH drops to $1000 -- put is deep ITM
4. Protocol owner calls `setSystemFullyPaused(true)` (legitimate emergency)
5. User calls `emergencyWithdrawVault(vaultId)`
6. User receives $2000 USDC back (should receive $0 for a fully ITM put)
7. MM's oTokens are burned -- MM loses both the premium paid AND the $2000 ITM value

**Consequence:**
- Vault writer extracts collateral that rightfully belongs to option buyer (MM)
- MM loses premium paid + ITM intrinsic value -- total economic loss
- Once system is paused (even legitimately), ALL vault writers can exploit this for ANY ITM vault
- The burned oTokens eliminate the MM's claim permanently -- cannot be recovered on unpause

**Fix:**
```solidity
// In emergencyWithdrawVault, compute payout like settleVault does:
uint256 amount;
if (vault.shortOtoken != address(0) && vault.shortAmount > 0) {
    OToken oToken = OToken(vault.shortOtoken);
    Oracle oracle = Oracle(addressBook.oracle());
    (uint256 expiryPrice, bool isSet) = oracle.getExpiryPrice(
        oToken.underlying(), oToken.expiry()
    );
    if (isSet && block.timestamp >= oToken.expiry()) {
        uint256 payout = _calculatePayout(oToken, vault.shortAmount, expiryPrice);
        amount = payout >= vault.collateralAmount
            ? 0
            : vault.collateralAmount - payout;
    } else {
        // Pre-expiry or price not set: return full collateral
        // (option not yet settleable, no ITM value determinable)
        amount = vault.collateralAmount;
    }
    // ... burn oTokens, clear MM balance ...
} else {
    amount = vault.collateralAmount;
}
```

---

### Finding NM-002: No MM redemption path exists when system is fully paused after settlement

**Severity:** MEDIUM
**Source:** Cross-feed Pass 2 (State SI-003) -- discovered via parallel path comparison
**Verification:** Code trace (BatchSettler.sol L670 -> Controller.sol L215)

**Coupled Pair:** P2 (vault.shortAmount <-> oToken.totalSupply) + P3 (mmOTokenBalance <-> balance) + P9 (systemFullyPaused <-> redemption availability)
**Invariant:** If vault writers can extract during pause, option buyers should also have a path

**Feynman Question that exposed it:**
> "WHY does emergencyWithdrawVault work during full pause (vault writer path) but ALL MM redemption paths (mmSelfRedeem, operatorRedeemForMM) are blocked?"

**State Mapper gap that confirmed it:**
> All MM paths go through ctrl.redeem() which has `notFullyPaused`. No alternative redemption path exists for MMs during full pause.

**Breaking Operation:** `Controller.redeem` at `Controller.sol:215` has `notFullyPaused` modifier
- `mmSelfRedeem` -> `ctrl.redeem` -> blocked
- `operatorRedeemForMM._redeemForMM` -> `ctrl.redeem` -> blocked

**Trigger Sequence:**
1. Option expires ITM
2. Operator calls `batchSettleVaults` -- vault settled, ITM payout stays in MarginPool
3. Owner calls `setSystemFullyPaused(true)` before MM can redeem
4. MM tries `mmSelfRedeem` -> reverts (`notFullyPaused`)
5. Operator tries `operatorRedeemForMM` -> reverts (same)
6. MM's ITM payout locked in pool indefinitely until unpause

**Consequence:**
- MM's ITM payout is inaccessible during full pause (denial of access, not theft)
- Asymmetry: vault writers have an emergency path (`emergencyWithdrawVault`), option buyers do not
- If pause is extended (governance dispute, key loss), MM funds are locked indefinitely
- Reverts on unpause, so funds are not permanently lost unless pause is permanent

**Fix:**
Add an emergency redemption path in BatchSettler that bypasses Controller.redeem during full pause, OR remove `notFullyPaused` from Controller.redeem (since settled vaults have already released their collateral, redemption during pause is safe).

---

### Finding NM-003: Fee-on-transfer tokens cause vault collateral over-accounting

**Severity:** MEDIUM (conditional -- only exploitable if FOT token is whitelisted as collateral)
**Source:** Feynman only (F-002)
**Verification:** Code trace (Controller.sol L153, MarginPool.sol L42)

**Coupled Pair:** P1 (vault.collateralAmount <-> MarginPool actual balance)
**Invariant:** vault.collateralAmount must equal actual tokens received by pool

**Breaking Operation:** `Controller.depositCollateral` at `Controller.sol:138-158`
- Records `vault.collateralAmount += _amount` (L153) -- the requested amount
- Pool receives `safeTransferFrom(_from, pool, _amount)` (MarginPool L42) -- actual amount may be less

**Trigger Sequence:**
1. Owner whitelists a fee-on-transfer token as collateral (configuration error)
2. User deposits 100 tokens, 2% fee: pool receives 98
3. `vault.collateralAmount` records 100
4. Option expires OTM, `settleVault` returns `collateralToReturn = 100`
5. Pool tries `safeTransfer(user, 100)` but only has 98 (from this vault)
6. If pool has tokens from other vaults, it drains them; if not, reverts

**Consequence:**
- Pool insolvency: earlier settlers drain funds belonging to later settlers
- Current deployment uses USDC/WETH (not FOT) -- no immediate risk
- Risk materializes only if FOT token is whitelisted in the future

**Fix:**
```diff
  function depositCollateral(...) external ... {
      // ...
-     vault.collateralAmount += _amount;
-     MarginPool(addressBook.marginPool()).transferToPool(_asset, _owner, _amount);
+     uint256 balBefore = IERC20(_asset).balanceOf(addressBook.marginPool());
+     MarginPool(addressBook.marginPool()).transferToPool(_asset, _owner, _amount);
+     uint256 received = IERC20(_asset).balanceOf(addressBook.marginPool()) - balBefore;
+     vault.collateralAmount += received;
  }
```

---

### Finding NM-004: Cross-vault emergency withdrawal blocked by shared per-MM oToken balance

**Severity:** MEDIUM
**Source:** Cross-feed Loop: Pass 2 masking code (min() in clearMMBalanceForVault) -> Pass 3 Feynman interrogation
**Verification:** Code trace (Controller.sol L332-333, BatchSettler.sol L690-693)

**Coupled Pair:** P3 (mmOTokenBalance <-> oToken.balanceOf(settler)) + P6 (vaultMM <-> mmOTokenBalance)
**Invariant:** Each vault owner should be able to emergency withdraw independently

**Feynman Question that exposed it:**
> "WHY does clearMMBalanceForVault use `min(amount, balance)`? When would balance < amount?"

**State Mapper gap that confirmed it:**
> mmOTokenBalance is per-MM aggregate (not per-vault). Partial redemption from one vault's oTokens reduces the shared balance, blocking emergency withdrawal for another vault by the same MM.

**Breaking Operation:** `Controller.emergencyWithdrawVault` at `Controller.sol:332-333`
- Check: `mmBal = mmOTokenBalance[mm][oToken]; if (mmBal < vault.shortAmount) revert OTokensAlreadyRedeemed()`
- mmBal is shared across ALL vaults for this MM+oToken combination

**Trigger Sequence:**
1. MM executes orders for vault A (100 oTokens) and vault B (100 oTokens), same oToken
2. `mmOTokenBalance[mm][oToken]` = 200
3. Operator redeems 50 via `operatorRedeemForMM` -> balance = 150
4. System fully paused
5. Vault A owner calls `emergencyWithdrawVault`: check passes (150 >= 100), burns 100, clears 100 -> balance = 50
6. Vault B owner calls `emergencyWithdrawVault`: check FAILS (50 < 100) -> reverts with OTokensAlreadyRedeemed
7. Vault B owner's collateral is locked

**Consequence:**
- Second vault owner cannot emergency withdraw even though their collateral is intact
- Requires: same MM, same oToken, partial redemption before emergency, then multiple vault emergency withdrawals
- Vault B owner must wait for unpause and normal settlement

**Masking Code:**
```solidity
// BatchSettler.sol L691 -- the min() hides this:
uint256 toClear = amount < balance ? amount : balance;
```

**Fix:**
Add per-vault-per-MM balance tracking:
```solidity
mapping(address => mapping(uint256 => mapping(address => uint256))) public vaultMMOTokenBalance;
// Set in executeOrder: vaultMMOTokenBalance[owner][vaultId][oToken] = amount;
// Use in clearMMBalanceForVault instead of aggregate mmOTokenBalance
```

---

### Finding NM-005: De-whitelisted MM cannot self-redeem custodied oTokens

**Severity:** LOW
**Source:** Feynman only (F-007)
**Verification:** Code trace (BatchSettler.sol L653)

**Coupled Pair:** P3 (mmOTokenBalance stuck with no self-service exit)
**Invariant:** MMs should always have a path to retrieve their custodied assets

**Breaking Operation:** `BatchSettler.mmSelfRedeem` at `BatchSettler.sol:652`
- First check: `if (!whitelistedMMs[msg.sender]) revert MMNotWhitelisted()`

**Trigger Sequence:**
1. MM is whitelisted, executes orders, oTokens custodied
2. Owner calls `setWhitelistedMM(mm, false)` -- de-whitelists MM
3. MM calls `mmSelfRedeem` after expiry + escapeDelay -> reverts
4. MM depends on operator calling `operatorRedeemForMM` (no whitelist check)

**Consequence:**
- MM's funds require operator cooperation after de-whitelisting
- Mitigated by `operatorRedeemForMM` which does NOT check whitelist status
- If operator is uncooperative, MM's ITM payout is locked

---

## Feedback Loop Discoveries

| ID | Found via | Description |
|----|-----------|-------------|
| NM-002 | State parallel path comparison (Pass 2) | Neither Feynman (focused on emergency) nor State alone (focused on coupled pairs) caught the asymmetry between writer emergency paths and buyer redemption paths. The parallel path comparison in Pass 2 revealed the mismatch. |
| NM-004 | Pass 2 masking code -> Pass 3 Feynman "WHY" | The `min()` clamp in clearMMBalanceForVault was flagged as masking code by State Pass 2. Feynman Pass 3 interrogated "WHY would balance < amount?" and traced the cross-vault scenario where partial redemption blocks emergency withdrawal. |

## False Positives Eliminated

| ID | Original Claim | Reason for Elimination |
|----|---------------|----------------------|
| F-001 | Binary payout is a bug | By design -- protocol is binary options, not European |
| F-003 | Stale vault.shortAmount | Mitigated by vaultSettled flag on all write paths |
| F-006 | Shared pool cross-series drain | Under binary payout, each vault's collateral exactly covers max payout |
| SI-001 | settleVault doesn't reserve payout in pool | Pool design is correct -- payout stays in pool implicitly |
| SG-001 | Stale vault fields | View-only impact, gated by vaultSettled |
| SG-002 | No per-series pool isolation | Correct under binary payout model |
| SG-003 | Stuck unattributed oTokens | Self-harm only, no attacker benefit |

## Summary

- Total functions analyzed: 34
- Coupled state pairs mapped: 11
- Nemesis loop iterations: 4 (converged at Pass 4)
- Raw findings (pre-verification): 1 HIGH | 4 MEDIUM | 2 LOW
- Feedback loop discoveries: 2 (NM-002, NM-004 -- found ONLY via cross-feed)
- After verification: 5 TRUE POSITIVE | 7 FALSE POSITIVE | 0 DOWNGRADED
- **Final: 1 HIGH | 3 MEDIUM | 1 LOW**

---

## Addendum: PR #37 Decimal Scaling Verification (2026-03-17)

**Scope:** Focused re-audit of Controller.sol and BatchSettler.sol decimal scaling changes introduced by PR #37 (WBTC support), plus re-verification of pre-existing emergencyWithdrawVault/settlement logic.

**Branch:** `fix/b1n-182-controller-decimal-scaling`

### PR #37 Changes Audited

1. **Controller._getRequiredCollateral (L255-264):** Added bidirectional decimal bounds
   - Put path: `if (cd < 6 || cd > 16) revert UnsupportedDecimals()`
   - Call path: `if (cd < 8 || cd > 18) revert UnsupportedDecimals()`

2. **Controller._calculatePayout (L266-279):** Same bounds added to payout calculation

3. **BatchSettler._executePhysicalRedeem (L597-607):** Decimal-aware contra amount computation
   - Put: `contraAmount = amount * (10 ** (ud - 8))` with `ud in [8,18]`
   - Call: `contraAmount = (amount * strike) / (10 ** (16 - sd))` with `sd in [6,16]`

### Numerical Verification Matrix

| Scenario | Formula | Input | Result | Correct? |
|---|---|---|---|---|
| PUT collateral, USDC (6dec) | `(1e8 * 2500e8) / 10^10` | strike=$2500 | 2500e6 | Yes |
| PUT collateral, 16dec token | `(1e8 * 2500e8) / 10^0` | strike=$2500 | 2.5e19 | Yes |
| CALL collateral, WBTC (8dec) | `1e8 * 10^0` | 1 option | 1e8 (1 BTC) | Yes |
| CALL collateral, WETH (18dec) | `1e8 * 10^10` | 1 option | 1e18 (1 ETH) | Yes |
| Physical PUT contra, WETH (18dec) | `1e8 * 10^10` | 1 option | 1e18 (1 ETH) | Yes |
| Physical PUT contra, WBTC (8dec) | `1e8 * 10^0` | 1 option | 1e8 (1 BTC) | Yes |
| Physical CALL contra, USDC (6dec) | `(1e8 * 90000e8) / 10^10` | strike=$90k | 90000e6 | Yes |

### Cross-Contract Consistency

| Check | Controller | BatchSettler | Match? |
|---|---|---|---|
| Put collateral bounds | `cd in [6,16]` | N/A (collateral handled by Controller) | -- |
| Call collateral bounds | `cd in [8,18]` | N/A (collateral handled by Controller) | -- |
| Put contra (underlying) bounds | N/A | `ud in [8,18]` (same asset class as call collateral) | Yes |
| Call contra (strike) bounds | N/A | `sd in [6,16]` (same asset class as put collateral) | Yes |
| Put payout = put required collateral | `(amt*strike)/10^(16-cd)` | N/A | Identical formulas |
| Call payout = call required collateral | `amt*10^(cd-8)` | N/A | Identical formulas |

### Overflow Analysis

- Max realistic `amount * strikePrice`: ~1e16 * 1e14 = 1e30 (well under 2^256)
- Max `amount * 10^10`: ~1e16 * 1e10 = 1e26 (safe)
- Exponent ranges: Put `[0,10]`, Call `[0,10]` -- no underflow possible within bounds

### Previously Reported _revertOnPanic Bug: FALSE POSITIVE

A previous analysis claimed `_revertOnPanic` (BatchSettler.sol:719-727) was bugged because `mload(add(reason, 32))` loads 32 bytes including the panic code argument. Re-analysis confirms: for all standard Solidity panic codes (0x00-0x51), the uint256 argument's high 28 bytes are zero. The first 32 bytes of ABI-encoded Panic data produce `0x4e487b71` followed by 28 zero bytes, which correctly matches `_PANIC_SELECTOR` after bytes4 extraction.

### PR #37 Verdict

**All decimal scaling changes are SOUND.** No new findings. All 5 pre-existing findings (NM-001 through NM-005) remain unchanged and unaffected by PR #37.
