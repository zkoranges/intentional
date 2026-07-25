# V2 plan — reviewer findings

> Review of `V2_IMPLEMENTATION_PLAN.md`. Companion to `REVIEW_FINDINGS.md` (v1).
>
> Verification method: every load-bearing external claim was checked against the
> primary source — the ERC texts in `ethereum/ERCs`, Lido's contract documentation,
> and Lido's deployed-contracts registry — not accepted from prose. Fork-state claims
> originally required archive-RPC revalidation. They have since been executed
> at the exact block/hash pin and are recorded in `docs/V2_FORK_REALISM.md`;
> this historical plan review is not itself that runtime evidence.

## Status legend

- `VERIFIED-OK` — claim checked against primary source and found accurate.
- `OPEN` — confirmed gap or defect, not yet addressed.
- `RESOLVED` — confirmed and folded into the plan/direction.
- `RESOLVED-PARTIAL` — valid core concern fixed with an overstatement corrected.
- `UNVERIFIED` — requires archive RPC; correctly deferred by the plan.

---

## 0. Verified claims

The plan's standards work is unusually accurate. Everything below was confirmed:

| # | Claim | Source evidence |
|---|---|---|
| W1 | ERC-8161 exists and is **Final** | `ERCS/erc-8161.md`: "Transferable Tokenized Vault Requests", `status: Final`, `created: 2025-02-12`, `requires: 165, 7540`. |
| W2 | ERC-8161 transfers the **entire** Pending balance and must not touch Claimable | "Transfers the entire pending Request balance from `oldController` to `newController`… **MUST only transfer the Pending balance. Claimable balances MUST NOT be affected.**" |
| W3 | ERC-8161 permits transfer fees and returns no amount | "…MUST increase by the same amount (**less any fees**)." `transferRedeemRequest` declares no outputs. |
| W4 | ERC-8161 authorization is controller-or-operator | "`msg.sender` MUST be `oldController` or an operator approved by `oldController`." |
| W5 | ERC-8161 redeem interface ID `0x7846f5bd` | "Vaults implementing `IERC7540RedeemTransferable` MUST return… `true` when `0x7846f5bd`". **Exact match.** |
| W6 | ERC-7540 async-redeem interface ID `0x620ee8e4` | "Asynchronous redemption Vaults MUST return… `true` if `0x620ee8e4`". **Exact match.** |
| W7 | `requestId == 0` aggregates per controller | ERC-7540 §Request Ids: "the Vault MUST use purely the `controller` to discriminate the request state. The Pending and Claimable state of multiple requests from the same `controller` would be aggregated." **The plan's rejection is well-founded.** |
| W8 | Pending and Claimable coexist (partial claimability) | ERC-7540: "If a Request with `requestId != 0` becomes partially claimable, all requests of the same `requestId` MUST become claimable at the same pro-rata rate." **Confirms the two-leg design; an `if/else` would be wrong.** |
| W9 | Async preview methods must revert | ERC-7540: "`previewRedeem` and `previewWithdraw` MUST revert for all callers and inputs." |
| W10 | Lido bounds: 100 wei min, 1000 ETH max | Lido docs: "The minimal amount for a request is 100 wei, and the maximum is 1000 eth." |
| W11 | `WithdrawalRequestStatus` fields | `{amountOfStETH, amountOfShares, owner, timestamp, isFinalized, isClaimed}` — exactly the fields §6.1 step 6 validates. |
| W12 | Finalized `unstETH` stays transferable until claimed | "Once claimed, NFT is burned"; transfer requires "request must not be claimed." |
| W13 | Lido function surface | `requestWithdrawals`, `getWithdrawalStatus`, `claimWithdrawalsTo`, `findCheckpointHints`, `getLastCheckpointIndex` all exist as used. |
| W14 | Canonical addresses | Lido deployed-contracts: `Withdrawal Queue ERC721: 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1 (proxy)`; stETH `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`. |

