# B1N-495 settlement-route qualification

## Verdict

**Qualification and non-broadcast preparation tooling are complete. No route was deployed, proposed, activated, or broadcast.** The approved pool-impact policies are NVDAc 30 bps and cbZEC/cbHYPE/VVV 50 bps; oracle-vs-DEX is 100 bps and post-quote slippage is 30 bps. Preparation proposes only preserved WETH/cbBTC. All four new assets are hard-excluded because the B1N-496 backend controls remain unmerged and unconfigured; the current finalized preflight reports evidence but cannot authorize them.

- NVDAc: pool impact is 5–7 bps through $10,000. Official 8-decimal Base Chainlink deviation is 35–38 bps for USDC→NVDAc and 23–25 bps for NVDAc→USDC.
- cbZEC: no direct Base AggregatorV3; pool impact is 22 bps at $100 and exceeds the 30-bps reference from $1,000.
- cbHYPE: no direct Base AggregatorV3; pool impact is 22 bps at $100 and exceeds the 30-bps reference from $1,000.
- VVV: measured pool impact is 31 bps at $100. Its official feed has 18 decimals and cannot be connected raw to the existing 8-decimal `Oracle.sol` assumption.

## Deterministic snapshot

| Field | Value |
|---|---|
| Chain | Base mainnet (`8453`) |
| Block | `50,780,000` |
| Timestamp | `1,788,349,347` |
| Parent hash | `0x25fe310773dc0da61c61050b004c8fad9279b093ac804f45cc99857788e79db2` |
| Runner | `base-forge 1.6.0-v1.1.0`, commit `6130ccf6af0b3399777aee3876486e2ba9ebb38f` |
| Pool-impact policies | NVDAc 30 bps; cbZEC/cbHYPE/VVV 50 bps, inclusive |
| Amounts | 100 / 1,000 / 5,000 / 10,000 USDC-equivalent; oracle-sized where available, otherwise pool-spot-sized |

## Canonical routes

| Asset | Token decimals | Venue | Pool | Factory | Router | Fee / spacing | Oracle |
|---|---:|---|---|---|---|---|---|
| NVDAc | 8 | Aerodrome Slipstream | `0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9` | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` | 500 pips / 10 | `0x04689a41629776563E6822F76f2e57D148d28513`, 8 decimals |
| cbZEC | 8 | Aerodrome Slipstream | `0x0Fc47C17AF86078d809358db1b4db2DeBC988566` | same | same | 2,000 pips / 200 | unavailable on Base |
| cbHYPE | 18 | Aerodrome Slipstream | `0xD5Eaea9da564217EA101D1E369fDA168A3025686` | same | same | 2,000 pips / 200 | unavailable on Base |
| VVV | 18 | Uniswap V3 | `0x67A11022B7B6ed66f81233F6C8Ed6e48F7826530` | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` | `0x2626664c2603336E57B271c5C0b26F421741e481` | 3,000 pips / 60 | `0xaABc55Ca55D70B034e4daA2551A224239890282F`, 18 decimals; raw integration blocked |

PUT remains USDC → asset exact-output. CALL remains asset → USDC exact-input. Pool token ordering is USDC token0 / asset token1 for every route. DIEM and VIRTUAL were not tested.

## Economic boundaries

Last passing 10-USDC increment under exact cross-product 30/50/100-bps guards. A `≥` result reached the 100,000-USDC search ceiling while still inside the guard and is a lower bound, not a discovered boundary. Zero means the first $10 probe exceeded the guard. Every non-ceiling next increment still quoted and failed economically rather than from venue exhaustion.

| Asset | Direction | 30 bps | 50 bps | 100 bps |
|---|---|---:|---:|---:|
| NVDAc | USDC→asset | 88,080 | ≥100,000 | ≥100,000 |
| NVDAc | asset→USDC | 88,270 | ≥100,000 | ≥100,000 |
| cbZEC | USDC→asset | 480 | 1,450 | 3,900 |
| cbZEC | asset→USDC | 480 | 1,450 | 3,900 |
| cbHYPE | USDC→asset | 340 | 1,030 | 2,780 |
| cbHYPE | asset→USDC | 340 | 1,030 | 2,780 |
| VVV | USDC→asset | 0 | 1,330 | 4,750 |
| VVV | asset→USDC | 0 | 1,330 | 4,690 |

## Adverse quote-to-execution boundaries

Limits are derived only from the stale pre-move quote: exact-input uses `preQuote × 0.997`; exact-output uses `ceil(preQuote × 1.003)`. A deterministic 10-USDC adversary search finds the largest inside move and the first outside move. The inside execution succeeds with the stale limit. At the identical moved state an unlimited control execution succeeds, while the outside execution reverts with the stale limit.

