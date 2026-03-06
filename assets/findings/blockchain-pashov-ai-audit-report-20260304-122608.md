# Security Review — b1nary Options Protocol

> This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | DEEP (full repo + adversarial reasoning)               |
| **Files reviewed**               | `AddressBook.sol` · `BatchSettler.sol` · `Controller.sol`<br>`MarginPool.sol` · `Oracle.sol` · `OToken.sol`<br>`OTokenFactory.sol` · `Whitelist.sol` |
| **Confidence threshold (1-100)** | 75                                                     |

---

## Findings

| # | Confidence | Title |
|---|---|---|
| 1 | [100] | Undercollateralized minting via repeated `mintOtoken` calls drains MarginPool |
| 2 | [75] | Chainlink `latestRoundData()` missing staleness check and L2 sequencer uptime validation |
| 3 | [75] | Missing deadline on Uniswap `exactOutputSingle` swap |
| 4 | [75] | Fee-on-transfer collateral tokens inflate vault accounting |
| 5 | [75] | Emergency withdrawal leaves oToken holders with unbacked claims |
| | | **Below Confidence Threshold** |
| 6 | [65] | USDC blacklist on vault owner permanently locks collateral |
| 7 | [65] | UUPS upgrade not atomic with post-upgrade configuration |
| 8 | [60] | Rebasing collateral tokens cause MarginPool accounting drift |

---

[100] **1. Undercollateralized Minting via Repeated `mintOtoken` Calls Drains MarginPool**

`Controller.mintOtoken` · Confidence: 100

**Description**

The collateral sufficiency check compares `vault.collateralAmount` against `_getRequiredCollateral(oToken, _amount)` using only the current mint `_amount` rather than the cumulative `vault.shortAmount + _amount`, allowing a vault owner to call `mintOtoken` multiple times to mint far more oTokens than collateral supports — e.g., a vault with 100 collateral can mint 80 + 80 = 160 oTokens (needing 200 collateral), creating unbacked oTokens. When ITM, `settleVault` reverts due to arithmetic underflow (`collateralAmount - payout`), making the vault permanently unsettleable, while redeemers call `redeem()` and drain other vault owners' collateral from the shared MarginPool.

**Fix**

```diff
- uint256 requiredCollateral = _getRequiredCollateral(oToken, _amount);
+ uint256 requiredCollateral = _getRequiredCollateral(oToken, vault.shortAmount + _amount);
  if (vault.collateralAmount < requiredCollateral) revert InsufficientCollateral();
```

As defense-in-depth in `settleVault`:

```diff
- uint256 collateralToReturn = vault.collateralAmount - payout;
+ uint256 collateralToReturn = payout >= vault.collateralAmount
+     ? 0
+     : vault.collateralAmount - payout;
```

---

[75] **2. Chainlink `latestRoundData()` Missing Staleness Check and L2 Sequencer Uptime Validation**

`Oracle._validatePriceDeviation` / `Oracle.getPrice` · Confidence: 75

**Description**

`_validatePriceDeviation` and `getPrice` call `latestRoundData()` but never check `updatedAt` against a maximum age threshold and never query the Chainlink L2 Sequencer Uptime Feed required on Base — during a sequencer outage the function compares the submitted expiry price against a stale Chainlink answer, allowing an expiry price to pass the deviation guard even if it diverges significantly from the true market price. Additionally, the deviation check uses the *current* Chainlink price rather than the price at the expiry timestamp, meaning valid expiry prices may be rejected if significant time elapses between expiry and price submission.

---

[75] **3. Missing Deadline on Uniswap `exactOutputSingle` Swap**

`BatchSettler._redeemAndSwap` · Confidence: 75

**Description**

The `ExactOutputSingleParams` struct passed to `swapRouter.exactOutputSingle` omits a `deadline` field, allowing validators to hold the transaction in the mempool and execute it at a later block when the price has moved against the protocol, consuming up to `maxCollateralSpent` of the operator's collateral surplus.

---

[75] **4. Fee-on-Transfer Collateral Tokens Inflate Vault Accounting**

`Controller.depositCollateral` / `MarginPool.transferToPool` · Confidence: 75

**Description**

`Controller` records `vault.collateralAmount += _amount` using the nominal deposit amount before transfer fees are deducted, while `MarginPool` receives only `_amount - fee`; at settlement, `transferToUser` attempts to send the full over-recorded amount and reverts, permanently locking the vault owner's collateral.

---

[75] **5. Emergency Withdrawal Leaves oToken Holders with Unbacked Claims**

`Controller.emergencyWithdrawVault` · Confidence: 75

**Description**

When the system is fully paused, any vault owner can call `emergencyWithdrawVault` to reclaim the full `vault.collateralAmount` immediately, leaving all outstanding oTokens minted against that vault permanently unbacked with no mechanism for oToken holders to recover their collateral claim.

---

[65] **6. USDC Blacklist on Vault Owner Permanently Locks Collateral**

`Controller.settleVault` / `MarginPool.transferToUser` · Confidence: 65

**Description**

If a vault owner's address is added to the USDC blocklist after depositing collateral, every settlement path (`settleVault`, `emergencyWithdrawVault`) ultimately calls `MarginPool.transferToUser` which pushes directly to the owner's address and reverts — the collateral can never be returned.

---

[65] **7. UUPS Upgrade Not Atomic with Post-Upgrade Configuration**

`BatchSettler._authorizeUpgrade` / `Controller._authorizeUpgrade` · Confidence: 65

**Description**

`upgradeTo()` and any subsequent configuration calls are separate transactions, creating a window where the upgraded implementation is live but not yet properly configured; a searcher monitoring the mempool can interact with the protocol in the intermediate state.

---

[60] **8. Rebasing Collateral Tokens Cause MarginPool Accounting Drift**

`Controller.settleVault` / `MarginPool` · Confidence: 60

**Description**

`vault.collateralAmount` is set once at deposit time and never updated; if a rebasing token (e.g., stETH, aToken, AMPL) is whitelisted as collateral, the actual balance held in MarginPool diverges from the sum of all vault records over time, causing settlement transfers to revert on a negative rebase or silently under-distribute on a positive rebase.
