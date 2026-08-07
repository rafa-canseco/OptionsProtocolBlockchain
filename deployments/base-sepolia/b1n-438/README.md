# B1N-438 Base Sepolia CSP policy target

Status: **source-only; no broadcast or runtime mutation recorded**.

The objective on-chain CSP bounds are 36–60 hours around the approved 48-hour target, at most 80% utilization, and at least 20 bps net premium relative to collateral. The premium observation is the writer's actual USDC balance delta after `BatchSettler` deducts its configured protocol fee and before the vault/fund assesses any performance fee.

`policy.target.json` is a desired-state artifact, not a claim about deployed state. Historical B1N-336/B1N-352 manifests and reconciliation remain factual deployment records.

Dynamic selection remains off-chain: target delta `0.09` and maximum quote deviation `150 bps` require IV/model and reference-price inputs that are absent from the preserved `IEthCspOptionSelector` ABI. No Black–Scholes implementation or attestation scheme is introduced.

`ConfigureB1N438CspPolicy.s.sol` is deliberately preflight-only and rejects `B1N438_EXECUTE=true`. The script asserts Base Sepolia, contract code, recognized source/target configurations, CSP product wiring, current protocol/performance fee values, and a recognized Meta Wheel policy transition from v1 to the checked-in v2 SHA-256. Preflight requires standalone CSP, tokenized CSP, and Meta Wheel manager/coordinator addresses through the documented `B1N438_*` environment variables. Any later runtime change requires separately reviewed AccessManager schedule/execute phases bound to an approved deployment artifact; this ticket performs none.
