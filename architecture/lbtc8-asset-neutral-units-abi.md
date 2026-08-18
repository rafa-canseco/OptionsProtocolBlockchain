# B1N-441 — LBTC8 test-asset units, generic ABI, and manifest contract

Status: implementation-ready specification; no deployment or activation is authorized.

The approved Base Sepolia underlying candidate is Binary's existing Loot BTC
(`LBTC`) test token at `0x39fA11EbBE82699Fd9F79C566D7384064571d2b4`.
It is a verified `MockERC20` with 8 decimals and unrestricted
`mint(address,uint256)`. It has no production-backing claim and must never be
presented to consumers as cbBTC, canonical BTC collateral, or a production asset.
Its pinned runtime codehash is
`0x599a6b80cccf2c7082103129c3725529a49d37b569dc0ecc031f0444b0ce0fff`.

This document freezes the contract consumed by B1N-442 and by allocator, backend,
and frontend integrations. It does not change an adapter, proxy, Wheel, deployment,
or existing ETH artifact. Normative machine-readable files live in
`deployments/specifications/b1n-441/`.

## 1. Authority and prerequisite snapshot

The only repository authority used for this slice is `origin/staging` at
`6cbd32512b8b85c60c23443f3e3f91d7da18cc5f`.

Available prerequisites at that snapshot are:

- Meta Wheel contract merge: `7e7fac6c45a0f6a468da86282e19db5a4d20878b`.
- B1N-419 deployment merge: `8e82fdd3c09ae41c5f75ae21d9a9dceb94e4cbd4`.
- B1N-419 branch tip included by that merge:
  `f58739fd62cf981e96f9020fa8654dc071e10908`.
- B1N-419 exact local-bytecode handoff fix:
  `70720568b470a433ec1be1c85b9c8e28c4e2a4f8`, merged by the snapshot commit
  `6cbd32512b8b85c60c23443f3e3f91d7da18cc5f`.

No B1N-411 commit or merge is present in `origin/staging` or the fetched refs at
this snapshot. B1N-411 is therefore a merge gap, not an authority. If it later
lands, this specification must be reconciled by an explicit reviewed change;
no legacy branch may be used to infer its contents. B1N-419 is no longer a merge
gap at this snapshot, but downstream consumers must pin the exact commits above
rather than infer it from an older task packet.

## 2. Canonical units

Every integer is unsigned and every conversion is overflow-checked. `floor(x/y)`
and `ceil(x/y)` mean full-precision `mulDiv` behavior; an implementation must not
multiply first if that can overflow.

| Domain | Symbol | Decimals | Meaning and trust rule |
| --- | --- | ---: | --- |
| oToken amount | `Q8` | 8 | `OToken.decimals()` must equal 8. |
| LBTC test underlying | `U8` | 8 | LBTC native units; exact supported underlying scale. Test-only and unrestricted-mint. |
| WETH underlying | `U18` | 18 | Existing ETH scale; supported only by a version-matched manifest. |
| USD price/strike | `P8` | 8 | Oracle and oToken strike scale, not a transferable token amount. |
| USDC settlement | `S6` | 6 | USDC native units; `decimals()` must equal 6. |

For this version the supported tuples are exactly `(oToken=8, underlying=8,
price=8, settlement=6)` for the approved LBTC test asset and `(8,18,8,6)` for WETH. A different value,
a reverting `decimals()` call, an unknown token, or a mismatch with the manifest
fails closed. General `8..18` protocol support does not authorize an adapter to
accept every value in that interval.

### 2.1 Conversion table and dust ownership

