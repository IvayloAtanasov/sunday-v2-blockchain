# FundingVault review — open observations

Date: 2026-09-11
Scope: `src/FundingVault.sol` as of `ef5edb7`, read together with `src/ChainlinkYieldAdapter.sol`,
`src/SunToken.sol`, `script/DeployFundingVault.s.sol`, and the off-chain rebase pipeline in
`sunday-v2-backend/chainlink-yield-syncer`.

Status: all items below are open. Each is written to be picked up independently once the
intended product shape is settled.

## Intended model, as understood

A PV installation needs financing. Lenders deposit EURC and receive SunToken (ERC1155, one
token id per installation) 1:1. The borrower draws the principal down to build the installation.
Each day a Chainlink Function computes the installation's net yield in EURC and calls
`rebase()`, which is meant to make the loan self-repaying. At maturity lenders burn tokens and
redeem principal plus accrued yield.

## Summary verdict

As written this is not a loan, and the exit path cannot execute. The two blocking items are
[#1](#1-rebase-creates-a-claim-but-never-a-cash-flow) and
[#2](#2-redeem-can-never-execute); the rest are mostly downstream of #1 or are independent
hardening items.

---

## 1. `rebase()` creates a claim but never a cash flow

**Severity: structural — this is the item everything else hangs off.**

`FundingVault.sol:87` only increments an accounting number:

```solidity
redeemable += uint256(valueDelta);
```

No EURC moves. `withdraw()` (`:104`) sends the entire balance to the borrower, so after drawdown
the vault holds zero EURC while `redeemable` climbs toward ~12.7k over the five year term.

There is no `repay()`. Nothing obliges the borrower to return anything: no schedule, no penalty,
no collateral to seize, no default state. The oracle reports revenue the installation earned
off-chain; it does not deliver that revenue on-chain. Revenue is not cash in the contract.

The rebase manufactures a liability with no matching asset. The borrower *can* repay by a plain
ERC20 transfer to the vault address, but see [#3](#3-withdraw-is-an-unconditional-drain).

**To decide:** is the on-chain contract meant to custody the revenue, or only to account for it
while settlement happens off-chain? The answer changes almost every item below.

## 2. `redeem()` can never execute

**Severity: blocking, functional.**

`SunToken.burn` is `onlyOwner` (`SunToken.sol:51`) and `OwnerIsCreator` sets the owner to the
SunToken deployer (the EOA in `script/DeploySunToken.s.sol`). `FundingVault.sol:125` calls
`assetToken.burn(...)`, so `msg.sender` inside SunToken is the vault, not the owner. It reverts,
always.

Transferring SunToken ownership to a vault does not fix it: `script/DeployFundingVault.s.sol`
points every vault at one shared SunToken (`0xCA65a75b7475e32C6C4563D95328E75cEc6fB038`) with a
per-installation `assetTokenId`. Only one vault could ever be owner.

Second, quieter break behind the same line: `burn`'s inner require needs the redeemer to have
called `setApprovalForAll(vault, true)`. Nothing in the flow does that.

## 3. `withdraw()` is an unconditional drain

**Severity: high.**

```solidity
function withdraw() external onlyBorrower {
    uint256 collateralValueLocked = collateralToken.balanceOf(address(this));
    collateralToken.transfer(borrower, collateralValueLocked);
}
```

No cap, no once-only guard, no maturity check. Any repayment sent to the vault — the only way
repayment can currently happen at all — is withdrawable by the borrower at any time, including
the block before redemption opens.

## 4. Under-funding strands lender capital

**Severity: high.**

`redeem()` divides by `targetFunding`, a constant, rather than by what was actually raised:

```solidity
uint256 redeemableForBurned = (amount * redeemable) / targetFunding;
```

Over-funding *is* prevented — the vault is minted exactly `funding` asset tokens, so `borrow()`
reverts once they run out. That part works as intended.

But a raise that only reaches 50% produces total claims of 50% of `redeemable`, and the rest is
permanently stranded. There is also no deadline-and-refund path: a lender in a raise that never
completes has no exit, and the borrower may already have withdrawn the money.

## 5. `rebase()` is replayable and unbounded

**Severity: medium-high.**

`rebasedAt` is written (`:96`) but never checked. Missing: `require(updatedAt > rebasedAt)`, any
cap on `|valueDelta|`, any staleness check, any bound to the loan term. A duplicate fulfillment
for the same day inflates `redeemable` permanently.

Deduplication currently lives entirely off-chain, in the syncer's Mongo bookkeeping. That is a
weak place for it: the contract should not depend on the backend being correct to stay solvent.

`ChainlinkYieldAdapter.sol:106` also reverts when `requestId != s_lastRequestId`, so any two
overlapping requests silently lose a rebase.

## 6. Unchecked ERC20 return values

**Severity: medium (low against EURC specifically).**

`IERC20.transfer`/`transferFrom` return `bool` and all three call sites discard it: `:106`,
`:115`, `:128`. EURC reverts on failure so this is latent today, but `borrow()` is the dangerous
shape — a non-reverting token means free asset tokens. solmate is already a dependency; use
`SafeTransferLib`.

## 7. Economics: no floor, and a flat fee that dominates

**Severity: design, not a bug.**

Negative days shrink principal. The Deno script only applies corporate tax when the result is
positive, so a low-production day yields `revenue / 1.2 - 2 < 0` and `rebase` pushes `redeemable`
below `targetFunding`. Lenders have no floor and bear full production risk.

`SUNDAY_COMMISSION = 2` EUR/day is flat: roughly 730 EUR/yr against roughly 1,100 EUR/yr gross on
a 10k installation. The fee is most of the margin and is what pushes marginal days negative.

## 8. Smaller items

- No events on `borrow()` or `withdraw()`.
- `assetTokenID` (`:15`) is not `public`, inconsistent with the other state vars.
- No pause or admin recovery path after a bad rebase.
- Decimals coupling is implicit: the Deno script emits 6dp (`BigInt(Math.round(netYield * 1_000_000))`)
  to match EURC. Nothing asserts the collateral token's decimals.
- Naming is inverted relative to the model: lenders call `borrow()`, the borrower calls `withdraw()`.
- `redeem()` is all-or-nothing at maturity — no amortisation, no periodic yield claim.

---

## Sketch of a sound version

Recorded so the shape isn't re-derived later; not a proposal to implement yet.

- `repay()` that actually pulls EURC in, and is the only thing that raises a lender's claim.
- `rebase()` demoted to reporting an accruing debt obligation, not crediting a payout.
- `withdraw()` capped at `targetFunding`, callable once, only after the raise closes.
- Redemption paid from real balance, with an explicit documented shortfall rule.
- Something real behind default: escrowed revenue, assignment of the feed-in contract, or a lien
  on the hardware.

Without these, the on-chain part is an unsecured revenue-share note where the issuer self-reports
revenue and can withdraw any repayment at will. The self-repaying property lives entirely in the
borrower's goodwill.
