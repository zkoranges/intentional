# Next steps: candidate directions

> Status: **ideas under consideration, nothing committed.** Each section states
> what exists today, what the change would enable, and what it would cost.
> Sizings are engineering estimates, not schedules.
>
> Measurements in this document were taken 2026-07-26 by running the suites and
> counting the code, not by reading the git log. `make test` → 252 passed,
> 0 failed, 0 skipped at the time of writing.

Three candidates, in rough order of how much of the work is already paid for:

| # | Idea | Already built | To a live app feature |
|---|---|---|---|
| 1 | Uniswap payouts — pay sellers in any asset | contracts, tests, fork proof | ~2.5–3 h to bounty; app wiring deferred |
| 2 | Ether.fi as a second market | nothing; the pattern to copy | ~2 weeks |
| 3 | Users run their own factors | nothing; blocked by a sealed binding | see §3 — depends entirely on which shape |

§4 is the observation that matters most for sequencing.

## 1. Uniswap payouts — let the seller choose the payout asset

Full specification: [`uniswap_payouts_idea.md`](uniswap_payouts_idea.md). This is
a summary of what it would mean for the product, not a restatement of the spec.

**What it enables in one sentence.** A seller sells a delayed claim and receives
the token they asked for — USDC is the demonstrated case — instead of always
receiving WETH, in the same single transaction.

Today someone exiting stETH gets WETH and then has to swap it themselves: a
second transaction, second gas, second slippage, and the price moves in between.
With this, the factor still underwrites in WETH, a Uniswap route converts the
exact advance, and the payout asset lands directly in the seller's wallet.
Fill-or-kill is preserved end to end — if the route cannot deliver at least the
signed minimum, the whole fill reverts: no claim sold, no nonce consumed. Price
improvement above the minimum belongs to the seller.

In the interface this is the mirror image of the sell-side asset selector: the
hardcoded `WETH` output pill becomes a token picker.

### 1.1 State

S-1 through S-6 are built and green, and the any-payout-asset generalization
shipped with them. Verified present at the stated sizes: `src/payouts/` (4 files,
631 lines), both fixtures committed, and unit, integration and fork suites.
Missing, as the spec claims: `execute-uniswap-payout-quote.mjs`,
`UniswapPayoutDemo.s.sol`, `DeployUniswapPayoutMainnet.s.sol`, and three Makefile
targets.

### 1.2 Cost

Remaining work parallelizes into five tracks with **zero file collisions** — the
three missing files are new, the hardening touches one test, the docs touch three
markdown files. Critical path is **≈ 2.5–3 h wall clock**, of which only ~90
minutes is genuinely parallel; the serial join and the demo video dominate the
tail. Serial execution is 3–4 h, so parallelizing buys roughly 45 minutes rather
than a multiple.

Optional mainnet deployment adds 2–4 h plus budget and is irreducibly serial —
one deployer, one nonce sequence, a `computeCreateAddress` prediction.

### 1.3 The honest caveat

**None of that reaches the app.** §14 of the spec defers frontend payout
selection, and §3.3 repeats that the toggle is cut because the demo is scripted
on the jury fork. The remaining hours produce bounty deliverables; a visitor to
the site would see no difference.

Reaching the app additionally requires:

- **A second mainnet deployment.** The payout kernel is a *sibling* of the live
  v2 kernel, not an upgrade — §3.1 needs three fresh instances because the
  funding account, reserve adapter and Lido adapter bindings are sealed or
  immutable.
- **Non-interchangeable quotes.** The payout kernel signs under a different
  EIP-712 domain, so existing signed quotes are invalid against it by design.
- **Frontend and quote-desk changes.** `/api/quote/lido` serves the v2 envelope;
  `lib/ethereum.ts` needs the 14-field quote struct, the `fill()` signature with
  `payoutData`, and the 17-field `ClaimSettled` decode. The spec warns plainly
  that the v2 decode path does not work against this kernel.

Worth weighing: the live market is capped at 0.0005–0.005 stETH in pre-alpha, so
the near-term audience for "pay me in USDC" is small. That is probably why the
spec scoped it to the jury demo rather than the product.

## 2. Ether.fi as a second market

**What it enables.** A second protocol to factor. The market card already exists
in the interface, labelled *Soon*, with the icon and the ~10 day typical queue
time in place — only the plumbing behind it is missing.

### 2.1 The contract layer is genuinely ready

`IClaimAdapter` is 16 lines and two functions, `inspect()` and `acquire()`.
Three adapters already implement it — Lido originate (238 lines), Lido unstETH
exit (241), generic ERC-8161 redeem (273) — so Ether.fi would be a fourth
against a proven pattern.

Better: `allowAdapter()` is `onlyFactor` and deliberately **not** gated by
`beforeSeal` (`AsyncClaimSettlement.sol:112`), with the code commenting the
allowlist as an intentionally open trust boundary. Adding a market to the
already-sealed, already-live deployment is one factor transaction. No new kernel,
no new funding account, no migration.

Ether.fi is also a structural twin of Lido — stake token, request withdrawal,
receive a transferable ERC-721 claim, redeem for ETH after finalization — so the
Lido adapter maps onto it closely.

### 2.2 The cost is above the contracts

Nothing in the off-chain stack is adapter-shaped. Counted 2026-07-26:

| File | Size | Lido/stETH references |
|---|---|---|
| `frontend/lib/ethereum.ts` | 1,267 ln | **151** |
| `services/quote-signer/server.mjs` | 1,073 ln | **78** |
| `frontend/scripts/create-lido-quote.mjs` | 420 ln | 36 |
| `frontend/app/api/quote/lido/route.ts` | 199 ln | 17 |

