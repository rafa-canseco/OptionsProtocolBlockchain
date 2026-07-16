# B1N-348: Tokenized Fund Vault Architecture

Status: Approved for executable specification and implementation
Date: 2026-07-16  
Scope: Product and smart-contract architecture  
Decision type: Foundational; fresh deployment required  

Sections 18 and later contain the reviewer disposition and the normative
revision that addresses it. Where the original proposal and the normative
revision differ, the normative revision controls.

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

## 18. Initial reviewer conclusions

Reviewer disposition: **approve the product direction, subject to specification
changes before implementation approval**.

### 18.1 Product decisions confirmed

1. The architecture is a strategy-independent foundation for tokenized,
   ETF-like funds. The fund core standardizes shares, NAV, deposits,
   redemptions, distributions, governance, and adapter boundaries; each fund
   defines its own strategy and risk policy.
2. Products may include a complete Wheel fund, a CSP fund, a covered-call fund,
   a concentrated-liquidity range fund, or future strategy funds without
   changing the core share model.
3. Premiums and other realized strategy income first accrue to fund NAV.
   Periodic distributions are supported, with frequency and policy configured
   per fund by its curator.
4. Curator changes to distribution policy require a timelock, cannot affect an
   already declared distribution, and cannot distribute assets reserved for
   claims or required risk collateral.
5. Redemption policy is configurable per fund. A fund may support instant
   accounting-asset redemption, asynchronous redemption, in-kind redemption,
   secondary-market exit, or an approved combination of these paths.
6. Every fund must retain at least one viable exit path. Curator changes to
   redemption policy require a timelock and cannot retroactively change pending
   redemption requests.
7. In-kind redemption is included. Instant in-kind redemption is limited to
   free assets; assets locked by an active strategy become redeemable through
   the asynchronous queue after settlement or a bounded unwind.
8. The in-kind basket is fund-specific. Examples include USDC and WETH for a
   Wheel fund, WETH and accrued USDC for a covered-call fund, and token0 and
   token1 for a concentrated-liquidity fund.
9. A Wheel fund keeps assigned WETH inside the same fund and transitions from
   CSP execution to covered-call execution without changing its share class.
10. The Wheel covered-call policy protects an adjusted economic cost basis, not
    only the literal assignment strike:

```text
protected cost basis =
    assignment strike
  - attributable net CSP premium
  - attributable net covered-call premiums
  + attributable execution costs and strategy fees
```

The allocator must not open a covered call below the protected cost basis. Fund
NAV nevertheless remains mark-to-market and must never use the protected cost
basis as the current value of WETH.

### 18.2 Required specification changes

The following points remain blocking for implementation approval:

1. **NAV execution model.** Specify component-level, block-bound reports,
   reporter independence, position-hash invalidation, primary-market windows,
   and protection against depositing or redeeming immediately before a NAV
   update. A signed `netAssets` value alone is insufficient.
2. **Redemption standard.** Choose and document one authoritative share-burning
   lifecycle. Prefer exact ERC-7540 asynchronous redemption semantics, with an
   immediately claimable request when liquidity is available, over maintaining
   independent synchronous and queued accounting systems. If a separate queue
   is retained, the product must not claim ERC-7540 compliance.
3. **Exit-cost allocation.** Define when market losses are socialized across all
   shares and when marginal unwind costs, exit fees, or swing pricing are
   charged to the exiting flow.
4. **In-kind accounting.** Define basket calculation, rounding, minimum output
   protection, partial processing, claim reservations, and behavior when an
   adapter returns multiple assets.
5. **Distribution accounting.** Define declaration, record checkpoint,
   entitlement calculation, claim mechanism, NAV reduction, fee interaction,
   and treatment of transferred shares after the record checkpoint.
6. **Smart-wallet compatibility.** Keep ERC-2612 for EOA and integration
   compatibility, but do not rely on it as the primary UX for contract smart
   wallets. Specify batched approval, ERC-1271-compatible authorization, or an
   equivalent supported path.
7. **Option close separation.** Keep buyback quote verification, payment, and
   settlement ledgers in the option adapter or settler. The Controller should
   expose only the atomic primitive required to burn or reduce the short and
   release excess collateral. The externally initiated flow must remain atomic.
8. **Lifecycle invariants.** Replace any per-vault equality between global
   oToken supply and vault ledgers with stage-specific invariants covering open,
   partially closed, settled, reserved, and redeemed positions.
9. **Fee accounting.** Specify management and performance fee accrual,
   crystallization, high-water marks, fee-share minting, and their interaction
   with distributions and queued redemptions.
10. **Failure and governance policy.** Define NAV-zero behavior, donation and
    unaccounted-balance handling, adapter deficits, queue cancellation,
    emergency in-kind exits, upgrades, timelocks, and migration.

### 18.3 Initial approval boundary

The accepted direction is a fresh, standards-oriented fund core using
transferable ERC-20 shares, ERC-4626-compatible accounting where applicable,
strategy adapters, conservative NAV, configurable distributions, and
fund-specific redemption policies including eventual in-kind redemption.

