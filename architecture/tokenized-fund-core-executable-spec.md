# B1N-349: Tokenized Fund Core Executable Specification

Status: Approved architecture converted to executable specification

This document is the implementation handoff from B1N-349 to B1N-350. The
normative architecture remains
`architecture/tokenized-fund-vault-architecture.md`, sections 19-30. Where an
implementation detail was still open, the decisions below close it.

## 1. Toolchain

The fresh fund stack uses one OpenZeppelin release across regular and
upgradeable contracts:

| Dependency | Pinned version |
| --- | --- |
| `@openzeppelin/contracts` | `5.5.0` |
| `@openzeppelin/contracts-upgradeable` | `5.5.0` |
| `@openzeppelin/foundry-upgrades` | `0.4.1` |
| `@openzeppelin/upgrades-core` | `1.45.0` |

`foundry.toml` enables FFI, AST, build info, and storage layout output. Upgrade
validation must use `Upgrades`, never `UnsafeUpgrades`,
`unsafeSkipStorageCheck`, or `unsafeSkipAllChecks`.

`npm audit --omit=dev` reports zero production vulnerabilities. The upgrade CLI
dependency tree currently reports six low-severity findings in the development
toolchain through `elliptic`, with no upstream fix. These packages are not
linked into deployed bytecode.

## 2. Standards Surface

`FundVault` is:

- An ERC-4626 vault with synchronous `deposit` and `mint`.
- An ERC-7540 asynchronous redemption vault.
- An ERC-7575 vault whose `share()` returns the external `FundShare` token.
- An ERC-165 responder for the required async interfaces.

`FundShare` is the transferable ERC-20/ERC-2612 share token. Only its configured
vault may mint, burn, escrow, or return escrowed shares.

Required interface IDs:

| Interface | ID |
| --- | --- |
| ERC-165 | `0x01ffc9a7` |
| ERC-7540 operators | `0xe3bc4e65` |
| ERC-7540 async redeem | `0x620ee8e4` |
| ERC-7575 vault | `0x2f0a18c5` |
| ERC-7575 share | `0xf815c03d` |

`previewRedeem` and `previewWithdraw` always revert. `maxRedeem` and
`maxWithdraw` expose only claimable shares/assets. ERC-4626 entry previews
remain synchronous.

Fund shares always use 18 decimals. Accounting assets with more than 18
decimals are rejected at initialization. For an accounting asset with `d`
decimals:

```text
decimalsOffset = 18 - d
shareScale = 1e18
virtualAssets = 1
virtualShares = 10 ** decimalsOffset
```

These values match OpenZeppelin ERC-4626 conversion math. The vault exposes
`depositWithMinShares(assets, receiver, minSharesOut)` as the protected entry
used by the product. The standard two-argument `deposit` remains available for
ERC-4626 compatibility.

Canonical interfaces are under `src/fund/interfaces/`. B1N-350 implements these
interfaces without changing selectors.

## 3. Redemption State Machine

The standard request ID is always zero. ERC-7540 state is aggregated by
controller. Operational unwind groups use an internal `uint64 batchId`; they are
not exposed as ERC-7540 request IDs.

For exact ERC-7540 conformance, `pendingRedeemRequest` and
`claimableRedeemRequest` return zero for every nonzero request ID. They never
revert because an ID is unsupported.

```text
Pending
  requestRedeem(shares, controller, owner)
  shares move from owner to FundVault escrow in FundShare
  shares remain in totalSupply and participate in NAV

Claimable
  processor applies one processing NAV pro rata to the batch
  processed shares burn from escrow
  exact accounting assets move into the claim reserve/escrow
  reserved assets leave shareholder NAV

Claimed
  controller or approved operator calls redeem/withdraw
  claimable state decreases
  reserved assets transfer to receiver
```

An immediately liquid request may transition to Claimable during
`requestRedeem`, but assets are never pushed. A separate `redeem` or `withdraw`
call is mandatory.

Authorization is exact ERC-7540 behavior:

- The owner may request directly.
- When the controller is also the owner, an approved controller operator may
  request without consuming ERC-20 allowance.
- Otherwise, a delegated requester must consume the owner's share allowance.
- A controller operator may claim on the controller's behalf.

Cancellation is an extension, not part of ERC-7540. It is allowed only while
the controller has no claimable portion and no unwind is committed, including
after sealing but before a successful processing preflight. It returns escrowed
shares to the original owner without changing supply. A controller's aggregated
request cannot mix shares from different owners, so an operator can never make
itself the cancellation recipient.

