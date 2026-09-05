# 🔐 Security Review — Oracle

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename                                               |
| **Files reviewed**               | `src/core/Oracle.sol`                                  |
| **Confidence threshold (1-100)** | 75                                                     |

**Completeness:** 9 unique `(Contract, function)` areas were raised across the 12 audit agents; 6 are covered below. The remaining 3 owner-only configuration paths were rejected under the access-control gate because no unprivileged amplifier was demonstrated.

## Findings

[75] **1. Legacy generic settlement still accepts a post-expiry price**

`Oracle.setExpiryPrice` · Confidence: 75

**Description**

The unchanged legacy path compares against `latestRoundData()` at submission time, so an authorized operator can wait for a favorable post-expiry update and permanently store it as the expiry price; this remains an explicit B1N-496 compatibility exception.

---

[75] **2. Historical settlement round and submitted price remain operator-selectable**

`Oracle.setExpiryPriceAtRound` · Confidence: 75

**Description**

The new round-specific path accepts any valid round before expiry within the configured age window and, when deviation checking is enabled, also permits a different submitted price within tolerance; with a zero threshold it does not bind the submitted price to the selected round at all.

---

[75] **3. Close settlement does not identify a unique official-close round**

`Oracle.setExpiryPriceFromCloseAtRound` · Confidence: 75

**Description**

Any complete round published from `closeAt` through the one-hour capture window passes `_validateFinalizedCloseRound`, allowing an authorized operator to choose among multiple economically different post-close rounds despite the owner-precommitted calendar.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [75] | Legacy generic settlement still accepts a post-expiry price |
| 2 | [75] | Historical settlement round and submitted price remain operator-selectable |
| 3 | [75] | Close settlement does not identify a unique official-close round |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Live round metadata is not fully validated** — `Oracle.getPrice` — Code smells: ignored `roundId`, `answeredInRound`, zero timestamps, and unchecked future-timestamp subtraction. A malformed feed round could be accepted when freshness is disabled or cause a panic when enabled; production-feed reachability remains unverified.
- **Pre-close feed publications can make close settlement unavailable** — `Oracle._validateFinalizedCloseRound` — Code smells: all observations with `updatedAt < closeAt` are rejected. If a supported feed publishes the final close immediately before the calendar boundary and no update arrives during the capture window, settlement may remain unsettable before the next session opens.
- **Zero deviation threshold removes the round-price binding** — `Oracle._validatePriceDeviationAgainst` — Code smells: the early return for `priceDeviationThresholdBps == 0` allows arbitrary positive submitted prices in round-specific settlement. Whether zero is intentionally configured as unrestricted manual pricing remains unverified.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
