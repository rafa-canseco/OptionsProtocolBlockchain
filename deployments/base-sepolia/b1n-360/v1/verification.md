# B1N-360 Blockscout verification

Status: **PARTIAL VERIFIED — 18/21 CONTRACTS**

Blockscout verified the CoveredCallFundAdapter implementation and proxy, CoveredCallFundValuatorV2,
all six ERC1967 fund/adapter proxies, StrategyManager, the shared fund modules already known to the
explorer, both strategy escrows, ClaimEscrow, FundAccessManager, FundAccessManagerDeployer,
NavReportVerifier, and the one-shot factory runtime.

## Verified covered-call contracts

- CoveredCallFundAdapter implementation:
  `0x42e603131671Aba8C9e2b0B21b0f7B376C9151Be`.
- CoveredCallFundAdapter proxy:
  `0x0BF96C5cE0D637d4D686d342aE42Bc00fDa19De9`.
- CoveredCallFundValuatorV2:
  `0xA1BFC1bE3C7fCA77CA0b32d25de1Ce58A50333A0`.

The adapter submission used the exact linked library binding:

```text
src/fund/libraries/CoveredCallFundAdapterOperations.sol:CoveredCallFundAdapterOperations
0x3AB0634fCb58D4447fd8A5469De001d64f028AEe
```

## Blockscout-limited submissions

Blockscout accepted and processed exact standard-JSON inputs for the following contracts, then
returned only `Fail - Unable to verify`:

- CoveredCallFundAdapterOperations
  `0x3AB0634fCb58D4447fd8A5469De001d64f028AEe`,
  GUID `3ab0634fcb58d4447fd8a5469de001d64f028aee6a67d792`.
- FundVault implementation
  `0xAf51984EcC261a4B3052eA90c9a85768F81DE764`,
  GUID `af51984ecc261a4b3052ea90c9a85768f81de7646a67d7e2`.
- FundFlowManager implementation
  `0x20EB957dfF753074a52487CbC3F4297879E9536e`,
  GUID `20eb957dff753074a52487cbc3f4297879e9536e6a67d7e3`.

The exact original compiler input was recovered from the deployment build-info:
Solidity 0.8.24, optimizer 200, via-IR, Cancun EVM, IPFS metadata, and all 255 source units.
For all three rejected contracts, the compiler output matches the onchain runtime byte-for-byte
after zeroing the compiler-declared immutable ranges. The operations library also matches after
normalizing Solidity's library self-address immutable. This establishes reproducibility; the
remaining failure is explorer-side and does not indicate an onchain bytecode mismatch.

Source-verification status is independent of activation. Deposits remain paused, the strategy is
inactive, and final worker roles have not been granted.