`requestRedeemWithMinAssets` is the slippage-protected extension used by the
product. Its `minAssetsOut` is stored with the controller's pending shares. On
partial processing the minimum is allocated pro rata with ceiling rounding;
processing starts only after every member's allocated output satisfies its
persisted minimum. The standard `requestRedeem` records a minimum of zero.

### Bounded operational batches

There is no global or historical controller scan. An open batch accepts at most
64 unique controllers. A complete cancellation removes its member slot with a
bounded swap-and-pop, so request/cancel recycling cannot consume capacity.

Processing has three explicit phases and one recovery transition:

1. `sealRedeemBatch` closes additions to the candidate set and opens the next
   batch. Existing members may still cancel; sealing does not commit an unwind.
2. `startRedeemBatch` computes one processing NAV, eligible supply, target
   shares, marginal exit cost, net asset budget, and every persisted minimum
   without changing state. Only after that preflight succeeds does it commit the
   unwind, close primary entry, and reserve the complete net asset budget.
3. `processRedeemBatch` advances a persistent cursor over at most 16 controllers
   per transaction.

`releaseRedeemBatch` is an O(1) recovery for a sealed batch with no active round
and no committed unwind, including a remainder left by partial processing. It
advances `nextProcessBatchId` without burning, repricing, or moving the remaining
shares. The released requests remain pending and cancelable, so an impossible
minimum cannot block later batches even if its controller never cancels.

Allocation uses cumulative pro-rata differences:

```text
allocatedThroughI = floor(cumulativePendingThroughI * target / roundPending)
controllerShares = allocatedThroughI - allocatedThroughPrevious
roundNetBudget = floor(target * processingNAV / eligibleSupply) - marginalExitCost
netAssetsThroughI = floor(allocatedThroughI * roundNetBudget / target)
controllerAssets = netAssetsThroughI - netAssetsThroughPrevious
```

This assigns exactly the target shares and exactly the net asset budget across
all pages. Gross value and marginal cost are never rounded independently per
controller, so an aggregate-valid round cannot fail on a local subtraction. A
partially processed batch may start another round only with a fresh NAV
checkpoint. New requests cannot join a sealed batch, and one controller cannot
hold pending shares in multiple operational batches. Sealed batches start only
in monotonic `nextProcessBatchId` order. The primary market reopens after the
final page proves that cumulative claims equal the reserved net budget. When no
pending shares remain, that final page also advances `nextProcessBatchId`.

## 4. NAV Reports

NAV is never accepted as one opaque signed integer. Every active component
provides a `FundTypes.ComponentReport` containing:

- Fund and chain.
- Component ID.
- Snapshot block and block hash.
- Activation and expiry blocks.
- Reporter-set version.
- Component nonce and `positionStateHash`.
- Gross assets, liabilities, liquid assets, and base exit cost.
- Hash of valuation evidence.

The idle accounting-asset component is also a custody checkpoint. Its
`componentNonce` must equal the vault's `fundFlowNonce`, and its
`positionStateHash` commits to the fund, chain, nonce, accounted idle assets,
and raw token balance. Deposits, claims, fee minting, and strategy cash flows
advance that nonce. A deposit or direct transfer after the reporter snapshot
therefore makes the report fail at submission instead of combining new custody
state with old NAV.

The accounting implementation must reject:

- Missing, duplicate, or inactive components.
- Future, unknown, or stale snapshot blocks.
- Same-block activation.
- Mixed snapshot/window values in one aggregate.
- Reporter-set version mismatch.
- Invalid or duplicate reporters.
- Invalid thresholds, zero/duplicate reporters, or non-monotonic reporter-set
  versions.
- Component nonce or position hash mismatch.
- Component liabilities greater than component gross assets.
- A report nonce other than `lastReportNonce + 1`.

Reporter signatures use EIP-712. The domain name is `b1nary Fund NAV`, version
`1`, current chain ID, and the `FundAccounting` proxy as verifying contract. The
signed struct commits to the fund, reporter-set version, monotonic
`reportNonce`, and hash of every component report. `submitNav` consumes the
nonce in state and requires exactly `lastReportNonce + 1`. Two funds, two
accounting proxies, or two report nonces cannot replay reports, and reports
cannot be accepted out of order. Reporter quorum, component consistency, and
block-window validation are delegated to the stateless, versioned
`NavReportVerifier` using a normal external `view` call.
The accepted commit also stores a hash of the quorum addresses and signatures
for onchain auditability without duplicating variable-length signature data.

