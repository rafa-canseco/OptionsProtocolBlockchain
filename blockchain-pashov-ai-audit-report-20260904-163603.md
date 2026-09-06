# 🔐 Security Review — Oracle

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename                                               |
| **Files reviewed**               | `src/core/Oracle.sol`                                  |
| **Confidence threshold (1-100)** | 80                                                     |

Fresh remediation review using 12 parallel specialty and gap-hunter passes.

## Findings

[95] **1. Chainlink phase transition blocks close predecessor validation**

`Oracle._validateFirstCloseRound` · Confidence: 95

**Description**

The close validator derives the previous Chainlink proxy round with `_roundId - 1`, which is not the chronological predecessor when the proxy changes aggregator phase, so valid close settlement reverts and leaves expiry prices unset.

**Fix**

```diff
- _validateFirstCloseRound(_feed, _roundId, _closeAt);
+ _validateFirstCloseRound(_feed, _roundId, _closeAt, _previousRoundId);
```

Resolve and pass an explicit phase-aware predecessor round, then validate its returned ID, metadata, and timestamp.
---

[95] **2. Chainlink phase transition blocks expiry successor validation**

`Oracle._validateExpiryRound` · Confidence: 95

**Description**

The historical expiry validator derives the next Chainlink proxy round with `_roundId + 1`, which is not the chronological successor across a phase boundary, so valid exact-price settlement becomes permanently unavailable.

**Fix**

```diff
- _validateExpiryRound(feed, roundId, _expiry);
+ _validateExpiryRound(feed, roundId, _expiry, _nextRoundId);
```

Resolve and pass an explicit phase-aware successor round, then validate its returned ID, metadata, and post-expiry timestamp.
---

[82] **3. Delayed settlement can reject a price that was fresh at expiry**

`Oracle._validateExpiryPriceAtLatestRound` · Confidence: 82

**Description**

The latest-round path measures staleness against transaction time while the historical path measures it against expiry, so a delayed bot or feed outage can block a valid expiry price even though it was fresh when the option expired.

**Fix**

```diff
- if (maxAge > 0 && block.timestamp - updatedAt > maxAge) {
+ if (maxAge > 0 && _expiry - updatedAt > maxAge) {
```

The existing `updatedAt <= _expiry` check makes this subtraction safe.
---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [95] | Chainlink phase transition blocks close predecessor validation |
| 2 | [95] | Chainlink phase transition blocks expiry successor validation |
| 3 | [82] | Delayed settlement can reject a price that was fresh at expiry |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Same-block expiry round race** — `Oracle.setExpiryPrice` — Code smells: canonical-round timing — A transaction at the expiry timestamp can store the current pre-expiry round before a later Chainlink transmission in the same block reports another round at the expiry timestamp; the operator-only trigger and feed ordering assumptions need confirmation.
- **Close report is not authenticated as an official close** — `Oracle._validateFinalizedClose` — Code smells: caller-independent calendar semantics — The owner-committed timestamps and proximity checks prove timing but not that the selected feed update is the exchange's official close; exploitability depends on the configured feed's close-publication guarantees.
- **Feed denomination and decimals are not validated** — `Oracle.setPriceFeed` — Code smells: unchecked feed metadata — The protocol interprets answers as eight-decimal USD prices while the owner can register any nonzero address; no concrete misconfigured production feed was verified.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
