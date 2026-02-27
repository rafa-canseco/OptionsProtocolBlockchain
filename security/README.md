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
| Controller | 262 | UUPS | Vault lifecycle: open, deposit, mint, settle, redeem |
| MarginPool | 58 | UUPS | Holds collateral (USDC/WETH) |
| OToken | 106 | — | ERC20 per option series (non-upgradeable) |
| OTokenFactory | 145 | UUPS | CREATE2 deployment of OToken instances |
| Oracle | 121 | UUPS | Expiry price storage + Chainlink live price |
| Whitelist | 113 | UUPS | Asset/product/oToken/MM allow lists |
| BatchSettler | 591 | UUPS | Order execution, batch settlement, physical delivery |
| **Total** | **1,498** | | |

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
| Controller owner | Deployer multisig | setBetaMode, transferOwnership, upgrade |
| Oracle owner | Deployer multisig | Set price feeds, set/reset expiry prices |
| BatchSettler owner | Deployer multisig | Set operator, fee BPS, treasury, swap fee tier, Aave/Uniswap addresses, upgrade |
| BatchSettler operator | Backend bot | Execute orders, batch settle, batch redeem, physical redeem |
| Whitelist owner | Deployer multisig | Whitelist assets, products, oTokens, MMs |

## Test Coverage

| Category | Files | Tests | Runs |
|----------|-------|-------|------|
| Unit | 8 files | 175 | 175 |
| Fuzz | 1 file | 22 | 5,632 |
| Invariant (original) | 1 file | 5 | 1,280 |
| Invariant (new lifecycle) | 1 file | 13 | 3,328 |
| Upgrade | 1 file | 50 | 50 |
| **Total** | **12 files** | **260** | — |

## Artifacts

| File | Description |
|------|-------------|
| `static-analysis-report.md` | Slither + Aderyn findings, triage, fixes |
| `invariant-report.md` | All 15 invariant properties with rationale |
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

# Static analysis
slither . --config-file slither.config.json
FOUNDRY_EVM_VERSION=cancun aderyn .
```
