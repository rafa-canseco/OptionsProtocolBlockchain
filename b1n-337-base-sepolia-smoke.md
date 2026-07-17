# B1N-337 Base Sepolia CSP smoke test

Status: complete; OTM, ITM physical delivery, timeout fallback, and final reconciliation confirmed

Network: Base Sepolia (`84532`)

Deployment manifest: `deployments-csp-base-sepolia.json`

This is an isolated smoke test using publicly mintable mock USDC/WETH, a mock price feed, and EOA-operated roles. It is not production configuration. The deployed V1 stack is not read or modified by this workflow.

## Scenario design

One expiry and one expiry price cover three independent batches:

| Batch | Strike | Expiry price | Expected path | Collateral |
| --- | ---: | ---: | --- | ---: |
| 1 | 2,000 USD | 2,100 USD | OTM | 20 USDC |
| 2 | 2,200 USD | 2,100 USD | ITM physical delivery | 22 USDC |
| 3 | 2,300 USD | 2,100 USD | ITM timeout/default fallback | 23 USDC |

Each batch writes `0.01 WETH` of puts. The initial deposit is `1,000 mock USDC`, below the configured isolated-smoke caps.

## Execution windows

- Opened: `2026-07-15`
- Expiry: `2026-07-16 08:00:00 UTC` (`1784188800`)
- Settlement prepared: `2026-07-17 19:41:28 UTC`
- Timeout eligible: `2026-07-17 20:41:28 UTC` (`1784320888`)
- Completed: `2026-07-17 20:55:12 UTC`

## Transactions

### Deposit and open

