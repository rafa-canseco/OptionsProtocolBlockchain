# Threat Model — b1nary Options Protocol

## Trust Assumptions

### Trusted

| Actor | Trust Level | Justification |
|-------|-------------|---------------|
| AddressBook owner | Full | Controls all protocol address pointers. Compromise = protocol takeover. Pre-mainnet: deployer EOA. Mainnet: multisig. |
| Contract owners | Full | Each contract owner can upgrade (UUPS), change settings, transfer ownership. Same key as AddressBook owner pre-mainnet. |
| Oracle owner | Full | Sets expiry prices used for settlement. Incorrect price = incorrect payouts. Must be automated bot with manual override. |
| BatchSettler operator | Elevated | Executes orders and settlements. Cannot steal funds (premiums go to users, collateral to pool). Can grief by not executing. |

### Partially Trusted

| Actor | Trust Level | Justification |
|-------|-------------|---------------|
| Whitelisted MMs | Partial | Sign quotes. Cannot drain protocol (quotes are fill-capped). Can grief by signing then not honoring. Quote cancellation via makerNonce. |

### Untrusted

| Actor | Trust Level | Justification |
|-------|-------------|---------------|
| Option buyers (users) | None | Interact via executeOrder. All inputs validated on-chain. |
| External contracts | None | Aave pool and Uniswap router are external. Validated via address registry. Flash loan callback checks initiator == address(this). |

## Attack Surfaces

### 1. EIP-712 Signature Replay

**Vector:** Replay a valid MM signature on a different chain or after
contract upgrade.

**Mitigations:**
- Domain separator includes `chainId` and `verifyingContract`
- Domain separator is re-computed on chain ID change
- `makerNonce` in quote struct — MM can invalidate all prior quotes
- `quoteId` tracks fill state per quote — prevents double-fill
- `deadline` — quotes expire

**Residual risk:** None identified.

### 2. Oracle Price Manipulation

**Vector:** Set incorrect expiry price to manipulate settlement.

**Mitigations:**
- `setExpiryPrice` is owner-only
- Once set, price cannot be overwritten (`PriceAlreadySet` error)
- `resetExpiryPrice` only works in betaMode (testnet)
- Invariant #9 (`oracleImmutability`) validates this

**Residual risk:** Owner compromise allows one-time incorrect price
setting. Mitigation: multisig for mainnet.

### 3. Flash Loan Callback Hijacking

**Vector:** Attacker calls `executeOperation` directly to steal
tokens during physical redemption.

**Mitigations:**
- `msg.sender` must be `aavePool` address (set by owner)
- `initiator` must be `address(this)` (only self-initiated loans)
- `nonReentrant` modifier on `physicalRedeem`

**Residual risk:** None identified.

### 4. Reentrancy

**Vector:** External calls (token transfers, flash loans, swaps)
re-enter protocol functions.

**Mitigations:**
- `physicalRedeem` has `nonReentrant` (first modifier position)
- Controller functions follow checks-effects-interactions
- OToken `mintOtoken`/`burnOtoken` are controller-only
- MarginPool `transferToPool`/`transferToUser` are controller-only

**Residual risk:** Low. Slither's reentrancy detector found no
actionable paths. Flash loan flow is fully guarded.

### 5. Collateral Accounting Discrepancy

**Vector:** Token amounts differ between vault storage and actual
pool balance, allowing over-withdrawal.

**Mitigations:**
- All collateral goes through MarginPool (single source of truth)
- Vault `collateralAmount` is incremented on deposit, never
  decremented until settlement
- Settlement payout is calculated from oracle price, not vault state
- Invariants #7 (`collateralConservation`) and #12
  (`itmSettleReturnsZero`) validate correctness

**Residual risk:** Fee-on-transfer tokens would break accounting.
Mitigation: whitelist only standard ERC20s (USDC, WETH).

### 6. Expired Option Minting

**Vector:** Mint oTokens for an already-expired option series to
create unbacked obligations.

**Mitigations:**
- `Controller.mintOtoken` checks
  `block.timestamp >= oToken.expiry()` (added during this audit)
- `OTokenFactory.createOToken` prevents creating tokens with past
  expiry
- Invariant #6 (`noExpiredMint`) validates this

**Bug found during audit:** Controller was missing the expiry check.
Fixed.

### 7. Upgrade Hijacking

**Vector:** Attacker upgrades contract implementation to malicious
code.

**Mitigations:**
- `_authorizeUpgrade` is `onlyOwner` on all UUPS contracts
- Implementation contracts call `_disableInitializers()` in
  constructor
- 50 upgrade-specific tests verify access control and state
  preservation

**Residual risk:** Owner key compromise. Mitigation: multisig.

### 8. Quote Over-Fill

**Vector:** Execute same quote multiple times to mint more oTokens
than the MM intended.

**Mitigations:**
- `quoteState` tracks filled amount per (MM, quoteId) pair
- Fill check: `filled + amount > maxAmount` reverts with
  `CapacityExceeded`
- Invariant #13 (`quoteFillNeverExceedsMax`) validates this

**Residual risk:** None identified.

## Known Limitations

### Chainlink Staleness

`Oracle.getPrice()` does not check `updatedAt` from
`latestRoundData()`. A stale feed returns the last known price.

**Impact:** Low. `getPrice()` is only used for live price display
(frontend). Settlement uses `expiryPrice` set explicitly by the
operator. If `getPrice` is ever added to a settlement path, a
staleness check must be added.

### Centralization

31 owner-only functions across all contracts. Pre-mainnet, the owner
is a single EOA. For mainnet, all ownership must transfer to a
multisig (e.g., Safe) with a timelock for critical operations
(upgrades, fee changes).

### betaMode Bypass

When `betaMode == true`, time-based checks are bypassed (expiry
checks in Controller, Oracle price reset). This is intentional for
testnet demos but must be disabled before mainnet. `betaMode` is
owner-only and defaults to `false`.

### No Partial Collateral Withdrawal

Once collateral is deposited into a vault, it cannot be withdrawn
until settlement. There is no `withdrawCollateral` function. This is
by design (fully collateralized model) but limits capital efficiency.

### Token Assumptions

The protocol assumes standard ERC20 behavior:
- No fee-on-transfer
- No rebasing
- `decimals()` returns a static value
- `transfer`/`transferFrom` revert on failure (enforced by
  SafeERC20)

Non-standard tokens would break collateral accounting.
