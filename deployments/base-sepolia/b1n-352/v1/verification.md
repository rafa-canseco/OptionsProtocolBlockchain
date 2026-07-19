# Blockscout verification checklist

Use Blockscout only:

```bash
CONTRACT_ADDRESS=0x... \
CONTRACT_FQN=src/fund/FundVault.sol:FundVault \
./scripts/verify-b1n-352-blockscout.sh
```

For constructors, set `CONSTRUCTOR_ARGS` to the ABI-encoded constructor arguments. For the linked adapter implementation, also set `CSP_ADAPTER_OPERATIONS_ADDRESS`.

The linked operations library is stateless: it declares only constants and receives the adapter's ERC-7201 storage layout explicitly. Record its deployed codehash in the manifest and verify the exact linked address used by the adapter implementation.

Verify and record the Blockscout URL for:

- FundVault, FundShare, FundAccounting, FundFlowManager, StrategyManager implementations.
- All five ERC1967Proxy instances plus the CspFundAdapter proxy.
- NavReportVerifier, FundFactory, ClaimEscrow, AccessManager.
- CspFundAdapterOperations, CspFundAdapter implementation, CspFundValuator.
- Both StrategyAssetEscrow instances.

Core proxies use constructor args `(implementation, 0x)` because FundFactory initializes them after deployment. The adapter proxy uses `(adapterImplementation, adapterInitializeCalldata)`; preserve that calldata in the final manifest.

No verification command in this checklist has been executed for B1N-352.