At this initial review stage, contract implementation was not yet authorized.
Sections 19-30 incorporate the blocking specifications, and the final
disposition at the end of section 30 supersedes this initial gate.

## 19. Normative architecture after review

This section resolves the review blockers and is the recommended architecture
for implementation. It deliberately separates fund accounting from strategy
execution while avoiding excessive contract fragmentation.

### 19.1 Final design decisions

1. Every fund share is the transferable ERC-20 surface of an
   ERC-4626-compatible fund vault. For ERC-7540/ERC-7575 compatibility,
   `share()` returns the vault itself and the required interfaces are exposed
   through ERC-165.
2. All direct redemptions use one authoritative ERC-7540 request lifecycle.
   There is no second synchronous share-burning path.
3. A liquid request may become claimable immediately, but requesting and
   claiming remain two distinct calls as required by ERC-7540.
4. The fund core never imports option, AMM, lending, or NFT-position logic.
5. Strategies execute through separately upgradeable, capped adapters using
   normal external calls. No strategy runs with `delegatecall` in fund storage.
6. NAV is committed to the fund from component-level, block-bound reports. A
   naked signed `netAssets` value is insufficient.
7. Position-changing strategy operations invalidate primary-market NAV before
   they execute and keep creation/redemption processing closed until a new NAV
   is activated.
8. Option RFQ verification and payment remain in the option adapter/settler.
   The Controller exposes only atomic position primitives.
9. Each stateful fund component uses an individual UUPS `ERC1967Proxy`. Beacon
   proxies are not used because a single beacon upgrade would change every fund
   simultaneously.
10. New contracts use OpenZeppelin Contracts Upgradeable from one pinned major
    release and ERC-7201 namespaced storage. Existing proxies from another
    OpenZeppelin major version are not upgraded into this architecture.

### 19.2 Contract map

The production stack has four stateful core proxies per fund:

```text
                         OpenZeppelin AccessManager
                         multisig + delayed roles
                                   |
          +------------------------+------------------------+
          |                        |                        |
          v                        v                        v
 +----------------+      +------------------+      +------------------+
 | FundVault      |<---->| FundAccounting   |      | StrategyManager  |
 | UUPS proxy     |      | UUPS proxy       |      | UUPS proxy       |
 | ERC20/4626/    |      | NAV + fees       |      | caps + adapters  |
 | 7540 facade    |      +------------------+      +---------+--------+
 +-------+--------+                                           |
         |                                                    |
         v                                                    v
 +----------------+                              +-------------------------+
 | FundFlowManager|                              | Strategy adapter proxies|
 | UUPS proxy     |                              | option / wheel / LP     |
 | requests/claims|                              +------------+------------+
 +-------+--------+                                           |
         |                                                    v
         v                                        protocol-specific systems
 ClaimEscrow / DistributionEscrow                 Controller / Settler / AMM
```

Shared or replaceable supporting contracts:

- `AccessManager`: standard OpenZeppelin deployment, not custom proxy logic.
- `IPositionValuator` implementations: stateless, non-proxy contracts selected
  by the delayed registry in `FundAccounting`.
- `OptionCloseSettler`: optional UUPS proxy shared by compatible option adapters
  in a single option stack; it handles early buyback only and does not replace
  the deployed `BatchSettler`.
- `ClaimEscrow` and `DistributionEscrow`: one minimal immutable instance of each
  per fund. They record and release declared liabilities, have no admin sweep,
  and contain no strategy or governance logic.
- `FundFactory`: versioned deployer that creates ERC-1967 proxies from approved
  implementations. It has no authority over deployed fund assets.

The four-contract fund core is an intentional boundary. Combining them creates
a large implementation with mixed trust domains. Splitting further would spread
share and NAV invariants across too many cross-contract calls.

### 19.3 Lightweight contract budgets

The following are design budgets, not reasons to omit required checks:

| Contract | Responsibilities | Runtime target |
| --- | --- | ---: |
| `FundVault` | ERC-20/4626 surface, custody, committed NAV, authorized mint/burn, reserves | `< 18 KB` |
| `FundAccounting` | NAV reports, component aggregation, fee crystallization | `< 16 KB` |
| `FundFlowManager` | ERC-7540 requests, processing, accounting/in-kind claims | `< 18 KB` |
| `StrategyManager` | Adapter registry, caps, allocation/deallocation | `< 14 KB` |
| Strategy adapter | One strategy lifecycle only | `< 18 KB` |
| Stateless valuator/policy | One valuation or policy domain | `< 10 KB` |

Every contract remains below the EIP-170 runtime limit with operational margin.
If a component exceeds its target, first extract a coherent external subsystem,
not arbitrary internal functions. Reusable arithmetic can be a library, but an
internal library does not reduce deployed bytecode when inlined.

## 20. Core proxy responsibilities

### 20.1 `FundVault`

