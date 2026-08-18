# B1N-352 v2 Base Sepolia redeploy

Status: **DEPLOYED — QA HANDOFF**

This is the single replacement Fund deployment for B1N-352. It reuses the codehash-pinned isolated
B1N-336 core and the existing Base Sepolia authority. It does not deploy or upgrade V1 components and
does not overwrite the historical `b1n-352/v1` handoff. The final deployment and read-only reconciliation
are recorded in `manifest.json`, `reconciliation.json`, and `v1-boundary-evidence.json`.

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

## Deployment endpoints

The deployment is on Base Sepolia (`84532`) only. Contract addresses and the deployment block range are
recorded in `manifest.json`; the pause, emergency-exit reconciliation, and NAV smoke transactions are
recorded in `transactions.json`. Deposits are still paused and the allocator bot is not authorized.

## QA status

1. Fund deployment, zero-delay access configuration, policy configuration, and adapter onboarding: complete.
2. Deposit pause and state reconciliation: complete; `depositsPaused()` is `true`.
3. NAV reporter smoke: complete; nonce 1 confirmed on-chain.
4. Full deposit/CSP/redemption smoke: pending QA; no strategy position or user funds are enabled.

Access and policy phases are immediate, idempotent, and atomic within their respective
`AccessManager.multicall` transactions. No v1 schedule/execute script is part of this v2 path.

The remaining work is the capped end-to-end smoke suite: NAV/deposit/share transfer, CSP open and settlement,
and redemption. No allocator bot or mainnet operation is authorized.

## Approved deployment bindings

- Approved source commit: `4a72b3e616a9c2fa335cbbe3e798474f8c390394`.
- Approved policy SHA-256: `0xa0a2d82226d1bd0e6d5472eab980acead94af8a9f17bd5b0212356d05f6f34aa`.
- Approved inputs SHA-256: `0x1c534e8dccfef493b9559d14f846118c142abc5313aafe705acc79a790705345`.
- Adapter implementation: `0x66677E767806c85656596AB9F1cE4939580Db453`.
- Linked adapter implementation codehash:
  `0xa7a47e2077e533405467ff332fb072cb940871dfd72929b7e8f78da14555894f`.
- Reproducibility check:

```bash
npm run b1n352:inputs:check -- \
  deployments/base-sepolia/b1n-352/v2/deployment-inputs.approved.json \
  0x1c534e8dccfef493b9559d14f846118c142abc5313aafe705acc79a790705345
forge fmt --check
forge build
forge test --offline --match-path test/fund/B1N352ZeroDelayFundFactory.t.sol -vv
forge test --offline --match-path test/fund/B1N352Deployment.t.sol -vv
```
