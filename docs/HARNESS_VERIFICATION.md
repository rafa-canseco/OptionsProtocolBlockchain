# Contracts Harness Verification

The contracts harness separates deterministic feedback from extended property
and fork evidence.

## Verification levels

| Level | Command | Required evidence |
| --- | --- | --- |
| Environment | `npm run harness:doctor` | Required tools/files and pinned local dependencies |
| Fast | `npm run harness:fast` | Dependency and storage policy plus offline unit/specification tests |
| Extended | `npm run harness:extended` | Security-profile fuzz/invariant properties and explicit Base forks |
| Full | `npm run harness:full` | Fast plus extended evidence |

During implementation, use the narrowest relevant Forge selector. Run `fast`
once before handoff rather than after every edit. It excludes fork suites and
routes fuzz/invariant property functions to `extended`; ordinary deterministic
functions remain in `fast`. Storage checks run from an isolated repo-local
Foundry output/cache so full build information stays complete without invalidating
the ordinary compilation cache.

`extended` is the delta used by the dependent CI job after `fast` succeeds. It
does not rerun deterministic checks. It requires non-empty `BASE_RPC_URL` and
`BASE_SEPOLIA_RPC_URL`; missing configuration fails before property or fork tests
run. Every `*Fork*.t.sol` file must be listed in
`scripts/harness-fork-paths.txt`, including any state-dependent pinned block.

`full` remains the comprehensive local command and composes `fast` with
`extended`. Storage compatibility is owned by `fast`, including in CI.

## When deep evidence is required

Deep targeted evidence, the full gate, and independent defensive review are
mandatory for changes affecting:

- custody, collateral, share accounting, NAV, fees, or asset movement;
- authorization, signatures, nonces, roles, pausing, or emergency controls;
- option creation, exercise, redemption, settlement, or physical delivery;
- proxy initialization, implementation upgrades, or storage layout;
- deployment scripts, manifests, verification, or deployed Base assumptions;
- fund adapters, strategy escrow, valuation, limits, or cross-contract wiring.

Lower-risk harness or documentation changes may use targeted checks plus `fast`
when the user or Linear explicitly approves that risk level.

## Handoff and review record

Record:

1. Linear issue and revision reviewed.
2. Acceptance criteria mapped to changed files and regression checks.
3. Affected invariant and why it remains preserved.
4. Exact commands and pass/fail status.
5. Fork chain, pinned block, and suite names when applicable.
6. Dependency and storage-layout results.
7. Existing failures or skipped required evidence as blockers.
8. Independent reviewer result when deep review is required.

Do not store RPC URLs, keys, signed payloads, environment dumps, or other
credentials in evidence.

## Defensive review format

Report findings as root cause, affected invariant, impact, minimal fix, and the
regression check proving the fix.