| Asset | Product/mode | Stale quote | Stale limit | Inside move / quote | Outside move / quote |
|---|---|---:|---:|---:|---:|
| NVDAc | PUT exact-output | 100356291 | 100657360 | 52490 / 100657335 | 52500 / 100657390 |
| NVDAc | CALL exact-input | 100255457 | 99954690 | 53280 / 99954690 | 53290 / 99954640 |
| cbZEC | PUT exact-output | 100221158 | 100521822 | 720 / 100519772 | 730 / 100523922 |
| cbZEC | CALL exact-input | 99779365 | 99480026 | 720 / 99483012 | 730 / 99478905 |
| cbHYPE | PUT exact-output | 100229590 | 100530279 | 510 / 100526977 | 520 / 100532812 |
| cbHYPE | CALL exact-input | 99771003 | 99471689 | 510 / 99475938 | 520 / 99470166 |
| VVV | PUT exact-output | 100233869 | 100534571 | 990 / 100531815 | 1000 / 100534827 |
| VVV | CALL exact-input | 99603459 | 99304648 | 1000 / 99305332 | 1010 / 99302355 |

## Full isolated matrix

Each row starts from the pinned snapshot. Feed-backed assets use the independent oracle to size asset-denominated USDC equivalents; cbZEC/cbHYPE use pre-swap pool spot because no direct Base feed exists. Quote equals actual execution in raw units with no intervening move. Impact is execution price versus pre-swap pool spot and includes the separately listed venue fee. Ticks and post-swap active liquidity are traversal evidence. `n/a` means no independent Base AggregatorV3 exists.

