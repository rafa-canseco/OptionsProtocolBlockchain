# 🔐 Security Review — Oracle

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename (`src/core/Oracle.sol`)                      |
| **Files reviewed**               | `src/core/Oracle.sol`                                  |
| **Confidence threshold (1-100)** | 75                                                     |

---

## Findings

[75] **1. Market-hours settlement can be bypassed through the legacy writer [agents: 4]**

`Oracle.setExpiryPrice` · Confidence: 75

**Description**

`setExpiryPrice` never checks `marketHoursAsset`, so an operator can permanently store a fresh next-session price for an enabled market-hours asset instead of the required official close price.

**Fix**

```diff
 function setExpiryPrice(address _asset, uint256 _expiry, uint256 _price) external {
     if (msg.sender != owner && msg.sender != operator) {
         revert OnlyOwnerOrOperator();
     }
+    if (marketHoursAsset[_asset]) revert InvalidCloseWindow();
```

---

[75] **2. Generic expiry settlement is bound to submission time, not expiry [agents: 2]**

`Oracle.setExpiryPrice` · Confidence: 75

**Description**

For non-market-hours assets, the setter validates `_price` against `latestRoundData()` at call time without requiring the selected observation to be at or before `_expiry`, allowing delayed settlement to lock a post-expiry price.

**Fix**

```diff
-    (, int256 answer,, uint256 updatedAt,) = IChainlinkAggregator(feed).latestRoundData();
+    // Read and validate a historical Chainlink round whose updatedAt is bound to _expiry.
+    (, int256 answer,, uint256 updatedAt,) = IChainlinkAggregator(feed).getRoundData(roundId);
+    if (updatedAt > _expiry) revert InvalidCloseWindow();
```

---

[75] **3. Caller-controlled session boundaries and symmetric capture do not prove an official close [agents: 6]**

`Oracle.setExpiryPriceFromClose` · Confidence: 75

**Description**

The operator supplies both `_closeAt` and `_nextSessionOpenAt`, and `_validateFinalizedClose` only checks a symmetric one-hour timestamp distance, so a fabricated calendar can relabel an ordinary pre-close or after-hours round as the official close.

**Fix (Option A — trusted calendar)**

```diff
-    // caller-supplied _closeAt and _nextSessionOpenAt
+    // derive or verify both boundaries against a trusted on-chain exchange calendar
```

**Fix (Option B — precommitted calendar)**

```diff
-    // arbitrary session timestamps accepted from the settlement caller
+    // require owner-approved, precommitted close/open timestamps distinct from the operator
```

**Fix (Option C — official-close attestation)**

```diff
-    if (updatedAt > _closeAt + CLOSE_CAPTURE_WINDOW || updatedAt + CLOSE_CAPTURE_WINDOW < _closeAt)
+    // validate an authenticated market-status/official-close datum or feed-specific close round
```

---

[75] **4. Close settlement accepts observations published after expiry [agents: 3]**

`Oracle.setExpiryPriceFromClose` · Confidence: 75

**Description**

The close path bounds `updatedAt` only around caller-supplied `_closeAt` and never requires `updatedAt <= _expiry`, allowing a round published after expiry to determine the immutable settlement price.

**Fix**

```diff
         uint256 feedUpdatedAt = _validateFinalizedClose(_asset, _price, _closeAt);
+        if (feedUpdatedAt > _expiry) revert InvalidCloseWindow();
```

---

[75] **5. Latest-round-only lookup can make a valid historical close un-settleable [agents: 4]**

`Oracle.setExpiryPriceFromClose` · Confidence: 75

**Description**

After a later Chainlink update falls outside the one-hour close window, `latestRoundData()` no longer exposes the valid historical close and the contract cannot lock the expiry price despite the advertised 96-hour close-age window.

**Fix (Option A — historical round lookup)**

```diff
-    latestRoundData()
+    getRoundData(_roundId)
```

**Fix (Option B — persist the qualifying close)**

```diff
-    // query only the latest round during settlement
+    // persist the qualifying close round when it is observed
```

---

[75] **6. Downward BPS rounding permits out-of-bound settlement prices [agents: 2]**

`Oracle._validatePriceDeviation` · Confidence: 75

**Description**

Integer division floors the calculated deviation before comparison, allowing a price almost one basis point beyond the configured limit and potentially flipping a binary settlement decision near a strike.

**Fix**

```diff
-        uint256 deviationBps = (diff * 10_000) / chainlinkPrice;
+        uint256 deviationBps = Math.mulDiv(diff, 10_000, chainlinkPrice, Math.Rounding.Ceil);
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [75] | Market-hours settlement can be bypassed through the legacy writer [agents: 4] |
| 2 | [75] | Generic expiry settlement is bound to submission time, not expiry [agents: 2] |
| 3 | [75] | Caller-controlled session boundaries and symmetric capture do not prove an official close [agents: 6] |
| 4 | [75] | Close settlement accepts observations published after expiry [agents: 3] |
| 5 | [75] | Latest-round-only lookup can make a valid historical close un-settleable [agents: 4] |
| 6 | [75] | Downward BPS rounding permits out-of-bound settlement prices [agents: 2] |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Incomplete Chainlink round validation** — `Oracle.getPrice` — Code smells: `roundId`, `startedAt`, and `answeredInRound` are ignored even though the close path rejects incomplete or inconsistent rounds; confirm whether any configured feed can expose malformed metadata.
- **Future feed timestamps panic live pricing** — `Oracle.getPrice` — Code smells: `block.timestamp - updatedAt` can underflow before a future timestamp is rejected; confirm whether a configured feed or proxy can return a future-dated round.
- **Future feed timestamps panic generic expiry validation** — `Oracle._validatePriceDeviation` — Code smells: the same unchecked subtraction can revert with a Solidity panic and block expiry capture; production-feed reachability remains unverified.
- **Missing-feed deviation check fails open** — `Oracle._validatePriceDeviation` — Code smells: a zero feed address returns successfully whenever the deviation threshold is nonzero, allowing the operator to store an unbounded positive price; the affected live deployment state was not verified.
- **Disabling deviation also disables freshness validation** — `Oracle._validatePriceDeviation` — Code smells: an early return on `priceDeviationThresholdBps == 0` skips the independently configured `maxOracleStaleness` check; confirm whether threshold zero is ever used with stale-data protection expected.
- **Feed decimal scale is unchecked** — `Oracle.setPriceFeed` — Code smells: feeds are stored and consumed as eight-decimal prices but `decimals()` is neither exposed nor validated; confirm every configured production feed’s denomination.
- **Historical round retrieval is unavailable inside the close validator** — `Oracle._validateFinalizedClose` — Code smells: only `latestRoundData()` is available through the interface, so a valid close can become inaccessible after another feed update; confirm the configured feeds’ closed-session update behavior.
- **Operator privilege survives ownership rotation** — `Oracle.acceptOwnership` — Code smells: changing `owner` leaves the previous operator unchanged and able to win first-write races for unset expiry prices; confirm whether operator rotation is intentionally independent.
- **Proxy initialization must be atomic** — `Oracle.initialize` — Code smells: the initializer is publicly callable once in proxy storage; if deployment is not atomically initialized, the first caller can set owner and upgrade authority. Deployment evidence was not part of this source review.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
