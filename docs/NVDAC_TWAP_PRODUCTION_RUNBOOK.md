# NVDAc TWAP production upgrade

## Approved Base values

- Oracle proxy: `0x09daa0194A3AF59b46C5443aF9C20fAd98347671`
- Owner/Ledger: `0xC217A5B774cd17388a7C2782f0Cc3F4aaf8a29a7`
- Operator: `0x0bbD599cEB63b4603c2F007c5122e33f7b12364c`
- Price pool: `0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC`
- Factory: `0x9CB220581b91b0C83223012FE69688b92aD07a76`
- Window: 3,600 seconds
- Maximum settlement delay: 86,400 seconds
- Minimum harmonic liquidity: `6,900,000,000,000`
- USDC/USD max age: 259,200 seconds (72 hours, matching backend policy)
- NVDAc reference max age: 3,600 seconds
- Fresh-reference deviation: 100 bps

## Preflight

1. Required repository gates, storage comparison, fork tests, review, and sensitive check must pass.
2. Record the proxy implementation slot, owner, operator, global threshold/staleness, market-hours flags, and latest pool harmonic liquidity.
3. Connect/unlock the Ledger, open Ethereum, enable blind signing, and verify derivation path `m/44'/60'/6'/0/0` resolves to the owner above.
4. Dry-run `UpgradeOracleNvdacTwap.s.sol` against Base and review both transactions and all encoded parameters.

## Broadcast

```sh
forge script script/UpgradeOracleNvdacTwap.s.sol \
  --rpc-url "$BASE_RPC_URL" \
  --ledger --mnemonic-derivation-paths "m/44'/60'/6'/0/0" \
  --broadcast --slow -vvv
```

The first Ledger signature deploys the implementation. The second calls `upgradeToAndCall`, atomically upgrading and configuring the proxy. If configuration reverts, the proxy upgrade reverts too; the deployed implementation may remain unused.

## Verification before backend activation

- Both receipts succeeded.
- Proxy implementation slot equals the new implementation.
- `owner()` and `operator()` are unchanged.
- `nvdacTwapConfig()` exactly matches the approved values and `enabled=true`.
- Global threshold/staleness and NVDAc market-hours/legacy flags are unchanged.
- `Upgraded` and `NvdacTwapConfigured` logs are present.
- Verify source on Base Blockscout.

## Emergency disable

The owner can stop new NVDAc TWAP expiry writes without reverting the upgrade:

```sh
cast send 0x09daa0194A3AF59b46C5443aF9C20fAd98347671 \
  'setNvdacTwapEnabled(bool)' false \
  --rpc-url "$BASE_RPC_URL" \
  --ledger --mnemonic-derivation-path "m/44'/60'/6'/0/0"
```

Also set backend `NVDAC_WEEKEND_TWAP_SETTLEMENT_ENABLED=false` and redeploy. Already stored expiry prices remain immutable. Re-enable only after the failure is understood and state is re-verified.
