# B1N-360 Base Sepolia covered-call fund

Status: **DEPLOYED — INTEGRATION HANDOFF**

This deployment creates the WETH-accounting covered-call fund on Base Sepolia and binds it to the
approved B1N-362 testnet-only policy. The deployment, access configuration, policy configuration,
V1 product whitelist, adapter onboarding, and strict read-only reconciliation all completed
successfully.

The canonical integration artifact is `manifest.json`. Confirmed mutations are recorded in
`transactions.json`, and the final state assertions are recorded in `reconciliation.json`.

## Current safe state

- Fund key: `base-sepolia:covered-call`.
- Strategy kind: `covered_call`.
- Accounting asset: WETH.
- Settlement and normalization asset: USDC.
- Maximum allocation: 25%.
- Maximum open positions: 1.
- Target policy: 0.05 call delta, 1.5–2.5 day expiry, minimum 10 bps net premium.
- Deposits remain paused.
- The strategy remains inactive.
- Final allocator and processor workers have not been granted roles.
- No mainnet authority exists.

## Handoff sequence

1. Backend B1N-361 consumes `manifest.json` and configures the covered-call NAV reporter/product API.
2. Backend reports and reconciles a fresh NAV for this exact fund.
3. Run the separate final-worker and activation phases.
4. Open deposits only after the explicit backend NAV reconciliation gate passes.

The final-worker, activation, and deposit-opening phases are deliberately separate and idempotent.
They were not executed as part of B1N-360.

## Verification

Local validation completed with 41 directed tests, 512 fuzz cases, 256 invariant runs,
128,000 invariant calls, and OpenZeppelin upgrade validation. Blockscout source submission is
tracked separately from deployment correctness and does not authorize activation.
