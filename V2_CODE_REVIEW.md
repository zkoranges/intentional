# V2 implementation review

> Review of the shipped v2 claims layer (`src/claims/**`), not the plan.
> Companion to `V2_REVIEW_FINDINGS.md` (plan review) and `REVIEW_FINDINGS.md` (v1).
>
> Method: full read of `AsyncClaimSettlement`, `ProductiveFundingAccount`,
> `LidoWithdrawalClaimAdapter`, `ERC8161RedeemClaimAdapter`, and `ClaimTypes`;
> plus a local run of the deterministic suite.
>
> Suite state at review: **186 passed, 0 failed, 0 skipped**; invariants clean at
> 128 runs / 4096 calls / 0 reverts, including constant-total phase drift.

## Status legend

- `OPEN` — confirmed gap, not yet addressed.
- `ADOPTED` — prior review finding verified as genuinely fixed in code.

---

## 0. Prior findings verified as fixed

| Prior | Claim | Evidence in code |
|---|---|---|
| F3 | stETH rounding would break "pull exact stETH" | `LidoWithdrawalClaimAdapter.acquire` measures `receivedStETH` as a balance delta, bounds it with `bounds.maxStETHShortfall`, requests on the **measured** amount, and validates against the **live** `queue.MIN/MAX_STETH_WITHDRAWAL_AMOUNT()` rather than hardcoded constants. `ADOPTED` |
| F4 | Missing ERC-165 check for the operator interface | `ERC8161RedeemClaimAdapter` constructor requires all four: `0xe3bc4e65`, `0x620ee8e4`, `0x2f0a18c5`, `0x7846f5bd`. `ADOPTED` |
| F5 | Interface naming diverged from the standard | File and type are `IERC7540RedeemTransferable`. `ADOPTED` |

---

## 1. High — hardening

### H1 — No on-chain guard that the claim destination differs from the seller
- **Status:** OPEN
- **Where:** `AsyncClaimSettlement.fill` (§192–194), `LidoWithdrawalClaimAdapter.acquire`.
- **Defect:** The kernel requires `claimController != 0` and `claimReceiver != 0`, but
  never that either differs from `quote.seller`.
- **Failure scenario:** A quote signed with `claimReceiver == seller` causes the Lido
  adapter to pull the seller's stETH, mint the fresh `unstETH` **to the seller**, and
  then pay the seller the full `paymentAmount`. The factor pays and receives nothing.
  Every existing check passes: the NFT owner equals `claimReceiver`, amounts and share
  floors match, no dust remains.
- **Exploitability:** Not seller-exploitable — the factor signs the quote. This is a
  single-field misconfiguration in quote construction (frontend or quoting service) that
  is unrecoverable and produces a valid, non-reverting settlement.
- **Asymmetry worth noting:** the ERC-8161 adapter is *already* protected against the
  same mistake. A self-transfer leaves the seller's Pending balance intact, so
  `SellerPositionNotDrained` reverts. Lido has no equivalent because origination mints a
  new NFT rather than moving an existing position. The two adapters therefore have
  unequal safety against an identical operator error.
- **Why it stays invisible:** `test/unit/claims/LidoWithdrawalClaimAdapter.t.sol:362`
  builds its standard context with `claimController: seller`. The dangerous shape is
  already exercised as the normal case.
- **Fix:** two comparisons in the kernel — reject `claimReceiver == quote.seller` and
  `claimController == quote.seller`. There is no legitimate quote in which the buyer's
  claim destination is the seller. Add a test asserting the revert.

---

## 2. Medium

### M1 — `MAX_QUOTE_LIFETIME` makes a quote fillable only in the 15 minutes *before* its deadline
- **Status:** OPEN (documentation / runbook, not a code defect)
- **Where:** `AsyncClaimSettlement.fill` §213–219.
- **Behaviour:** `fill` requires both `block.timestamp <= quote.deadline` **and**
  `quote.deadline <= block.timestamp + MAX_QUOTE_LIFETIME`. The valid fill window is
  therefore `[deadline − 15 min, deadline]` — a quote with a far-future deadline is
  *not* fillable when signed; it reverts `QuoteDeadlineTooFar` until 15 minutes before
  expiry.
- **Consequence:** a quote cannot be pre-signed hours ahead of a live demo. Either it
  carries a far deadline (rejected) or a near deadline (expired). `script/V2Demo.s.sol`
  and `script/DeployV2Local.s.sol` correctly use `block.timestamp + 10 minutes`.
- **Action:** state this explicitly in `docs/LIVE_ACTIVATION.md` §7 and any stage
  runbook: **the factor must sign within ~10 minutes of the fill.** The design itself is
  right — it bounds the free option the seller holds on the factor's price — but it
  constrains demo choreography and is currently undocumented.

### M2 — `isSealed` does not seal the adapter set
- **Status:** OPEN
- **Where:** `AsyncClaimSettlement.allowAdapter` / `revokeAdapter` (§108–131) — neither
  carries `beforeSeal`.
- **Claim:** After `seal()`, the factor can still add or remove adapters. Since the
  kernel validates only `positionKey != 0` and `pendingUnits + claimableUnits != 0`
  (§250) and delegates all real measurement to the adapter, **the allowlist is the
  entire trust boundary.**
- **Severity:** low exploitability — only factor capital is at risk, and a seller is
  protected because they must separately approve the adapter named in the signed quote.
  But `isSealed` reads as stronger immutability than it provides, and the deployment
  verifier checks "sealed configuration, adapter count, allowlisting" as if it were
  frozen.
