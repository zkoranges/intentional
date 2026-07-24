# Reservoir — reviewer findings

> Companion to `REVIEW.md`. `REVIEW.md` records the *original design review* whose
> corrections are already folded into `SPEC.md`. This file records the
> evidence-backed disposition of the second review against `SPEC.md` +
> `IMPLEMENTATION_PLAN.md`.
>
> Scope: the repo currently contains only planning docs (no Solidity). This is a
> plan/spec coherence + feasibility review, plus verification of the upstream API
> assumptions the design depends on.
>
> Verification method: the upstream claims were checked against the actual source at
> the pinned commits — SwapVM `0817db4a618d975648e018222aedcdeb1206959e` and
> Aqua `7a5972a6b562e3e622f6e6b2a0befef659cd5386` — not trusted from prose.
>
> This file is the auditable findings trail. Resolved requirements have been
> incorporated into `V1_SCOPE.md`, `SPEC.md`, and `IMPLEMENTATION_PLAN.md`;
> those three files are normative for v1.

## Status legend

- `RESOLVED` — confirmed and folded into the normative docs.
- `RESOLVED-PARTIAL` — a valid core concern was fixed, but part of the claim or
  proposed remedy was inaccurate.
- `REJECTED` — the claimed defect is false and no substantive new requirement
  was adopted; explanatory wording may still be clarified.
- `VERIFIED-OK` — upstream/spec claim checked and found accurate (no action).

---

## 0. Upstream claims verified accurate (VERIFIED-OK)

These are the load-bearing source assumptions the design rests on. All are
confirmed against the pinned source. They justify the Gate 0 mechanism spike;
they do not replace executing it.

| # | Claim (SPEC/REVIEW) | Evidence at the pin |
|---|---|---|
| V1 | `0x92`/`Opcode._92` is the first free "balance-tuning" slot, not in reserved `0xf0–0xff` | `src/libs/OpcodeList.sol`: bank `0x90–0xaf` = "Balances tuning"; `90 StaticBalances`, `91 DynamicBalances`, `92 _92` (free), `94 DutchAuctionBalanceIn`… Reserved bank is `0xf0–0xff`. |
| V2 | Override virtual `_runOpcode`; `AquaSwapVMRouter._dispatch` is not virtual | `src/opcodes/AquaOpcodes.sol`: `function _runOpcode(...) internal virtual`. `src/routers/AquaSwapVMRouter.sol`: `function _dispatch(...) internal override { _runOpcode(ctx, opcode, args); }` — `override`, not `virtual` (sealed). |
| V3 | `FlatFeeAmountOut` is not dispatched by `AquaOpcodes` | `AquaOpcodes._runOpcode` has no `FlatFeeAmountOut` branch. (It *is* enum `0x80` and *is* dispatched by base `src/opcodes/Opcodes.sol` via `FeeExperimental._flatFeeAmountOutXD` — see finding m5.) |
| V4 | Instruction name is `XYCSwap` / `_xycSwapXD` | `src/instructions/XYCSwap.sol`: `function _xycSwapXD(Context memory ctx, bytes calldata) internal pure`. |
| V5 | XYCSwap tail is re-runnable / "pure" w.r.t. balances | `_xycSwapXD` is `internal pure`, writes only `ctx.swap.amountOut` (exact-in) or `ctx.swap.amountIn` (exact-out); never mutates `balanceIn`/`balanceOut`. |
| V6 | Wrapper-before-curve calling `ctx.runLoop()` is the real pattern | `src/instructions/FeeExperimental.sol` `_progressiveFeeOutXD`/`_progressiveFeeInXD`: adjust register → `ctx.runLoop()` → adjust register. `src/libs/VM.sol` `runLoop(Context)` loops `ctx.vm.nextPC`→end dispatching; `setNextPC(ctx, pc)` exists for a re-run. |
| V7 | `IMakerHooks` hook set/signatures | `src/interfaces/IMakerHooks.sol`: `preTransferIn/postTransferIn/preTransferOut/postTransferOut(address maker, address taker, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, bytes32 orderHash, bytes makerData, bytes takerData)`. |
| V8 | `Aqua.ship` signature/return + `pull`/`push` shapes | Aqua `src/interfaces/IAqua.sol`: `ship(address app, bytes strategy, address[] tokens, uint256[] amounts) returns (bytes32 strategyHash)`; `pull(maker, strategyHash, token, amount, to)`; `push(maker, app, strategyHash, token, amount)`. |
| V9 | XYC domain guard / singularity | `_xycSwapXD` requires `balanceIn>0 && balanceOut>0` (`XYCSwapRequiresBothBalancesNonZero`); exact-out divisor `balanceOut - amountOut` needs `amountOut ≤ balanceOut-1` ⇒ SPEC `curveMaxOut = balanceOut-1` is correct; exact-in floors output, exact-out `ceilDiv` rounds input up — matches SPEC rounding rules. |
| V10 | The pinned public quote/swap path permits a smaller actual partial fill | `src/libs/TakerTraits.sol` uses `takerAmount >= amountIn` for exact-in and `takerAmount >= amountOut` for exact-out. This is load-bearing: later source changed these checks to equality, so the dependency cannot be floated. |

