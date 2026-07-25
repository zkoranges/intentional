# Direction: Reservoir v2

> **Status: historical product rationale.** `V2_SCOPE.md` now controls the
> implemented wallet-driven live beta. `V1_SCOPE.md`, `SPEC.md`, and
> `IMPLEMENTATION_PLAN.md` remain normative for the shipped v1 engine. Nothing
> here retracts v1.

## 1. Situation

Two facts should drive the decision:

1. **The critique does not touch the engine.** It reviews a pooled-ETH-across-LST-ARMs
   product (Origin ARM / Mintly / Valantis STEX comparables). That is a *different*
   Reservoir from the one in this repo, which is an Aqua/SwapVM maker that keeps
   inventory in ERC-4626 vaults and materializes exact output just-in-time at
   settlement. Every one of the seven points attacks the application/narrative layer.
   The critic scored technical impressiveness **8/10**.
2. **The engine is already built, tested, and independently reviewed.**
   `ReservoirSwapVMRouter`, `ReserveClamp` (opcode `0x92`), `ReservoirMakerAccount`,
   `ERC4626ReserveAdapter`, plus unit/integration/invariant/fork suites, the
   `ReserveOpcodeSpike`, gas-isolation tests, and a `MaliciousTaker` harness.

So this is not a rewrite. It is: **keep the engine, replace the story, add the layer
that makes the story defensible.**

## 2. Verdict on the Reservoir v2 direction

**Adopt the boundary. Reject the framing.**

What it gets right — it fixes four of the seven criticisms structurally rather than
rhetorically:

| Criticism | How Reservoir v2 answers it |
|---|---|
| #2 Three conflated products | Commits to one: a settlement layer for claim-for-liquidity exchange. |
| #3 Pooling gain may be illusory | No pooled reserve at all. **The VaR simulation go/no-go dissolves — you no longer owe it.** |
| #4 Isolation is a feature | Per-intent isolated accounting; no socialization between claims. |
| #7 "Intent-native" adds nothing | *Manufacturing* a claim atomically inside settlement genuinely cannot be expressed as a CoW/1inch swap. First version where the intent framing isn't garnish. |

Two corrections:

- **Do not call it a VM.** This repo already contains a real VM (SwapVM). A second
  "VM" that the proposal itself says is "a typed state machine rather than arbitrary
  bytecode" is a naming own-goal that invites the "generic intents framework with no
  real application" review.
- **The proposal half-sees its own best idea.** See §3.

## 3. The sharpened primitive

Neither adapter carries the claim alone:

- ERC-8161 already standardizes transferability, and no suitable production
  deployment is currently in scope.
- Lido Originate is real and useful, but its economics overlap existing instant
  exits and ARMs. It is not an always-on alternative to selling stETH.
- Selling an existing `unstETH` is ordinary ERC-721 exchange and is stretch.

The defensible technical claim is therefore correctness under a race:

> **A fixed-payment fill succeeds only after every quoted claim unit is secured,
> even if one asynchronous request is partly Pending and partly Claimable when
> settlement executes.**

The ERC-7540/8161 reference path demonstrates the standards-hard state race.
Lido Originate demonstrates that the same kernel can bind to an unmodified
production protocol. Productive reserves are load-bearing because episodic
demand would otherwise leave factor capital idle between rare fills.

## 4. Naming

- **Reservoir v1** — the shipped Aqua/SwapVM reserve engine.
- **Reservoir v2** — the asynchronous-claim settlement application that reuses
  v1's ERC-4626 funding adapter.

There is no secondary product name. `V1_SCOPE.md`, `SPEC.md`, and
`IMPLEMENTATION_PLAN.md` remain valid for v1; `V2_SCOPE.md` and
`V2_IMPLEMENTATION_PLAN.md` govern v2.

## 5. Why the engine is the right foundation (not sunk cost)

The critic's point #5 — *idle lending conflicts with instant liquidity; you need
explicit hot/warm/encumbered tiers* — is the objection that sinks most "idle capital
earns yield" pitches. **You have already specified, built, and tested the answer.**
`SPEC.md` §4.1:

```
safeAvailable = (idle + vault.maxWithdraw) − liquidityBufferAssets
canDeliver    = min(wanted, safeAvailable)
```

That is hot ETH + warm ETH − emergency reserve, with a hard clamp, honest partial
fills when capacity binds, and a `maxWithdraw`-reverts-safely path for exactly the
lending-stress scenario raised. Shipped with boundary tests.

The reserve adapter generalizes directly; the Aqua hook path does not:

| Reservoir v1 | Reservoir v2 |
|---|---|
| `ERC4626ReserveAdapter.availableFor` | fill-or-kill payment-capacity check |
| exact `materialize` into the maker account | exact materialization into a dedicated funding account |
| Aqua ERC-20 settlement | separate claim kernel: originate/acquire claim, then pay seller |