- Mock USDC mint: [`0x306bd44b...a607`](https://base-sepolia.blockscout.com/tx/0x306bd44b2505fa3b095aceed0847ecf79c24bf07dd8a90dbbb9f47a92088a607)
- Vault approval: [`0x3562915a...6092`](https://base-sepolia.blockscout.com/tx/0x3562915acaf76df820a651cb6c40b7407146680b513d65ff635ebaf86c5d6092)
- Deposit `1,000 USDC`: [`0x39caae2d...e629`](https://base-sepolia.blockscout.com/tx/0x39caae2da2237523d1d534d8268fd95666d71364a1a2d4617a0814f077fde629)
- OTM oToken creation: [`0xc197fb1d...5653`](https://base-sepolia.blockscout.com/tx/0xc197fb1d3660d83dbe5ed128e431e8185d1c022cb310a4a5da189400957f5653)
- Physical oToken creation: [`0x19967fcd...8e80`](https://base-sepolia.blockscout.com/tx/0x19967fcd0a3d5e68855901d4b2f7201b68ff546fe96392ef0307ec2a3df48e80)
- Fallback oToken creation: [`0xd0726588...1824`](https://base-sepolia.blockscout.com/tx/0xd07265881d6dc0c6bf26022f31f3c146f98d5f8065f6a55e8181fad922c71824)
- Open batch 1 / protocol vault 1: [`0x653c9b8b...b3ce`](https://base-sepolia.blockscout.com/tx/0x653c9b8b177418f3c8b91cf1420de4a0d0066ada9773f932ee94fb441b1eb3ce)
- Open batch 2 / protocol vault 2: [`0x9bc3baac...ae7a`](https://base-sepolia.blockscout.com/tx/0x9bc3baaca61f1b9cb788e8a794e621937c1375223c95f57a07a5580daf41ae7a)
- Open batch 3 / protocol vault 3: [`0x18d2598e...e17a`](https://base-sepolia.blockscout.com/tx/0x18d2598e4ff762fb101fc78cb0d0696e6af4c194960c045b411678335460e17a)

Created oTokens:

- Batch 1 OTM: `0x5f0095EdE2B3539C0a6fDa6b50cCF850Fc5E3CF4`
- Batch 2 physical: `0x09b0844b757410aA97ea433b5e4DEBEdEa0CB126`
- Batch 3 fallback: `0x61faa2bA6f7135b0cFE528e3844727391D98E798`

### OTM and physical settlement

- Feed price `2,100 USD`, block `44274516`: [`0x20424adf...de86`](https://base-sepolia.blockscout.com/tx/0x20424adfa268d664a1fe237ed7a67e59afe8847b7a6a3e87a3129176ab45de86)
- Expiry price, block `44274517`: [`0xb952b2f6...80c9`](https://base-sepolia.blockscout.com/tx/0xb952b2f69c06c78f4415fd2b57637e0e93b26d4495e2c050f8606c77f41b80c9)
- OTM settlement, block `44274518`: [`0x29d95bb6...d7e`](https://base-sepolia.blockscout.com/tx/0x29d95bb6bed6905e488d692403f6044ba3934999241d142225481527747abd7e)
- ITM preparation, block `44274519`: [`0xcb93b337...0a39`](https://base-sepolia.blockscout.com/tx/0xcb93b3373f073dbe71943c0c0bd31b6852db41945ddc3119c78558ca92480a39)
- ITM physical delivery, block `44274520`: [`0x279a9442...9ffd`](https://base-sepolia.blockscout.com/tx/0x279a94424398deed63a17ac8661a4e8b728a8751dd3fe2c76ce41bde8c0e9ffd)
- ITM finalization, block `44274521`: [`0x7e0490ef...44ec`](https://base-sepolia.blockscout.com/tx/0x7e0490ef6dd1a6ad04de4ba864ef6f0e1f792a8280ebed8e83ed1cbdac5444ec)
- Fallback preparation, block `44274522`: [`0x51843c6a...b022`](https://base-sepolia.blockscout.com/tx/0x51843c6aa9a9909927c73455a06ec9c1549e79acf570b7e43d7b9f9a4b23b022)

Before open, the vault held `0 USDC`, `0 WETH`, and had no shares or batches.

After open, independently read from Base Sepolia RPC:

| State | Value |
| --- | ---: |
| Vault USDC balance | `935.025920 USDC` |
| Accounted idle assets | `935.025920 USDC` |
| Total shares | `1,000.000000` |
| Active batches | `3` |
| Active collateral | `65 USDC` |
| Net premium per batch | `0.009600 USDC` |

All opening and settlement receipts have status `0x1`.

Decoded settlement events:

- `ExpiryPriceSet(WETH, 1784188800, 210000000000)`.
- OTM `CspBatchSettled(1, 1, 1, 20000000, 0, 0)`.
- ITM `PhysicalDelivery(oToken, vault, 10000000000000000, 21000000)`.
- ITM `CspBatchSettled(2, 1, 2, 0, 10000000000000000, 22000000)`.
- Batch 3 emitted `VaultSettled` and `PhysicalDeliveryReleased`; it remains prepared for fallback.

### Emergency guard

- Full pause, block `44274549`: [`0xf48f0baa...5f59`](https://base-sepolia.blockscout.com/tx/0xf48f0baa7ad7891984fe6acae69b5be446f0060a62a72e927d32a897d8995f59)
- `settleDefaultedCspBatch(3)` reverted with exact `SettlementDefaultNotReady()` data
  `0x4bcc2fc6` while fully paused.
- Unpause, block `44274552`: [`0xbe796296...b2d`](https://base-sepolia.blockscout.com/tx/0xbe796296096bef0f604bf813d9eb64c5925661e730457aa00e6b13cdf77a3b2d)
- Post-check: `systemFullyPaused == false`, `preparedSettlementBatchId == 3`.

### Timeout fallback and withdrawal

- Timeout fallback, block `44276709`: [`0xfaa64e58...6755`](https://base-sepolia.blockscout.com/tx/0xfaa64e587426e66a8848ad146d0ad4afb8ef70d55e1c742fb4cdd4c89b446755)
- Epoch close, block `44276710`: [`0xe95dd7dd...9cba`](https://base-sepolia.blockscout.com/tx/0xe95dd7dd5495babffc6568a63096651f0bb9ac07d42a75321143945e6c3e9cba)
- WETH claim, block `44276711`: [`0x67477ee3...b226`](https://base-sepolia.blockscout.com/tx/0x67477ee3d280b649ede5e49a46157b2c4adb8607f422ba0eae4e58846f2bb226)
- USDC withdrawal, block `44276712`: [`0x29fbc952...ee37`](https://base-sepolia.blockscout.com/tx/0x29fbc95266e8b4fb17a0c6537ab20def5ed01e1704e520f66a933b920ebdee37)

Decoded final events:

- `CspBatchSettled(3, 1, 3, 21000000, 0, 2000000)`.
- `EpochClosed(1, 28800, 24000000, 2880, 0)`.
- `AssignedUnderlyingClaimed(user, user, 10000000000000000)`.
- `IdleWithdrawn(user, user, 976025920, 1000000000)`.

## Balance evidence

| State after OTM + ITM settlement | Token balance | Accounted ledger |
| --- | ---: | ---: |
| Vault USDC | `955.025920` | `955.025920` |
| Vault WETH | `0.010000000000000000` | `0.010000000000000000` |

- `activeBatches = 1`.
- `activeCollateral = 23 USDC`.
- `preparedSettlementBatchId = 3`.
- `batchUnderlyingReceived(2) = 0.01 WETH`.
- Token balances and both accounted ledgers match exactly.

Final state after fallback, epoch close, claim, and withdrawal:

| State | Value |
| --- | ---: |
| Vault USDC balance | `0` |
| Accounted idle assets | `0` |
| Vault WETH balance | `0` |
| Accounted underlying assets | `0` |
| Active batches | `0` |
| Active collateral | `0` |
| Total shares | `0` |
| Prepared settlement batch | `0` |

The user received `976.025920 USDC` from the idle withdrawal and `0.01 WETH` from assignment.

## Events for backend/indexer

- `OTokenFactory.OTokenCreated`
- `EthCspVault.Deposited`
- `CspBatchSettler.OrderExecuted`
- `CspBatchSettler.PhysicalDeliveryReserved`
- `EthCspVault.CspBatchOpened`
- `Oracle.ExpiryPriceSet`
- `CspBatchSettler.PhysicalDeliveryReleased`
- `CspBatchSettler.PhysicalDelivery`
- `EthCspVault.CspBatchSettled`
- `EthCspVault.EpochClosed`
- `EthCspVault.AssignedUnderlyingAllocated`
- `EthCspVault.AssignedUnderlyingClaimed`
- `EthCspVault.IdleWithdrawn`

Indexer addresses are the `integrationEnv` values in `deployments-csp-base-sepolia.json`. Batch and protocol vault IDs are separate identifiers and both must be indexed from `CspBatchOpened`.

## Commands

Load the Fish-format project `.env`, which provides the Base Sepolia RPC and testnet deployer key,
then run each pending phase:

```bash
script/smoke-csp-base-sepolia.sh open
script/smoke-csp-base-sepolia.sh settle
script/smoke-csp-base-sepolia.sh emergency
script/smoke-csp-base-sepolia.sh finalize
```

If `PRIVATE_KEY` is unavailable, the pending settlement phases fall back to the Foundry `operator`
keystore and prompt for its password interactively. Set `FOUNDRY_ACCOUNT` to override that account.
The already-completed `open` phase always requires `PRIVATE_KEY` because it creates EIP-712 quote
signatures inside the Solidity script.

`settle` must run after expiry. `finalize` must run at least one hour after `settle` because the deployed vault enforces the minimum default delay.

## Findings

- No contract accounting mismatch was observed in OTM, ITM physical, or timeout fallback settlement.
- The runner initially decoded the batch `amount` as `protocolVaultId`; fixed in commit `938cd58`
  before broadcast. The failed attempt was simulation-only and changed no onchain state.
- The final vault token balances, accounted ledgers, shares, collateral, and active batch count are zero.