| Asset | Direction | Mode | USDC eq. basis | USDC eq. | Quote raw | Actual in raw | Actual out raw | Fee pips | Impact bps | Ticks | Liquidity after | Oracle deviation bps |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| NVDAc | USDC->asset | exact-input | oracle | 100 | 46018080 | 100000000 | 46018080 | 500 | 5 | 1 | 27337578412571 | 35 |
| NVDAc | USDC->asset | exact-input | oracle | 1000 | 460170531 | 1000000000 | 460170531 | 500 | 5 | 1 | 27337578412571 | 35 |
| NVDAc | USDC->asset | exact-input | oracle | 5000 | 2300624367 | 5000000000 | 2300624367 | 500 | 6 | 1 | 27337578412571 | 36 |
| NVDAc | USDC->asset | exact-input | oracle | 10000 | 4600650012 | 10000000000 | 4600650012 | 500 | 7 | 2 | 22507107899872 | 38 |
| NVDAc | USDC->asset | exact-output | oracle | 100 | 100356291 | 100356291 | 46182038 | 500 | 5 | 1 | 27337578412571 | 35 |
| NVDAc | USDC->asset | exact-output | oracle | 1000 | 1003585398 | 1003585398 | 461820385 | 500 | 5 | 1 | 27337578412571 | 35 |
| NVDAc | USDC->asset | exact-output | oracle | 5000 | 5018426767 | 5018426767 | 2309101925 | 500 | 6 | 1 | 27337578412571 | 36 |
| NVDAc | USDC->asset | exact-output | oracle | 10000 | 10038165781 | 10038165781 | 4618203851 | 500 | 7 | 2 | 22507107899872 | 38 |
| NVDAc | asset->USDC | exact-input | oracle | 100 | 100255457 | 46182038 | 100255457 | 500 | 5 | 1 | 27337578412571 | 25 |
| NVDAc | asset->USDC | exact-input | oracle | 1000 | 1002532153 | 461820385 | 1002532153 | 500 | 5 | 1 | 27337578412571 | 25 |
| NVDAc | asset->USDC | exact-input | oracle | 5000 | 5012161893 | 2309101925 | 5012161893 | 500 | 6 | 1 | 27337578412571 | 24 |
| NVDAc | asset->USDC | exact-input | oracle | 10000 | 10023076866 | 4618203851 | 10023076866 | 500 | 7 | 1 | 27337578412571 | 23 |
| NVDAc | asset->USDC | exact-output | oracle | 100 | 46064363 | 46064363 | 100000000 | 500 | 5 | 1 | 27337578412571 | 25 |
| NVDAc | asset->USDC | exact-output | oracle | 1000 | 460653909 | 460653909 | 1000000000 | 500 | 5 | 1 | 27337578412571 | 25 |
| NVDAc | asset->USDC | exact-output | oracle | 5000 | 2303498249 | 2303498249 | 5000000000 | 500 | 6 | 1 | 27337578412571 | 24 |
| NVDAc | asset->USDC | exact-output | oracle | 10000 | 4607568382 | 4607568382 | 10000000000 | 500 | 7 | 1 | 27337578412571 | 23 |
| cbZEC | USDC->asset | exact-input | pool spot | 100 | 12599567 | 100000000 | 12599567 | 2000 | 22 | 0 | 171541030391 | n/a |
| cbZEC | USDC->asset | exact-input | pool spot | 1000 | 125761730 | 1000000000 | 125761730 | 2000 | 40 | 0 | 171541030391 | n/a |
| cbZEC | USDC->asset | exact-input | pool spot | 5000 | 623661913 | 5000000000 | 623661913 | 2000 | 122 | 0 | 171541030391 | n/a |
| cbZEC | USDC->asset | exact-input | pool spot | 10000 | 1234691533 | 10000000000 | 1234691533 | 2000 | 222 | 0 | 171541030391 | n/a |
| cbZEC | USDC->asset | exact-output | pool spot | 100 | 100221158 | 100221158 | 12627427 | 2000 | 22 | 0 | 171541030391 | n/a |
| cbZEC | USDC->asset | exact-output | pool spot | 1000 | 1004083986 | 1004083986 | 126274276 | 2000 | 40 | 0 | 171541030391 | n/a |
| cbZEC | USDC->asset | exact-output | pool spot | 5000 | 5062454957 | 5062454957 | 631371382 | 2000 | 124 | 0 | 171541030391 | n/a |
| cbZEC | USDC->asset | exact-output | pool spot | 10000 | 10231998107 | 10231998107 | 1262742764 | 2000 | 231 | 0 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-input | pool spot | 100 | 99779365 | 12627427 | 99779365 | 2000 | 22 | 0 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-input | pool spot | 1000 | 995941005 | 126274276 | 995941005 | 2000 | 40 | 0 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-input | pool spot | 5000 | 4938946637 | 631371382 | 4938946637 | 2000 | 122 | 0 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-input | pool spot | 10000 | 9777854734 | 1262742764 | 9777854734 | 2000 | 222 | 1 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-output | pool spot | 100 | 12655355 | 12655355 | 100000000 | 2000 | 22 | 0 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-output | pool spot | 1000 | 126789980 | 126789980 | 1000000000 | 2000 | 40 | 0 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-output | pool spot | 5000 | 639257838 | 639257838 | 5000000000 | 2000 | 124 | 0 | 171541030391 | n/a |
| cbZEC | asset->USDC | exact-output | pool spot | 10000 | 1292038160 | 1292038160 | 10000000000 | 2000 | 231 | 1 | 171541030391 | n/a |
| cbHYPE | USDC->asset | exact-input | pool spot | 100 | 1233021612671092326 | 100000000 | 1233021612671092326 | 2000 | 22 | 0 | 38174463537659621 | n/a |
| cbHYPE | USDC->asset | exact-input | pool spot | 1000 | 12298057787567035837 | 1000000000 | 12298057787567035837 | 2000 | 48 | 0 | 38174463537659621 | n/a |
| cbHYPE | USDC->asset | exact-input | pool spot | 5000 | 60785690367997983143 | 5000000000 | 60785690367997983143 | 2000 | 162 | 0 | 38174463537659621 | n/a |
| cbHYPE | USDC->asset | exact-input | pool spot | 10000 | 119854658020740958596 | 10000000000 | 119854658020740958596 | 2000 | 301 | 1 | 38174463537659621 | n/a |
| cbHYPE | USDC->asset | exact-output | pool spot | 100 | 100229590 | 100229590 | 1235851669354138740 | 2000 | 22 | 0 | 38174463537659621 | n/a |
| cbHYPE | USDC->asset | exact-output | pool spot | 1000 | 1004930493 | 1004930493 | 12358516693541943244 | 2000 | 49 | 0 | 38174463537659621 | n/a |
| cbHYPE | USDC->asset | exact-output | pool spot | 5000 | 5084046979 | 5084046979 | 61792583467710049729 | 2000 | 168 | 0 | 38174463537659621 | n/a |
| cbHYPE | USDC->asset | exact-output | pool spot | 10000 | 10320589819 | 10320589819 | 123585166935420210628 | 2000 | 320 | 1 | 34284981166046366 | n/a |
| cbHYPE | asset->USDC | exact-input | pool spot | 100 | 99771003 | 1235851669354138740 | 99771003 | 2000 | 22 | 0 | 38174463537659621 | n/a |
| cbHYPE | asset->USDC | exact-input | pool spot | 1000 | 995107915 | 12358516693541943244 | 995107915 | 2000 | 48 | 0 | 38174463537659621 | n/a |
| cbHYPE | asset->USDC | exact-input | pool spot | 5000 | 4917968043 | 61792583467710049729 | 4917968043 | 2000 | 164 | 1 | 34284981166046366 | n/a |
| cbHYPE | asset->USDC | exact-input | pool spot | 10000 | 9685853043 | 123585166935420210628 | 9685853043 | 2000 | 314 | 1 | 34284981166046366 | n/a |
| cbHYPE | asset->USDC | exact-output | pool spot | 100 | 1238689047922411776 | 1238689047922411776 | 100000000 | 2000 | 22 | 0 | 38174463537659621 | n/a |
| cbHYPE | asset->USDC | exact-output | pool spot | 1000 | 12419450269910067908 | 12419450269910067908 | 1000000000 | 2000 | 49 | 0 | 38174463537659621 | n/a |
| cbHYPE | asset->USDC | exact-output | pool spot | 5000 | 62839331733411318393 | 62839331733411318393 | 5000000000 | 2000 | 169 | 1 | 34284981166046366 | n/a |
| cbHYPE | asset->USDC | exact-output | pool spot | 10000 | 127725816732491198703 | 127725816732491198703 | 10000000000 | 2000 | 335 | 1 | 34284981166046366 | n/a |
| VVV | USDC->asset | exact-input | oracle | 100 | 6312249886592165128 | 100000000 | 6312249886592165128 | 3000 | 31 | 0 | 167251094831182711 | 23 |
| VVV | USDC->asset | exact-input | oracle | 1000 | 63037408773971446693 | 1000000000 | 63037408773971446693 | 3000 | 44 | 1 | 167251094831182711 | 36 |
| VVV | USDC->asset | exact-input | oracle | 5000 | 313332530020274600570 | 5000000000 | 313332530020274600570 | 3000 | 103 | 2 | 177205655739914958 | 96 |
| VVV | USDC->asset | exact-input | oracle | 10000 | 622601026233297216966 | 10000000000 | 622601026233297216966 | 3000 | 167 | 4 | 211438680902732601 | 162 |
| VVV | USDC->asset | exact-output | oracle | 100 | 100233869 | 100233869 | 6327009993006123153 | 3000 | 31 | 0 | 167251094831182711 | 23 |
| VVV | USDC->asset | exact-output | oracle | 1000 | 1003696877 | 1003696877 | 63270099930061231537 | 3000 | 45 | 1 | 167251094831182711 | 36 |
| VVV | USDC->asset | exact-output | oracle | 5000 | 5048510340 | 5048510340 | 316350499650306157686 | 3000 | 105 | 1 | 177205655739914958 | 97 |
| VVV | USDC->asset | exact-output | oracle | 10000 | 10164279227 | 10164279227 | 632700999300612315373 | 3000 | 172 | 3 | 211438680902732601 | 164 |
| VVV | asset->USDC | exact-input | oracle | 100 | 99603459 | 6327009993006123153 | 99603459 | 3000 | 31 | 0 | 167251094831182711 | 39 |
| VVV | asset->USDC | exact-input | oracle | 1000 | 994693027 | 63270099930061231537 | 994693027 | 3000 | 44 | 0 | 167251094831182711 | 53 |
| VVV | asset->USDC | exact-input | oracle | 5000 | 4943756788 | 316350499650306157686 | 4943756788 | 3000 | 104 | 1 | 166414749854358433 | 112 |
| VVV | asset->USDC | exact-input | oracle | 10000 | 9813988632 | 632700999300612315373 | 9813988632 | 3000 | 177 | 4 | 145612504412957810 | 186 |
| VVV | asset->USDC | exact-output | oracle | 100 | 6352202795418365952 | 6352202795418365952 | 100000000 | 3000 | 31 | 0 | 167251094831182711 | 39 |
| VVV | asset->USDC | exact-output | oracle | 1000 | 63608172719006861069 | 63608172719006861069 | 1000000000 | 3000 | 45 | 0 | 167251094831182711 | 53 |
| VVV | asset->USDC | exact-output | oracle | 5000 | 319976908216619031827 | 319976908216619031827 | 5000000000 | 3000 | 106 | 1 | 166414749854358433 | 113 |
| VVV | asset->USDC | exact-output | oracle | 10000 | 644882029284375012871 | 644882029284375012871 | 10000000000 | 3000 | 184 | 4 | 145612504412957810 | 188 |

