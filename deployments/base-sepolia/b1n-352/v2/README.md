# B1N-352 v2 Base Sepolia redeploy

Status: **NOT DEPLOYED — PREFLIGHT READY**

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

## Deployment endpoints

Addresses and transaction receipts are intentionally absent until the separately authorized
Base Sepolia broadcast. Run all scripts without `--broadcast` for local/fork validation.

- FundVault: `0x53e38Baf2fC55259729085b7542BFF066F6a509e`
- FundShare: `0x07Db1F574ecCFD15c4A8bd4582e5d25baA84De7d`
- FundAccounting: `0x21d3acc5a2c64666dA93ABC8c77AB483b96836a3`
- FundFlowManager: `0x0206C0A5050b09B7A2AD4E8CbF83a06ae2193080`
- StrategyManager: `0xfC28237145596D4E1dfD28B80e186EFC09A1F988`
- CSP adapter: `0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3`
- CSP valuator: `0x43a6a2470Cb382d525B2ec17548C3F74cbc2fDDC`
- AccessManager: `0x729d5076C1C59a7C2676Faf3fB9133Ff80cDaB12`

## Planned phases (not yet broadcast)

1. Fund deployment: fresh one-shot stack, deposits paused inside `createFund`.
2. Access configuration: immediate zero-delay role grants.
3. Policy configuration: low-cap inactive policy.
4. Configured reconciliation.
5. Adapter onboarding; pinned B1N-336 implementation remains unchanged.
6. Onboarded reconciliation.
7. Strategy activation; deposits remain paused.
8. Activated reconciliation.
9. Deposit opening only after final smoke-test gate.
10. Final open reconciliation.

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
