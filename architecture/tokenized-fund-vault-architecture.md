# B1N-348: Tokenized Fund Vault Architecture

Status: Proposed for review  
Date: 2026-07-16  
Scope: Product and smart-contract architecture  
Decision type: Foundational; fresh deployment required  

## 1. Executive summary

b1nary should evolve from a strategy-specific epoch vault into a platform for
tokenized, strategy-managed funds. A user deposits an accounting asset, receives
fungible ERC-20 shares, and owns a proportional claim on the net value of the
fund regardless of which assets or positions the strategy holds internally.

The first strategy remains the ETH/USDC cash-secured put (CSP) vault. The same
fund architecture must later support covered calls, concentrated-liquidity
positions, and combinations of strategies without redesigning share ownership,
NAV, deposits, or redemptions each time.

The proposed foundation is:

1. One ERC-4626 vault per fund. The vault itself is the ERC-20 share token.
2. ERC-2612 permit support for composability and delegated transactions.
3. One accounting and redemption asset per fund, initially USDC for the CSP
   and LP-range funds.
4. A conservative NAV layer that values all assets and subtracts all open
   liabilities, including the cost of closing short options.
5. Instant ERC-4626 redemptions only up to demonstrably available liquidity and
   post-redemption risk limits.
6. A separate asynchronous redemption queue, modeled after ERC-7540, for demand
   that exceeds the instant liquidity budget.
7. Strategy adapters with isolated caps and no arbitrary delegatecall into the
   fund.
8. An atomic oToken buyback and collateral-release path so option exposure can
   be reduced before expiry when redemptions or risk management require it.
9. A concentrated-liquidity adapter that can own an LP position, value both
   token inventories and fees, remove liquidity, and return the fund's
   accounting asset.

This is intentionally described as an **ETF-like onchain fund**, not as a legal
or regulated ETF. The architecture borrows the useful economic mechanics of an
ETF: fungible shares, observable NAV, secondary liquidity, and primary creation
and redemption. Legal classification, distribution, transfer restrictions, and
market-access requirements are separate workstreams.

## 2. What product are we building?

### 2.1 User promise

The product should let a user:

1. Select a fund by strategy and risk profile.
2. Deposit its accounting asset, such as USDC.
3. Receive transferable ERC-20 shares immediately when the NAV is fresh and
   deposits are enabled.
4. Hold one fungible asset while the fund manages options, LP positions, spot
   assets, fees, collateral, and strategy transitions internally.
5. See share price, NAV, current composition, utilization, liquidity available
   for instant redemption, and queued-redemption status.
6. Exit by selling shares in a secondary market, redeeming immediately against
   available fund liquidity, or requesting an asynchronous redemption.

The user's share must represent the entire economic portfolio. A strategy event
such as assignment, option expiry, an LP range crossing, or fee collection must
change NAV and not create a different class or generation of share.

### 2.2 Product families the architecture must support

The initial and roadmap products are:

| Product | Main inventory | Main liability or risk | Liquidity action |
| --- | --- | --- | --- |
| Cash-secured put fund | USDC collateral, premium, assigned WETH | Short put marked to market | Buy back put or settle; sell WETH when required |
| Covered-call fund | WETH or other underlying, premium | Short call marked to market | Buy back call or settle; rebalance underlying |
| Concentrated-liquidity fund | Token0, token1, LP NFT, uncollected fees | Inventory and range/IL risk | Decrease liquidity, collect, swap to accounting asset |
| Multi-strategy fund | Allocations to approved adapters | Aggregate adapter liabilities | Deallocate adapters according to liquidity/risk policy |

Each fund has one share supply and one accounting asset. Supporting more assets
does not mean every vault must accept every asset. It means the platform can
deploy multiple funds with different accounting assets and can add controlled
conversion entry points later.

### 2.3 What “ETF-like” means operationally

A traditional ETF does not guarantee that every retail holder can redeem one
share directly with the fund. Retail investors normally buy and sell shares in
a secondary market. Authorized Participants create or redeem large blocks
against a basket of assets and cash, which creates an arbitrage path between
market price and NAV.

The onchain equivalent should eventually have two markets:

- **Secondary market:** anyone transfers or trades the ERC-20 share.
- **Primary market:** the fund creates and redeems shares against NAV, with
  stricter limits for large or in-kind operations.

