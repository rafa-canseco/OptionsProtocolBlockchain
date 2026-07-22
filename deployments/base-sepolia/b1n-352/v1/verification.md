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
- NavReportVerifier, FundFactory, FundAccessManagerDeployer, ClaimEscrow, FundAccessManager.
- CspFundAdapterOperations, CspFundAdapter implementation, CspFundValuator.
- Both StrategyAssetEscrow instances.

Core proxies use constructor args `(implementation, 0x)` because FundFactory initializes them after deployment. The adapter proxy uses `(adapterImplementation, adapterInitializeCalldata)`; preserve that calldata in the final manifest.

Base Sepolia status after deployment:

- Verified on Blockscout: the operations library, FundShare/FundAccounting/FundFlowManager implementations,
  NavReportVerifier, CspFundAdapter implementation, CspFundValuator, both StrategyAssetEscrow instances,
  FundAccessManager, FundAccessManagerDeployer, ClaimEscrow, and all six ERC1967Proxy instances.
- Blockscout returned `Fail - Unable to verify` for the FundVault implementation, StrategyManager implementation,
  and FundFactory after accepting their standard-json submissions. Their on-chain deployment receipts and runtime
  code remain reconciled; retry these three when the Blockscout verifier queue/tooling is fixed.