An accepted `NavCommit` is executable only from `validAfterBlock` through
`validUntilBlock`. Informational NAV may remain readable after expiry, but
deposits and redemption processing stop.

## 5. Accounting Math

All arithmetic uses OpenZeppelin `Math.mulDiv`.

### Management fee

```text
elapsedRate = annualRateWad * elapsed / YEAR
feeAssets = preFeeNav * elapsedRate / 1e18
feeShares = ceil(feeAssets * supply / (preFeeNav - feeAssets))
```

Accrual runs before deposit/mint and before redemption-batch pricing. A fee
configuration change first checkpoints elapsed time under the old rate and old
recipient, then starts the new period. Performance-fee crystallization writes
the high-water mark from post-fee NAV and post-fee supply.

### Performance fee

```text
preFeePps = preFeeNav * shareScale / eligibleSupply
gainAssets = max(preFeePps - adjustedHwm, 0) * eligibleSupply / shareScale
feeAssets = gainAssets * performanceFeeBps / 10_000
feeShares = ceil(feeAssets * supply / (preFeeNav - feeAssets))
```

Performance fees crystallize before every executable primary-market window,
configured crystallization date, and distribution. Pending shares remain
eligible. Burned claimable shares do not.

### Distribution adjustment

```text
numerator = distributionAssets * shareScale + priorRemainder
distributionPerShare = floor(numerator / eligibleSupply)
newRemainder = numerator % eligibleSupply
adjustedHwm = max(hwm - distributionPerShare, 0)
```

The remainder persists in fee state so repeated sub-unit distributions do not
create permanent HWM drift. It is tagged with the eligible supply that defines
its denominator. If supply changes before the next distribution, the old
remainder is discarded rather than mixed across denominators; this can only
undercharge the protocol by less than one accounting-asset base unit per share.
Performance gain and fee assets round down; minted fee shares round up.
Therefore fee rounding never overcharges shareholders and sub-unit fee dust
remains fund NAV.

### Redemption and swing pricing

```text
roundGrossAssets = floor(processedShares * (processingNav + virtualAssets)
                         / (eligibleSupply + virtualShares))
authorizedExitCost = ceil(signedBaseExitCost * processedShares / eligibleSupply)
roundAfterCost = roundGrossAssets - marginalExitCost
roundExitFee = ceil(roundAfterCost * exitFeeBps / 10_000)
roundPayout = roundAfterCost - roundExitFee
payoutThroughI = floor(allocatedSharesThroughI * roundPayout / processedShares)
controllerPayout = payoutThroughI - payoutThroughPrevious
```

Market P&L and expected close cost already represented in NAV are socialized.
Only the signed base exit cost committed with NAV may be charged, pro rata, to
an exiting round; the processor cannot choose a different amount. Gross assets,
marginal cost, and exit fee are calculated once per round; they are never
independently rounded or subtracted at controller level.

If supply is nonzero and NAV is zero, deposits, fee minting, and NAV-priced
processing stop. Virtual assets/shares protect initial deposits. Raw token
donations enter `unaccountedBalances` and do not affect NAV until a fresh report
authorizes synchronization. A raw surplus is quarantined from accounted NAV,
claims, distributions, and allocation capacity, but it does not block operations
that spend only accounted assets. A raw deficit still closes those operations.
Only `FundAccounting.commitNav` may recognize a surplus atomically with a fresh
flow-nonce and idle-state checkpoint.

## 6. Strategy Boundary

`IFundStrategyAdapter` deliberately has no `totalValue()` or equivalent NAV
function. It exposes typed allocation/deallocation operations, free balances,
version, and `positionStateHash`.

`IPositionValuator` is separate and returns gross assets, liabilities, liquid
assets, base exit cost, and an evidence hash from protocol state. The mock tests
prove that an adapter's claimed value cannot set authoritative NAV.

No adapter can mint/burn shares, commit NAV, modify fee state, or receive an
arbitrary target plus arbitrary calldata from an allocator.

## 7. AccessManager Policy

Roles are `uint64` values:

| Role | ID | Execution delay |
| --- | ---: | ---: |
| Upgrader | 1 | 72 hours |
| Accounting | 2 | Immediate after report validation |
| Allocator | 3 | Immediate inside caps |
| Processor | 4 | Immediate inside accepted NAV window |
| Curator | 5 | 24 hours |
| Guardian | 6 | Immediate risk reduction only |
| Reporter | 7 | Signature quorum, no direct asset authority |

Risk-reducing and risk-increasing methods use different selectors. Examples:

- `pauseDeposits()` is guardian/immediate; `resumeDeposits()` is
  curator/delayed.