- **Fix:** either gate `allowAdapter` behind `beforeSeal`, or rename/document the
  guarantee precisely in the threat model and the verifier's expectations.

---

## 3. Low

### L1 — Two dead errors in the Lido adapter
- **Status:** OPEN — `LidoWithdrawalClaimAdapter.sol:57` `PreexistingStETHShares` and
  `:59` `ResidualStETH` are declared and never used (declaration is the only occurrence
  in `src/`). Remove them, or wire them to the checks they were meant to cover.

### L2 — `claimController` is required but unused in Lido origination
- **Status:** OPEN — The kernel requires it non-zero; the Lido adapter validates it
  non-zero and then ignores it (the NFT owner is `claimReceiver`). Tests set it to
  `seller` — precisely the value that is dangerous under H1. Either bind it for Lido
  (`require(claimController == claimReceiver)`) or document that it is ignored in
  origination mode.

### L3 — Exact `amountOfStETH` equality is a small-amount rounding risk
- **Status:** OPEN — `acquire` requires `status.amountOfStETH == receivedStETH`
  (§193–195). This holds at the rehearsed 0.9 stETH scale, but stETH is share-accounted;
  near the 100-wei minimum, share↔balance conversion can make the recorded amount differ
  and revert. **Relevant to a cheap mainnet demo:** do not size the live fill near the
  protocol minimum; stay at the proven scale.

### L4 — stETH donated to the Lido adapter is permanently locked
- **Status:** OPEN (informational) — `sharesBefore` is preserved and only the
  current-flow residual is refunded to the seller; there is no sweep. This is arguably
  the correct trade (no extraction surface on an allowlisted adapter), but it should be
  stated in the threat model rather than discovered.

---

## 4. Confirmed strengths (do not regress)

1. **The two-leg ERC-8161 acquisition is correct and required** — `transferRedeemRequest`
   for Pending, `redeem` for Claimable, never `if/else`, matching ERC-8161's "MUST only
   transfer the Pending balance. Claimable balances MUST NOT be affected."
2. **`SellerPositionNotDrained`** is a strong postcondition: it makes a no-op or partial
   acquisition impossible, and incidentally defends H1 on the 8161 path.
3. **Rebase-invariant residual accounting** via `sharesOf` rather than `balanceOf` — the
   right choice for stETH.
4. **Effects before interactions** — the nonce is consumed before any external call
   (§235), with an explicit comment on rollback semantics.
5. **Conservative capacity** — `ProductiveFundingAccount.availableFor` returns 0 on any
   nonzero `exitCostWad`, any `available > wanted`, any pause, or any revert.
6. **v2 cannot inherit v1's partial-fill semantics** — `configureReserve` requires
   `idleThreshold == 0` and `liquidityBufferAssets == 0`, and the kernel demands
   `capacity == paymentAmount` exactly.
7. **EIP-712 domain** binds chain ID and verifying contract, so quotes cannot replay
   across chains or deployments.
8. **Delta-measured payment** in `materializeAndPay` deliberately rejects
   fee-on-transfer payment assets.

---

## 5. Suggested tackle order

1. **H1** — two comparisons plus one test. Do this before any funded mainnet activity.
2. **M1** — one paragraph in the live runbook; it changes demo choreography.
3. **M2, L2** — fold into the threat model and the deployment verifier's expectations.
4. **L1, L3, L4** — cleanup and documented limits.

---

## 6. Resolution addendum — 2026-07-25

The implementation review above is preserved as the original finding record.
The following dispositions were verified after remediation:

| Finding | Disposition | Evidence |
|---|---|---|
| H1 | `RESOLVED` | The kernel rejects either signed claim destination when it equals the seller. Unit, integration, browser/CLI, and canonical Lido-fork coverage prove rejection before nonce use, claim movement, or payment. |
| M1 | `RESOLVED-DOCS` | `docs/LIVE_ACTIVATION.md` now requires factor signing only after the seller is ready and explains the approximately ten-minute operating window. |
| M2 | `ACCEPTED-DESIGN` | Post-seal adapter revocation/addition is intentional for emergency response and upgrades. The spec, README, contract comment, and verifier language now describe the current allowlist as a mutable, factor-controlled trust boundary; `isSealed` freezes core bindings, not the allowlist. |
| L1 | `RESOLVED` | The two unused Lido adapter errors were removed. |
| L2 | `RESOLVED-DOCS` | Lido ownership is explicitly bound to `claimReceiver`; `claimController` remains signed buyer-side metadata. Safe fixtures no longer normalize the seller as either destination. |
| L3 | `RESOLVED-RUNBOOK` | Live activation uses the fork-rehearsed 0.9 stETH scale and explicitly avoids the rounding-sensitive protocol minimum. |
| L4 | `ACCEPTED-DESIGN` | Pre-existing donated stETH shares are intentionally preserved and unrecoverable through the adapter, avoiding a privileged sweep surface. |

Post-remediation evidence:

- deterministic Foundry suites: **187 passed, 0 failed, 0 skipped**;
- production-contract mainnet-fork suites: **10 passed, 0 failed, 0 skipped**;
- exact release deploy/sign/approve/fill mainnet-fork rehearsal: **passed**;
- paused/unfunded deployment and activation rehearsal: **passed**;
- frontend lint, rendered tests, pinned-address build, and native Vercel build: **passed**.
