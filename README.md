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
-   `DeployLendingVault`: deploys a lending vault and binds it to its claim token id. Requires an existing SunToken collection in `SUN_TOKEN_ADDRESS` (deploy it first with `DeploySunToken`).
-   `DeployChainlinkYieldAdapter`: deploys the adapter and, if `LENDING_VAULT_ADDRESS` is set, wires it to that vault (only while funding is open).

See the `.env.*.example` files for all variables and defaults.

Don't keep a plain `.env` in this folder: Foundry loads it automatically and it fills in any variable the network file leaves unset.

#### Full deployment order

1. DeploySunToken → SUN_TOKEN_ADDRESS (once)
2. DeployYieldReceiver → YIELD_RECEIVER_ADDRESS (once)
3. cre workflow deploy, with that receiver address in the workflow config → WORKFLOW_ID
4. SetWorkflowId (once, irreversible)
5. DeployLendingVault, repeated per vault

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