**Verdict from §0: the mechanism is source-feasible against the pin.** The
findings below de-risk sequencing and turn implicit guarantees into asserted
ones.

---

## 1. Originally reported blockers

### B1 — Gate 0 freezes the novel VM mechanism without ever executing it
- **Status:** RESOLVED
- **Affected:** `IMPLEMENTATION_PLAN.md` §4 (Gate 0 tasks + acceptance), §5 Agent A.
- **Claim:** Gate 0 acceptance is only `forge test --match-test VanillaAqua`. That test
  exercises none of the three riskiest, most novel pieces that all of Wave-1 Agent A
  builds on: the `0x92` `_runOpcode` override, the wrapper's `ctx.runLoop()` call, and
  the two-pass exact-in mode-flip re-run (`setNextPC` reset + second `runLoop`).
- **Evidence:** Vanilla Aqua uses only stock opcodes; nothing in the vanilla path invokes
  a subclass `_runOpcode` override or a double `runLoop`. Confirmed feasible at the pin
  (V2/V5/V6), but feasible ≠ demonstrated.
- **Proposed correction:** Add a Gate 0 spike test: a minimal `ReservoirSwapVMRouter`
  handling `0x92`, wrapping one `XYCSwap` via `runLoop`, plus one binding exact-in case
  that resets `nextPC` to `tailPC` and re-runs the tail as exact-out. Make it a Gate 0
  acceptance gate before agents fan out.
- **Disposition:** Confirmed and adopted as the deliberately small Gate 0
  `ReserveOpcodeSpike`. It exercises the public `asView().quote` path as well as
  dispatch, nested `runLoop`, the two-pass transition, and V10's exact-in
  partial-fill taker validation before production architecture is frozen.

### B2 — `REINVEST_GAS_CAP` is frozen before real-vault deposit gas is known
- **Status:** RESOLVED
- **Affected:** `IMPLEMENTATION_PLAN.md` §4.6 (freeze) & §5 Agent C tasks; `SPEC.md` §5, §7 step 6.
- **Claim:** The reinvest gas constants are frozen at Gate 0, but a real Aave
  StataTokenV2 / Morpho V1 `deposit` costs well over 100k gas. If the cap is too low the
  happy-path reinvest silently fails on every fork swap (emits `ReinvestFailed`). The
  "non-fatal reinvest" tests still pass, so nothing catches it — while the demo's headline
  claim "input is reinvested after settlement" (SPEC §7.6, REVIEW §6) is quietly false.
- **Evidence:** Agent C wave-1 tasks record `maxWithdraw/maxDeposit/previewDeposit`
  (PLAN §5 Agent C) but not deposit gas; the cap is frozen in Gate 0 which runs before
  Agent C. Real lending-vault deposits are 100k–250k gas.
- **Proposed correction:** Freeze only the reserve/overhead *accounting scheme* at Gate 0;
  make the numeric `REINVEST_GAS_CAP` a per-adapter value set from a measured
  deposit-gas + margin. Add a positive fork assertion that the happy path emits
  `Reinvested`, not `ReinvestFailed`.
