# Lending Vault — specification

Date: 2026-09-14
Status: draft for refinement.

Sections are numbered so they can be refined individually. Requirements are tagged `R-n` and
referenced from the invariants and open-decision lists.

---

## 1. Instrument

**1.1** The vault issues a **zero-coupon bond with a performance-based premium**, denominated in EURC, against a single real-world asset (a PV installation).

**1.2** Lenders subscribe EURC during a funding window and receive ERC1155 claim tokens at a fixed **1:1** ratio to principal. The ratio is 1:1 at issuance and never changes; the *value* of a token changes, its count does not.

**1.3** The client draws the raised principal down and builds the asset. Once the asset is live, profit is measured off-chain and pushed on-chain, growing the total owed. That growth is the **premium**.

**1.4** The client repays **principal + premium in a single bullet payment at maturity**. There are no coupons and no amortisation schedule.

**1.5** There is **no early redemption**. A lender wanting out before maturity sells the ERC1155 on a secondary market, as with any bond.

**1.6** The obligation is **unsecured on-chain**. EURC is converted into physical hardware that cannot be escrowed or seized by the contract. This is accepted, not a defect. The contract's job is to record the obligation honestly, freeze it when it should be frozen, and distribute whatever is actually repaid fairly. Recourse on default is off-chain.

---

## 2. Actors