At launch, direct ERC-4626 deposits and limited redemptions can be the primary
market. A permissioned or permissionless AP layer and a share/USDC market can be
added without changing the share contract semantics.

## 3. Current situation

### 3.1 What is already valuable

The current CSP stack has production-relevant strategy primitives:

- Fully collateralized option creation.
- EIP-712 market-maker quotes with capacity and replay protection.
- Strategy constraints for utilization, strike, premium, expiry, and caps.
- OTM and ITM settlement.
- Reserved physical delivery.
- Timeout/default fallback.
- Assignment accounting and emergency protections.
- Role separation for owner, curator, allocator, and settlement executor.
- An isolated CSP settlement module that does not modify deployed V1.

These components prove the option execution and settlement engine. They should
be reused behind a strategy adapter rather than discarded.

### 3.2 Why the current vault is not the target fund architecture

The current `EthCspVault` explicitly does not implement ERC-4626. It stores
shares in an internal mapping, queues deposits and withdrawals around epochs,
and allocates assigned WETH to individual users.

| Concern | Current model | Required fund model |
| --- | --- | --- |
| Share ownership | `sharesOf` mapping | Transferable ERC-20 balances and allowances |
| Supply | `totalShares` custom accounting | ERC-20 `totalSupply` |
| NAV | Idle USDC plus active collateral | All assets minus all liabilities at fair value |
| Open option | Collateral counted at face value | Collateral counted as asset and short option as liability |
| Assignment | WETH claim per holder/generation | WETH becomes a fund asset reflected in every share |
| Deposits | May remain pending until a new epoch | Mint at a fresh NAV or explicitly reject/queue |
| Instant exit | Only when no active batches/WETH | Up to liquidity and post-exit risk capacity |
| Delayed exit | Epoch withdrawal queue | NAV-based asynchronous redemption queue |
| Position reduction | Wait for expiry | Partial early close/buyback plus collateral release |
| Strategy model | ETH/USDC CSP-specific state | Capped, replaceable strategy adapters |

Making only `sharesOf` transferable would be unsafe. A transfer during an open
batch would not transfer the current holder's separately accrued WETH claim in a
coherent way. Likewise, allowing deposits or withdrawals against the current
`totalManagedAssets` would ignore the market value of the outstanding puts and
permit value transfer between entering, exiting, and remaining holders.

### 3.3 Migration boundary

The current Base Sepolia CSP deployment remains a smoke-test deployment for the
existing model. It should not be upgraded in place into the tokenized fund.

The target architecture requires a fresh fund deployment because it changes:

- The source of truth for share ownership.
- NAV and fee accounting.
- Assignment semantics.
- Deposit and redemption semantics.
- Strategy ownership and position-reduction capabilities.

Migration, if needed, should only occur from a settled and reconciled old vault:
users withdraw or an explicit migration contract exchanges finalized assets for
shares in the new fund at an audited checkpoint.

## 4. Industry standards and reference designs

### 4.1 Standards selected

