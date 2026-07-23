# B1N-352 v2 Base Sepolia redeploy

Status: **NOT_DEPLOYED — BROADCAST NOT YET EXECUTED**

This is the single replacement Fund deployment for B1N-352. It reuses the codehash-pinned isolated
B1N-336 core and the existing Base Sepolia authority. It does not deploy or upgrade V1 components and
does not overwrite the historical `b1n-352/v1` handoff.

## Fixed deployment invariants

- Chain: Base Sepolia (`84532`) only.
- Factory: one-shot and owner-only.
- AccessManager role grant, member execution, and target-admin delays: zero from creation.
- Deposits are paused inside `createFund`, before selector authority is transferred.
- Strategy is configured inactive.
- No allocator bot or public mainnet operation is authorized.
- Fund and per-position collateral caps: 25 USDC.
- Maximum open positions: 3.
- Management, performance, and exit fees: zero.
- Minimum idle: 75%; maximum strategy allocation: 25%.
- NAV activation: 1 block; strategy cooldown: zero.
- CSP minimum expiry and fallback delay: 1 second.

The reused V1 `OTokenFactory` still requires every expiry to be in the future at exactly 08:00 UTC.

## Required phases

Every mutating phase requires a separately approved `--broadcast`. Until then, run without it.

1. Approve and digest-bind `deployment-inputs.approved.json` after committing the exact source.
2. Run `PreflightB1N352BaseSepolia`.
3. Deploy with `DeployTokenizedCspFundBaseSepoliaV2`; deposits are already paused.
4. Run `ConfigureB1N352V2Access`, then `ConfigureB1N352V2Policy`.
5. Run `ReconcileB1N352V2Configured`.
6. Run `OnboardB1N352V2Adapter`, then `ReconcileB1N352V2Onboarded`.
7. Run `ActivateB1N352V2Strategy`, then `ReconcileB1N352V2Activated`.
8. Open deposits explicitly with `OpenB1N352V2Deposits` only after the activated reconciliation passes.
9. Run `ReconcileB1N352V2Open` and capped end-to-end smoke tests.

Access and policy phases are immediate, idempotent, and atomic within their respective
`AccessManager.multicall` transactions. No v1 schedule/execute script is part of this v2 path.

## Pre-broadcast gates

- Replace the draft source commit and predicted adapter implementation address.
- Derive the linked runtime codehashes.
- Change approval status to `APPROVED`, record approver/time, and record the exact-file SHA-256 externally.
- Run:

```bash
npm run b1n352:inputs:check -- \
  deployments/base-sepolia/b1n-352/v2/deployment-inputs.approved.json \
  "$FUND_APPROVED_INPUTS_SHA256"
forge fmt --check
forge build
forge test --offline --match-path test/fund/B1N352ZeroDelayFundFactory.t.sol -vv
forge test --offline --match-path test/fund/B1N352Deployment.t.sol -vv
```
