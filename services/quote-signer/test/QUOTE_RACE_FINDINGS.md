# Quote / requote adversarial findings

Scope reviewed: `services/quote-signer/server.mjs`,
`services/quote-signer/reservations.mjs`, `frontend/app/page.tsx`, and
`frontend/app/api/quote/lido/route.ts` at `03eff60`.

## Confirmed

1. Exact retries are now idempotent. `buildQuote()` sweeps and then calls
   `ReservationStore.recover()` before signing. Concurrent handlers are
   serialized by `SerialExecutor`, so double-clicks cannot produce two nonces.
2. A wallet rejection cannot safely release a reservation. The old signed
   envelope remains executable onchain. An identical requote must recover that
   envelope until it expires or its nonce is consumed.
3. The frontend has no request generation / request fingerprint guard. An
   account, amount, asset, claim, or mode switch while `fetch()` or
   `verifyReservoirQuote()` is pending can let a stale completion write global
   `claimQuoteCheck`, `pending`, `status`, and `action` state.
4. The account race is material UX state corruption: the quote closure verifies
   against the old account, while `loadWalletAccount()` can install a new
   account before the old request completes. `stEthOffer` checks mode and
   amount, but not the quote seller against the current account.
5. Rejected approval/fill prompts clear a still-valid quote. In
   `approveReservoir()`, both modes eventually clear `claimQuoteCheck` on
   errors. The next request can recover it, but the UI presents this as a failed
   requote flow.
6. Single-flight is global. One small active quote blocks every other wallet and
   every other amount for the full configured TTL, even if reserve capacity
   remains. This is safe but unnecessarily prevents multi-wallet testing.
7. The public edge accepts any syntactically valid `seller` and does not prove
   the caller controls that address. Because stETH balances and unstETH owners
   are public, an anonymous caller can reserve the global quote slot for
   somebody else and repeat after expiry. The reverse-proxy secret authenticates
   Vercel to the signer, not the seller to Vercel.
8. The reservation store itself supports multiple active rows and exposes each
   `paymentWei`. The signer can safely admit multiple users by requiring:
   `newPayment + sum(active paymentWei) <= authoritative availableFor(total)`.
   It should retain one active envelope per seller/request fingerprint and
   recover exact retries.

## False positives / constraints

- “Always issue a fresh nonce when Requote is clicked” is unsafe. The prior
  signature is still valid and could fill. Fresh issuance is safe only after
  expiry, onchain consumption, or explicit onchain nonce invalidation.
- The durable SQLite reservation is not the race bug. It is required to keep
  signer restart from forgetting live liabilities.
- Serializing `sweep -> validate -> sign -> reserve` is correct. Removing the
  executor would reintroduce oversubscription.

## Smallest state-machine and API contract

- Client state is scoped by an immutable fingerprint:
  `(account, mode, asset, amount-or-requestId)`.
- Every request owns a monotonically increasing generation and an
  `AbortController`. Only the current generation may write quote, error,
  pending, or idle state. Changing any fingerprint field aborts and invalidates
  the previous generation.
- Explicit phases: `idle -> requesting -> verifying -> ready -> approving ->
  ready -> filling -> success`, with `error` and `expired` recoveries.
- Wallet rejection returns `ready` while the quote remains unexpired; it does
  not clear the quote.
- The ready state shows deadline/countdown. “Refresh offer” returns the same
  envelope while active, and a fresh one only after safe release.
- Signer responses should distinguish `issued` from `reused` and include
  `deadline`/`retryAfterSeconds`. A conflicting reservation should return a
  structured capacity/reservation response, not only prose.
- Replace global single-flight with aggregate reservation accounting. Preserve
  the serial critical section.
- Before public multi-wallet use, authenticate seller control (EIP-712/SIWE
  request authorization, ideally a short-lived session signature). IP rate
  limiting alone does not prove seller ownership and is only defense in depth.

The executable sibling test uses the real SQLite store and executor to cover
double-clicks, delayed callers, wallet rejection, request switches, expiry,
consumption, restart durability, two users, and capacity oversubscription.
