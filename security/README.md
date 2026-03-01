# Security Audit Package — b1nary Options Protocol

## Protocol Overview

Fully-collateralized options protocol on Base L2. Users buy options
via EIP-712 signed quotes from whitelisted market makers (MMs).
Settlement is physical (flash loan + DEX swap) or cash (burn oTokens
for collateral payout).

## Scope

| Contract | Lines | Proxy | Role |
|----------|-------|-------|------|
| AddressBook | 102 | UUPS | Central registry for protocol addresses |
| Controller | 331 | UUPS | Vault lifecycle: open, deposit, mint, settle, redeem, pause, emergency withdraw |
| MarginPool | 58 | UUPS | Holds collateral (USDC/WETH) |
| OToken | 106 | — | ERC20 per option series (non-upgradeable) |
| OTokenFactory | 126 | UUPS | CREATE2 deployment of OToken instances |
| Oracle | 138 | UUPS | Expiry price storage + Chainlink live price + deviation bounds |
| Whitelist | 106 | UUPS | Asset/product/oToken/MM allow lists |
| BatchSettler | 564 | UUPS | Order execution, batch settlement, physical delivery |
| **Total** | **1,531** | | |

Out of scope: mock contracts (`src/mocks/`), test files, interfaces.

## Key Dependencies

- OpenZeppelin Contracts 5.1.0 (UUPS, ERC20, SafeERC20, ECDSA,
  ReentrancyGuard, Initializable)
- Solidity 0.8.24 (checked arithmetic by default)
- Foundry (build + test framework)

## Privileged Roles

| Role | Held By | Powers |
|------|---------|--------|
| AddressBook owner | Deployer multisig | Register/update all protocol addresses, upgrade contracts |
| Controller owner | Deployer multisig | setPartialPauser, setSystemFullyPaused, transferOwnership, upgrade |
| Partial pauser | Set by Controller owner | Toggle partial pause (blocks new positions, exits remain open) |
| Oracle owner | Deployer multisig | Set price feeds, set/reset expiry prices, set deviation threshold |
| BatchSettler owner | Deployer multisig | Set operator, fee BPS, treasury, swap fee tier, Aave/Uniswap addresses, upgrade |
| BatchSettler operator | Backend bot | Execute orders, batch settle, batch redeem, physical redeem |
| Whitelist owner | Deployer multisig | Whitelist assets, products, oTokens, MMs |

## Test Coverage

| Category | Files | Tests | Runs |
|----------|-------|-------|------|
| Unit | 9 files | 196 | 196 |
| Fuzz | 1 file | 23 | 5,888 |
| Invariant (original) | 1 file | 4 | 1,024 |
| Invariant (lifecycle PUT+CALL) | 1 file | 13 | 3,328 |
| Invariant (batch redeem) | 1 file | 1 | 256 |
| Invariant (pause/emergency) | 1 file | 6 | 1,536 |
| Upgrade | 1 file | 50 | 50 |
| Fork (Base mainnet, PUT+CALL+surplus) | 1 file | 5 | 5 |
| **Total** | **14 files** | **301** | — |

## Artifacts

| File | Description |
|------|-------------|
| `static-analysis-report.md` | Slither + Aderyn findings, triage, fixes |
| `invariant-report.md` | All 24 invariant properties with rationale |
| `threat-model.md` | Trust assumptions, attack surfaces, known limitations |
| `aderyn-report.md` | Raw Aderyn output |

## How to Reproduce

```bash
# Build
forge build

# Run all tests (default profile: 256 fuzz runs)
forge test -v

# Run invariant suite only
forge test --match-path test/Invariant.t.sol -vv

# Run with security profile (10K fuzz, 1K invariant depth 100)
FOUNDRY_PROFILE=security forge test -vv

# Fork test (PUT+CALL physical delivery against real Aave + Uniswap on Base)
# Pinned to block 42733000 for deterministic results
forge test --match-contract ForkPhysicalRedeemTest \
  --fork-url $BASE_RPC_URL -vvv

# Static analysis
slither . --config-file slither.config.json
FOUNDRY_EVM_VERSION=paris aderyn .
```
