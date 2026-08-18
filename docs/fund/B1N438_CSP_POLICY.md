# B1N-438 CSP objective policy and trust boundary

## On-chain facts

The ETH/USDC CSP paths enforce facts available from the existing ABI and protocol state:

- put product: WETH underlying, USDC strike asset, and USDC collateral;
- expiry delay from 36 hours through 60 hours (the approved bounds around a 48-hour target);
- cumulative utilization no greater than 80%;
- premium received no lower than 20 bps of posted collateral.

The premium floor uses the actual USDC balance delta received by the writer. `BatchSettler` deducts the configured protocol fee first. The vault validates the remaining premium before calculating or transferring any performance fee. The floor rounds required premium up to the smallest collateral unit, so an exact threshold passes and one unit below it fails.

## Off-chain selection boundary

The dynamic target delta (`0.09`) and quote-deviation limit (`150 bps`) remain allocator/curator checks. `IEthCspOptionSelector.validateOption` receives no IV, volatility model, model version, reference quote, or delta, and `validatePremium` receives only collateral and observed premium. The ABI is preserved. Contracts therefore do not invent Black–Scholes inputs or add an attestation trust model.

Curator and allocator operational controls must reject a candidate before submission when the off-chain delta or deviation policy is not met. On-chain validation is a defense-in-depth boundary for objective series, utilization, expiry, strike, collateral, and received-premium facts; it is not evidence that the dynamic model checks ran.

## Scope exclusions

B1N-438 does not change protocol-fee rates, performance-fee rates, deposits, epochs, settlement, assignment, Covered Calls, the proxied settler, or deployed runtime state.