`FundVault` is the only share token and the only contract allowed to change
share supply. It is an upgradeable ERC-4626/2612 implementation and exposes the
ERC-7540/ERC-7575 user interface through thin calls into `FundFlowManager`.
Because the vault itself is the share token, `share()` returns `address(this)`.
It exposes the required ERC-165 interface IDs and emits all standard request and
claim events from the vault address, even though the flow manager owns the
request state machine.

It stores only fund-critical source-of-truth state:

- Accounting asset.
- ERC-20 balances, allowances, permit nonces, and total supply through
  OpenZeppelin upgradeable modules.
- Active `FundAccounting`, `FundFlowManager`, and `StrategyManager` addresses.
- Last committed NAV, NAV activation/expiry blocks, report nonce, and
  `positionsHash`.
- Accounted idle balance.
- Assets reserved for processed redemption and distribution claims.
- Primary-market pause flags and component compatibility versions.

It does not store option batches, LP ticks, strategy premiums, MM quotes, or
strategy-specific positions.

Only these components may change core state:

- `FundAccounting` commits NAV and requests fee-share minting.
- `FundFlowManager` escrows/burns shares and reserves/releases claims.
- `StrategyManager` asks the vault to transfer a capped asset amount to an
  approved adapter.

Core component proxy addresses and both escrow addresses are fixed at
initialization and have no routine governance setter. Normal evolution upgrades
the implementation behind the same proxy. Changing the topology or replacing a
proxy address requires the explicit fund migration process in section 29.5.

`totalAssets()` reads the committed local NAV and deterministic post-commit cash
flows. It does not call an adapter, oracle, or reporter and therefore satisfies
the ERC-4626 non-reverting view requirement.

### 20.2 `FundAccounting`

`FundAccounting` is the only component that can propose a NAV commit. It owns:

- Component-to-valuator registry and valuator interface versions.
- Reporter-set versions and thresholds.
- Component report nonces and accepted component values.
- Management-fee accrual time.
- Performance-fee crystallization schedule.
- Distribution-adjusted high-water mark.
- Component and aggregate report validation.

After validating a complete report and crystallizing fees, it calls the vault
once with the resulting NAV, supply adjustment, report hash, and validity
window. The vault verifies the caller and that the report references its current
position nonce/hash.

Combining NAV and fees in one accounting component prevents a deposit,
redemption, or distribution from using NAV before required fees are reflected.

### 20.3 `FundFlowManager`

`FundFlowManager` is the only redemption lifecycle. It owns:

- Pending and claimable ERC-7540 request state.
- Request batch IDs and immutable processing mode.
- Pro-rata partial processing.
- Accounting-asset and in-kind basket claims.
- Request cancellation state.
- Exit-cost and swing-pricing records.

The manager never mints arbitrary shares. On request, the vault escrows shares.
On processing, the manager instructs the vault to burn the processed portion and
move exact assets into a claim escrow. On claim, assets move from escrow to the
receiver.

### 20.4 `StrategyManager`

`StrategyManager` owns strategy configuration, not assets:

- Approved adapter addresses and interface versions.
- Absolute and relative allocation caps.
- Asset permissions.
- Allocation, deallocation, and emergency permissions.
- Adapter position nonce and aggregate `positionsHash`.
- Cooldowns, slippage bounds, and loss limits.

An allocator can operate only inside active limits. Adding an adapter, raising a
cap, changing a valuator, or expanding allowed assets is delayed governance.
Removing exposure, lowering caps, pausing allocation, and emergency deallocation
can be immediate guardian actions.

Before a position-changing call, `StrategyManager` closes the fund's primary
market and increments the affected component position nonce. After execution it
records the resulting state hash. Primary-market processing reopens only after a
new report covers that hash.

### 20.5 Cross-contract execution safety

Modularity must not create a reentrancy path across proxies. Asset-, NAV-, or
supply-changing operations acquire a fund-wide execution lock in `FundVault`.
The flow and strategy managers may enter that lock only through their typed
entry points and cannot invoke one another arbitrarily.

Every asset-moving path also follows these rules:

- Checks and accounting effects precede external protocol calls.
- Adapters expose typed methods and cannot receive an arbitrary target plus
  arbitrary calldata from an allocator.
- Actual token balance deltas, not return values, determine received assets.
- `SafeERC20` is used and protocol allowances are exact or bounded, then reset
  when the integration permits it.
- Unsupported fee-on-transfer, rebasing, callback, and ERC-777-like accounting
  assets are rejected at fund creation.
- A callback cannot reenter deposits, request processing, NAV activation,
  allocation, fee crystallization, or distribution declaration.
- Every module validates `msg.sender`, the configured fund, interface version,
  and active compatibility version before changing state.

## 21. Strategy separation

### 21.1 Adapter boundary

Every strategy adapter is a separate UUPS proxy and owns only its strategy state
and strategy-held assets. It implements a versioned interface:

```solidity
interface IFundStrategyAdapter {
    function fund() external view returns (address);
    function accountingAsset() external view returns (address);
    function interfaceVersion() external pure returns (uint32);
    function positionStateHash() external view returns (bytes32);
    function freeAssets(address asset) external view returns (uint256);

    function allocate(address asset, uint256 amount, bytes calldata data)
        external;

    function deallocate(
        uint256 targetValue,
        uint256 minAccountingAssetsOut,
        bytes calldata data
    ) external returns (uint256 accountingAssetsOut);

    function deallocateInKind(
        uint256 fractionWad,
        address escrow,
        bytes calldata data
    ) external returns (address[] memory assets, uint256[] memory amounts);

    function emergencyExit(address escrow, bytes calldata data)
        external
        returns (address[] memory assets, uint256[] memory amounts);
}
```

The adapter cannot call share mint/burn functions. The fund never trusts
`adapter.totalValue()` as NAV. Valuation is independently produced by approved
valuators from protocol state and balances.

### 21.2 Options architecture

Options use three layers:

```text
Fund / StrategyManager
        |
        v
Option strategy adapter proxy
position IDs, lifecycle, cost-basis attribution, strategy policy
        |
        v
OptionCloseSettler proxy
RFQ signatures, quote capacity, MM payments, settler ledgers
        |
        v
Controller proxy
open/deposit/mint and atomic reduce-short/release-collateral primitive
```

The Controller does not know fund NAV, withdrawal requests, or buyback prices.
The option adapter does not manipulate Controller storage directly. The settler
verifies the quote, receives/reconciles oTokens, pays the MM, and invokes one
Controller primitive atomically.

The existing V1 Controller and BatchSettler bytecode, proxy implementations,
storage layout, accounting, and settlement behavior are not changed for this
architecture. A fresh CSP adapter does require standard authorization through
the existing owner-only public interface:

```solidity
BatchSettler.setPhysicalDeliveryVault(cspAdapter, true);
```

This onboarding is configuration, not an implementation upgrade. Deployment
must execute it from the current `BatchSettler` owner, verify
`authorizedPhysicalDeliveryVault(cspAdapter) == true`, record the transaction
hash, and fail closed before allocating fund assets if authorization is absent.
Authorization can later be revoked with the same interface after exposure and
reserved-delivery obligations are reconciled.

Initial CSP adapters use the existing expiry-settlement interfaces. If early
close requires a new Controller primitive, that primitive is delivered in a
fresh, separately audited option stack; Phase 3 never changes the deployed V1
stack in place.

At expiry, `BatchSettler` remains responsible for the existing automatic
settlement and physical-delivery accounting. The MM does not deliver WETH. The
optional `OptionCloseSettler` exists only for a pre-expiry RFQ in which the fund
buys back oTokens and releases the corresponding collateral atomically.

Standalone products use a CSP or covered-call adapter. A Wheel product uses a
small `WheelStrategyAdapter` coordinator that:

- Tracks CSP, assigned inventory, and covered-call phases.
- Keeps assigned WETH inside the fund strategy.
- Attributes net premiums and execution costs.
- Enforces protected economic cost basis before opening a covered call.
- Calls common option settlement primitives rather than duplicating them.

Protected cost basis is strategy policy only. The independent valuator always
marks WETH and option liabilities to current conservative market value.

### 21.3 Concentrated-liquidity architecture

`ConcentratedLiquidityAdapter` owns the LP NFT and interacts with the approved
position manager. It contains:

- Pool, fee tier, token pair, ticks, and token ID.
- Allocation/deallocation and fee collection.
- Rebalance cooldown and execution bounds.
- Emergency decrease-liquidity and raw-token return.

It does not calculate authoritative NAV. A separate stateless LP valuator reads
position liquidity, current amounts, collectible fees, independent token
oracles, TWAP deviation, and configured exit haircuts.

Adding an LP strategy therefore requires one adapter, one valuator, and one
policy configuration. It does not modify the fund proxy implementation.

## 22. Proxy and upgrade scheme

### 22.1 Pattern selection

