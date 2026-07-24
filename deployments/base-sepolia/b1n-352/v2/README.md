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

- Approved source commit: `4a72b3e616a9c2fa335cbbe3e798474f8c390394`.
- Approved policy SHA-256: `0xa0a2d82226d1bd0e6d5472eab980acead94af8a9f17bd5b0212356d05f6f34aa`.
- Approved inputs SHA-256: `0x1c534e8dccfef493b9559d14f846118c142abc5313aafe705acc79a790705345`.
- Predicted adapter implementation: `0x66677E767806c85656596AB9F1cE4939580Db453`, derived from
  pending deployer nonce `12224` and confirmed by the no-broadcast dry-run.
- Linked adapter implementation codehash:
  `0xa7a47e2077e533405467ff332fb072cb940871dfd72929b7e8f78da14555894f`.
- Immediately before broadcast, revalidate that the pending deployer nonce is still `12224`.
- Run:

```bash
npm run b1n352:inputs:check -- \
  deployments/base-sepolia/b1n-352/v2/deployment-inputs.approved.json \
  0x1c534e8dccfef493b9559d14f846118c142abc5313aafe705acc79a790705345
forge fmt --check
forge build
forge test --offline --match-path test/fund/B1N352ZeroDelayFundFactory.t.sol -vv
forge test --offline --match-path test/fund/B1N352Deployment.t.sol -vv
forge script \
  script/fund/DeployTokenizedCspFundBaseSepoliaV2.s.sol:DeployTokenizedCspFundBaseSepoliaV2 \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --libraries \
  src/fund/libraries/CspFundAdapterOperations.sol:CspFundAdapterOperations:0x0863A20B89d027472639A1E0c76278798e03D276
```

The final command is a dry-run unless `--broadcast` is added explicitly. Omitting the `--libraries` binding
causes Foundry to deploy a temporary library and the script correctly rejects the resulting address.