- **Disposition:** Confirmed. Pinned-fork direct vault deposits measured roughly
  224k gas on repeat for Stata USDC and 538k for MetaMorpho USDT, before the
  adapter's transfer/approval overhead; exact values remain fixture-dependent.
  The reviewer's generic “100k–250k” estimate was therefore too low for
  Morpho, strengthening the sequencing concern rather than serving as accepted
  evidence.
  The docs now freeze only the bounded-call scheme at Gate 0, seal a measured
  per-asset gas limit later, and require positive physical-delta/event
  assertions for each real path. The maker success event is named
  `ReinvestSucceeded`, as explained under m2.

---

## 2. Major

### M1 — `amountIn ≤ requestedIn` is never asserted as a property
- **Status:** RESOLVED-PARTIAL
- **Affected:** `SPEC.md` §6.4, §9 (properties table), §10.3; E2E §10.4.
- **Claim:** The spec only states "never charge the full input for a clipped output." The
  security-relevant invariant is stronger: in binding exact-in, the recomputed input must
  never *exceed* what the taker offered.
- **Evidence:** In the binding branch the clamped output is strictly `< candidateOut`, and
  the exact-out re-inversion uses `ceilDiv` (XYCSwap.sol). It should hold, but it is not
  written as an asserted invariant anywhere.
- **Proposed correction:** Add `recomputed amountIn ≤ requestedIn` to the §9 table and as
  an explicit assertion in §10.3 instruction tests and the E2E suite.
- **Disposition:** The inequality is confirmed and is now explicit throughout
  the spec, plan, instruction tests, invariants, and E2E gate. The report's
  description of it as “stronger” was backwards: the old strict claim “never
  charge the full input” was itself false on integer plateaus. For example,
  reserves `(1,100)`, requested input `1`, candidate output `50`, and cap `49`
  still inverse to input `1`. The universal rule is `actualInput <=
  requestedInput`; strict `<` is required only of the economic-size hero
  fixture.

### M2 — Two-pass clamp silently depends on `XYCSwapRecomputeDetected` internals
- **Status:** RESOLVED
- **Affected:** `SPEC.md` §6.4 (frozen partial-fill algorithm).
- **Claim:** The re-run works *only* because exact-in guards `amountOut==0` and exact-out
  guards `amountIn==0`, and the wrapper zeroes exactly `amountIn` before the exact-out
  pass. The spec never names this guard and doesn't enumerate the full set of ctx fields
  the wrapper must snapshot/restore between passes.
- **Evidence:** `XYCSwap.sol`: exact-in `require(ctx.swap.amountOut == 0, XYCSwapRecomputeDetected())`;
  exact-out `require(ctx.swap.amountIn == 0, XYCSwapRecomputeDetected())`. The two-pass
  sequence must manage `isExactIn`, `ctx.vm.nextPC`, `amountIn`, `amountOut` precisely.
- **Proposed correction:** Document the guard semantics in §6.4; enumerate the exact
  snapshot/restore set (`isExactIn`, `nextPC`, `amountIn`, `amountOut`); add a regression
  test. Note this is a concrete reason the pin matters — a future guard that also checked
  `amountOut` in exact-out mode would break the algorithm.
- **Disposition:** Confirmed, with one precision correction. The docs now
  specify the exact transition and a guard-regression test. Only the original
  exact-in flag is restored; final `amountIn`/`amountOut` and the consumed
  end-of-program `nextPC` are deliberately retained. All unrelated context
  fields must remain unchanged.

### M3 — "Explicit rounding tolerance" is never quantified
- **Status:** RESOLVED-PARTIAL
- **Affected:** `SPEC.md` §9 (non-binding symmetry); `REVIEW.md` §4.
- **Claim:** Symmetry is required "within explicit rounding tolerance" but no numeric bound
  is given, so the property is untestable as written.
- **Evidence:** exact-in floors output (`/`), exact-out ceils input (`Math.ceilDiv`) in
  XYCSwap.sol — the round-trip error is bounded and derivable.
- **Proposed correction:** State the actual bound (e.g. exact-in→exact-out returns original
  input within a stated ≤1-unit ceil error under these formulas) and assert it.