Use individual OpenZeppelin UUPS implementations behind `ERC1967Proxy` for each
stateful fund component and strategy adapter. UUPS keeps proxies light and
matches the existing protocol's proxy direction. OpenZeppelin requires
`_authorizeUpgrade` to enforce access control; see the [UUPS and ERC-1967 proxy
documentation](https://docs.openzeppelin.com/contracts/5.x/api/proxy).

An implementation may be shared initially by many fund proxies, but every proxy
retains its own implementation slot and delayed upgrade decision. This preserves
deployment efficiency without coupling production rollouts across funds.

Do not use:

- Beacon proxies for funds or adapters: one upgrade would change all products
  and removes canary rollout isolation.
- Diamond/facet storage: the system is modular across contracts already, and
  diamonds add selector and storage complexity without solving a current need.
- Minimal clones for stateful core components: they are not individually
  upgradeable. Clones remain acceptable for simple claim escrows.
- Untrusted `delegatecall`: strategy code must not execute in fund storage.

### 22.2 Storage and dependencies

All fresh implementations use:

- A pinned, audited OpenZeppelin Contracts Upgradeable v5 release.
- Upgradeable token/access/security modules and explicit parent initializers.
- ERC-7201 storage namespaces with unique identifiers. ERC-7201 standardizes
  namespaced structs at collision-resistant slots; see
  [ERC-7201](https://eips.ethereum.org/EIPS/eip-7201).
- Implementation constructors that call `_disableInitializers()`.
- No constructor state, mutable immutables, `selfdestruct`, or arbitrary
  `delegatecall`.

Every upgrade runs OpenZeppelin Foundry upgrade validation with storage layout
output enabled. The repository must add and pin
`openzeppelin-contracts-upgradeable` and `openzeppelin-foundry-upgrades` before
implementation. `UnsafeUpgrades` and blanket storage-check bypasses are not
allowed in deployment scripts.

### 22.3 Upgrade authority

Each fund stack is controlled by an OpenZeppelin `AccessManager` whose admin is
a production multisig. OpenZeppelin supports function-level permissions,
execution delays, and guardians across multiple targets; see
[AccessManager](https://docs.openzeppelin.com/contracts/5.x/access-control).

Minimum policy:

| Change | Delay |
| --- | ---: |
| Core implementation upgrade | 72 hours |
| Adapter/settler implementation upgrade | 48 hours |
| Add adapter or valuator | 48 hours |
| Raise allocation/risk cap | 24 hours |
| Distribution/redemption policy change | 24 hours |
| Lower cap, pause allocation or primary market | Immediate guardian |
| Resume after incident | Delayed |

An upgrade cannot alter a pending request's mode, processing checkpoint, claim
basket, or declared distribution. Storage migrations use versioned
`reinitializer` calls in the same scheduled `upgradeToAndCall` operation.

Production upgrades follow:

1. Storage and selector validation against the exact deployed implementation.
2. Full upgrade simulation on a stateful fork.
3. Base Sepolia canary deployment and invariant suite.
4. Scheduled production upgrade with bytecode hash published.
5. Post-upgrade state, role, NAV, reserve, and position reconciliation.

## 23. NAV execution model

### 23.1 Component reports

Each report is component-level rather than a single opaque NAV number:

```solidity
struct ComponentReport {
    address fund;
    bytes32 componentId;
    uint256 chainId;
    uint64 snapshotBlock;
    bytes32 snapshotBlockHash;
    uint64 validAfterBlock;
    uint64 validUntilBlock;
    uint64 reporterSetVersion;
    uint256 componentNonce;
    bytes32 positionStateHash;
    uint256 grossAssets;
    uint256 liabilities;
    uint256 liquidAccountingAssets;
    uint256 baseExitCost;
    bytes32 dataHash;
}
```

Components include idle custody, every adapter, fees, and reconciliation records
for claim and distribution escrows. Escrowed claims and distributions have zero
shareholder-NAV contribution because those assets already left fund custody;
their component records prove that the excluded assets match immutable
liabilities. The aggregate report lists every active component exactly once.
Missing, duplicate, stale, or mismatched components invalidate the report.

### 23.2 Reporter independence

Reporter domains are separated:

- Spot/oracle reporters cannot allocate assets or execute strategy trades.
- Option liability requires independent market data and at least two approved
  executable MM observations when available; the executing MM alone cannot set
  the accepted close liability.
- LP valuation uses deterministic position math plus independent token oracles;
  the LP adapter cannot sign its own value.
- Aggregate NAV approval requires a quorum from a reporter set controlled by
  delayed governance.

The accepted report stores reporter-set version and signatures hash for audit.

### 23.3 Primary-market windows

Supply-changing exchange is permitted only in explicit NAV windows:

```text
1. Close primary market.
2. Snapshot all components at block B.
3. Submit component reports bound to B and current position nonces.
4. Aggregate and commit NAV after B.
5. Activate at B + activationDelay for a bounded number of blocks.
6. Expire the window automatically.
```

There is no valid period in which users can deposit or process redemptions
immediately before a known NAV update. Reports submitted through the mempool do
not activate in the same block. Users protect entry with `minSharesOut`; queued
redemptions carry minimum accounting-asset or basket outputs.

Any strategy operation that changes exposure closes the window first and
increments a component nonce. Deterministic cash movements that do not change
share price, such as a deposit at the committed rate, are recorded as NAV deltas
inside the same window. A price-sensitive operation invalidates the window.

`totalAssets()` may continue to show the last committed value after expiry, but
all max creation/claim-processing functions return zero until a new active
window. This separates informational NAV from executable NAV.

## 24. Authoritative ERC-7540 redemption lifecycle

### 24.1 One lifecycle

All direct exits enter one authoritative request state machine. The
accounting-asset path begins with standard `requestRedeem` and implements
ERC-7540 exactly. In-kind exit begins with the extension
`requestRedeemInKind`, but uses the same escrow, processing, burn, and claim
states. There is no direct ERC-4626 withdrawal that bypasses request accounting.
Synchronous `deposit` and `mint` remain standard ERC-4626 entry functions while
an executable NAV window is active.

```text
Pending
  requestRedeem(shares, controller, owner)
  -> shares transferred to vault escrow
  -> shares remain in totalSupply and exposed to NAV

Claimable
  processRedeem(requestId, fraction)
  -> fresh NAV window required
  -> processed shares burned
  -> exact assets moved to ClaimEscrow
  -> claim is no longer exposed to fund NAV

Claimed
  redeem/withdraw(..., controller)
  -> consumes claimable request
  -> escrow sends assets to receiver
```

If idle liquidity and risk capacity are sufficient, `requestRedeem` may make the
request claimable immediately using the currently active NAV. The user must
still call `redeem` or `withdraw` separately. This provides a two-call instant
path without creating a competing share-burning system.

Requests with the same `requestId` are fungible, priced at one processing NAV,
and partially processed pro rata. Users call the standard functions on
`FundVault`; it forwards state transitions to `FundFlowManager` and remains the
contract that moves or burns shares and emits standard events.

Exact conformance includes:

- `pendingRedeemRequest` and `claimableRedeemRequest` report the two balances
  independently.
- `setOperator` and `isOperator` support controller delegation without relying
  on ERC-2612.
- `previewRedeem` and `previewWithdraw` revert for the asynchronous redemption
  path, as required by ERC-7540.
- `maxRedeem` and `maxWithdraw` expose only the caller/controller's currently
  claimable request, never pending liquidity.
- A request can transition to claimable in the `requestRedeem` transaction, but
  it never skips the claimable state and assets move only in the later
  `redeem`/`withdraw` call.
- ERC-7540, ERC-7575, ERC-4626, ERC-2612, ERC-20, and ERC-165 conformance is
  covered by interface-ID and behavior tests.

### 24.2 Cancellation

A request may be cancelled only while fully pending and before the manager has
committed an unwind for its batch. Cancellation returns escrowed shares and does
not change supply. A partially processed, claimable, or claimed request cannot
be cancelled. Emergency governance may extend claim deadlines but cannot seize
or reprice a processed claim.

### 24.3 Exit-cost allocation and swing pricing

Costs are allocated by cause:

- Market movement and ordinary strategy P&L before the processing checkpoint
  affect NAV and are shared by every outstanding share, including pending
  requests.
- Expected normal close cost already present in the accepted liability is part
  of NAV and is shared.
- Incremental spread, price impact, protocol fee, and gas reimbursement caused
  by an unwind solely to service a redemption batch are charged to that batch
  through swing pricing.
- Rebalance costs incurred for portfolio policy, risk reduction, expiry roll, or
  all-holder benefit are socialized through NAV.

```text
gross redemption value = processedShares * processingNAV / eligibleSupply
batch payout = gross value - allocated marginal exit cost - disclosed exit fee
```

The manager records reference price, actual proceeds, cost classification, and
allocation. `minAssetsOut` protects the requester. Any unspent exit fee remains
fund NAV; it is not an undisclosed transfer to the manager.

### 24.4 Liquidity buffer and unwind order

The liquidity buffer is a fund risk parameter, not a guaranteed fixed-rate
redemption promise. `StrategyManager` enforces a configured `minimumIdleBps`,
while `FundFlowManager` also enforces per-window and rolling outflow caps.
Immediate claimability uses only accounting assets remaining after processed
claims, declared distributions, fees payable in assets, minimum idle, and
strategy collateral requirements.

When the buffer is insufficient, redemption batches source liquidity in this
order:

1. Free accounting assets above required reserves.
2. Scheduled strategy maturities or ordinary deallocation.
3. A bounded early option close or LP unwind only when an independently
   verified executable quote satisfies loss, spread, and slippage limits.
4. The selected in-kind basket, when enabled for the request.
5. Emergency raw-asset in-kind recovery after the normal route is unavailable.

The allocator cannot consume the minimum idle buffer or assets already reserved
for claims. A curator can change the target only through delayed governance, and
the new target cannot reprice or change the mode of an existing request.

Transferable shares and an optional secondary market provide a separate exit:
selling shares transfers fund exposure and does not burn supply or force a
strategy unwind. The fund never guarantees secondary-market price parity; an
authorized market maker may arbitrage discounts only through the same primary
request lifecycle and risk limits as any other controller.

## 25. In-kind redemption

In-kind redemption is an extension of the same request and burn lifecycle, not
a separate supply system. It enters through
`requestRedeemInKind(shares, controller, owner, basketVersion, minAmountsOut)`;
that extension creates the same request record and request ID domain used by
ERC-7540 accounting-asset requests. The request stores an immutable mode.
Standard ERC-7540 pending/claimable views include only accounting-asset requests;
parallel extension views expose in-kind requests so an in-kind claim can never
be consumed through standard `redeem` or `withdraw`.

At request time, the user selects an immutable approved basket mode and supplies
asset-specific minimum outputs. Each fund publishes versioned basket definitions.
Examples:

- Wheel: free USDC and WETH.
- Covered call: free WETH and accrued free USDC.
- LP range: token0 and token1 after proportional liquidity removal and fee
  collection.

At processing:

1. Determine the processed share fraction at one active NAV.
2. Deallocate the proportional strategy fraction or use free assets.
3. Measure actual received token deltas; never trust adapter return values alone.
4. Apply fund-specific basket rules, marginal exit costs, and round each token
   down.
5. Verify every `minAmountOut` pro rata for the processed fraction.
6. Burn processed shares.
7. Transfer exact token amounts to a claim escrow and increase per-asset claim
   reserves.
8. Record basket version and amounts immutably.

Partial processing is pro rata across all requests in the same batch. Rounding
dust remains fund NAV until a governed dust threshold allows collection.
Processed basket claims are excluded from NAV and cannot be reallocated.

If an adapter returns an unexpected asset, processing reverts unless that asset
is included in the active basket definition. Emergency in-kind exit can create a
new disclosed raw-asset basket through guardian activation, but it cannot alter
already processed claims.

## 26. Fee and distribution accounting

### 26.1 Management fee

Management fees accrue continuously as dilution and are materialized as shares:

```text
feeAssets = preFeeNAV * annualRate * elapsed / YEAR
feeShares = feeAssets * supply / (preFeeNAV - feeAssets)
```

The implementation uses full-precision `mulDiv` with an annual rate scaled to
`1e18`; the expression above is descriptive rather than integer operation order.

Accrual is bounded by maximum elapsed time per call and a governance cap. It is
run before NAV activation, request processing, deposits, and distributions.

### 26.2 Performance fee

Performance fee is calculated from a fresh NAV before every primary-market
window that permits deposits or redemption processing. This prevents a new
subscriber from paying for pre-entry gains and prevents an exiting holder from
escaping an already earned fee. It is also crystallized on configured dates and
before a distribution, but never merely because shares transfer:

```text
gainPerShare = max(preFeePps - adjustedHighWaterMark, 0)
gainAssets = gainPerShare * eligibleSupply / shareScale
feeAssets = gainAssets * performanceFeeBps / 10_000
feeShares = feeAssets * supply / (preFeeNAV - feeAssets)
```

The high-water mark is updated after crystallization. Deposits and transfers do
not change it. Queued pending shares remain eligible until processed. Burned
claimable shares do not pay future fees.

Cash distributions reduce the high-water mark by distribution per eligible
share so returning to the pre-distribution NAV does not create a false new gain.

### 26.3 Distribution lifecycle

Realized income first increases NAV. A distribution is optional and fund-policy
specific.

1. Close the primary market and activate a fresh NAV.
2. Accrue management fee and crystallize any due performance fee.
3. Verify the amount is free accounting asset after claims, minimum idle, and
   required risk collateral.
4. Record `distributionId`, amount, record block, eligible supply, policy
   version, and expiry.
5. Transfer the full amount to a `DistributionEscrow` immediately. This reduces
   fund NAV and makes the amount unavailable to strategy or redemptions.
6. Build holder entitlements from ERC-20 transfer events and the flow manager's
   pending-request beneficial-owner ledger at the record block. Shares escrowed
   by a pending request are attributed to its controller; they are not assigned
   to the vault address or counted twice.
7. Submit a Merkle root under an independent reporter quorum and challenge
   delay.
8. Holders claim with a Merkle proof. Transfers after the record block do not
   transfer the recorded entitlement.

The root's total claimable amount cannot exceed escrowed assets. Root replacement
is allowed only during the challenge period and through delayed/cancelable
governance. Expired unclaimed assets follow a disclosed policy: roll into the
next distribution or return to the fund through a NAV-increasing transaction.

This Merkle design keeps ERC-20 transfers light. A future fund that requires
fully onchain historical entitlement can deploy a checkpoint-enabled share
implementation as a separately reviewed version.

## 27. Smart-wallet compatibility

ERC-2612 remains enabled for EOAs and standard integrations, but the product does
not depend on ECDSA-only permit.

Supported paths:

- Direct calls from smart wallets.
- Smart-wallet `executeBatch` for asset approval plus deposit, or share approval
  plus `requestRedeem`.
- A periphery `FundRouter` using OpenZeppelin `SignatureChecker` for EOA ECDSA
  and ERC-1271 contract signatures, with fund-bound nonces and deadlines.
- Permit2 or token-specific permit only in the periphery, never as a custody
  requirement in the fund core.

The router is replaceable and holds no balances after a transaction. Core
deposit and request functions remain usable without it.

## 28. Stage-specific option invariants

Global oToken supply need not equal one fund vault ledger because many writers
and holders may use the same series. Invariants are scoped by owner, protocol
vault, MM, and lifecycle stage.

| Stage | Required invariant |
| --- | --- |
| Open | Controller short amount = settler vault oToken ledger = physical-delivery reserved amount; collateral >= requirement |
| Partially closed | Initial short = remaining short + cumulatively closed; remaining Controller short = remaining settler ledger = remaining reservation |
| Settled OTM | Controller vault settled; collateral return reconciled; reserved and settler vault balances are zero after oToken redemption |
| Settled ITM, reserved | Controller vault settled; remaining oTokens are custodied and reserved; no double redemption or MM escape |
| Physical delivery complete | Reserved amount and vault oToken ledger are zero; measured delivered asset equals strategy accounting delta |
| Cash fallback complete | OToken ledger/reservation zero; fallback payout and collateral residual reconcile to settled collateral |
| Emergency | Claims and custody cannot be erased; every release has a matching burn, redemption, or explicit migrated claim |

Every transition emits position owner, protocol vault ID, option series, amount,
collateral delta, payment, and resulting lifecycle state.

## 29. Failure, governance, and migration policy

### 29.1 NAV zero or insolvency

If committed NAV is zero or liabilities exceed gross assets:

- Deposits, NAV-priced processing, fee minting, and distributions stop.
- No division assumes a positive NAV or supply.
- Pending requests remain pending or may cancel if no unwind was committed.
- Transfers remain enabled unless legally or operationally required otherwise.
- Guardian may enable emergency pro-rata in-kind recovery of realizable assets.
- Losses cannot be hidden by resetting the high-water mark or share generation.

### 29.2 Donations and unaccounted balances

Raw `balanceOf` is not automatically NAV. Unexpected token transfers enter an
unaccounted balance bucket. They become shareholder assets only through a
`syncDonation` operation covered by a new NAV report. They cannot be allocated,
distributed, or used to manipulate deposit share price before synchronization.
OpenZeppelin virtual assets/shares remain required for first-deposit protection.

### 29.3 Adapter deficit

If measured protocol state or balances are below adapter accounting:

- Close primary market and pause new allocations.
- Invalidate the component report.
- Record and report the deficit; do not silently net it against idle assets.
- Accept the loss only through a fresh, elevated-quorum NAV report.
- Enable bounded deallocation or emergency exit.

### 29.4 Governance constraints

- Every fund retains at least one viable exit mode.
- Redemption/distribution policy changes are delayed and versioned.
- Pending requests retain their original mode and policy version.
- Processed claims and declared distributions are immutable liabilities.
- Guardian can reduce risk immediately but cannot raise caps, redirect claims,
  upgrade implementations, or distribute assets.

### 29.5 Migration

Migration is a user-visible operation, not an implementation upgrade across
incompatible storage or semantics.

1. Pause new allocation and primary-market entry.
2. Settle or safely migrate every adapter position.
3. Process/cancel pending requests and fully reserve claims/distributions.
4. Commit a final NAV and positions hash.
5. Deploy the new UUPS stack and verify implementations.
6. Exchange old shares for new shares through a dedicated migration escrow at
   the final checkpoint, or let users redeem old assets and deposit manually.
7. Reconcile both supplies, assets, liabilities, and unclaimed escrows.

The existing CSP smoke deployment remains untouched. The future fresh fund
reuses the V1 implementation and settlement behavior only after the CSP adapter
receives the standard authorization specified in section 21.2.

## 30. Revised implementation phases and approval gate

### Phase 0: executable specifications

- ERC-7540 conformance tests and request state machine.
- Component NAV report schema and reporter threat model.
- Fee/high-water-mark numerical model.
- Exit-cost and in-kind basket simulations.
- Proxy storage namespaces and upgrade validation harness.

### Phase 1: lightweight core

- `FundVault`, `FundAccounting`, `FundFlowManager`, and `StrategyManager` UUPS
  proxies with a mock adapter.
- OpenZeppelin AccessManager role/delay configuration.
- Accounting-asset requests only; in-kind interfaces disabled.
- Donation, stale NAV, fee, queue, upgrade, and failure invariants.

### Phase 2: CSP adapter

- CSP adapter and independent option valuator.
- Existing expiry settlement behind the adapter.
- Owner onboarding with
  `BatchSettler.setPhysicalDeliveryVault(cspAdapter, true)`, followed by onchain
  authorization verification and deployment-manifest evidence.
- Assigned WETH retained as fund inventory.
- Queue funded by idle buffer or expiry settlement.

### Phase 3: atomic early close

- `OptionCloseSettler` buyback RFQ.
- Controller reduce-short/release-collateral primitive.
- Partial-close lifecycle invariants and swing-pricing evidence.

### Phase 4: Wheel, distributions, and secondary liquidity

- Wheel coordinator and protected-cost-basis policy.
- Merkle distribution escrow.
- Share/accounting-asset secondary market and monitoring.

### Phase 5: in-kind and LP-range strategy

- Versioned basket claims.
- Concentrated-liquidity adapter and independent valuator.
- Raw-asset emergency exit and LP-specific risk controls.

The final reviewer confirmed that sections 19-30 resolve the ten blockers in
section 18.2 after documenting the required V1 `BatchSettler` authorization
onboarding. The architecture is approved and implementation begins with B1N-349.
Each phase receives its own threat model, tests, storage-layout baseline, and
audit scope.