The v1 router, clamp, and sealed maker account remain unchanged. Claims are
whole-position, settlement-critical objects; they should not inherit Aqua's
ERC-20 partial-fill or best-effort-reinvestment semantics.

## 6. Current recommended scope

`V2_IMPLEMENTATION_PLAN.md` is the checkable build plan. The hard cut is:

1. A signed, seller-initiated, fixed-payment claim settlement kernel.
2. A productive WETH funding account using the shipped ERC-4626 adapter.
3. A nonzero-ID ERC-7540/8161 reference proof that handles Pending and
   Claimable simultaneously and fuzzes every constant-total split.
4. Lido Originate as the live production application.
5. One deterministic local demo, a minimal frontend, one pinned Lido fork
   proof, and an independent final review.

### Lanes

| Lane | Owns | Deliverable |
|---|---|---|
| **K — Kernel** | settlement kernel, escrow, claim lifecycle, per-intent isolated accounting | The universal invariant: *fill reverts unless the user's minimum immediate output is satisfied **and** the solver's future claim is irrevocably secured.* Knows nothing about Lido/Aave/bridges. |
| **E — ERC standards** | strict reference vault and `IERC7540RedeemTransferable` adapter | Prove the two-leg Pending transfer plus Claimable redemption path and total-unit binding. |
| **L — Lido** | Originate hard cut and fork fixture | Manufacture a live Lido claim directly for the factor and settle WETH payment atomically. |
| **F — Funding** | dedicated account bound to `ERC4626ReserveAdapter` | Factor WETH remains productive until acquisition succeeds; no pooling or Aqua strategy. |
| **V — Verification & demo** | invariants, fork fixtures, terminal demo, minimal frontend, pitch narrative | Owns `docs/`; integrator alone folds into `README.md`. |

### Flagship demo (the one that must work)

Factor WETH starts entirely in ERC-4626 shares. The factor signs while a
reference request is `100 Pending / 0 Claimable`. Before fill, the request
becomes `60 Pending / 40 Claimable`:

```
transfer remaining Pending + redeem Claimable
  → prove both measured factor-side deltas
  → materialize exact WETH
  → pay seller
  → revoke operator and prove reuse fails
```

The pinned fork then originates a real Lido request directly for the factor.
Its job is production credibility, not a claim that Lido factoring always beats
CoW.

### Gates

- **Gate 0** — standards and Lido mechanism spikes; freeze interfaces.
- **Gate 1** — local kernel and productive funding.
- **Gate 2** — ERC-7540/8161 standards vertical slice.
- **Gate 3** — Lido Originate application.
- **Gate 4** — demo, minimal frontend, and submission package.
- **Gate 5** — independent Claude Opus 5 review.

## 7. Anti-scope

Guard against the failure mode the proposal walks into: answering "not differentiated"
with "build a bigger platform." Surface area is not defensibility.

- **Conditional / health-factor rescue** → after Gate 4 at the earliest, first to cut. It adds
  keeper + oracle + signed-intent replay surface, and it is where *"isn't this DeFi
  Saver / Breakglass?"* bites hardest.
- **RFQ / solver auction** → a single solver is fine for a demo. Cut early.
- **A third claim family** (bridges) → narrative only unless Gates 0–4 are green.
- **Any pooled reserve or cross-claim socialization** → reintroduces every one of
  criticisms #3–#5. Isolated books only.

## 8. Claims to verify, not market

1. The reference fixture conforms to the Final ERC-7540/8161 semantics it
   demonstrates. It is not described as a production integration.
2. The Lido fork transaction executes against the canonical queue without
   impersonating its finalizer. It is production evidence, not a forecast of
   constant demand.
3. The supplied backtest is described as reported and assumption-sensitive.
   Its robust result is episodic opportunity; productive reserves improve
   standby utilization, not post-fill underwriting.

## 9. The pitch

> **Reservoir v2 settles asynchronous withdrawal claims fill-or-kill: the seller
> is paid now only if every quoted claim unit is secured in the same transaction,
> correctly across the Pending/Claimable race, while standby capital stays
> productive until fill.**

One kernel, isolated per-claim accounting, no pooled solvency, and a shipped
just-in-time liquidity engine underneath.

## 10. Scorecard delta

| Axis | Before | Target | Why |
|---|---|---|---|
| Technical distinction | 4/10 | 7–8 | Correct mixed-state acquisition and payment-if-and-only-if-acquisition are the defensible claims. |
| Defensibility | 2/10 | 6–7 | Isolated books; no pooling to socialize; kernel is necessary, not decorative. |
| Usefulness | 6/10 | 7–8 | One kernel gives factors a safe fixed-price execution path across heterogeneous asynchronous claims. |
| Technical | 8/10 | 8–9 | Retains the reviewed engine and adds a claim state machine. |
| "Origin ARM but pooled" risk | very high | **eliminated** | There is no pool. |