## B20 and regression evidence

At the pinned block, NVDAc/cbZEC/cbHYPE expose decimals 8/8/18, multiplier `1e18`, no paused features, and sender/receiver/executor policy IDs 5/118/119 respectively. The Base OracleRegistry returns the same `1e18` multiplier and is unpaused for each token. Every policy exists, decodes to the `BLOCKLIST` type tag, and authorizes the concrete contract path: MarginPool, BatchSettler, facade, adapter, venue router, pool, route owner, and configured settlement recipient. Dynamic PUT recipients must still be authorized at runtime; deployment cannot attest unknown future users.

Real one-raw-unit non-pool-holder-to-contract and contract-to-recipient transfers preserve exact raw balance deltas. Matrix funding uses authorized non-pool holder `0x4985…2b2b` for NVDAc, the Coinbase hot wallet for cbZEC/cbHYPE, and the second cbZEC holder when needed. Every scenario asserts funding leaves both pool token balances unchanged before the swap, then asserts exact swap-induced pool balance deltas. Existing adapters fail closed on non-exact transfer deltas and clear allowances.

Existing WETH/cbBTC production behavior is preserved because no source contract was changed. Their route/delivery regression remains in `test/UniswapV3SettlementAdapterFork.t.sol`. The B1N-495 tool test proves the preserved routes honor the one-day delay, repeated calls are no-ops, all new routes remain empty, excluded pending routes and foreign replacements fail closed, and `BatchSettler.swapRouter()` is untouched. Route delay, replacement, cancellation, and immediate disable remain covered by `test/PairRoutingSwapRouter.t.sol`.

