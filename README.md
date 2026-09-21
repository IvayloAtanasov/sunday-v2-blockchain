## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
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

Each network has its own env file: `.env.arc` (Arc mainnet) and `.env.arc-testnet` (Arc testnet). They hold the RPC URL, deployer key and addresses, and are gitignored. Create them from the committed templates:

```shell
$ cp .env.arc-testnet.example .env.arc-testnet
$ cp .env.arc.example .env.arc
```

Then deploy with `./deploy.sh <network> <Script> [forge args]`, which loads `.env.<network>` and runs `script/<Script>.s.sol`:

```shell
$ ./deploy.sh arc-testnet DeployLendingVault                        # simulate
$ ./deploy.sh arc-testnet DeployLendingVault --broadcast            # send transactions
$ ./deploy.sh arc-testnet DeployLendingVault --broadcast --verify   # send transactions and verify on Arcscan
```

Scripts:

-   `DeploySunToken`: deploys the SunToken collection. Needs `DEPLOYER_PRIVATE_KEY`.
-   `DeployEnergyPriceOracle`: deploys the shared price oracle. One per network, and every adapter pins its address, so replacing it means replacing every vault.
-   `DeployYieldAdapter`: deploys the adapter that prices production and rebases vaults. Requires `PRICE_ORACLE_ADDRESS`. The yield formula lives in this contract as constants — read `src/YieldAdapter.sol` before deploying one.
-   `DeployLendingVault`: deploys a lending vault, binds it to its claim token id, and registers it with the adapter. Requires an existing SunToken collection in `SUN_TOKEN_ADDRESS` and an adapter in `YIELD_ADAPTER_ADDRESS`.

See the `.env.*.example` files for all variables and defaults.

Don't keep a plain `.env` in this folder: Foundry loads it automatically and it fills in any variable the network file leaves unset.

#### Full deployment order

1. `DeploySunToken` → `SUN_TOKEN_ADDRESS` (once)
2. `DeployEnergyPriceOracle` → `PRICE_ORACLE_ADDRESS` (once)
3. `DeployYieldAdapter` → `YIELD_ADAPTER_ADDRESS` (once per formula)
4. `DeployLendingVault`, repeated per vault

Both the oracle and the adapter can be deployed without a publisher address. They accept nothing
until `setPublisher` is called, so that is the safe order when the lambda keys do not exist yet.

What is frozen, and what is not:

| | Frozen | Why |
|---|---|---|
| The formula and its rates | yes, per adapter | It is what a lender was sold. Correcting it needs a new adapter, and therefore new vaults |
| The price oracle address | yes, per adapter | A settable price source is a settable source of truth for what a vault owes |
| A vault's station, market and capacity | yes, per vault | A settable ceiling would not bound the operator |
| The publisher keys | **no**, rotatable by the owner | Losing a key must not permanently stop every vault accruing |
| The price sanity bound | **no**, settable by the owner | A fixed ceiling on an unbounded quantity would cost every vault any period whose real price exceeded it |

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