| Operation | Exact v2 formula | Rounding | Dust owner / accounting treatment |
| --- | --- | --- | --- |
| oToken8 to underlying `d` | `Q8 * 10^(d-8)` | Exact for supported `d` | No conversion dust. For LBTC8 this is identity; for WETH18 multiply by `1e10`. |
| underlying `d` to oToken8 | `floor(Ud / 10^(d-8))`; remainder `Ud % 10^(d-8)` | Down | Remainder remains with the underlying custodian. It is idle accounted underlying only if the ledger already owns it; otherwise it is isolated as unaccounted dust. It cannot mint exposure. LBTC8 has zero scale dust. |
| CSP USDC collateral | `ceil(Q8 * P8 / 1e10)` in `S6` | Up | The position/lane owns the posted integer collateral. Any amount above the minimum remains position collateral and returns to the same position/lane on settlement. The ceiling quantum is not premium. |
| Covered-call collateral | `Q8 * 10^(d-8)` in underlying | Exact | The position/lane owns collateral. Extra caller-supplied collateral is forbidden by the v2 open DTO policy rather than silently pooled. |
| Gross premium | `floor(Q8 * premiumPerOptionS6 / 1e8)` | Down | Fractional USDC below one native unit remains with the market maker. Protocol fee is `floor(grossPremiumS6 * feeBps / 10_000)`; fee division dust benefits the option writer through net premium. `bidPrice` is not USD8. |
| CSP physical assignment | `Q8 * 10^(d-8)` underlying received | Exact | Exact expected underlying belongs to the originating position/assignment lot. Excess observed balance delta is unaccounted and isolated; a short delta reverts. |
| Covered-call call-away | `floor(Q8 * P8 / 1e10)` in `S6` | Down | Exact integer USDC belongs to the originating position/assignment lot. The sub-USDC fraction is not representable and remains with the paying counterparty. Excess observed delivery is isolated; a short delta reverts. |
| Put cash fallback, gross strike leg | `floor(Q8 * P8 / 1e10)` in `S6` | Down for receivable | Integer proceeds belong to the originating position. Liabilities paid from that leg use the conservative rules below and may not exceed observed proceeds. |
| Underlying asset value for USDC NAV | `floor(Ud * spotP8 / 10^(d+2))` in `S6` | Down | Asset-value dust is excluded from NAV and remains owned by the underlying ledger. For LBTC8 denominator is `1e10`; for WETH18 it is `1e20`. |
| USDC asset value in underlying NAV | `floor(S6 * 10^(d+2) / spotP8)` | Down | Settlement dust is excluded from underlying-denominated NAV and remains in the settlement ledger pending normalization. |
| Underlying-denominated liability to USDC NAV | `ceil(liabilityUd * spotP8 / 10^(d+2))` | Up | The extra conservative unit is borne by shareholder NAV, never credited as an asset. |
| USDC-denominated liability/cost to underlying NAV | `ceil(liabilityS6 * 10^(d+2) / spotP8)` | Up | Same conservative treatment. |
| Normalization exact-input minimum output | `floor(fairOutput * (10_000-slippageBps) / 10_000)` | Down | Actual balance deltas are authoritative. Unspent input remains accounted to the originating lane; unexpected excess output is isolated until reconciled. |
| Normalization exact-output maximum input | `ceil(fairInput * (10_000+slippageBps) / 10_000)` | Up | Unspent maximum remains with the originating ledger. The adapter never books quoted output before observing it. |
| Fund NAV | `netAssets = grossAssets - liabilities` under the canonical `NavReportVerifier` invariant | Assets down; liabilities up | `baseExitCost` remains a separate redemption-time charge in `FundFlowManager`; it is reported but is never subtracted from NAV a second time. If liabilities exceed gross assets, canonical verification fails closed. |

A quote DTO retains `BatchSettler.Quote.bidPrice` for protocol compatibility,
but v2 defines it as **settlement-asset native units per whole oToken**. It is
multiplied by `Q8` and divided by `1e8`. Consumers must not label or decode that
field as USD8.

## 3. Versioned ABI, events, and DTOs

The canonical Solidity sources are
`src/fund/interfaces/IAssetNeutralOptionsAdapterV2.sol` for standalone/child
adapters and `src/fund/interfaces/IAssetNeutralWheelV2.sol` for the Meta Wheel
coordinator. Their exported ABIs and SHA-256 pins are in the B1N-441
specification directory.

Required rules:

1. A conforming implementation returns exactly `2` from `interfaceVersion()`.
   Zero, one, values above two, a revert, malformed return data, or multiple
   manifest ABI candidates are unsupported and fail closed.
2. `assetConfigV2()` is immutable deployment identity. `underlyingAsset`,
   `settlementAsset`, and every decimal must equal the hash-pinned manifest and
   live token reads.
3. Fields ending in `8` are fixed eight-decimal domains. Every other amount is
   in native decimals of the explicitly named asset. Generic events include the
   asset identities needed to avoid symbol inference.
4. `OpenPositionDataV2` is encoded as the `allocate` data payload.
   `optionAmount8` is oToken8 and `collateralAmount` is native collateral units.
   `DeallocateDataV2.amount` and `minAmountOut` are native input/output units.