## Latest-finalized preflight and tooling

- `script/B1N495RoutePreflight.sol` validates exact chain, facade/adapter bindings, venue identities/liquidity, B20 decimals/pause/multiplier/policy/authorization, feed decimals/round validity/freshness, safe VVV 18-to-8 evidence normalization, and the 100-bps spot/oracle gate.
- `script/B1N495RouteTools.s.sol:PrepareB1N495Routes` uses the pinned Arachnid deterministic deployment proxy and role-specific CREATE2 salts. It deploys or reuses exact bytecode, verifies every immutable, and proposes only WETH/cbBTC. It never calls `BatchSettler.setSwapRouter`.
- `PreflightB1N495Routes` is read-only. `ActivateB1N495Routes` is a separate explicit-confirmation tool and exposes only preserved WETH/cbBTC activation. NVDAc/cbZEC/cbHYPE/VVV remain disabled.
- Foreign observations are not caller-supplied prices. `scripts/b1n495-finalized-pins.py` queries each RPC's `finalized` tag, validates chain IDs, and returns ABI-encoded block numbers/hashes through Foundry FFI. Before each fork, the helper re-reads the captured block number and requires its hash to match. The Solidity tool then forks that exact block and reads the HYPE/ZEC proxies. Base verifies EVM number/parent hash; HyperEVM verifies EVM number; Arbitrum's NUMBER/BLOCKHASH expose L1 values, so the RPC hash check plus `createSelectFork` binds its finalized L2 block.

A non-broadcast latest-finalized preparation simulation passed; all four new routes remained unproposed and inactive. The current NVDAc feed exceeded the one-hour age policy, and no new asset is ready for proposal or activation. cbZEC has no Base-local standard feed and its earlier captured round exceeded the one-hour release threshold. cbHYPE exceeds its 50-bps pool-impact policy at the approved $5,000/$10,000 representative sizes. VVV's earlier release observation was about 209 bps. B1N-496 commit `3f2ae03` / draft PR #241 implements the backend 30/50-bps runtime impact gate and VVV 18-to-8 worker normalization, but it is unmerged, unconfigured, and defaults every routed asset off. Those controls remain prerequisites; this B1N-495 tooling exposes no cbHYPE/VVV activation entry point.

Pool-impact policy remains per settlement, not a fixed notional cap: the caller must reject a quote outside 30 bps for NVDAc or 50 bps for the other assets before calling the adapter. The adapter then enforces the caller's 30-bps post-quote min-output/max-input limit, as the adverse-move tests prove. This deployment tool cannot replace that runtime quote gate.

## Reproduce

```bash
BASE_RPC_URL=https://mainnet.base.org npm_config_offline=true base-forge test --offline \
  --match-path test/fund/B1N495SettlementRouteQualificationFork.t.sol \
  --fork-url https://mainnet.base.org --fork-block-number 50780000 -vv
```

No transaction was signed, submitted, or broadcast.
