# Invariant Report — b1nary Options Protocol

18 invariant properties tested via Foundry stateful fuzzing.

## Original Invariants (ProtocolHandler)

Scope: vault open/deposit/mint lifecycle (pre-expiry only).

### 1. poolBalanceMatchesDeposits

Pool's USDC balance equals the sum of all deposits made via
`depositCollateral`. No collateral appears or vanishes before
settlement.

### 2. oTokenSupplyMatchesMinted

OToken `totalSupply()` equals the sum of all amounts passed to
`mintOtoken`. No tokens minted outside the handler's tracked calls.

### 3. poolCoversObligations

Pool balance >= sum of all vault `collateralAmount` values. The pool
always has enough to cover every vault's stored collateral.

### 4. vaultCountConsistent

`controller.vaultCount(user)` equals the number of vaults opened
by each user in the handler. No phantom vaults.

## Batch Redeem Invariant (BatchRedeemHandler)

### 5. batchRedeemNeverRevertsCompletely

`batchRedeem` with valid arrays never reverts at the batch level,
even if individual redeems fail (e.g., revoked approval). The
try/catch in the loop ensures graceful degradation.

## Full Lifecycle Invariants (FullLifecycleHandler)

Scope: complete options lifecycle — order execution, expiry, vault
settlement, cash redemption, physical delivery, plus negative tests.

Handler actions:
- `executeOrder` — pre-expiry: sign EIP-712 quote, execute via BatchSettler
- `expire` — one-shot: warp to expiry+1, set oracle + chainlink prices
- `settleVault` — post-expiry: settle via batchSettleVaults
- `redeemTokens` — post-expiry: MM redeems via batchRedeem
- `physicalRedeem` — post-expiry ITM: flash loan + swap delivery
- `tryMintExpired` — negative: attempt mint after expiry
- `tryDoubleSettle` — negative: attempt re-settle
- `tryOverwriteOracle` — negative: attempt oracle price overwrite
- `tryUnauthorizedCall` — negative: test 6 privileged functions

### 6. noExpiredMint

After expiry, no call to `Controller.mintOtoken` succeeds. The
handler's `tryMintExpired` action attempts to mint after warping past
expiry; the `expiredMintSucceeded` flag must remain false.

**Bug found:** Controller was missing the expiry check. Fixed by
adding `if (!betaMode && block.timestamp >= oToken.expiry()) revert
OptionExpired()` to `mintOtoken`.

### 7. collateralConservation

MarginPool's USDC balance equals `totalPoolInflow - totalPoolOutflow`
tracked by the handler. Every token entering or leaving the pool is
accounted for.

Inflows: collateral deposits during `executeOrder`.
Outflows: collateral returned during `settleVault`, payouts during
`redeemTokens` and `physicalRedeem`.

### 8. premiumConservation

`totalGrossPremium == totalNetPremium + totalFees`. No dust lost in
the fee split arithmetic. Verified across all executed orders.

### 9. oracleImmutability

Once an expiry price is set, `setExpiryPrice` cannot overwrite it.
The handler's `tryOverwriteOracle` action attempts to set a different
price for an already-set (asset, expiry) pair; the
`oracleOverwriteSucceeded` flag must remain false.

### 10. settlerHoldsNoTokens

After every sequence, `BatchSettler` holds 0 USDC and 0 WETH. The
settler is a pass-through — it should never accumulate tokens. This
validates the physical delivery flow completes fully (flash loan
repaid, swap output forwarded).

### 11. accessControlExhaustive

6 owner-only functions tested from a random attacker address:
- `Controller.setBetaMode`
- `Controller.transferOwnership`
- `BatchSettler.setOperator`
- `BatchSettler.setProtocolFeeBps`
- `Oracle.setPriceFeed`
- `Whitelist.whitelistCollateral`

All must revert. The `accessControlBypassed` flag must remain false.

### 12. itmSettleReturnsZero

For ITM-settled vaults (expiry price < strike for puts), the vault's
`collateralAmount` exactly equals the payout obligation. The writer
receives 0 collateral back. This validates the payout math:
`payout = amount * strike / 1e10` consumes 100% of deposited
collateral for puts.

### 13. quoteFillNeverExceedsMax

For every executed quote hash, the filled amount (lower 255 bits of
`quoteState`) never exceeds `maxAmount` (100e8 in the handler). The
BatchSettler's fill tracking correctly prevents over-fill.

### 14. vaultOTokenConsistency

`sum(vault.shortAmount)` for all tracked vaults equals
`oToken.totalSupply() + totalOTokensBurned`. Every minted oToken is
accounted for — either still circulating or burned via
redeem/settlement.

### 15. noDoubleSettle

Settling an already-settled vault always reverts. The handler's
`tryDoubleSettle` action attempts to re-settle; the
`doubleSettleSucceeded` flag must remain false.

### 16. physicalDeliveryExactAmount

For every physical delivery executed by the handler, the user receives
exactly the expected contra-asset amount. For puts: `amount * 1e10`
WETH (the underlying). The handler records `expectedContraAmount` and
`actualContraReceived` for each delivery and the invariant asserts
they are equal. This validates the flash loan → redeem → swap →
transfer pipeline delivers exact amounts with no rounding loss or
leakage.

### 17. noCallbackTampering

The flash loan callback (`executeOperation`) cannot be called
directly by an attacker. The handler's `tryCallbackTamper` action
attempts two attack vectors:
1. Random caller with fabricated params (redirecting funds to attacker)
2. Correct Aave pool address but wrong initiator

Both must revert. The `callbackTamperSucceeded` flag must remain
false. This validates that the `msg.sender == aavePool` and
`initiator == address(this)` guards prevent callback hijacking.

### 18. makerNonceInvalidation

After `incrementMakerNonce()`, all previously-signed quotes become
unfillable. The handler's `tryStaleNonceQuote` action:
1. Signs a valid quote at the current nonce
2. MM calls `incrementMakerNonce()` (circuit breaker)
3. Attempts to fill the now-stale quote

The fill must revert with `StaleNonce`. The `staleNonceQuoteFilled`
flag must remain false. This validates the bulk cancellation mechanism
that lets MMs invalidate all outstanding quotes in a single tx.

## Run Configuration

Default profile: 256 runs, 500 calls per run.
Security profile: 1,000 runs, depth 100.

```bash
# Default
forge test --match-path test/Invariant.t.sol -vv

# Security (deeper)
FOUNDRY_PROFILE=security forge test --match-path test/Invariant.t.sol -vv
```
