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

```shell
forge test --offline
```

### Format

```shell
forge fmt
```

### Fund Core Specifications

```shell
forge test --offline --match-path 'test/fund/*'
forge test --offline --match-path test/fund/StorageLayoutSpec.t.sol --force
npm run storage:check
```

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
