# B1N-352 v2 Blockscout verification

Verifier: Base Sepolia Blockscout only.

Status: **18/21 fully verified; 3 accepted submissions failed in the Blockscout verifier.**

## Fully verified

- [FundShare implementation](https://base-sepolia.blockscout.com/address/0xaefF1f67F925a8410D7BE36703FaB63e265b158F?tab=contract)
- [FundAccounting implementation](https://base-sepolia.blockscout.com/address/0x95902E4fbC65a008703a43f308C4Bb6694E431B1?tab=contract)
- [FundFlowManager implementation](https://base-sepolia.blockscout.com/address/0x3e7dB54f340C23A7c8479AaAf8a8626Ce4b34b9E?tab=contract)
- [FundAccessManagerDeployer](https://base-sepolia.blockscout.com/address/0x1a043801B1ac557a41730aF45bE1fc78e1F542dd?tab=contract)
- [NavReportVerifier](https://base-sepolia.blockscout.com/address/0x3093a0f0634aF2991ACD265d1f1F325480113d40?tab=contract)
- [FundAccessManager](https://base-sepolia.blockscout.com/address/0x729d5076C1C59a7C2676Faf3fB9133Ff80cDaB12?tab=contract)
- [ClaimEscrow](https://base-sepolia.blockscout.com/address/0xf0E540dfb0D3d8c3eDfCB5B5E457CafE116C5439?tab=contract)
- [CspFundAdapterOperations](https://base-sepolia.blockscout.com/address/0x0863A20B89d027472639A1E0c76278798e03D276?tab=contract)
- [CspFundAdapter implementation](https://base-sepolia.blockscout.com/address/0x66677E767806c85656596AB9F1cE4939580Db453?tab=contract)
- [CspFundValuator](https://base-sepolia.blockscout.com/address/0x43a6a2470Cb382d525B2ec17548C3F74cbc2fDDC?tab=contract)
- [In-kind StrategyAssetEscrow](https://base-sepolia.blockscout.com/address/0x40cC1867582a369449a918aA7A7E16028f25aC8b?tab=contract)
- [Emergency StrategyAssetEscrow](https://base-sepolia.blockscout.com/address/0xD9D92B4D29554A1FaF61478e517AF0f87364d37E?tab=contract)
- [FundVault proxy](https://base-sepolia.blockscout.com/address/0x53e38Baf2fC55259729085b7542BFF066F6a509e?tab=contract)
- [FundShare proxy](https://base-sepolia.blockscout.com/address/0x07Db1F574ecCFD15c4A8bd4582e5d25baA84De7d?tab=contract)
- [FundAccounting proxy](https://base-sepolia.blockscout.com/address/0x21d3acc5a2c64666dA93ABC8c77AB483b96836a3?tab=contract)
- [FundFlowManager proxy](https://base-sepolia.blockscout.com/address/0x0206C0A5050b09B7A2AD4E8CbF83a06ae2193080?tab=contract)
- [StrategyManager proxy](https://base-sepolia.blockscout.com/address/0xfC28237145596D4E1dfD28B80e186EFC09A1F988?tab=contract)
- [CspFundAdapter proxy](https://base-sepolia.blockscout.com/address/0x68e5C9f55201a4fa87040830b1A53A4B6E26b0e3?tab=contract)

Blockscout reports the adapter implementation as fully verified with optimizer runs `200`, Solidity
`v0.8.24+commit.e11b9ed9`, and external library
`src/fund/libraries/CspFundAdapterOperations.sol:CspFundAdapterOperations` linked at
`0x0863A20B89d027472639A1E0c76278798e03D276`.

## Accepted but failed

- [FundVault implementation](https://base-sepolia.blockscout.com/address/0xAf77368c61ef4C0Cfc4A9b64D53d17807204F5A1):
  GUID `af77368c61ef4c0cfc4a9b64d53d17807204f5a16a62b877`.
- [StrategyManager implementation](https://base-sepolia.blockscout.com/address/0x6EA9FC22349a23634cF99C7363023d64fb625ACa):
  GUID `6ea9fc22349a23634cf99c7363023d64fb625aca6a62b8af`.
- [B1N352ZeroDelayFundFactory](https://base-sepolia.blockscout.com/address/0xf8b508271F92eE5DC81a9Bc8E569C7Ff458E517C):
  GUID `f8b508271f92ee5dc81a9bc8e569c7ff458e517c6a62b8cb`.

Each standard-json submission was accepted with `OK`, remained pending, and then returned
`Fail - Unable to verify`. They remain unverified after a final API recheck. The same two implementation
types and the v1 FundFactory previously produced this Blockscout failure mode.

## Not applicable

None. All six proxies are supported by Blockscout and are fully verified as `ERC1967Proxy` contracts.