| Standard | Status and role | Decision |
| --- | --- | --- |
| [ERC-20](https://eips.ethereum.org/EIPS/eip-20) | Fungible balances, transfers, approvals | Required for every fund share |
| [ERC-2612](https://eips.ethereum.org/EIPS/eip-2612) | Signed `permit` approvals | Required for share UX and integrations |
| [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) | Final standard for single-asset tokenized vaults; shares are ERC-20 | Core fund interface |
| [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540) | Final extension for asynchronous ERC-4626 requests | Model for delayed redemptions; exact compliance evaluated separately |
| [ERC-7575](https://eips.ethereum.org/EIPS/eip-7575) | Final extension for multiple asset entry points and external share tokens | Defer until a fund genuinely needs multiple entry assets |

ERC-4626 is the correct base because it standardizes the interface expected by
wallets, routers, aggregators, lending protocols, analytics, and other DeFi
integrations. It also requires `maxWithdraw` and `maxRedeem` to conservatively
represent what can succeed now. That maps directly to the distinction between
fund NAV and currently available liquidity.

The implementation should use OpenZeppelin's maintained ERC-4626 and ERC-20
extensions instead of a local reimplementation. OpenZeppelin documents virtual
assets/shares and a decimal offset as defenses against the ERC-4626 donation or
inflation attack. See the [OpenZeppelin ERC-4626 implementation and security
notes](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#ERC4626).

### 4.2 Large protocol patterns and lessons

| Protocol/reference | Observed pattern | Lesson for b1nary |
| --- | --- | --- |
| [Morpho Vaults](https://legacy.docs.morpho.org/morpho-vaults/contracts/overview/) | ERC-4626 with permit; idle liquidity is used first, then a withdrawal queue deallocates liquid markets | ERC-4626 does not create liquidity. `maxRedeem` must be bounded by what can actually be deallocated |
| [Morpho Vaults V2](https://docs.morpho.org/developers/contracts/morpho-vaults-v2/) | Adapter-based allocation, caps, explicit deallocation, and permissionless force-deallocation with a configurable penalty | Isolate strategies behind capped adapters and make expensive liquidity release explicit |
| [Yearn V3](https://github.com/yearn/yearn-vaults-v3/blob/master/contracts/VaultV3.vy) | ERC-20 vault shares, `minimum_total_idle`, strategy debt, withdrawal queues, and realized-loss allocation on exit | Maintain a real liquidity buffer and charge strategy exit loss to the exiting flow rather than remaining holders |
| [Fluid](https://github.com/Instadapp/fluid-contracts-public/blob/main/docs/docs.md) | ERC-4626 fTokens over a shared liquidity layer with utilization and expanding withdrawal limits | A share can be standard while withdrawals remain capacity-limited |
| [Centrifuge](https://docs.centrifuge.io/developer/protocol/features/vaults/) | ERC-7540 asynchronous vaults and a hybrid model with synchronous deposits and asynchronous redemptions | A standards-based delayed exit is preferable to inventing another epoch-specific user API |
| [Ribbon Theta Vaults](https://docs.ribbon.finance/theta-vault/ribbon-v2) | ERC-20 option-vault shares but epoch-based withdrawals while capital is committed | ERC-20 shares alone do not solve option liquidity or fair NAV during an open short |
| [Uniswap v3](https://app.uniswap.org/whitepaper-v3.pdf) | Concentrated-liquidity positions are non-fungible and fees do not automatically compound | The fund share must wrap and normalize a strategy-specific NFT position and explicitly account for/compound fees |
| [BlackRock BALI prospectus](https://www.ishares.com/us/literature/prospectus/pro-bali-etf.pdf) | Retail trades shares on exchange; APs create/redeem blocks; NAV is assets less liabilities; derivatives use market/dealer valuation | Separate transferable share liquidity from direct fund redemption and mark derivatives as liabilities |
| [BlackRock IVVW SEC prospectus](https://www.sec.gov/Archives/edgar/data/1100663/000119312526081834/d293132d497k.htm) | Covered calls are generally closed with offsetting options on the roll date instead of always waiting for settlement | Early close and roll are core portfolio operations, not optional emergency features |

These protocols are references, not drop-in implementations. Morpho, Yearn,
and Fluid allocate into lending positions that may be atomically withdrawable.
An option writer cannot unlock collateral until the short is reduced or settled.
The strategy adapter must therefore provide an option-specific deallocation
primitive.

## 5. Proposed architecture

### 5.1 Layered model

```text
Users / routers / secondary markets / APs
                    |
                    v
      +--------------------------------+
      | TokenizedFundVault             |
      | ERC-4626 + ERC-20 + ERC-2612  |
      | shares, deposits, NAV exchange |
      +---------------+----------------+
                      |
          +-----------+-----------+
          |                       |
          v                       v
 +------------------+    +----------------------+
 | LiquidityManager |    | ValuationRouter      |
 | buffer, max exit |    | assets, liabilities, |
 | redemption queue |    | freshness, reports   |
 +---------+--------+    +-----------+----------+
           |                         |
           +------------+------------+
                        v
              +-------------------+
              | StrategyRegistry  |
              | caps and adapters |
              +---------+---------+
                        |
          +-------------+--------------+
          |             |              |
          v             v              v
   CSP adapter   Covered-call    LP-range adapter
                 adapter
          |             |              |
          v             v              v
  Controller / oTokens / Settler   AMM position manager
```

The fund owns shares and global accounting. Adapters own or control isolated
strategy positions. Adapters never mint or burn fund shares.

### 5.2 `TokenizedFundVault`

Recommended inheritance:

```solidity
contract TokenizedFundVault is ERC4626, ERC20Permit, ReentrancyGuard
```

Responsibilities:

- ERC-20 balances, transfers, allowances, and total supply.
- ERC-4626 deposit, mint, withdraw, redeem, preview, and max functions.
- Accounting-asset custody.
- Accepted NAV checkpoint and deterministic changes since that checkpoint.
- Fee-share minting.
- Adapter allocation caps.
- Pausing creation/redemption independently from ERC-20 transfers.
- Coordination with the liquidity manager and redemption queue.

Non-responsibilities:

- Selecting strikes or LP ranges.
- Computing Black-Scholes values internally.
- Holding market-maker signing keys.
- Implementing every strategy protocol directly.
- Making arbitrary external calls selected by an allocator.

The fund contract should itself be the ERC-20 share token. A separate share
contract would split authorization and supply invariants without providing a
current benefit. ERC-7575 allows an external share if multi-entry architecture
later makes that separation necessary.

### 5.3 `StrategyRegistry` and adapters

Each approved adapter has:

- Absolute allocation cap.
- Relative allocation cap.
- Allowed assets and external protocols.
- Maximum tolerated loss or exit slippage.
- Allocation and deallocation permissions.
- Optional cooldown and timelock.
- Emergency-exit behavior.

Illustrative interface:

```solidity
interface IFundStrategyAdapter {
    function accountingAsset() external view returns (address);
    function positionStateHash() external view returns (bytes32);
    function liquidAssets() external view returns (uint256);
    function allocate(uint256 assets, bytes calldata data) external;
    function deallocate(uint256 assets, uint256 minAssetsOut, bytes calldata data)
        external
        returns (uint256 assetsOut);
    function emergencyExit(bytes calldata data) external returns (uint256 assetsOut);
}
```

The exact valuation interface should be separate from allocation. An adapter
cannot be trusted to self-report arbitrary value merely because it is allowed to
move capital. The `ValuationRouter` derives or validates value from approved
oracles, protocol state, and signed reports.

Adapters should be called normally, not with `delegatecall`. This provides a
clear storage and custody boundary and lets a compromised adapter be capped and
removed without corrupting share accounting.

## 6. NAV architecture

### 6.1 Accounting definition

Each fund selects one ERC-20 accounting asset. All ERC-4626 values are expressed
in units of that asset.

```text
gross asset value =
    idle accounting asset
  + collateral value
  + spot inventory value
  + LP position value
  + collectible fees and receivables

liabilities =
    cost to close short options
  + accrued protocol/management/performance fees
  + claimable redemption assets
  + debt or settlement obligations
  + conservative unwind costs when applicable

NAV = max(gross asset value - liabilities, 0)
NAV per share = NAV / totalSupply
```

Examples:

**Cash-secured put**

```text
NAV = idle USDC
    + locked USDC collateral
    + WETH inventory valued in USDC
    - executable/conservative put close cost
    - accrued fees and redemption claims
```

Premium is not pure profit at trade open. The fund receives cash and creates a
short-option liability at the same time.

**Covered call**

```text
NAV = idle accounting asset
    + underlying inventory
    + premium
    - short-call close cost
    - accrued fees and claims
```

**Concentrated liquidity**

```text
NAV = idle accounting asset
    + token0 amount at conservative price
    + token1 amount at conservative price
    + collectible token0/token1 fees
    - swap and exit haircut
    - accrued fees and claims
```

The LP NFT is not valued by token ID or deposit cost. It is valued from current
liquidity, ticks, pool state, token balances, collectible fees, approved price
sources, and conservative exit assumptions. Uniswap documents that concentrated
positions can become entirely one asset when price leaves the range and stop
earning fees when inactive; the fund must expose this inventory and range risk.
See [Uniswap concentrated-liquidity concepts](https://developers.uniswap.org/docs/get-started/concepts/liquidity-providers/concentrated-liquidity).

### 6.2 Accepted NAV checkpoints

Calling external pricing systems from `totalAssets()` is fragile and conflicts
with ERC-4626's requirement that the view not revert. The fund should store the
last accepted NAV checkpoint:

```solidity
struct NavCheckpoint {
    uint256 netAssets;
    uint64 timestamp;
    uint64 validUntil;
    bytes32 positionsHash;
    uint256 reportNonce;
}
```

The checkpoint is accepted only if:

- It references the current chain and fund.
- `positionsHash` matches current strategy positions.
- Required price sources and MM close quotes are fresh.
- Signatures meet the configured reporter threshold.
- The change is within deviation bounds or receives elevated approval.
- Its nonce is unused and monotonic.

Deterministic cash flows after a checkpoint, such as a deposit, redemption,
premium receipt, fee payment, realized strategy trade, or claim reservation,
must update accounted NAV immediately. Unrealized position changes require a new
checkpoint.

When NAV is stale or the position hash no longer matches:

- `maxDeposit`, `maxMint`, `maxWithdraw`, and `maxRedeem` return zero.
- State-changing creation and redemption functions revert.
- ERC-20 transfers remain enabled.
- Risk-reducing settlement and emergency deallocation remain available.

This freezes primary-market exchange at an unreliable price without trapping
share ownership.

### 6.3 Price sources

No single market maker should unilaterally set fund NAV. Recommended hierarchy:

- Spot assets: independent oracle plus protocol TWAP and deviation checks.
- Listed or liquid options: executable RFQ median or conservative best available
  buyback cost from multiple approved MMs.
- Illiquid options: conservative model value plus spread/haircut and disabled
  instant creation/redemption if confidence is insufficient.
- LP inventory: deterministic position math plus independent token prices and a
  bounded exit-cost haircut.

The report must expose confidence/freshness so liquidity limits can become more
conservative before the fund fully pauses creation/redemption.

## 7. Liquidity and redemption design

### 7.1 Three exit paths

1. **Secondary transfer or sale.** The holder transfers ERC-20 shares without
   touching fund positions.
2. **Instant ERC-4626 redemption.** The fund burns shares and pays the
   accounting asset from currently available liquidity.
3. **Asynchronous redemption request.** Shares are escrowed, strategy exposure
   is reduced or settled, and assets become claimable later.

These paths are complementary. Secondary liquidity gives ETF-like user exit;
instant redemption anchors the share to NAV; the asynchronous path prevents the
fund from promising liquidity it does not have.

### 7.2 Dynamic idle buffer

The fund should maintain two configurable thresholds:

- `targetIdleBps`: desired idle liquidity under normal operation.
- `minimumIdleBps`: hard post-redemption safety floor.

Candidate values such as 20% target and 5% minimum are starting hypotheses for
simulation, not production decisions.

Instant redemption capacity is the minimum of:

```text
idle capacity = idle assets - reserved claims - minimum idle requirement
risk capacity = amount that preserves every adapter's post-exit utilization cap
flow capacity = configured per-block/per-day redemption limit
oracle capacity = capacity allowed by current NAV confidence

max instant assets = min(idle, risk, flow, oracle capacities)
```

`maxWithdraw` and `maxRedeem` must conservatively expose this number. If a call
could fail because liquidity is not available, the max functions must
underestimate rather than advertise impossible liquidity.

New deposits first restore reserved claims and the target buffer before becoming
deployable strategy capital. This is accounting, not permission to pay old
holders from new deposits at a stale price: all deposits require a fresh NAV,
and processed redemption claims are already explicit liabilities.

### 7.3 Asynchronous queue

The preferred initial architecture is a separate `RedemptionQueue` that escrows
the same ERC-20 shares while the vault remains strictly synchronous ERC-4626 for
its instant path.

Request lifecycle:

```text
requestRedeem(shares)
    -> shares escrowed; holder remains economically exposed

processBatch(requestId, acceptedNav)
    -> strategy liquidity obtained
    -> requests priced pro rata at one accepted checkpoint
    -> shares burned
    -> claimable accounting assets become a fund liability

claimRedeem(requestId)
    -> accounting assets transferred
    -> claim liability reduced
```

The payout is not fixed when the request is submitted. It is fixed when the
request is processed against a fresh NAV after actual unwind costs are known.
Until processing, the requester remains exposed to gains and losses. After
processing, the requester holds a fixed claim and no longer participates in NAV.

Requests processed in the same batch use the same exchange rate. Partial
processing is pro rata. Queue ordering, cancellation rules, and maximum wait
times require a dedicated specification.

This lifecycle follows ERC-7540's Pending -> Claimable -> Claimed model. Exact
ERC-7540 conformance should be decided after integration testing because strict
asynchronous redeem vaults change ERC-4626 preview semantics. The initial design
must not claim ERC-7540 compliance unless every interface requirement is met.

## 8. Early oToken buyback and collateral release

### 8.1 Why it is required

The current Controller settles writer vaults only after expiry. That is safe for
an epoch vault but prevents an ETF-like fund from reducing exposure or releasing
collateral when redemptions arrive.

An early-close path must let the fund repurchase oTokens from the economic holder,
burn them, reduce the writer short, and release excess collateral atomically.

### 8.2 Signed buyback quote

Illustrative EIP-712 quote:

```solidity
struct BuybackQuote {
    address fund;
    uint256 protocolVaultId;
    address oToken;
    uint256 amount;
    uint256 totalCost;
    uint256 deadline;
    uint256 quoteId;
    uint256 makerNonce;
}
```

Required protections:

- Quote bound to fund, protocol vault, option series, chain, and executor.
- Exact or capped partial amount.
- Deadline, nonce, quote capacity, and cancellation.
- Maximum cost derived from the accepted NAV report or explicit slippage guard.
- Only the recorded MM/economic oToken owner can sign.
- Ledger amount and actual custodied oToken balance must agree.

### 8.3 Atomic close operation

The Controller should expose one atomic primitive, conceptually:

```solidity
closeShortAndWithdrawCollateral(
    address owner,
    uint256 vaultId,
    uint256 shortAmount,
    address oTokenHolder,
    address collateralReceiver,
    uint256 minCollateralOut
) returns (uint256 collateralOut);
```

Atomic sequence:

1. Verify authorization and non-expired close intent.
2. Transfer buyback payment from the fund to the MM.
3. Burn the repurchased custodied oTokens.
4. Decrease the protocol vault's short amount.
5. Recompute required collateral for the remaining short.
6. Release only collateral above the new requirement.
7. Update CspBatchSettler MM/vault ledgers and physical-delivery reservations.
8. Update the strategy adapter position and realized PnL.
9. Assert actual balances, ledger balances, short amount, and collateral agree.

Burning the short and withdrawing collateral must not be two independently
callable allocator actions. An intermediate undercollateralized or ledger-mismatched
state is unacceptable.

### 8.4 How the queue uses buybacks

The liquidity manager aggregates redemption demand rather than unwinding an
option for every retail request:

```text
queued demand
  -> determine required liquidity
  -> select positions by cost/risk policy
  -> request competitive MM buyback quotes
  -> execute bounded partial closes
  -> release collateral
  -> checkpoint realized NAV
  -> process redemption batch
```

Selection should minimize total cost while preserving strategy constraints. A
buyback can be skipped when waiting for near-term expiry is cheaper and within
the queue's service-level objective.

The same close primitive supports covered calls: repurchase and burn calls,
reduce the short, and release the corresponding WETH collateral.

## 9. Concentrated-liquidity fund adapter

The roadmap LP strategy is not an exception to the architecture. It is a second
implementation of the same allocation/deallocation/valuation contract boundary.

### 9.1 Responsibilities

`ConcentratedLiquidityStrategyAdapter` should:

- Accept the fund's accounting asset.
- Swap a bounded portion into the paired asset.
- Mint and custody the LP NFT at approved pool, fee tier, and tick range.
- Increase/decrease liquidity only within policy.
- Collect and optionally compound fees.
- Report deterministic inventory and position state hash.
- Exit partially or fully and return the accounting asset with `minAssetsOut`.
- Support emergency removal of liquidity without requiring a favorable swap.

The adapter may temporarily return both pool assets in emergency mode. Normal
fund redemption remains denominated in the accounting asset; emergency in-kind
distribution would require a separate reviewed mechanism.

### 9.2 Valuation and risk

The LP adapter's NAV module must include:

- Token0 and token1 amounts represented by current liquidity.
- Collectible but uncollected fees.
- Idle balances in the adapter.
- Independent prices, not only the pool's manipulable spot tick.
- TWAP deviation and sequencer/oracle health checks.
- Swap and price-impact haircut for the size expected to be unwound.
- Range status and concentration exposure.

Risk limits should include:

- Approved pools and fee tiers.
- Minimum oracle and onchain liquidity depth.
- Maximum share of fund NAV in one pool/range.
- Maximum token inventory imbalance.
- Minimum range width and rebalance cooldown.
- Maximum rebalance slippage and daily turnover.

No changes to ERC-20 shares, deposit semantics, or the redemption queue are
needed when this adapter is added.

## 10. Extensibility model

### 10.1 More strategies

Adding a strategy requires:

1. A strategy adapter.
2. A valuation module.
3. Risk and allocation policy.
4. Deallocation and emergency-exit tests.
5. Integration/audit approval.

It does not require a new share implementation.

### 10.2 More accounting assets

Deploy another `TokenizedFundVault` configured with the new ERC-20 asset. Each
fund remains a valid single-asset ERC-4626 vault.

Examples:

- USDC CSP fund.
- WETH covered-call fund.
- USDC ETH/USDC range-liquidity fund.
- cbBTC covered-call fund with cbBTC as accounting asset.

The frontend may show every NAV in USD, but ERC-4626 math remains in the fund's
accounting asset.

### 10.3 Multiple deposit assets

Do not add multi-asset deposits directly to the core fund in the first version.
Use a router or zap that converts the user's token to the accounting asset and
then calls `deposit` with `minSharesOut`.

Adopt ERC-7575 only if the product requires multiple canonical asset entry
points sharing one share token. This preserves simple ERC-4626 integrations now
without closing the future path.

### 10.4 Multi-strategy funds

The same fund can allocate to multiple approved adapters, but a product should
start with one principal strategy. Combining adapters changes risk, fees, and
liquidity behavior and should be a deliberate product configuration, not an
incidental consequence of extensibility.

## 11. Roles and governance

Recommended roles:

| Role | Authority |
| --- | --- |
| Owner/timelock | Upgrade or replace governed components; assign roles |
| Curator | Set strategy policies, adapter caps, buffer targets, and risk bounds |
| Allocator | Allocate/deallocate within approved bounds; cannot change bounds |
| NAV reporter set | Sign or submit valuation reports |
| Settlement/close executor | Execute approved settlements and buybacks |
| Guardian | Pause deposits/redemptions and new allocations; allow risk reduction |
| AP role, optional | Submit large creation/redemption or in-kind operations |

Production control should use a multisig and timelock for value-expanding
changes. Emergency actions should only reduce exposure or pause primary-market
exchange. Pausing should not normally disable ERC-20 transfers.

## 12. Security invariants

The implementation and audits must enforce at least these invariants:

### Share and NAV invariants

1. `totalSupply` is the only source of share supply.
2. Only successful deposit/mint, fee accrual, redeem/withdraw, and processed
   queue operations change share supply.
3. A transfer changes ownership but never fund NAV or supply.
4. No deposit or redemption executes against stale or mismatched NAV.
5. Every claimable redemption is excluded from shareholder NAV and fully
   reserved as a liability.
6. Rounding favors the fund according to ERC-4626 rules and cannot mint zero
   shares for an accepted nonzero deposit.
7. Virtual shares/assets or an equivalent audited defense protects first
   deposits and donations.

### Strategy invariants

1. Sum of adapter allocations never exceeds available, non-reserved assets.
2. Every adapter remains within absolute and relative caps.
3. Adapter-reported inventory is reconciled against external protocol state and
   token balances.
4. No adapter can mint fund shares or modify core accounting storage.
5. A strategy trade cannot leave NAV based on a pre-trade position hash.

### Option invariants

1. Short oToken supply, Controller short amount, settler custody, MM ledger, and
   fund batch ledger remain equal for each position.
2. Collateral after partial close is never below the requirement for the
   remaining short.
3. Buyback payment cannot be made unless the corresponding short is burned in
   the same transaction.
4. Physical-delivery reservations are reduced exactly with the closed amount.
5. Premium receipt and short-option liability enter NAV together.

### Redemption invariants

1. Instant redemption never spends pending deposits or claim reserves.
2. Instant redemption never violates adapter or fund post-exit utilization.
3. Queue processing uses one accepted NAV per batch and is pro rata.
4. Actual unwind losses and fees are charged according to disclosed queue
   policy and cannot be shifted silently to remaining holders.
5. A processed request cannot regain strategy exposure before claim.

## 13. Alternatives considered

### Add ERC-20 transfers to `EthCspVault`

Rejected. Assignment claims, share generations, and epoch-specific state would
not transfer coherently. This treats the visible symptom and preserves incorrect
NAV semantics.

### Use a separate wrapper token around current shares

Rejected. A wrapper cannot make the underlying position continuously redeemable
or correctly mark the short liability. It adds another supply layer and worsens
integration/accounting risk.

### Promise unlimited instant redemption from a fixed buffer

Rejected. A buffer can be exhausted and redemptions can increase remaining
holders' utilization. Instant capacity must include both cash and risk limits.

### Keep all exits epoch-based

Rejected as the long-term product. Epochs remain useful for strategy scheduling,
but share ownership and user liquidity should not depend on a strategy's roll
calendar.

### Make the core fund multi-asset immediately

Rejected for v1. It complicates ERC-4626 compliance, valuation, and redemption.
One accounting asset plus adapters and optional zaps is simpler and extensible.

### Let one MM set NAV and execute the close

Rejected. The MM benefits from a higher buyback cost. Pricing and execution need
independent validation, competition, bounds, or conservative haircuts.

## 14. Recommended delivery phases

### Phase A: specification and prototypes

- Finalize this architecture.
- Model NAV for CSP, covered call, and LP range positions.
- Simulate buffer/redemption demand and buyback costs.
- Specify exact queue fairness and fee policy.
- Define storage/upgradability policy.

### Phase B: ERC-4626 fund core

- Implement OpenZeppelin ERC-4626 + ERC-2612 shares.
- Implement virtual-share defense and slippage-aware entry wrappers.
- Implement NAV checkpoints, freshness gates, roles, and a mock adapter.
- Test deposits, transfers, instant redemptions, fees, donations, and stale NAV.

### Phase C: CSP adapter without early close

- Connect the existing CSP engine behind the new adapter.
- Treat assigned WETH as a fund asset instead of a per-user claim.
- Add asynchronous queue fulfilled by expiry settlement.
- Validate complete accounting on Base Sepolia.

### Phase D: option buyback and early close

- Add signed buyback RFQ.
- Add atomic partial short close and collateral release.
- Let queue processing choose early close or expiry.
- Audit Controller, settler ledger, NAV, and queue together.

### Phase E: secondary and AP liquidity

- Seed a share/accounting-asset secondary market.
- Add creation/redemption limits and monitoring.
- Introduce AP or in-kind baskets only when operationally justified.

### Phase F: covered-call and LP-range adapters

- Reuse the option close primitive for covered calls.
- Implement concentrated-liquidity inventory, valuation, deallocation, and
  emergency exit.
- Add multi-strategy allocation only after each adapter is independently proven.

## 15. Review decisions required

The architecture review should explicitly approve or change:

1. ERC-4626 vault-as-share versus an external ERC-7575 share.
2. Accounting asset for each initial product.
3. Accumulating premium in NAV versus periodic cash distributions.
4. NAV reporter trust model and minimum source set.
5. Buyback quote competition and acceptable valuation haircuts.
6. Target/minimum idle policy and redemption flow limits.
7. Queue ordering, partial processing, cancellation, and service objective.
8. Adapter custody model and emergency in-kind behavior.
9. Upgradeability, timelock, and migration policy.
10. Whether AP/in-kind creation is launch scope or a later liquidity phase.

## 16. Acceptance criteria for the target platform

The architecture is successful when:

- Shares are standard ERC-20/ERC-4626 assets that transfer without special
  per-holder strategy accounting.
- NAV includes every asset and liability for all active adapters.
- No holder can enter or exit at another holder's expense due to an unmarked
  option or LP position.
- Instant redemption truthfully reflects current liquidity and risk capacity.
- Excess redemption demand has a deterministic, fair asynchronous path.
- A CSP or covered-call short can be partially repurchased and collateral can be
  released atomically before expiry.
- Assignment changes portfolio composition, not share class or generation.
- A concentrated-liquidity strategy can be added without changing the fund
  share, NAV contract, or user redemption interface.
- New assets and strategies are added through configured fund deployments,
  valuation modules, and capped adapters rather than core rewrites.

## 17. Recommendation

Approve ERC-4626 + ERC-2612 as the permanent share and primary-market standard.
Build a fresh `TokenizedFundVault` with conservative NAV checkpoints, dynamic
instant liquidity, and an asynchronous redemption queue. Reuse the existing
options engine through an adapter, but add an audited atomic buyback/partial-close
primitive before promising redemptions backed by locked option collateral.

Keep one accounting asset per fund and use adapters for strategy diversity. This
is the smallest architecture that solves the current CSP share problem at its
root while remaining capable of supporting covered calls, concentrated-liquidity
positions, more underlyings, and eventually multi-strategy funds.