**Verdict: the plan is buildable and its standards reading is correct.** The findings
below are about where the *novelty weight* sits, plus one concrete implementation defect.

---

## 1. Major — strategic

### F1 — Rejecting `requestId == 0` excludes the modal ERC-7540 vault
- **Status:** RESOLVED-PARTIAL
- **Affected:** plan §5.1, §14 (known limitations), and the framing in §1.
- **Claim:** §5.1's rejection of `requestId == 0` is technically correct and safe (W7).
  But ERC-7540's own Rationale states: *"Certain Vaults, **especially `requestId==0`
  cases**, benefit from using the underlying ERC-4626 methods for claiming because there
  is no discrimination at the `requestId` level. **This standard is written primarily
  with those use cases in mind.** A future standard can optimize for nonzero request ID
  with support for claiming and transferring requests discriminated also with a
  `requestId`."*
- **Consequence:** The generic adapter's addressable set is `nonzero-requestId` **AND**
  `ERC-8161-supporting` vaults. The plan already concedes no production ERC-8161 vault
  may exist (§14). Together, the "generic standards hero" is a demo against a reference
  vault that resembles very little deployed today. That is defensible *as a
  standards-conformance proof*, but it cannot carry the novelty claim.
- **Proposed correction:** State this explicitly in §14 rather than only "adoption may
  be limited" — the limitation is structural, not just adoption timing. Reweight §1 so
  the Lido Originate path is named the primary proof and ERC-8161 is named the
  generality proof. §13 already makes Originate the hard cut, which is the right
  instinct; the framing should match.
- **Disposition:** The structural limitation is confirmed and explicit in
  `V2_SCOPE.md`. Later market evidence and an independent pre-scope Opus 5
  review refined the presentation: neither a reference-only ERC-8161 adapter
  nor Lido Originate carries the product claim alone. The kernel invariant
  leads; ERC-8161 is the standards-hard proof and Lido is the production-hard
  proof. The title's word “modal” was not adopted as a deployed-market fact:
  the ERC rationale establishes ID zero as a primary design center, not
  empirical prevalence across live vaults.

### F2 — ERC-8161 being Final changes the novelty thesis (corrects my own prior advice)
- **Status:** RESOLVED
- **Affected:** `DIRECTION.md` §3, plan §1.
- **Claim:** `DIRECTION.md` argued the defensible primitive was *"claims that cannot be
  sold because they are not transferable,"* citing ERC-7540 requests as structurally
  non-transferable. **ERC-8161 is Final and standardizes exactly that transferability.**
  So "you cannot transfer a 7540 request" is now only true for non-8161 vaults.
- **Consequence:** The 8161 adapter's honest positioning is *early integrator of a Final
  standard* — timely and credible, but not a new primitive. The remaining genuinely
  unserved capability is **origination**: manufacturing a claim that does not yet exist
  and selling it atomically in the same transaction. That is the Lido Originate path.
- **Proposed correction:** Update `DIRECTION.md` §3 to drop the non-transferability
  argument and rest defensibility on origination. Lead every judge-facing artifact with
  Originate. Keep ERC-8161 as the generality/standards story.
- **Disposition:** Confirmed. `DIRECTION.md` treats ERC-8161 transferability as
  standardized. Subsequent commercial evidence showed that Lido Originate is
  also too thin to carry the identity by itself. `V2_SCOPE.md` therefore leads
  with payment-if-and-only-if-acquisition across the mixed-state race, with
  Lido Originate retained as mandatory live-protocol evidence.

---

## 2. Major — correctness

### F3 — stETH transfer rounding will break "pull exact stETH"
- **Status:** RESOLVED
- **Affected:** plan §6.1 steps 1, 6, 7; Lido test matrix §12.
- **Claim:** §6.1 step 1 says "Pull exact stETH from seller with `SafeERC20`", and step 6
  requires `amountOfStETH` to equal the acquired amount. stETH is a rebasing,
  share-accounted token: `transfer`/`transferFrom` convert through shares and are
  documented to deliver up to **1–2 wei less** than the requested amount. A `transferFrom`
  of exactly `N` can leave the adapter holding `N-1`.
