# B1N-352 v2 Blockscout verification

Status: **PARTIAL VERIFIED — 18/21 CONTRACTS**

The deployment is live on Base Sepolia. Eighteen of twenty-one submitted contracts are fully verified
by Blockscout, including all six ERC1967 proxies and the linked adapter library. Three accepted
standard-json submissions remain unverified because Blockscout returned `Fail - Unable to verify` after
processing; this is an explorer-verification limitation, not a deployment failure.

## Fully verified

See the address links below for the complete verified set:

- FundVault, FundShare, FundAccounting, FundFlowManager, StrategyManager and CspFundAdapter proxies.
- FundShare, FundAccounting, FundFlowManager and CspFundAdapter implementations.
- FundAccessManager, FundAccessManagerDeployer, NavReportVerifier, ClaimEscrow, CspFundValuator,
  both strategy escrows, and `CspFundAdapterOperations`.

## Accepted but failed

- FundVault implementation `0xAf77368c61ef4C0Cfc4A9b64D53d17807204F5A1`.
- StrategyManager implementation `0x6EA9FC22349a23634cF99C7363023d64fb625ACa`.
- B1N352ZeroDelayFundFactory `0xf8b508271F92eE5DC81a9Bc8E569C7Ff458E517C`.

The submitted GUIDs and Blockscout links are preserved in the deployment manifest history. Retry is
optional and should not block frontend/backend integration.

After broadcast, verify each deployed contract using Blockscout (not Basescan/Etherscan) and record
the resulting addresses and verification status in this file and the v2 manifest.
