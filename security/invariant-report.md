# Invariant Report — b1nary Options Protocol

24 invariant properties tested via Foundry stateful fuzzing.

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

Scope: complete options lifecycle for both PUT and CALL options —
order execution, expiry, vault settlement, cash redemption, physical
delivery, plus negative tests. Each run randomly creates puts
(collateral=USDC) and calls (collateral=WETH) to exercise both
code paths through the protocol.

Handler actions:
- `executeOrder` — pre-expiry: randomly pick PUT or CALL, sign EIP-712 quote, execute via BatchSettler
- `expire` — one-shot: warp to expiry+1, set oracle + chainlink prices
- `settleVault` — post-expiry: settle via batchSettleVaults (handles both USDC and WETH outflows)
- `redeemTokens` — post-expiry: MM redeems random put/call oTokens via batchRedeem
- `physicalRedeemPut` — post-expiry ITM put: flash loan WETH + swap USDC→WETH delivery
- `physicalRedeemCall` — post-expiry ITM call: flash loan USDC + swap WETH→USDC delivery
- `tryMintExpired` — negative: attempt mint after expiry (both token types)
- `tryDoubleSettle` — negative: attempt re-settle
- `tryOverwriteOracle` — negative: attempt oracle price overwrite
- `tryUnauthorizedCall` — negative: test 6 privileged functions
- `tryCallbackTamper` — negative: attempt flash loan callback hijacking
- `tryStaleNonceQuote` — negative: attempt fill after nonce increment

### 6. noExpiredMint

After expiry, no call to `Controller.mintOtoken` succeeds. The
handler's `tryMintExpired` action attempts to mint after warping past
expiry; the `expiredMintSucceeded` flag must remain false.

**Bug found:** Controller was missing the expiry check. Fixed in
B1N-83 by adding `if (block.timestamp >= oToken.expiry()) revert
OptionExpired()` to `mintOtoken`. Regression caught in B1N-100 after
betaMode removal lost the fix.

### 7. collateralConservation

MarginPool's USDC and WETH balances each equal
`totalPoolInflow - totalPoolOutflow` tracked by the handler. Both
collateral types are verified independently.

USDC inflows: PUT collateral deposits during `executeOrder`.
USDC outflows: collateral returned during PUT `settleVault`, payouts
during PUT `redeemTokens` and `physicalRedeemPut`.

WETH inflows: CALL collateral deposits during `executeOrder`.
WETH outflows: collateral returned during CALL `settleVault`, payouts
during CALL `redeemTokens` and `physicalRedeemCall`.

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
- `Controller.setPartialPauser`
- `Controller.transferOwnership`
- `BatchSettler.setOperator`
- `BatchSettler.setProtocolFeeBps`
- `Oracle.setPriceFeed`
- `Whitelist.whitelistCollateral`

All must revert. The `accessControlBypassed` flag must remain false.

### 12. itmSettleReturnsZero

For ITM-settled vaults, the vault's `collateralAmount` exactly equals
the payout obligation. The writer receives 0 collateral back. This
validates the payout math for both option types:
- PUT ITM (expiryPrice < strike): `payout = amount * strike / 1e10`
  consumes 100% of deposited USDC collateral
- CALL ITM (expiryPrice > strike): `payout = amount * 1e10` consumes
  100% of deposited WETH collateral

### 13. quoteFillNeverExceedsMax

For every executed quote hash, the filled amount (lower 255 bits of
`quoteState`) never exceeds `maxAmount` (100e8 in the handler). The
BatchSettler's fill tracking correctly prevents over-fill.

### 14. vaultOTokenConsistency

For each option type separately:
`sum(vault.shortAmount)` for all put (or call) vaults equals
`oToken.totalSupply() + totalOTokensBurned` for that token type.
Every minted oToken is accounted for — either still circulating or
burned via redeem/settlement. Put and call tokens are tracked
independently to ensure cross-type accounting is correct.

### 15. noDoubleSettle

Settling an already-settled vault always reverts. The handler's
`tryDoubleSettle` action attempts to re-settle; the
`doubleSettleSucceeded` flag must remain false.

### 16. physicalDeliveryExactAmount

For every physical delivery executed by the handler, the user receives
exactly the expected contra-asset amount:
- PUT: user receives `amount * 1e10` WETH (the underlying) via
  flash loan WETH → redeem USDC → swap USDC→WETH → repay
- CALL: user receives `(amount * strike) / 1e10` USDC (the strike
  asset) via flash loan USDC → redeem WETH → swap WETH→USDC → repay

The handler records `expectedContraAmount` and `actualContraReceived`
for each delivery and the invariant asserts they are equal. This
validates the flash loan → redeem → swap → transfer pipeline delivers
exact amounts with no rounding loss or leakage for both directions.

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

## Pause/Emergency Invariants (PauseEmergencyHandler)

Scope: pause state transitions and emergency withdraw behavior.
Handler creates 3 vaults with collateral, then randomly toggles
pause states and probes all vault operations + emergency withdraw.

Handler actions:
- `togglePartialPause` — toggle partial pause via pauser role
- `toggleFullPause` — toggle full pause via owner
- `tryEntryWhilePartiallyPaused` — probe deposit during partial pause
- `tryOpsWhileFullyPaused` — probe all 5 vault ops during full pause
- `tryEmergencyWithdrawWhenNotPaused` — probe emergency withdraw when not paused
- `tryEmergencyWithdrawByNonOwner` — probe emergency withdraw by attacker
- `tryEmergencyWithdrawOnSettled` — probe emergency withdraw on settled vault
- `doEmergencyWithdrawAndRetry` — valid withdraw + immediate retry (double-claim check)

### 19. partialPauseBlocksEntry

When `systemPartiallyPaused == true`, `depositCollateral` reverts.
Entry operations (deposit, mint) are blocked. Exit operations
(settle, redeem) remain available. The
`entrySucceededWhilePartiallyPaused` flag must remain false.

### 20. fullPauseBlocksAll

When `systemFullyPaused == true`, all 5 vault operations revert:
`openVault`, `depositCollateral`, `mintOtoken`, `settleVault`,
`redeem`. The `anyOpSucceededWhileFullyPaused` flag must remain false.

### 21. emergencyWithdrawOnlyWhenFullyPaused

`emergencyWithdrawVault` reverts unless `systemFullyPaused == true`.
The `emergencyWithdrawSucceededWhenNotFullyPaused` flag must remain
false.

### 22. emergencyWithdrawOnlyForVaultOwner

An attacker (non-vault-owner) cannot call `emergencyWithdrawVault` to
steal another user's collateral. The vault lookup uses
`msg.sender` as the owner key. The
`emergencyWithdrawByNonOwnerSucceeded` flag must remain false.

### 23. emergencyWithdrawOnlyForUnsettled

`emergencyWithdrawVault` reverts on already-settled vaults (whether
settled via `settleVault` or a prior `emergencyWithdrawVault`). The
`emergencyWithdrawOnSettledSucceeded` flag must remain false.

### 24. emergencyWithdrawMarksSettled

After a successful `emergencyWithdrawVault`, the vault is marked as
settled. An immediate retry on the same vault reverts with
`VaultAlreadySettledError`. The `doubleEmergencyWithdrawSucceeded`
flag must remain false. This prevents double-claim of collateral.

## Run Configuration

Default profile: 256 runs, 500 calls per run.
Security profile: 10,000 fuzz runs, 1,000 invariant runs, depth 100.

```bash
# Default
forge test --match-path test/Invariant.t.sol -vv

# Security (deeper)
FOUNDRY_PROFILE=security forge test --match-path test/Invariant.t.sol -vv
```