| Actor | Role | Trust assumption |
|---|---|---|
| **Client** (issuer/borrower) | Proposes the project, draws down principal, builds and operates the asset, repays at maturity | Untrusted with contract state; trusted off-chain for repayment |
| **Lender** (subscriber/holder) | Deposits EURC during funding, holds or trades the claim token, redeems after maturity | Untrusted |
| **Operator** (Sunday) | Deploys vaults, configures the oracle adapter, attests to asset go-live | Trusted for attestation only — see [§10.1](#101-who-calls-activate) |
| **Oracle adapter** | Chainlink Functions consumer that pushes measured profit into `rebase()` | Trusted for the profit figure; bounded by [§8](#8-oracle-and-rebase-rules) |

**2.1** The Operator must not be able to move funds, alter `owed`, or change the repayment obligation. Its powers are limited to configuration before funding opens and the attestation in [§10.1](#101-who-calls-activate).

---

## 3. Units and tokens

**3.1 — R-1.** The collateral token is EURC (6 decimals). The vault MUST read `decimals()` from the
collateral token at construction and store it, rather than assuming 6. The off-chain profit
pipeline emits values in the same unit and MUST be asserted against it, not assumed.

**3.2 — R-2.** One claim token represents one minor unit of principal (1 token = 0.000001 EURC at
6dp), so claim token counts and EURC amounts are denominated identically. This keeps the 1:1
invariant exact with no scaling factor at issuance.

**3.3 — R-3.** The claim token is an ERC1155 id on a shared collection (`SunToken`). The vault MUST
be granted a **per-id minter/burner role** on that collection, bound once and never reassignable.
It MUST NOT require collection ownership — one collection serves many vaults, so ownership cannot
be the authorisation mechanism.

**3.4 — R-4.** Redemption MUST NOT depend on the redeemer having called `setApprovalForAll` on the
vault. The burn path MUST authorise on `msg.sender` burning their own balance.

**3.5 — R-5.** Claim tokens are freely transferable. The secondary market is the only pre-maturity
exit ([§1.5](#1-instrument)), so transferability is load-bearing and MUST NOT be gated.

**3.6 — R-11.** Claim tokens are minted **on `subscribe()`**, never pre-minted to the vault. The
vault therefore never holds unsold claims, and outstanding supply at funding close is exactly
`principal`.

---

## 4. Lifecycle

```
                    ┌──────────────────────────────────────┐
                    │                                      │
  Funding ──────────┼─ target met ──> Drawdown ─ activate ─┼──> Accruing
     │              │                    │                 │       │
     │              └────────────────────┼─────────────────┘       │
     │ deadline, under target            │ activation deadline     │ maturity
     v                                   v                         v
  Failed                              Default <───── grace ────  Settlement
     │                                   │                         │
     │ refund 1:1                        │ finalize                │ finalize
     v                                   v                         v
  (terminal)                         Redemption <──────────────────┘
                                     (terminal)
```

Funding close, Failed and Default are derived from deadlines in `phase()`; nobody calls a function
to enter them.

**4.1 Funding.** Entry: construction. Callable: `subscribe()`. Not callable: `rebase()`, `drawdown()`, `repay()`, `redeem()`. Exits on `subscribed == principal` → **Drawdown**, or on `fundingDeadline` with `subscribed < principal` → **Failed**.

**4.1.1 — R-33.** Partial fills are not accepted. A raise fills exactly or goes to Failed.

**4.2 Failed.** Terminal. Callable: `refund()` — burn claim tokens, receive EURC 1:1. No premium, no loss. Once all claims are refunded, `withdrawRemainder()` (R-36); nothing else.

**4.3 Drawdown.** Entry: funding target met. Callable: `drawdown()` (client, once, capped), `activate()`. Not callable: `rebase()`, `redeem()`. The asset does not exist yet, so no premium can accrue. Exits on `activate()` → **Accruing**, or on `activationDeadline` → **Default**.

**4.3.1 — R-35.** `activate()` MUST require that `drawdown()` has happened. `drawdown()` is only callable in Drawdown, so activating first would lock the client out of the principal while the term starts and the obligation accrues against them.

**4.4 Accruing.** Entry: `activate()`, which sets `maturity = block.timestamp + term`. Callable: `rebase()`, `repay()`, and `finalize()` once `repaid >= owed` (R-16). Not callable: `subscribe()`, `drawdown()`, `redeem()`. Exits on `maturity` → **Settlement**, or early `finalize()` → **Redemption**.

**4.5 Settlement.** Entry: `maturity` reached. `owed` is frozen. Callable: `repay()`, `finalize()`. This is the grace window in which the client's bullet payment must land. Exits on `finalize()` → **Redemption**, or on `maturity + grace` with `repaid < owed` → **Default**.

**4.6 Redemption.** Entry: `finalize()`, which fixes `settled`, from Accruing, Settlement or Default. Callable: `redeem()`, `withdrawSurplus()`, `withdrawRemainder()`. Terminal. Whether the loan defaulted is recorded in `defaulted`, not in the phase.

**4.7 Default.** Entry: activation deadline missed, or grace expired with `repaid < owed`. A declared, publicly readable state — the on-chain record that off-chain recourse rests on. `owed` freezes at its current value. Callable: `repay()`, `finalize()`. `finalize()` runs against whatever balance exists (possibly zero), sets `defaulted`, and exits → **Redemption**.

**4.8 — R-6.** Every state transition MUST emit an event carrying the new state and the values frozen at that point (`owed`, `maturity`, `settled` as applicable).

**4.9 — R-7.** Phase transitions that depend on a deadline MUST be reachable by anyone, not only by the Operator or the client. A vault MUST NOT be able to stall because a privileged party declines to call a function.

---

## 5. Parameters and accounting model

**5.1** Everything the vault needs is fixed at construction. Nothing below is settable afterwards
except the rebase adapter, which freezes when funding closes (R-19).

| Parameter | Meaning |
|---|---|
| `client` | Address that may call `drawdown()` and is obliged to repay |
| `claimToken`, `tokenId` | ERC1155 collection and the id representing this vault's claim |
| `collateralToken` | EURC; its `decimals()` is read once and cached (R-1) |
| `principal` | Funding target |
| `fundingWindow` | Duration from deployment; fixes `fundingDeadline` ([§4.1](#4-lifecycle)) |
| `term` | **Duration** of the financed period. Starts at `activate()`, not at deployment (R-29) |
| `activationWindow` | Maximum delay from funding close to `activate()` (R-28) |
| `graceWindow` | Duration from maturity to default ([§4.5](#4-lifecycle)) |
| `maxRebaseDeltaRatio`, `maxStaleness` | Rebase bounds (R-26, R-27) |
| `rebaseAdapter` | Settable during Funding only (R-19) |

**5.1.1 — R-29.** `term` is a **duration**, fixed at construction, and MUST NOT be settable
afterwards by any party. Only its start floats, via `activate()`. This is the point of separating
the two: a build delay shifts when the clock starts, but cannot shorten or extend the period lenders
priced when they subscribed. `maturity` is derived once, at activation, and is immutable thereafter
(I-5, I-12).

**5.1.2** Corollary: `activate()` carries no arguments. It attests to a fact — the asset is live —
and nothing else. Anything the caller could parameterise is discretion that
[§10.1](#101-who-calls-activate) has to defend.

**5.2** Running state, each with exactly one writer. `owed` and `settled` are separate numbers:
what is owed, and what can actually be paid.

| Name | Meaning | Written by | Frozen at |
|---|---|---|---|
| `subscribed` | Funding progress; reaches `principal` or the raise fails | `subscribe()` | funding close |
| `owed` | Total obligation: principal + accrued premium | `rebase()` | maturity / default |
| `repaid` | Cumulative EURC received as repayment | `repay()` | finalize |
| `settled` | `min(owed, repaid)` — the pot redemptions are paid from | `finalize()` | immediately |

**5.2.1** `subscribed` tracks progress during Funding only. From Drawdown onward the amount raised
is `principal` (R-33).

**5.3 — R-9.** `owed` MUST be floored at `principal`. A performance-based premium may shrink to
zero; principal MUST NOT be forgiven by underperformance. The instrument is bond-shaped
([§1.1](#1-instrument)) and a bondholder does not lose principal to issuer underperformance.

**5.4 — R-10.** The floor applies at **read time over a signed cumulative accumulator**, not by
clamping each rebase:

```
cumulativeYield : int256     // signed, accumulated by rebase()
owed            = principal + max(0, cumulativeYield)
```

Clamping per-rebase would forgive a bad period permanently, letting later profit accrue on top of
the floor. Accumulating signed and flooring once lets a weak period offset later profit, while
principal stays protected.

**5.5 — R-12.** `drawdown()` MUST transfer exactly `principal` and be callable exactly once. It
MUST NOT derive the amount from `balanceOf(address(this))`. The client receives exactly what was
raised, no more and no less, so the transfer is fully determined by the contract's own rules rather
than by whatever the balance happens to hold.

**5.6 — R-13.** Solvency MUST be readable at any block as `owed - repaid`, and exposed as a view.

**5.7** R-8 is retired; R-11 lives in [§3.6](#3-units-and-tokens).

---

## 6. Redemption and the shortfall rule

**6.1** Because the instrument is unsecured, partial recovery is an expected outcome and the
contract MUST have a defined, fair rule for it. This is the single most important behaviour in the
spec.

**6.2 — R-14.** A shortfall MUST be shared **pro-rata across all holders**. It MUST NOT be
first-come-first-served: paying each caller their full claim until the balance runs dry turns an
80% recovery into "the first 80% by gas price are whole, the rest get nothing".

**6.3** Bullet repayment concentrates this risk rather than diluting it: with no early redemption
and a single due date, every holder arrives at the same block, so FCFS degenerates into a pure
priority-fee auction.

**6.4 — R-15.** Redemption opens only after `finalize()`, which snapshots a **total**, not a rate:

```solidity
settled = owed < repaid ? owed : repaid;   // uint256, EURC minor units
```

`redeem(n)` burns `n` tokens and pays `(n * settled) / principal`.

**6.4.1 — R-30.** No scaled per-token rate. Multiply first, divide once. 1 claim token = 1 EURC
minor unit (R-2), so both sides are in the same units.

**6.4.2 — R-31.** Division rounds down. Dust stays in the vault until R-36; the last redeemer is never short.

**6.4.3 — R-32.** Surplus (`repaid - owed`) is refundable to the client, not payable to lenders.

**6.4.4 — R-36.** EURC sent to the vault other than through `subscribe()` or `repay()` MUST NOT be
counted as subscription or repayment, and MUST NOT change `settled`. It is treated as a gift to the
client. Once the vault is terminal (Redemption or Failed) and the claim token supply for `tokenId`
is zero — every lender has redeemed or been refunded — the client MAY withdraw the vault's entire
remaining EURC balance: stray transfers, redemption dust, and any unwithdrawn surplus. While any
claim token is outstanding this path is closed, so it can never compete with a lender.

**6.5 — R-16.** `finalize()` MUST be callable by anyone once the grace window has closed, and MUST
be callable early by anyone once `repaid >= owed` (full repayment needs no waiting).

**6.6** Late payment arriving after `finalize()` is an open item — see
[§10.2](#102-late-payment-after-finalize).

---

## 7. Interface

Names are indicative; the phase gating and the argument/cap semantics are the normative part.

| Function | Caller | Phase | Notes |
|---|---|---|---|
| `subscribe(amount)` | anyone | Funding | Pulls EURC, mints claim tokens 1:1. Reverts past the target (R-17). |
| `refund(n)` | holder | Failed | Burn n tokens, receive n EURC. |
| `drawdown()` | client | Drawdown | Once, capped at `principal` (R-12). |
| `activate()` | see §10.1 | Drawdown | Requires prior `drawdown()` (R-35). Sets `maturity = now + term`. Once. |
| `rebase(delta, updatedAt)` | adapter | Accruing | Accumulates into `cumulativeYield`. Bounded by §8. |
| `repay(amount)` | anyone | Accruing, Settlement, Default | Pulls EURC, increments `repaid`. Prepayment allowed (R-18). |
| `finalize()` | anyone | Accruing (fully repaid), Settlement, Default | Fixes `settled`, sets `defaulted`, moves to Redemption (R-15, R-16). |
| `redeem(n)` | holder | Redemption | Burns n tokens, pays `(n * settled) / principal`. |
| `withdrawSurplus()` | client | Redemption | Pays `surplus` (R-32). |
| `withdrawRemainder()` | client | Redemption, Failed | Only at zero claim supply. Pays the whole remaining balance (R-36). |
| `setRebaseAdapter(a)` | Operator | Funding only | Frozen once funding closes (R-19). |

**7.1 — R-17.** `subscribe()` MUST reject any amount that would push `subscribed` past `principal`,
rather than relying on the vault running out of pre-minted tokens. Over-funding must fail loudly and
partial fills at the boundary must be explicit.

**7.2 — R-18.** `repay()` MUST accept partial prepayment during Accruing. It costs nothing to allow,
lets a client de-risk their own default, and shrinks the payment that must land in a single block.
Prepayment MUST NOT unlock early redemption and MUST NOT be withdrawable.

**7.3 — R-19.** The rebase adapter address MUST be frozen when funding closes. After lenders have
committed capital, no party should be able to swap out the source of truth for what is owed to them.

**7.4 — R-20.** All ERC20 movements MUST use `SafeTransferLib` or equivalent checked transfers.
Discarding the `bool` return is latent today because EURC reverts, but the subscribe path is the
dangerous shape: a silently-failing transfer mints free claim tokens.

**7.5 — R-21.** `subscribe()`, `drawdown()`, `repay()`, `redeem()` and `refund()` MUST emit events
with the caller, amount, and resulting aggregate.

**7.6 — R-22.** The vault MUST expose, as public views: the current claim per token, `principal`,
outstanding supply, `owed`, `repaid`, the phase, `maturity` (0 until activation), and the token id.
The secondary market is the only pre-maturity exit, and a buyer cannot price the token without
these.

---

## 8. Oracle and rebase rules

**8.1 — R-23.** `rebase()` MUST be callable only in **Accruing**. Before activation there is no
asset and no profit to report; after maturity the obligation is frozen ([§1.4](#1-instrument)).

**8.2 — R-24.** Accrual stops dead at maturity. A fulfillment arriving after maturity MUST be
rejected, even when the period it reports ended before maturity. The oracle is expected to report
the final period before the window closes; that is an off-chain guarantee the contract cannot
enforce, and it MUST NOT weaken the freeze to compensate.

**8.3 — R-25.** `rebase()` MUST enforce `updatedAt > lastRebasedAt` and reject any period it has
already seen. A duplicate fulfillment would otherwise inflate the debt permanently. Deduplication
MUST NOT live only in the off-chain syncer: the contract cannot depend on the backend being correct
to stay solvent.

**8.4 — R-26.** `rebase()` MUST bound `|delta|` per period against a configured maximum, so a
mis-scaled or corrupted oracle response cannot move the obligation arbitrarily. The maximum is
`maxRebaseDeltaRatio`: the largest delta a single rebase may apply, relative to `principal`, in
basis points (1–10 000). Expressing it against principal makes it scale with installation size;
the ratio itself is chosen per vault for its asset class and reporting cadence. The bound is per
call, not per unit of time, so the same ratio is looser the more often the oracle reports.

**8.5 — R-27.** `rebase()` MUST reject a stale `updatedAt` beyond a configured window.

**8.6** The adapter MUST verify the target vault before calling, rather than decoding a vault
address out of the oracle response and trusting it. If vaults are deployed by a factory, the
adapter checks factory membership; the vault independently enforces `msg.sender == adapter`.

**8.7 — R-34.** The adapter MUST track requests individually. A single-slot "last request id" makes
two overlapping requests silently lose a rebase.

---

## 9. Invariants

To be asserted in tests and, where cheap, on-chain.

**I-1** `subscribed <= principal` at all times; `subscribed == principal` in every phase past
Funding.
**I-2** After funding close, `outstanding token supply + burned == principal`, and the vault holds
no claim tokens of its own (R-11).
**I-3** `owed >= principal` at all times after funding close (R-9).
**I-4** `owed` is constant from maturity onward, and from an early `finalize()` onward (R-24).
**I-5** `maturity == 0` before activation; strictly positive and immutable after.
**I-6** `drawdown()` succeeds at most once, and transfers exactly `principal`.
**I-7** Sum of all EURC paid out by `redeem()` never exceeds `settled`.
**I-8** `settled` is zero before `finalize()` and immutable after.
**I-9** No function moves EURC out of the vault except `drawdown()`, `refund()`, `redeem()`,
`withdrawSurplus()` and `withdrawRemainder()`; the last only at zero claim supply (R-36).
**I-10** In Failed, EURC out == EURC in, and no premium is ever payable.
**I-11** Every EURC balance increase is attributable to `subscribe()` or `repay()`; a bare transfer
to the vault address increases neither `subscribed` nor `repaid`, is not claimable by lenders, and
is withdrawable by the client only under R-36.
**I-12** `term` never changes; `maturity == activatedAt + term` (R-29).
**I-13** Sum of all `redeem()` payouts ≤ `settled`, with truncation dust retained (R-31).

---

## 10. Open decisions

### 10.1 Who calls `activate()`

Setting maturity at go-live rather than at vault creation is settled and correct: build, delivery
and installation slip, and premium can only accrue against an asset that exists. What is not settled
is who attests to go-live, because that party controls when accrual starts, when it stops, and when
payment is due.

- **Client** — direct incentive to activate late: every day of delay is a day the asset produces
  off-chain while the on-chain clock has not started.
- **Operator** — lenders trust Sunday to attest to a physical fact. Plausible, given Sunday already
  controls the profit oracle, but it should be a stated trust assumption rather than an accident.
- **Oracle** — first non-zero production reading activates automatically. Most faithful to "the
  asset is live", and reuses trust already extended to the adapter.

Whichever is chosen, **R-28**: the activation deadline is mandatory. Without it a client can draw
the full principal at funding close, never activate, never accrue a premium, never owe a due date,
and leave the vault inert forever with the money gone.

### 10.2 Late payment after `finalize()`

`settled` is fixed at finalize ([§6.4](#6-redemption-and-the-shortfall-rule)). A defaulting client
might pay part at maturity and the rest weeks later. Three shapes:

1. **Single finalize, late payment handled off-chain.** Simplest, race-free, transfer-safe, no
   per-holder state. Late EURC is stranded and needs an admin path. *Recommended.*
2. **Re-finalizable tranches.** `finalize()` may run again when new EURC lands, raising `settled`.
   Holders who have not burned benefit; holders who already burned are short-changed unless they
   keep a receipt — which reintroduces per-holder state.
3. **Streaming index.** Holders draw continuously against a cumulative total. Handles late payment,
   but transfers must checkpoint, so the ERC1155 has to call back into the vault on every transfer.

Option 1 unless late payment is expected to be common rather than exceptional.

### 10.3 Premium cap

[§1.3](#1-instrument) lets the premium grow with measured profit, bounded only by the term. Whether
the client's total obligation should also carry an explicit ceiling (an APR cap, or a maximum
multiple of principal) is unresolved. Freezing accrual at maturity caps the *duration* but not the
*rate*.

### 10.4 Commission and negative periods

`SUNDAY_COMMISSION = 2` EUR/day is flat — roughly 730 EUR/yr against roughly 1,100 EUR/yr gross on a
10k installation. The fee is most of the margin, and it is what pushes marginal days negative in the
first place (the off-chain script applies corporate tax only when the result is positive, so a
low-production day yields `revenue / 1.2 - 2 < 0`). R-9 and R-10 mean negative periods now only
erode premium rather than principal, but the fee structure deserves revisiting independently of the
contract.