5. `AdapterStateV2.activeCollateralAmount` is denominated by the strategy's
   immutable collateral asset: settlement for CSP, underlying for Covered Call.
   Position DTOs also return `collateralAsset` explicitly.
6. `policyHash()` equals the manifest policy hash. The B1N-441 predeployment
   fixture uses SHA-256 of this exact specification file as its policy artifact
   hash; a deployed manifest may supersede it only through a versioned reviewed
   policy artifact.
7. Wheel v2 DTOs use `transitionUnderlyingAmount`,
   `accountedUnderlyingAmount`, `underlyingReceivedAmount`,
   `remainingUnderlyingAmount`, and `underlyingAmount`. The matching settlement
   fields are explicitly named and native-decimal. `UnderlyingTransition` and
   `UnderlyingFallback` replace the WETH-specific v1 enum labels without
   changing v1 enum ordinals or decoders.
8. Each deployed contract identity binds exactly one `interfaceRole`, matching
   interface contract name, and hash-pinned ABI artifact. `OPTIONS_ADAPTER`
   binds only `IAssetNeutralOptionsAdapterV2`; `WHEEL_COORDINATOR` binds only
   `IAssetNeutralWheelV2`. Mandatory semantic validation rejects duplicate
   addresses even when the duplicates claim different roles. The ABI selection
   key includes `kind`, role, ABI SHA-256, and a constructible `codeIdentity`:
   implementation runtime codehash for a proxy, runtime codehash for an
   immutable contract. One address can therefore never be decoded by both ABIs.

### 3.1 WETH-named v1 compatibility boundary

`ICspFundAdapter`, `ICoveredCallFundAdapter`, `IWheelCoordinatorAdapter`, and
`WheelTypes` remain version 1 and retain their existing WETH-named selectors,
fields, DTO layouts, event signatures, and meanings. This ticket does not edit
them.

An LBTC implementation must not return LBTC from `weth()`, populate
`accountedWeth` with LBTC, emit a `wethDelta` for LBTC, or decode v1 Wheel
`wethAmount`/`wethReceived` as generic underlying. That would be a silent ABI
reinterpretation. Version 2 uses only `underlyingAsset`,
`accountedUnderlyingAmount`, `underlyingDelta`, and
`assignedUnderlyingAmount`. An integration may support v1 and v2 side by side,
but it must select one exact ABI from `(chainId, deploymentId,
interfaceFamily, interfaceVersion, address, kind, interfaceRole,
abiArtifact.sha256, codeIdentity)` before any read or event decode. There is no heuristic fallback by field name, symbol, or
successful `eth_call`.

## 4. Manifest identity and trust

The JSON schema is
`deployments/specifications/b1n-441/asset-neutral-manifest.schema.json`.
The LBTC8 Base Sepolia fixture is intentionally `PREDEPLOYMENT`. It binds only
the already-deployed test underlying candidate by exact address, decimals,
runtime codehash, and mandatory `LBTC_TEST_ONLY` disclosure. Settlement identity,
all adapter/coordinator proxy and implementation identities, receipts, blocks,
and `deploymentId` remain explicitly `null` or empty. `consumerReady` is false
and `activationAuthorized` is false. Null is not a zero-address placeholder and
must never be treated as deployed. A canonical cbBTC or USDC address from Base
mainnet is not a Base Sepolia identity and cannot replace the LBTC test binding.

A deployed successor must bind all of the following before a consumer enables
writes or indexes events:

- a verified `manifestContentIdentity`, monotonic revision, exact predecessor
  link, and equality of `identity.deploymentId` and `deployment.deploymentId`;
- Base Sepolia `chainId` 84532 and the exact deployment ID;
- interface family `b1nary.asset-neutral-options-v2` and version 2;
- one exact interface role, interface contract name, and ABI artifact/hash for
  every deployed contract identity;
- policy hash and its declared hash algorithm;
- proxy address, ERC-1967 implementation address, proxy runtime codehash, and
  implementation runtime codehash for every proxy;
- address and runtime codehash for every immutable contract;
- valid-from block and canonical receipt/block hash;
- exact nonzero underlying/settlement addresses, live codehashes, and manifest
  decimals matching one supported tuple;
- SHA-256 pins for schema, ABI, Solidity interface source, and policy artifact.

