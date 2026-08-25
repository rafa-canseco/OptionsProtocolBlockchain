# B1N-491: Aerodrome NVDAc/USDC route qualification

## Verdict

**GO for the qualified Aerodrome route and downstream adapter implementation. Not yet GO for activation.** Both product gates pass on the pinned Base fork:

- PUT: USDC → NVDAc exact-output.
- CALL: NVDAc → USDC exact-input.

All 16 isolated swaps, observed ±1 negative bounds, B20 transfer matrix, directional depth probes, and sequential product-gate probes pass under the pinned Base Foundry runner. The effective fee is 500 pips (5 bps). Maximum observed 10,000-USDC execution impact/oracle deviation is 13/17 bps for USDC → NVDAc and 11/8 bps for NVDAc → USDC.

Recommended directional per-swap caps are **no higher than 1,000 USDC-equivalent**. The binding aggregate cap remains **1,000 USDC-equivalent per expiry shared across every direction, mode, AMM, adapter, route version, and executed/pending/reserved state**. Future deterministic adapter and recipient addresses must pass B20 eligibility and live transfer tests before activation. This report does not approve an upgrade, deployment, activation, or mainnet transaction.

## Reproducible snapshot

| Field | Value |
|---|---|
| Chain | Base mainnet, chain ID 8453 |
| Pinned finalized block | `50,400,001` |
| Block hash | `0xa5d536f76dd273ba4a4cbc5428c31315048e60f13c39ea2e7d8f5fbdec252e36` |
| Parent hash asserted by test | `0x08c2707d24192e903e1f9700cffa1c55479e4972e6f05c993f418191ae3420ad` |
| Timestamp | `2026-08-24T16:35:49Z` |
| Repository commit | `a50aa08942c5f45fac5465ff692ae2ad31411f77` |
| Stock Foundry for ordinary harness suites | `1.5.1-stable`, commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2` |
| Base Foundry for B1N-491 only | `base-forge` `1.6.0-v1.1.0`, commit `6130ccf6af0b3399777aee3876486e2ba9ebb38f` |
| Base Foundry installer pin | `base-foundryup --install v1.1.0` |
| Solidity | `0.8.24` |
| RPC requirement | Base archive access; credentials are not recorded |

## Canonical identities

Aerodrome's official Slipstream README Gauges V3 deployment table binds the factory, router, and quoter below. The pinned onchain checks bind both periphery contracts and the pool to that factory.

| Component | Address | Pinned `extcodehash` / identity |
|---|---|---|
| NVDAc B20 native token | `0xb20000000000000000000078ee7ce2fE4908108C` | `0x309b8896ee4c1ff7ec1966155373dee42663b6b40c3fedc70ba501684848d2a3`; native precompile, not a proxy and no per-token implementation |
| USDC proxy | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0xa6705a10bb756b5dea144591118be77d7af0c3eee3bf2dfe2583dcb0364fefab` |
| USDC implementation | `0x2Ce6311ddAE708829bc0784C967b7d77D19FD779` | `0x11b75a237997ab8328f65b2d5a55c10f0346d0a175741ed42ddf4f2c66b9e873` |
| Slipstream pool | `0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9` | `0xad8972486d67a48db1f32f254a4c2f4be28df0b5f399559d1e7cd8fbcfbedc96` |
| Gauges V3 CL factory | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | `0x4961963494e47f363617ab9a0f3999a28b33c519e51392952db06350cce700bd` |
| SwapRouter | `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` | `0xfedc4e21e1097b0ec1b4f1aa901cf645c22f9e5d297727b0f37275ee1d083df4` |
| QuoterV2 ABI | `0x514c8B5f54112481E28028F1166Bd78501089259` | `0x4c4c43e0024343e65597f0f0a1b829aaf69e5a6c0a0148fb63d28ff5730be551` |

Pinned relationships:

- `router.factory() == quoter.factory() == pool.factory() == 0xf8f2...61Ef`.
- `factory.getPool(NVDAc, USDC, 10) == 0x853f...7ab9` and `factory.isPool(pool) == true`.
- `token0 = USDC`, `token1 = NVDAc`, decimals `6/8`, and `tickSpacing = 10`.
- `pool.fee() == factory.getSwapFee(pool) == 500` pips, or 5 bps.
- `factory.getUnstakedFee(pool) == 100,000` pips, or 10%. This distinct unstaked-liquidity charge is one reason a UI percentage must not be treated as the swap fee.

Exact sources:

- Gauges V3 deployment table: [Aerodrome Slipstream README at `f8717faa`](https://github.com/aerodrome-finance/slipstream/blob/f8717faaae6e6717db3c8e3850149c01a79c0603/README.md#gauges-v3-deployment).
- Router tuple ABI and callback: [`ISwapRouter.sol` at `f8717faa`](https://github.com/aerodrome-finance/slipstream/blob/f8717faaae6e6717db3c8e3850149c01a79c0603/contracts/periphery/interfaces/ISwapRouter.sol) and [verified deployed ABI](https://base.blockscout.com/api?module=contract&action=getabi&address=0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F).
- QuoterV2 tuple ABI and returns: [`IQuoterV2.sol` at `f8717faa`](https://github.com/aerodrome-finance/slipstream/blob/f8717faaae6e6717db3c8e3850149c01a79c0603/contracts/periphery/interfaces/IQuoterV2.sol) and [verified deployed ABI](https://base.blockscout.com/api?module=contract&action=getabi&address=0x514c8B5f54112481E28028F1166Bd78501089259).
- Factory/pool getters: [verified factory source](https://base.blockscout.com/api?module=contract&action=getsourcecode&address=0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef) plus pinned calls asserted by the test.

## Exact ABI and payment flow

| Capability | Selector | Canonical tuple | Status |
|---|---|---|---|
| Exact input single | `0xa026383e` | `(tokenIn,tokenOut,int24 tickSpacing,recipient,deadline,amountIn,amountOutMinimum,sqrtPriceLimitX96)` | ABI/source verified; live fork call and observed +1 negative passed |
| Exact output single | `0xc714e838` | `(tokenIn,tokenOut,int24 tickSpacing,recipient,deadline,amountOut,amountInMaximum,sqrtPriceLimitX96)` | ABI/source verified; live fork call and observed -1 negative passed |
| Quote exact input single | `0x9e7defe6` | `(tokenIn,tokenOut,amountIn,int24 tickSpacing,sqrtPriceLimitX96)` | pinned `eth_call` works |
| Quote exact output single | `0xfa6af908` | `(tokenIn,tokenOut,amount,int24 tickSpacing,sqrtPriceLimitX96)` | pinned `eth_call` works |

The caller approves the router. The router authenticates the pool derived from its immutable canonical factory, pays the pool during `uniswapV3SwapCallback(int256,int256,bytes)`, and sends output directly to `recipient`. Exact-output returns actual input and enforces `amountInMaximum`; exact-input returns actual output and enforces `amountOutMinimum`. The required live calls and observed-result negative bounds pass in both directions.

## Independent oracle

| Field | Pinned result |
|---|---|
| Chainlink Coinbase NVDA proxy | `0x04689a41629776563E6822F76f2e57D148d28513` |
| Aggregator | `0xF72B1eB5932800F3d2a5EeC5f99e6cD586479675` |
| Decimals / heartbeat | 8 / 86,400 seconds |
| Description | `Coinbase NVDA` |
| Coinbase oracle registry | `0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD` |
| Registry result | multiplier `1e18`, oracle pause `false` |

The passing static test requires a positive answer, `answeredInRound >= roundId`, and `block.timestamp - updatedAt <= 86,400`. The registry result passes both pinned remote `eth_call` and local Base Foundry execution.

Conversions round down:

- `NVDAc raw = USDC raw × 10^10 / oracleAnswer`.
- `USDC raw = NVDAc raw × oracleAnswer / 10^10`.

These formulas use the external total-return feed, not the measured pool result.

## B20 matrix

NVDAc is a Base-native B20 asset, not an EIP-1967 proxy. Raw balances do not rebase. `multiplier()` changes redemption/UI-scaled units for corporate actions. At the pinned block the multiplier is `1e18`; exact transfer deltas remain raw token units and no fee-on-transfer behavior is specified.

| Check | Pinned observation |
|---|---|
| Transfer pause | `pausedFeatures()` empty; transfer/mint/burn queried unpaused |
| Sender policy | policy ID 5 |
| Receiver policy | policy ID 5 |
| Executor (`transferFrom`) policy | policy ID 5 |
| Existing holder | `0xA561...8412`; pinned NVDAc balance `6,417,215,487` raw and USDC balance `26,045,555,349` raw, sufficient for the largest isolated case |
| Holder / router / deployed settler eligibility | Registry `isAuthorized` returned true under the three transfer policies |
| Future adapter and contract recipient eligibility | **Downstream activation condition.** The exact deterministic addresses do not yet exist and the passing temporary contract-recipient mechanics are not identity evidence. Test both exact addresses with pinned Base Foundry before activation. |
| Approval | Not pause/policy gated by B20 ABI; allowance still does not guarantee a later transfer succeeds |
| Real-holder fork transfer | Passed under pinned Base Foundry; exact raw balance deltas observed |
| `transferFrom` executor matrix | Holder, router, and deployed settler each execute from index 0; source/recipient/allowance baselines and post-transfer deltas pass after every snapshot reset |
| Authorized pause mutation | Not executed. No role impersonation or fabricated issuer state. Authority and failure path are documented only. |

The Coinbase oracle registry pause is separate from the B20 transfer pause. During a corporate action the oracle can freeze while raw token transfers remain enabled. Runtime settlement must reject stale or paused oracle state and account in raw units while valuing with the current multiplier-aware feed.

Sources: [Base B20 interfaces](https://docs.base.org/base-chain/specs/reference/b20/interfaces/IB20), [IB20Asset](https://docs.base.org/base-chain/specs/reference/b20/interfaces/IB20Asset), [tokenized stocks](https://docs.base.org/base-chain/asset-issuance/tokenized-stocks-on-base), and [Chainlink Coinbase feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase).

## Sixteen isolated scenarios

Each scenario starts from the same pre-funding snapshot, funds from the real holder, records actor/recipient/router/pool baselines, executes the positive router call, resets, funds again, reasserts identical balances/allowance, and proves the observed-result negative bound (`actualOutput + 1` or `actualInput - 1`). All 16 pass. Fee is 500 pips and quote-to-execution slippage is 0 bps in every pinned deterministic case.

| Direction | Mode | USDC eq. | Actual input raw | Actual output raw | Execution impact bps | Oracle deviation bps | Quoter raw count | Strict initialized boundaries crossed |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| USDC → NVDAc | exact-input | 100 | 100,000,000 | 47,480,969 | 5 | 8 | 1 | 0 |
| USDC → NVDAc | exact-input | 1,000 | 1,000,000,000 | 474,774,173 | 5 | 9 | 1 | 0 |
| USDC → NVDAc | exact-input | 5,000 | 5,000,000,000 | 2,373,070,983 | 9 | 12 | 2 | 1 |
| USDC → NVDAc | exact-input | 10,000 | 10,000,000,000 | 4,743,900,910 | 13 | 17 | 3 | 2 |
| USDC → NVDAc | exact-output | 100 | 100,083,943 | 47,520,826 | 5 | 8 | 1 | 0 |
| USDC → NVDAc | exact-output | 1,000 | 1,000,914,388 | 475,208,265 | 5 | 9 | 1 | 0 |
| USDC → NVDAc | exact-output | 5,000 | 5,006,261,256 | 2,376,041,329 | 9 | 12 | 2 | 1 |
| USDC → NVDAc | exact-output | 10,000 | 10,017,263,954 | 4,752,082,659 | 13 | 17 | 3 | 2 |
| NVDAc → USDC | exact-input | 100 | 47,520,826 | 99,982,219 | 5 | 1 | 1 | 0 |
| NVDAc → USDC | exact-input | 1,000 | 475,208,265 | 999,747,387 | 5 | 2 | 1 | 0 |
| NVDAc → USDC | exact-input | 5,000 | 2,376,041,329 | 4,997,312,938 | 8 | 5 | 2 | 1 |
| NVDAc → USDC | exact-input | 10,000 | 4,752,082,659 | 9,991,864,885 | 11 | 8 | 2 | 1 |
| NVDAc → USDC | exact-output | 100 | 47,529,277 | 100,000,000 | 5 | 1 | 1 | 0 |
| NVDAc → USDC | exact-output | 1,000 | 475,328,349 | 1,000,000,000 | 5 | 2 | 1 | 0 |
| NVDAc → USDC | exact-output | 5,000 | 2,377,319,303 | 5,000,000,000 | 8 | 5 | 2 | 1 |
| NVDAc → USDC | exact-output | 10,000 | 4,755,953,761 | 10,000,000,000 | 11 | 8 | 2 | 1 |

The pre-swap spot is `210.50363963` USDC/NVDAc. Execution impact is average execution price versus that spot, with fee separate. Endpoint spot movement remains separately logged. Aerodrome's raw quoter count is retained but is not used as proof of exhaustion because its inclusive bitmap count can be positive when `tickBefore == tickAfter`. The corrected metric walks spacing boundaries strictly between the before/after ticks and checks each bit through `tickBitmap(int16)`. Initial active-range exhaustion occurs in the eight 5,000/10,000-USDC scenarios, not in the eight 100/1,000-USDC scenarios. No scenario reaches terminal zero liquidity.

## Directional depth

Deterministic exact-input search uses 10 USDC resolution. No result reaches the 100,000-USDC search ceiling, so all are bracketed depths rather than lower bounds.

| Direction | 10 bps | 25 bps | 50 bps |
|---|---:|---:|---:|
| USDC → NVDAc | 6,170 | 13,300 | 24,680 |
| NVDAc → USDC | 9,210 | 22,710 | 34,740 |

## Sequential product gates and caps

| Product gate | Executed | Safe prefix | Boundary/revert | Max oracle deviation | Max execution impact |
|---|---:|---:|---|---:|---:|
| PUT USDC → NVDAc exact-output | 1,000 | 1,000 | none | 9 bps | 5 bps |
| CALL NVDAc → USDC exact-input | 1,000 | 1,000 | none | 3 bps | 5 bps |

- Both product gates are **GO** at the shared 1,000-USDC-equivalent ceiling.
- Directional per-swap recommendation: no higher than 1,000 USDC-equivalent for either product route.
- Aggregate per-expiry recommendation: 1,000 USDC-equivalent shared across every direction, swap kind, AMM, adapter, route version, and executed/pending/reserved state.
- Splitting an order or changing route/version does not reset aggregate capacity.
- Runtime still requires fresh oracle/quote guards and the versioned route binding. The pinned snapshot is qualification evidence, not permanent liquidity.
- Exact future adapter/recipient B20 eligibility is a downstream activation condition, not a reason to fabricate an address in B1N-491.

## Pinned Base Foundry runner

```bash
base-foundryup --install v1.1.0
BASE_RPC_URL=<archive-rpc> base-forge test --match-contract B1N491AerodromeRouteForkTest -vvv
```

Required identity:

```text
forge Version: 1.6.0-v1.1.0
Commit SHA: 6130ccf6af0b3399777aee3876486e2ba9ebb38f
```

The harness selects `base-forge` only for `test/fund/B1N491AerodromeRouteFork.t.sol`, validates both lines exactly, and fails closed with install guidance on mismatch. Every other build/test/fork suite continues to use stock `forge`.

Final verification: static identity 1/1, narrow qualification 6/6, harness regression 5/5, deterministic fast gate 813/813, and full storage/security/Base-mainnet/Base-Sepolia gate all passed. Exact commands and results are in `harness/runs/B1N-491/verification.json`.

No transaction was signed, submitted, or broadcast.