- **Failure scenario:** Adapter pulls `N`, receives `N-1`, then calls
  `requestWithdrawals([N], ...)` → reverts on insufficient balance. Or it requests `N-1`
  and the step-6 equality check against the signed `N` fails. Either way the flagship
  path reverts nondeterministically, on mainnet fork, in the demo.
- **Proposed correction:** Measure the **received balance delta** and request on the
  measured amount, never the requested amount. Bind the economics with the
  `amountOfShares` floor (which the plan already has, and which is rebase-invariant —
  good design) plus an explicit `maxStETHShortfall` tolerance of a few wei. Add a test
  with a 1–2 wei short transfer. Also confirm the measured amount still clears the
  100-wei minimum (W10) at small sizes.
- **Disposition:** Confirmed against Lido's integration guide. §6.1 now measures
  `receivedStETH`, enforces a signed maximum shortfall, rechecks request bounds,
  requests only the measured amount, and reconciles status against that amount.
  Gate 0 and the Lido test matrix now cover one/two-wei rounding, excessive
  shortfall, and rounding below the minimum.

---

## 3. Minor

### F4 — Missing ERC-165 check for the operator interface
- **Status:** RESOLVED — **Affected:** plan §5.1 preconditions.
- §5.1 checks `0x620ee8e4` (async redeem) and `0x7846f5bd` (8161 redeem transfer). But
  ERC-7540 mandates that *all* async vaults return true for `0xe3bc4e65` (the operator
  methods) or `0x2f0a18c5` (ERC-7575). The adapter's entire authorization model depends
  on operator methods (`setOperator`/`isOperator`), so verify `0xe3bc4e65` explicitly.
  Since §5.1 also checks ERC-7575 `share()`, check `0x2f0a18c5` alongside it.
- **Disposition:** Both checks are now explicit preconditions.

### F5 — Interface naming diverges from the standard
- **Status:** RESOLVED — **Affected:** plan §9 layout.
- ERC-8161 names its interfaces **`IERC7540DepositTransferable`** and
  **`IERC7540RedeemTransferable`** (ERC-7540 prefix, not 8161). The layout uses
  `IERC8161RedeemTransferable.sol`. Cosmetic, but it costs greppability against the
  standard and will read as an error to a reviewer who knows the ERC.
- **Disposition:** The proposed file now uses the standard's
  `IERC7540RedeemTransferable` name.

### F6 — "Immutable binding" to a proxy
- **Status:** RESOLVED — **Affected:** plan §6 opening.
- `WithdrawalQueueERC721` is a **proxy** (W14). Binding immutably and checking runtime
  code pins the *proxy*, whose implementation can change. Harmless on a pinned fork;
  state it in §14 next to the other Lido risk acceptances rather than implying the
  binding freezes behavior.
- **Disposition:** §6 now distinguishes an immutable proxy endpoint from mutable
  implementation behavior, and §14 records proxy upgrade risk explicitly.

---

## 4. Deferred (correctly)

| Item | Status |
|---|---|
| Block `25,604,561` / hash `0x95ca77…7888d` | UNVERIFIED — needs archive RPC. |
| `unstETH` IDs `130816` (pending), `130808` (finalized, hint `1166`, 2.6 ETH) | UNVERIFIED — plan's instruction to re-read owner/status/amounts rather than trust the constants is exactly right. |
| Aave StataTokenV2 WETH `0x0bfc9d54Fc184518A81162F8fB99c2eACa081202` | UNVERIFIED — Gate 0 task 4 already covers code/asset/liquidity/deposit-gas. Retaining the shipped Stata **USDC** test as independent funding-adapter proof is a good hedge. |

---

## 5. Notably well-designed (no action)

Worth preserving explicitly under review pressure:

1. **The two-leg ERC-8161 acquisition is required, not defensive.** W2 + W8 prove an
   `if/else` would be incorrect. §3.2's 60/40 proof is the right demo.