- `pauseAllocation(adapter)` and `reduceStrategyCap(...)` are
  guardian/immediate.
- `resumeAllocation(adapter)`, `setStrategyConfig(...)`, fee policy, reporter
  sets, and exit policy are curator/delayed.

The guardian is configured as guardian of the curator role so it can cancel a
scheduled risk increase. It cannot schedule or execute that increase itself.

Admin and upgrader grants have a 72-hour grant delay, and both roles have a
72-hour execution delay. Every core proxy also has a 72-hour target-admin delay,
so changing selector policy cannot bypass the upgrade delay. OpenZeppelin's
setback applies to later attempts to reduce these configured delays.

## 8. ERC-7201 Storage

Each proxy owns one namespaced struct:

| Component | Namespace | Slot |
| --- | --- | --- |
| FundVault | `b1nary.storage.FundVault` | `0x06d529727cf5bc6dc96f9652d8da22d6b7df4e899f31f34198b231dafc3c1900` |
| FundShare | `b1nary.storage.FundShare` | `0xe2a81ba6c0d9ac928aa029ae20ba46e88a57a7f1559bca1aece691f6075ce400` |
| FundAccounting | `b1nary.storage.FundAccounting` | `0x6474ad405c872fad56414fb52b104b146a40ea9bc4a4a24e367ebf792f16e500` |
| FundFlowManager | `b1nary.storage.FundFlowManager` | `0xa2150758e26bb44e0a441458c3c47420e0cafabeb20258a8fa06803a087dec00` |
| StrategyManager | `b1nary.storage.StrategyManager` | `0x25887ea3e5e75cc13395c4a56dac59490fcb6528f03e6c5e7b324f5c7afd6b00` |

The executable checks prove:

- All four V1 harness implementations pass OpenZeppelin upgrade validation.
- Appending a field to the FundVault namespace is compatible.
- A UUPS upgrade preserves existing namespaced state.
- Changing a field type is rejected.
- Removing a namespace is rejected.

Every concrete implementation declares its own initializer, calls every parent
initializer, and disables initialization in its constructor.

## 9. Cross-Proxy Lock

`FundVault` is the lock authority. A registered module acquires a monotonically
increasing lock ID using its configured compatibility version. During the lock:

- Only the lock-owning module can use its typed FundVault callbacks.
- Deposits, redemptions, NAV activation, fee crystallization, and a second
  module entry revert.
- An incompatible module version fails before lock acquisition.
- An external callback cannot reenter a user or module path.
- If an external call bubbles a revert, the transaction rollback clears lock
  acquisition automatically.

Implementations must not expose a generic `execute(target, calldata)` path.

## 10. B1N-350 Implementation Contract

B1N-350 can implement the production fund stack without changing these
decisions:

1. Use the interfaces, types, roles, math, and storage definitions in
   `src/fund/`.
2. Use OpenZeppelin upgradeable ERC-20 and ERC-20 Permit on `FundShare`; keep
   the ERC-4626/7540/7575 entrypoints, custody, and module callbacks on
   `FundVault`.
3. Keep ERC-7540 redemption state in `FundFlowManager`, while standard calls and
   events remain on `FundVault`.
   Implement the bounded 64-controller batches and 16-controller processing
   pages; do not add a global controller array.
4. Keep NAV/report/fee state in `FundAccounting`; keep reporter quorum and
   component report verification in stateless `NavReportVerifier`.
5. Keep adapter caps and position nonces in `StrategyManager`.
6. Keep module proxy addresses fixed after initialization; topology changes use
   migration, not setters.
7. Reuse the tests in `test/fund/` as the baseline conformance suite.
8. Keep shares at 18 decimals and implement the exact offset/virtual values and
   protected entry/redemption extensions specified above.

B1N-350 does not integrate CSP. B1N-351 supplies the CSP adapter and valuator.
The later deploy must authorize that adapter through the existing
`BatchSettler.setPhysicalDeliveryVault(cspAdapter, true)` interface without
upgrading or changing V1 settlement behavior.

## 11. Verification

From a clean checkout:

```shell
npm ci --ignore-scripts
npm run deps:check
forge fmt --check
forge build --offline
npm_config_offline=true forge test --offline --match-path 'test/fund/*' --force
npm run storage:check
```

The stateful invariant suite checks supply, pending escrow, claims, reserves,
accounted NAV, and unsynchronized donations across randomized operation
sequences. `--force` is mandatory for any test run containing
`StorageLayoutSpec`: OpenZeppelin intentionally rejects partial/incremental
Foundry build-info.
