## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Dependencies

The fund-core upgrade toolchain is pinned in `package-lock.json`. Install it
before running Foundry from a clean checkout:

```shell
npm ci --ignore-scripts
npm run deps:check
```

### Build

```shell
forge build --offline
```

### Test

Use the repository harness rather than invoking the mixed unit/fork tree directly:

```shell
npm run harness:doctor
npm run harness:fast
```

The fast gate is deterministic and offline. It excludes storage, fork, fuzz, and
invariant work. The full gate adds forced-build storage compatibility checks, the Foundry
security profile, and every explicit Base mainnet and Base Sepolia fork suite:

```shell
BASE_RPC_URL=<base-mainnet-rpc> \
BASE_SEPOLIA_RPC_URL=<base-sepolia-rpc> \
npm run harness:full
```

`harness:full` fails closed before running tests when either RPC variable is absent.
Fork suite membership and any pinned starting block are declared in
`scripts/harness-fork-paths.txt`.

### Format

```shell
forge fmt
```

### Fund Core Specifications

Storage compatibility is part of `npm run harness:full`. The harness uses a forced
offline build because OpenZeppelin upgrade validation rejects incremental Foundry
build-info files.

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