- **Disposition:** The unquantified property was a real defect, but the suggested
  universal one-unit bound is false. The normative property is now exact and
  data-dependent: for `b = F(a) > 0`, `G(b)` is the least integer input
  reproducing `b`, so `G(b) <= a`, `F(G(b)) == b`, and
  `F(G(b)-1) < b` when `G(b)>0`. The committed balanced smoke matrix has an
  explicit zero-unit tolerance; wider fuzzing asserts the formula rather than
  inventing a universal constant.

### M4 — Reentrancy / taker-callback safety is claimed but its basis is unstated
- **Status:** RESOLVED
- **Affected:** `SPEC.md` §6.3, §10.2; §7 (traits).
- **Claim:** SPEC §10.2 tests "reentrancy and taker callbacks cannot create a
  quote/materialization gap," but the demo taker traits *disable* callbacks (§7) and the
  maker hooks don't validate taker callback traits — a non-demo taker could enable them.
  The output-first flag is keyed by `orderHash` only, so same-order reentrancy would
  set/clear the same key.
- **Evidence:** `IMakerHooks` receives `takerData` but the spec's hook validation (§5)
  checks router/maker/orderHash/pair/adapter — not taker callback selection.
- **Proposed correction:** State whether the guarantee rests on Aqua's own reentrancy
  guard, on maker-side rejection of callback traits, or on the flag scheme — and test the
  adversarial path (malicious taker enabling callbacks), not just the disabled-callback
  demo. Acceptable to explicitly scope-cut with documentation, but not to test-around it.
- **Disposition:** Confirmed. The basis is the pinned SwapVM router's
  order-hash lock, plus the maker's single accepted strategy hash and its
  transfer-order flag—not an Aqua lock and not disabled callbacks. The spec now
  requires caught/propagated same-order nested-swap tests, proves a
  different-order nested swap cannot materialize (normally Aqua rejects its
  inactive strategy before hooks), and separately tests wrong-hash hook
  authorization. `quote` is unlocked; tests use the interface-view
  `asView().quote` static-call path, which cannot materialize inventory.

