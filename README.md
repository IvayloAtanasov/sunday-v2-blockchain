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

**Quote any value containing `&`.** `deploy.sh` sources the env file, so it runs as shell: an
unquoted `&` is a control operator, the assignment gets backgrounded, and the variable is never
set in the parent shell. `VERIFIER_URL` is the one that hits this, and it fails as
`--verify needs VERIFIER_URL` rather than as anything pointing at the URL.

Verification goes through Blockscout's central PRO API rather than the explorer's own `/api`. The
explorer host serves anonymous callers 10 requests per ~30 minute window and does not recognise a
PRO key, so verification there fails on quota once a couple of retries have burned it. The key
belongs **in** `VERIFIER_URL`: forge's ABI preflight is a GET, and `--verifier-api-key` does not
reach its query string.

#### Full deployment order

Each step produces a value the next one needs. The right-hand column is where that value goes —
several of them leave this repo, and a deployment that stops at step 4 looks finished but accrues
nothing.

| | Script | Produces | Goes into |
|---|---|---|---|
| 1 | `DeploySunToken` | collection address | `SUN_TOKEN_ADDRESS` (once) |
| 2 | `DeployEnergyPriceOracle` | oracle address | `PRICE_ORACLE_ADDRESS` in the env file **and** in Secrets Manager (once) |
| 3 | `DeployYieldAdapter` | adapter address | `YIELD_ADAPTER_ADDRESS` (once per formula) |
| 3b | — | the adapter's **deploy block** | `FIRST_ADAPTER_DEPLOY_BLOCK` in Secrets Manager |
| 4 | `DeployLendingVault` | vault address + token id | the installation's Mongo document — see below (per vault) |

Steps 1–3 happen once per network. Step 4 repeats per installation, and is covered by
[Adding an installation](#adding-an-installation), which does not end in this repo.

The adapter's deploy block is not printed by the script; read it from the broadcast record:

```shell
$ cast to-dec $(jq -r '.receipts[0].blockNumber' \
    broadcast/DeployYieldAdapter.s.sol/<chain-id>/run-latest.json)
```

The indexer uses it as the floor for an adapter it has no cursor for. Too low costs empty log
queries; too high silently skips events, so take it from the record rather than estimating.

Both the oracle and the adapter can be deployed without a publisher address. They accept nothing
until `setPublisher` is called, so that is the safe order when the lambda keys do not exist yet.
Whatever address is set must hold gas on this chain — the publishers send one transaction each per
day and nothing tops them up.

The backend needs three secrets before any of this accrues: `PRICE_ORACLE_ADDRESS`,
`FIRST_ADAPTER_DEPLOY_BLOCK`, and `ORACLE_PUBLISHER_PRIVATE_KEY` for the publisher address above.
See the backend README.

What is frozen, and what is not:

| | Frozen | Why |
|---|---|---|
| The formula and its rates | yes, per adapter | It is what a lender was sold. Correcting it needs a new adapter, and therefore new vaults |
| The price oracle address | yes, per adapter | A settable price source is a settable source of truth for what a vault owes |
| A vault's station, market and capacity | yes, per vault | A settable ceiling would not bound the operator |
| The publisher keys | **no**, rotatable by the owner | Losing a key must not permanently stop every vault accruing |
| The price sanity bound | **no**, settable by the owner | A fixed ceiling on an unbounded quantity would cost every vault any period whose real price exceeded it |

#### Adding an installation

Deploying the vault is the middle of this, not the end. The last two steps are in other systems,
and skipping either leaves a vault that is correctly deployed, correctly registered, and never
accrues anything.

**1. Decide the capacity ceiling.** `MAX_PERIOD_MILLI_KWH` is the most the installation can
physically produce in one reporting period, in kWh × 1000 — daily *energy*, not the array's peak
power. For a nameplate figure in kWp, allow 8–10 kWh per kWp:

```
12.6 kWp × 10 h = 126 kWh → MAX_PERIOD_MILLI_KWH=126000
```

Ten hours at full rated output is not a day that happens; Sofia averages around four peak sun
hours and the best clear summer days reach six or seven. That headroom is the point. The ceiling
exists to catch a mis-scaled reading, it is frozen at registration, and a period it rejects is
lost for good once the staleness window closes — so too generous costs nothing and too tight
costs real days.

**2. Deploy the vault.** Set `STATION_ID`, `MAX_PERIOD_MILLI_KWH`, `PRINCIPAL`, `BORROWER_ADDRESS`
and `TOKEN_URI` (`STATION_COUNTRY` defaults to `BG`), then:

```shell
$ ./deploy.sh arc-testnet DeployLendingVault --broadcast --verify
```

Note the printed `LendingVault:` address and `tokenId:`. The script also does `setRebaseAdapter`
then `registerVault`; that order is forced, because the adapter refuses to register a vault that
does not already point at it, and a vault's adapter freezes when its funding closes.

**3. Record it in Mongo.** The publisher and the indexer both enumerate installations from the
database, not from the chain, so a vault missing here is invisible to both:

```js
db.installations.updateOne(
  { stationId: "<STATION_ID>" },
  { $set: {
      vaultAddress: "<vault address, exactly as forge printed it>",
      tokenId: <tokenId from the deploy output>,
      timezone: "Europe/Sofia"
  } },
  { upsert: true }
)
```

Store the address checksummed as printed, or fully lowercase. Both readers construct an
`ethers.Contract` from it, and a mixed-case address whose EIP-55 checksum does not validate
throws.

**4. Check the station id agrees in three places.** This is the one failure with no error
message:

| Where | What sets it |
|---|---|
| On chain, in the adapter's registry | `STATION_ID` at step 2 |
| The installation document | step 3 |
| `PvMetric.stationId` | `FUSIONSOLAR_STATION` in Secrets Manager |

The publisher reads a vault's station id **from the adapter**, then looks for production rows
carrying that id. If the collector is writing a different one, the vault is registered, accruing
and priced, and still reports nothing but `nothing to report this run`.

```shell
$ cast call $YIELD_ADAPTER_ADDRESS \
    'vaultState(address)((bool,string,bytes32,uint64,uint8,uint64))' <vault> --rpc-url $RPC_URL
```

That returns `(registered, stationId, country, maxPeriodMilliKwh, phase, lastRebasedAt)` — the
authoritative view, and the best single check before running the publishers.

**5. Fund, draw down, activate.** A vault only accrues in `Accruing`, which is phase 3. Until
`subscribe()` fills it, `drawdown()` runs and `activate()` is called, the publisher will correctly
report `phase N, not accruing` and submit nothing.

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
