# Oracle Pashov-style defensive re-audit

- Target: `src/core/Oracle.sol`
- Scope: post-remediation phase-aware historical settlement, delayed staleness, same-block finality, exact prices, metadata, close windows, storage compatibility.
- Method: independent read-only multi-agent review on the final local source. No remote or holdout repositories accessed.

## Remediated findings

1. Phase-boundary predecessor/successor validation now uses owner-recorded phase metadata instead of numeric proxy adjacency at phase transitions.
2. Active phases use an open terminal bound and are checked against the proxy's current phase. The terminal round can be finalized only after the proxy advances.
3. Same-phase predecessors/successors are accepted with phase-local validation.
4. Same-block phase activation equality is accepted for a predecessor timestamp because block timestamps do not encode transaction order.
5. Strict latest-round settlement requires a transaction after expiry, preventing same-expiry-block finality races.
6. Latest-round settlement now validates configured phase metadata.
7. Historical freshness is anchored at expiry, not delayed submission time.

## Final review result

No additional exploitable phase, staleness, metadata, exact-price, close-window, or same-block bypass was identified by the completed final review agents.

### Remaining operational lead

Historical validation still derives same-phase neighbors as `roundId - 1` and `roundId + 1`. If a deployed Chainlink aggregator exposes genuinely non-contiguous local round IDs, settlement fails closed for the affected expiry. The final review had no evidence that the configured production feeds exhibit this behavior, but production must explicitly qualify feed contiguity or add a feed-specific neighbor mechanism.

Other leads are owner-trusted phase metadata and existing operator continuity during ownership rotation. Neither is an unprivileged bypass in the current design.

## Verification

- Oracle, market-hours, and phase-boundary tests: 65 passed.
- Upgrade tests: 50 passed.
- Fuzz tests: 23 passed.
- Full offline build: passed.
- Non-fork unit suite: 698 passed, with the known `RuntimeBudget` baseline assertion still failing.
- Storage and dependency checks: passed.
- Backend targeted tests: 133 passed.
- Ruff checks and formatting: passed.

Production remains blocked pending acceptance of the feed-contiguity assumption by the authorized audit/release owner.
