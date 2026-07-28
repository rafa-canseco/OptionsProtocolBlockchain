# B1N-360 Base Sepolia covered-call fund

Status: **ACTIVE ON BASE SEPOLIA**

This deployment creates the WETH-accounting covered-call fund on Base Sepolia and binds it to the
approved B1N-362 testnet-only policy. The deployment, access configuration, policy configuration,
V1 product whitelist, adapter onboarding, and strict read-only reconciliation all completed
successfully.

The canonical integration artifact is `manifest.json`. Confirmed mutations are recorded in
`transactions.json`, and the final state assertions are recorded in `reconciliation.json`.
Every V2 contract entry carries its exact `validFromBlock`. Direct creations use confirmed receipt
blocks; contracts created inside factory calls use first-code evidence showing no code in the prior
block and code at the recorded block. Consumers must not default every address to `fundFirst` or
`fundLast`.

The isolated active V1 configuration was touched by exactly three approved mutations: WETH was
enabled as collateral, the WETH/USDC physically settled covered-call product was enabled, and the
new adapter was authorized as a physical-delivery vault. No V1 proxy implementation, owner, or
pending owner changed. The manifest records each mutation with its transaction hash and block.

## Current safe state

- Fund key: `base-sepolia:covered-call`.
- Strategy kind: `covered_call`.
- Accounting asset: WETH.
- Settlement and normalization asset: USDC.
- Maximum allocation: 25%.
- Maximum open positions: 1.
- Target policy: 0.05 call delta, 1.5–2.5 day expiry, minimum 10 bps net premium.
- `ACCOUNTING_ROLE` is held exclusively by the backend NAV submitter. The two independent
  reporters remain unchanged and are not granted submission authority.
- Deposits are open, and `resumeDeposits()` now enforces an active NAV window on-chain.
- The covered-call strategy is active.
- Final allocator and processor workers hold their exact immediate roles.
- No mainnet authority exists.

## Activation evidence

- Workers were finalized at block `44713445`.
- The Railway processor was rotated to `0x3c1a3ad44785bE4386F020050213D29589d1fb17`
  at blocks `44713589–44713590`.
- Strategy activation completed at block `44713652`.
- An initial deposit-resume transaction mined after its NAV window expired. Deposits were repaused
  at block `44713669`; no `Deposit` events occurred during the six-block interval.
- `FundVault` was upgraded at block `44714433` so stale NAV windows cannot unpause deposits.
- Deposits opened at block `44714463` during active NAV nonce 22, whose window ended at block
  `44714472`.

## Verification

Local validation completed with 41 directed tests, 512 fuzz cases, 256 invariant runs,
128,000 invariant calls, a stale-NAV resume regression, and OpenZeppelin upgrade validation.
Blockscout verified 18 of the original 21
contracts, including the CoveredCallFundAdapter implementation/proxy and CoveredCallFundValuatorV2.
The three rejected standard-JSON submissions reproduce the exact deployed runtime after normalizing
compiler immutables; Blockscout returned only `Fail - Unable to verify`. See `verification.md`.
The NAV-gated FundVault implementation is recorded separately in the manifest and has not yet been
submitted to Blockscout.
