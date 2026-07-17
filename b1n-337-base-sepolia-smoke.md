# B1N-337 Base Sepolia CSP smoke test

Status: in progress; deposit and batch opening confirmed onchain

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
- Timeout eligible: pending (`expiry settlement preparation + 1 hour`)
- Completed: pending

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

All nine opening receipts have status `0x1`. The vault's token balance and `accountedIdleAssets` are equal.

### Emergency guard

Pending. The expected behavior is that `settleDefaultedCspBatch(3)` reverts with `SettlementDefaultNotReady` while the Controller is fully paused, preserving the prepared claim. Pause and unpause transactions will be recorded here.

### Timeout fallback and withdrawal

- Deposit, share mint, quote execution, collateral reservation, and batch identifiers match expected accounting onchain.
- No contract bug found in the opening phase.
- Settlement remains time-gated by the protocol's valid 08:00 UTC expiry and cannot be completed before `2026-07-16 08:00 UTC`.

## Balance evidence

Pending.

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

Export `BASE_SEPOLIA_RPC_URL`. The pending settlement phases use the Foundry
`operator` keystore and prompt for its password interactively:

```bash
script/smoke-csp-base-sepolia.sh open
script/smoke-csp-base-sepolia.sh settle
script/smoke-csp-base-sepolia.sh emergency
script/smoke-csp-base-sepolia.sh finalize
```

Set `FOUNDRY_ACCOUNT` to override the default `operator` account. The already-completed `open`
phase is the only legacy phase that still requires `PRIVATE_KEY`, because it creates EIP-712 quote
signatures inside the Solidity script.

`settle` must run after expiry. `finalize` must run at least one hour after `settle` because the deployed vault enforces the minimum default delay.

## Findings

Pending.