~280 hardcoded references to one market. The quote route is literally
`/api/quote/lido`, the queue-time endpoint is hardcoded to `wq-api.lido.fi`, and
the core frontend type is `SourceAsset = "steth" | "unsteth"` with 23 uses of
`MIN`/`MAX_LIDO_*` constants. A second market means duplicating that path or
parameterizing it — and parameterizing touches the live signing service, the one
component holding the factor key.

### 2.3 Sizing

| Tier | Work | Est. |
|---|---|---|
| Contracts | adapter, interfaces, unit + integration + fork tests, deploy, `allowAdapter()` | 2–3 days |
| Quote path | desk, API route, operator CLI made market-aware | 2–3 days |
| Frontend | eETH balances, claim enumeration, approvals, market-aware copy and limits | 3–5 days |
| Operational | reserve capacity, Ether.fi queue-time source, risk review, activation discipline | separate, gated |

**~2 weeks to a live market**, of which the smart contract — the part that sounds
hardest — is about a fifth. A fork-proof demo with no app is **2–3 days**.

### 2.4 Verify before committing

1. **Is Ether.fi's withdrawal NFT freely transferable?** The whole model depends
   on the claim moving to the buyer atomically. Lido's unstETH is. If Ether.fi
   restricts transfers, the sell-an-existing-claim path does not exist and only
   the originate path works. This single question can invalidate the approach —
   check it against their deployed contracts first.
2. **weETH vs eETH.** Most holders hold wrapped weETH, which needs unwrapping
   before a withdrawal request — an extra user step or extra adapter logic.
3. The existing `ERC8161RedeemClaimAdapter` will **not** cover Ether.fi. That one
   is for ERC-7540 async vaults; the Ether.fi queue is not that shape.

## 3. Users run their own factors and participate

**What it enables.** Today there is exactly one factor — an operator with a key
on a VPS quote desk — and users can only ever be sellers. This would let a user
supply capital and earn the factoring spread, turning a single-operator product
into a two-sided market.

### 3.1 What blocks it today

The single-factor assumption is not incidental; it is bound in five places, all
immutable or sealed:

| Binding | Where |
|---|---|
| `address public immutable factorSigner` | `AsyncClaimSettlement.sol:71` |
| `onlyFactor` gate is `msg.sender != factorSigner` | `:85` |
| `quote.factor != factorSigner` reverts `QuoteFactorMismatch` | `:190` |
| signature checked against `factorSigner` | `:238` |
| constructor requires `fundingAccount.factor() == factorSigner` | `:104` |
| `address public immutable factor` on the funding account | `ProductiveFundingAccount.sol:44` |
| `configureSettlement` is `onlyFactor beforeSeal`, one-shot | `:105` |

One kernel is one factor, permanently. Unlike the adapter allowlist, there is no
open door here. This is the deepest of the three ideas.

### 3.2 Three shapes, cheapest first

**(a) Pooled passive reserve — users deposit, one operator underwrites.**
Depositors supply WETH and earn the factoring spread plus lending yield on idle
capital; the operator keeps signing. This touches the signing model not at all,
and the reserve is *already* an ERC-4626 position — `ERC4626ReserveAdapter` over
Aave StataWETH. The change is about who owns the funding account's capital and
how PnL is split, not about how quotes work.

Cheapest technically, and the non-technical cost is the real one: this is pooled
third-party capital. The factor bears genuine post-fill risk — it holds the claim
and carries queue duration, impairment and slashing exposure — and passing that
to depositors is a product, legal and disclosure decision before it is a coding
one. Loss socialization and a withdrawal/liquidity policy have to be designed,
not defaulted.

**(b) Factor-per-deployment — works today, zero contract change.**
Each factor deploys their own funding account, settlement and adapters. The
Uniswap payout build already proves this sibling-deployment pattern works, since
§3.1 of that spec requires exactly it. Costs: fragmented liquidity, a full deploy
per factor, and each factor needs their own quote desk and key. The app would
need a registry to discover them and a way to route a seller to the best quote.
Viable as a first step precisely because it needs no protocol change.

**(c) Multi-factor kernel — a registry instead of an immutable.**
Replace `factorSigner` with a mapping from factor to funding account. The wire
format already survives this: `ClaimTypes.Quote` carries `address factor` as
field one, so quotes are already factor-addressed. But it rewrites the reviewed
kernel's trust core in the four places listed above and re-opens the audit.
Highest value, highest cost, and it should not be attempted before (a) or (b)
has proven there is demand for the second side of the market.

### 3.3 Recommendation

Do not start with (c). (b) is free in protocol terms and would answer the only
question that matters — whether anyone actually wants to supply capital — before
committing to a kernel rewrite. (a) is the version most people mean by
"participating", and its blocking work is legal and product design rather than
Solidity.

## 4. The shared dependency, and what it means for sequencing

Ideas 1 and 2 want the same refactor from opposite directions.

The Uniswap payout work needs the quote desk and `lib/ethereum.ts` to stop
assuming one payout asset. Ether.fi needs the same files to stop assuming one
market. Both are the same ~280 hardcoded references, and doing that
de-coupling once — market and payout asset as configuration rather than as
constants — is worth more than either feature delivered on its own.

If both are likely, sequence the de-coupling first and treat each feature as
configuration on top. If only one is likely, do it the cheap hardcoded way and
do not pay for generality that never gets used.

Idea 3 is orthogonal to both and should not be bundled with them.