Activation is a separate reviewed manifest state, not an implication of
`DEPLOYED`. A deployed manifest may remain `activationAuthorized=false`. Setting
it true requires a non-null, hash-pinned `activationAuthorizationArtifact` in
`source`, a new `manifestId`, the next integer `manifestRevision`, and a
`supersedes` link to the exact predecessor `manifestContentIdentity`. The
content identity is SHA-256 of canonical key-sorted JSON with only the
`manifestContentIdentity` field omitted. Consumers must run both JSON Schema
validation and the mandatory semantic/transition validator in
`scripts/validate-b1n-441-manifest.mjs`; schema validation alone is insufficient
for cross-field equality and uniqueness. Activation also requires the separately
approved Base Sepolia release gate and consumer revalidation of every trust
binding. The predeployment fixture is revision 1, supersedes nothing, and
requires the authorization artifact to be null.

Runtime codehash means `EXTCODEHASH` of deployed runtime bytecode, not creation
bytecode or an artifact bytecode hash. For a proxy, both proxy codehash and the
implementation codehash are mandatory and the ERC-1967 slot must equal the
manifest implementation. A zero codehash, empty code, chain mismatch, stale
implementation, missing receipt, hash mismatch, token-decimal mismatch, or
ambiguous ABI version fails closed. Token symbol/name are display-only and are
never identity evidence. Decimals are trusted only when the manifest pin, the
live `decimals()` return, and the supported tuple all agree.

## 5. Standalone and Meta Wheel invariants

### 5.1 Asset and custody isolation

- One standalone fund or Meta Wheel coordinator is bound to exactly one
  `(underlyingAsset, settlementAsset, decimal tuple, policyHash)` for life.
- An LBTC test coordinator cannot register WETH lanes; a WETH coordinator cannot
  register LBTC lanes. Every lane, adapter, oToken, oracle feed, swap route,
  and assignment lot must match the coordinator pair.
- Existing ETH standalone funds, Meta Wheel contracts, proxies, deployment
  manifests, roles, positions, and balances are never registered, upgraded,
  edited, or reused by LBTC.
- Dedicated Meta Wheel lanes cannot be a standalone fund adapter and cannot be
  shared by coordinators. A lane has one coordinator, one adapter, one strategy
  kind, and at most one active option/assignment lot in this version.
- Only exact balance deltas of manifest assets enter accounting. Donations,
  unsupported tokens, excess assignment/call-away delivery, and scale dust not
  already owned by a ledger are quarantined and emitted as isolated dust.
  Recovery cannot credit NAV or another asset lane implicitly.
- Handoffs preserve the originating tranche and assignment-lot identity.
  Settlement and underlying amounts may not be pooled across asset pairs or
  used to satisfy another pair's redemption.

### 5.2 Roles and lanes

- `ALLOCATOR_ROLE` may open only within active caps and the immutable asset pair.
- `PROCESSOR_ROLE` may settle and hand off but cannot open, change policy,
  normalize through an unapproved route, or alter asset identity.
- `CURATOR_ROLE`, behind the existing delay, may reduce/raise approved risk
  configuration, register/remove matching idle lanes, and schedule a policy
  hash change. It cannot bypass decimal/codehash/interface checks.
- `GUARDIAN_ROLE` may pause allocations and reduce exposure; it cannot resume,
  open, change assets, move quarantined dust into NAV, or weaken assignment/call
  floors.
- `UPGRADER_ROLE` and `ADAPTER_UPGRADER_ROLE` remain separate delayed roles.
  An upgrade must preserve storage and re-prove manifest ABI, codehash, policy,
  decimals, and asset identity before activation.
- Standalone and Meta Wheel role grants are deployment-local. Possessing a role
  in an ETH deployment confers no LBTC authority.

All managed operations continue through the role-classed StrategyManager path
and fund-wide lock. Unknown operations, wrong lane kind, cross-asset payloads,
unknown interface versions, and incomplete valuation lane sets revert.

## 6. Handoff and change policy

B1N-442 may implement this ABI but must not modify v1 field semantics. Any
selector, tuple order, event signature, unit, rounding direction, dust owner,
supported decimal tuple, or manifest identity rule change requires a new
interface/schema version and new hash pins. Additive JSON fields require a
schema version because this schema is closed with `additionalProperties: false`.

No fixture in this ticket authorizes deployment, proxy upgrade, activation,
mainnet writes, allocator operation, or consumer writes. This specification is
Base Sepolia-only; chain ID 8453 is invalid for every manifest under this schema.