2. **Phase drift is execution-monotone, not necessarily economically
   buyer-favorable.** Pending→Claimable is one-way and preserves total share
   units; a seller who adds, transfers, or claims units changes the total, which
   invariant #7 rejects before movement. Binding
   `pendingShares + claimableShares == expectedTotalShares` is therefore
   sufficient for passive phase progression. ERC-7540 still leaves claim
   economics implementation-defined, so the redemption-rate floor remains
   necessary. This corrected proof is now required in `V2_SPEC.md`.
3. **`amountOfShares` floor as the economic bind** is the correct rebase-invariant choice
   for stETH.
4. **Guarded receive-and-wrap** in §6.2 (accept ETH only from the immutable
   queue-proxy address while an expected-claim guard is active) correctly
   avoids an arbitrary-recipient call inside settlement.
5. **Delta-measured acquisition** (invariant #8) is mandatory given W3 — the standard
   returns nothing and permits fees.
6. **`Empty ≠ Claimed`** in §4.2 is a genuinely subtle and correct distinction.
7. **Fill-or-kill separation from v1** is the right call: v1's clamp permits partial
   fills, and an NFT or a whole-Pending transfer is not partially fillable.

---

## 6. Suggested tackle order

1. **F3** — concrete defect on the flagship path; fix before Gate 3, add the test at Gate 0.
2. **F1, F2** — reframing, not rework. Do before the pitch and before `V2_SPEC.md` is frozen.
3. **F4, F5, F6** — fold into the Gate 0 interface freeze.
4. Promote the corrected §5.3 execution-monotonicity proof into `V2_SPEC.md`.

All six findings are now dispositioned:

- five confirmed and resolved;
- one partially confirmed/resolved with an overstatement corrected; and
- the archive-dependent fixture facts were subsequently verified at Gate 0 and
  again in the final seven-test fork matrix; see `docs/V2_FORK_REALISM.md`.

---

## 7. Pre-scope Claude Opus 5 advisory (2026-07-25)

This is an architecture/product advisory performed before implementation. It
does **not** satisfy the mandatory post-development review in
`V2_SCOPE.md` Gate 5.

Confirmed amendments:

1. **Kernel invariant leads.** The product claim is correctness across a
   Pending/Claimable race. ERC-8161 is the standards-hard proof; Lido Originate
   is production-hard evidence.
2. **Fixed payment remains.** Settlement-time variable pricing was rejected for
   v2. It would remove seller quote certainty and make exact just-in-time
   materialization unknowable until after acquisition. State contingency is
   binary: full fixed payment or revert.
3. **Both kinds of bounds are required.** Exact total shares constrain seller
   state before movement; rate floors constrain measured factor receipt after
   movement.
4. **Seller initiation is a security control.** The quoted seller directly
   calls `fill`; for ERC-8161 that address is also the seller controller.
   Relayed fills would require a separate controller authorization.
5. **Operator lifecycle is demonstrated.** Approve, fill, revoke, and a
   post-revocation rejection are hard-cut behavior.
6. **Acquisition precedes materialization.** Capacity is checked first, the
   claim is secured, exact payment is then materialized and paid. Any later
   failure rolls the entire transaction back.
7. **Funding reuse is exact.** The dedicated account approves the shipped
   adapter for both underlying and vault shares and uses a zero liquidity
   buffer.
8. **Commercial language is qualified.** Productive reserves improve
   standby-inventory utilization, not post-fill underwriting. Lido is episodic
   stress liquidity, not an always-on CoW competitor.

Rejected or qualified recommendations:

- continuous settlement-time unit pricing is deferred rather than adopted;
- existing-`unstETH` acquisition is stretch rather than a hard-cut demo; and
- the reported backtest direction is accepted, while its precise annualized
  magnitude remains assumption-sensitive and was not reproduced in this repo.

Canonical disposition is in `V2_SCOPE.md`; any earlier finding text that says
Lido Originate alone is the primary product proof is superseded.