### M5 — Mock-resolver ownership gap blocks Agent A's own unit gate
- **Status:** REJECTED
- **Affected:** `IMPLEMENTATION_PLAN.md` §5 (Agent A owns `test/unit/instructions/`,
  Agent B owns `test/mocks/`; integrator merges B after A's unit work).
- **Claim:** Agent A must unit-test `ReserveClampAndFee` in isolation, which needs a mock
  `IAquaReserveResolver` (`availableFor`), but that lives in Agent B's `test/mocks/` and B
  merges later.
- **Proposed correction:** Assign Agent A its own resolver stub under
  `test/unit/instructions/`, or provide a shared minimal resolver mock at Gate 0.
- **Disposition:** No ownership gap existed: Agent A already owns
  `test/unit/instructions/` and can declare an in-file or local resolver double;
  `test/mocks/` is not the exclusive home of every test double. The plan now
  states this explicitly, but no shared Gate 0 mock or sequencing dependency was
  added.

---

## 3. Minor

### m1 — Deadline opcode vs. taker `deadline` trait
- **Status:** REJECTED — **Affected:** `SPEC.md` §6.2, §7.
- Program is `[Deadline?]…`; demo sets a finite `deadline`. `Controls._deadline` *is*
  dispatched by `AquaOpcodes`, but if enforcement requires the opcode's presence, the demo
  program must include it, else the finite deadline is silently unenforced. Clarify.
- **Disposition:** The claimed enforcement gap is false. At the pin,
  `TakerTraitsLib.validate` independently enforces the taker's finite deadline.
  The program `Deadline` is a separate maker-selected strategy expiry. `SPEC.md`
  now clarifies the distinction; the demo does not need the opcode merely to
  enforce taker expiry.

### m2 — `Reinvested` event amount can't come from the `outSize=0` call
- **Status:** RESOLVED-PARTIAL — **Affected:** `SPEC.md` §5.
- The zero-returndata call cannot return `delivered`; the event amount must be a
  `balanceOf` delta measured inside the post-hook budget. State this and include the extra
  SLOAD in the reserve accounting.
- **Disposition:** Zero return bytes indeed cannot supply an amount, but a
  maker-side balance delta is not required and would add external calls, not
  merely one SLOAD. The maker now emits amount-less `ReinvestSucceeded`; the
  adapter emits assets/shares and the ERC-4626 vault emits `Deposit`. Tests
  reconcile those with physical deltas.

### m3 — Pin `evm_version = cancun` / `solc 0.8.30` at Gate 0
- **Status:** RESOLVED — **Affected:** `IMPLEMENTATION_PLAN.md` §4 Gate 0.
- The output-first flag uses transient storage; the *local* PoC needs it too, and it's not
  in the Gate 0 task list. Upstream is `pragma solidity 0.8.30`.
- **Disposition:** Confirmed as a reproducibility requirement. Gate 0 now pins
  Foundry and Solidity 0.8.30 and explicitly targets Cancun. Cancun is not the
  only valid target—any later EVM with transient storage also works—but an
  explicit target and transient-lock smoke are required.

### m4 — Fork fixtures pinned to exact wei / addresses
- **Status:** RESOLVED — **Affected:** `SPEC.md` §11.
- `maxWithdraw == 17_249_152_905_331` requires a correct archive node at block 25,604,561.
  Runtime code+`asset()` assertions are good; add a documented RPC/archive requirement and
  a clear failure message, and independently re-verify the StataTokenV2 (`0xD4fa…`) and
  aUSDC (`0x98C2…`) addresses (USDC/USDT/Aave-Pool check out).
- **Disposition:** Confirmed. The archive requirement, exact block hash, and
  clear preflight failure are now normative. At the pin, Stata reports USDC as
  `asset()` and the listed aUSDC as `aToken()`; aUSDC reports USDC and the
  listed Aave Pool. Morpho `maxWithdraw` was independently reproduced exactly.

### m5 — Wording: `FlatFeeAmountOut` "not dispatched"
- **Status:** RESOLVED-PARTIAL — **Affected:** `SPEC.md` §6.2; `REVIEW.md` §1.
- It *is* defined (enum `0x80`) and dispatched by base `Opcodes`; only `AquaOpcodes` omits
  it. Say "not in the `AquaOpcodes` dispatcher used by the Aqua router" so an implementer
  who greps and finds `_flatFeeAmountOutXD` isn't confused.
- **Disposition:** The existing wording already qualified the claim with
  `AquaOpcodes`, so it was not substantively wrong. The more explicit wording
  was adopted for grep-level clarity.

---

## 4. Nits / coherence

- **n1 — RESOLVED.** `SPEC.md` now identifies aUSDC as reference/internal
  wiring only. The adapter vault is StataTokenV2, the maker owns non-rebasing
  Stata shares, and `asset()` is non-rebasing USDC. It does not incorrectly
  describe aUSDC itself as non-rebasing.
- **n2 — RESOLVED.** The equivalence
  `min(N, min(G,A)) == min(N,A)` for `N <= G` is documented, together with its
  amount-independent-fee assumption. Economic fee code has also been cut from
  the hackathon path.
- **n3 — RESOLVED-PARTIAL.** The plan marks both protocol-named wrappers
  optional and forbids empty wrappers. Two compatible vault deployments may use
  the generic adapter; a named specialization must add behavior proven
  necessary by tests.
- **n4 — RESOLVED-PARTIAL.** Explicit `runs`, `depth`, and timeout now bound the
  CI campaign; those settings alone do not make randomness deterministic. The
  gating command therefore also fixes the seed and pins the Foundry toolchain.

---

## 5. Validation outcome

All 16 findings are dispositioned:

- 8 confirmed and resolved;
- 6 partially confirmed and resolved with corrected remedies; and
- 2 rejected false positives (`M5`, `m1`).

The implementation order is now: minimal novel-mechanism spike, deterministic
exact-in hero slice, one real Aave path, six-number demo, then optional Morpho.
`SPEC.md` and `IMPLEMENTATION_PLAN.md` are normative; this file remains the
auditable review trail.
