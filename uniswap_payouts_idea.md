# Reservoir Uniswap payouts — minimal specification

> Version: 0.2.0-minimal (the complete 0.1.0 specification is in git history)
>
> Status: Gate 0 API-side passed 2026-07-25; fork-side spike remaining
>
> Target bounty: ETHGlobal Lisbon 2026 — Best Uniswap API Integration ($7,000
> pool: $4,000 / $2,000 / $1,000)

## 1. Decision

A seller sells a delayed claim and receives USDC instead of WETH, in one
transaction. The factor still underwrites and funds the claim in WETH; a
Uniswap Trading API route converts the exact WETH advance and delivers USDC
directly to the seller.

```text
seller stETH
    -> canonical Lido withdrawal request minted to factor
    -> exact WETH materialized from Aave StataWETH
    -> Uniswap API-produced CLASSIC route executes
    -> seller receives at least the signed minimum USDC
```

The transaction reverts unless both hold: the complete claim is acquired, and
the seller's measured USDC increase is at least the signed minimum.

The API is load-bearing: without its route calldata there is no USDC payout.
A displayed quote without execution does not qualify and will not be shipped.
Uniswap prices only the WETH→USDC conversion; the factor prices the claim.

## 2. Gate 0 evidence

API-side probes ran 2026-07-25 with a valid key against
`trade-api.gateway.uniswap.org/v1`:

| Check | Result |
|---|---|
| `/quote`, contract as `swapper`, zero WETH balance | accepted, `routing: CLASSIC` (requestId `cfe8e6a4…`) |
| `recipient` different from `swapper` | accepted |
| `x-permit2-disabled: true` | `permitData: null` — no signature the executor cannot produce |
| `/swap` with `simulateTransaction: false` | usable transaction: `from` = contract swapper, `value: 0`, nonempty calldata |
| Observed proxy target | `0x02E5be68D46DAc0B524905bfF209cf47EE6dB2a9` (revalidate from official docs at build time) |
| Observed calldata selector | `0x2894adf9` |
| `/swap` with `simulateTransaction: true` | fails for a zero-balance swapper (`FAILED_TO_ESTIMATE_GAS: TRANSFER_FROM_FAILED`, requestId `15942d10…`) |

Consequences: request `/swap` with `simulateTransaction: false` and simulate
the complete fill on our own fork, as the existing tooling already does. The
simulation gap is FEEDBACK.md material, not a blocker.

Remaining fork-side spike, required before contract work is frozen:

1. a throwaway executor approves the proxy and invokes the exact `swap.data`
   nested inside a harness transaction;
2. the proxy pulls exactly the funded WETH from the contract caller;
3. USDC arrives at the separate recipient;
4. an excessive minimum makes the call revert; and
5. no balance or allowance residue remains after success.

## 3. Minimal scope

New contracts, deployed as siblings; the reviewed v2 kernel, funding account,
and adapters are not modified:

- **`UniswapPayoutSettlement`** — a copy of the reviewed v2 kernel with one
  payout branch and immutable bindings: one payout executor, WETH funding,
  USDC payout. No payout-asset allowlist, no runtime asset management, no
  direct-WETH mode — WETH-direct settlement remains the existing v2 kernel's
  job.
- **`UniswapPayoutExecutor`** — small immutable contract; the only caller is
  the settlement, the only callee is the Uniswap proxy.
- **A new `ProductiveFundingAccount` instance** — required because a sealed
  funding account binds exactly one settlement contract. It reuses the
  existing `ERC4626ReserveAdapter` and Aave StataWETH unchanged.

Quote creation stays offline in the existing CLI pattern: the operator fetches
the route server-side with the API key, validates it, and signs the Reservoir
quote with the factor key. API key and factor key remain separate secrets;
neither appears in the repository, frontend bundle, logs, or recordings.

Cut relative to the full 0.1.0 spec (deferred, not abandoned — see §10):
frontend USDC toggle (the demo is scripted on the jury fork), ERC-8161 payout
integration (Lido path only), payout-asset management, testnet leg (straight
to mainnet fork), RFC 8785 canonicalization (hash the exact retained JSON
string instead), and the monitoring/operations program.

## 4. Signed quote

New EIP-712 domain (`Reservoir Uniswap Payouts`, version 1); v2 signatures
are invalid in the new kernel and vice versa. The quote is the reviewed v2
quote shape plus two fields:

- `minimumPayoutAmount` — minimum measured seller USDC delta; and
- `payoutDataHash` — hash of the complete execution payload.

Funding asset, payout asset, and executor are immutable kernel bindings, not
quote fields. All v2 validity rules carry over unchanged: factor signature
(EOA or ERC-1271), seller-only execution, nonce and nonce floor, 15-minute
maximum quote lifetime, exact funding capacity.

Payout payload:

```solidity
struct UniswapPayoutData {
    bytes callData;      // exact /swap response data, never altered
    bytes32 apiQuoteHash; // keccak256 of the exact retained /quote JSON string
}
```

Target and value are not fields: the executor's proxy target is immutable and
the value is always zero. `apiQuoteHash` is evidence for auditability, not an
oracle.

## 5. Executor rules

1. Only the immutable settlement may call.
2. On entry: WETH balance equals exactly the funded input; USDC and native
   ETH are zero. Unexpected dust fails closed.
3. Record the seller's USDC balance.
4. Approve the immutable proxy for exactly the input amount.
5. Call the proxy with the exact API calldata; verify the selector matches
   the immutable Gate 0 selector.
6. Clear any remaining allowance.
7. Require the seller's measured USDC increase is at least the signed
   minimum. Router return values never substitute for the balance delta.
8. Require WETH, USDC, and native ETH balances return to zero.

No arbitrary targets, no native value, no rescue methods, no calldata
rewriting. A griefed executor is replaced, not patched.

## 6. Settlement sequence

The v2 sequence with one branch swapped: validate quote → consume nonce →
acquire complete claim (measured) → materialize exact WETH to the executor →
executor swaps and pays seller → verify minimum and zero residue → emit. Any
failure reverts everything, including the acquired claim and consumed nonce.

Invariants, unchanged in spirit from v2:

- payout if and only if complete claim acquisition, same transaction;
- the factor spends exactly the signed WETH amount;
- price improvement above the minimum belongs to the seller; and
- the executor is dustless before and after.

## 7. API integration

Server-side request (key in a server secret, `.env` is gitignored):

```json
{
  "type": "EXACT_INPUT",
  "amount": "<fundingAmount>",
  "tokenInChainId": 1, "tokenOutChainId": 1,
  "tokenIn": "<WETH>", "tokenOut": "<USDC>",
  "swapper": "<UniswapPayoutExecutor>",
  "recipient": "<seller>",
  "slippageTolerance": 0.5,
  "routingPreference": "BEST_PRICE",
  "protocols": ["V2", "V3", "V4"]
}
```

with `x-permit2-disabled: true` on `/quote` and `/swap`, and
`simulateTransaction: false`.

Reject the bundle unless: `routing == "CLASSIC"`; `permitData` null; input is
WETH for the exact funding amount; output is USDC to the seller; swapper is
the executor; same-chain; `swap.to` equals the configured proxy;
`swap.value == 0`; selector matches. Never alter `swap.data`. On API failure,
no Reservoir quote is issued — the existing WETH path is the fallback.

Two questions stay open until the fork spike: whether the API deadline can
always sit inside Reservoir's 15-minute quote lifetime, and whether the
calldata's own minimum matches the API-quoted minimum (our executor enforces
the signed minimum regardless).

## 8. Tests

- **Executor units:** caller gating, exact approve/spend/clear, dust
  fail-closed on entry and exit, below-minimum revert, rollback of all
  changes on later failure.
- **Kernel units:** new-domain signatures only, payout fields EIP-712-bound,
  payout failure rolls back claim and nonce, v2 replay/nonce/pause behavior
  preserved.
- **One canonical mainnet-fork proof:** live API-produced route; factor
  starts as StataWETH shares with zero idle WETH; Lido request minted to
  factor; exact WETH pulled by the proxy; seller receives at least the signed
  minimum USDC; executor dustless; and the forced-failure case (excessive
  minimum) rolls back the Lido request, nonce, and every token delta.
- **Non-regression:** the complete existing deterministic and fork suites
  stay green; v1 and v2 are untouched.

## 9. Demo and submission

Four acts, scripted on the jury fork:

1. **Productive capital** — factor holds StataWETH shares, zero idle WETH.
2. **API is load-bearing** — show the live server request and validated
   response fields (contract swapper, separate recipient, CLASSIC,
   no-Permit2), with the key redacted; show request IDs and the signed route
   hash.
3. **Atomic cashout** — one seller transaction: Lido claim to factor, WETH
   from StataWETH, route through Uniswap, at least the signed USDC minimum to
   the seller, executor empty.
4. **Failure is atomic** — a quote with an unmeetable minimum: no claim
   created, no nonce consumed, no reserve assets moved.

Submission checklist:

- [ ] Fork-side Gate 0 spike passed.
- [ ] Live valid-key `/quote` and `/swap` produce the route used onchain.
- [ ] Canonical fork proof, success and forced failure.
- [ ] `FEEDBACK.md`: key setup, contract-as-swapper behavior, no-Permit2
      proxy flow, separate recipient, routing restrictions, the
      zero-balance simulation gap, error handling.
- [ ] Feedback form submitted linking `FEEDBACK.md`.
- [ ] README links the exact integration files and lines.
- [ ] Demo video shows API evidence and onchain execution.
- [ ] No API key or factor key in repository, build, or recording.

## 10. Deferred

Everything else in the 0.1.0 specification: frontend payout selection,
additional payout assets and allowlist management, ERC-8161 payout
integration, UniswapX, cross-chain, native ETH, relayed fills, integrator
fees, monitoring program, and persistent-network activation beyond the
existing paused/unfunded discipline.

## 11. References

- [ETHGlobal Lisbon 2026 prizes](https://ethglobal.com/events/lisbon2026/prizes)
- [Uniswap Swapping API integration guide](https://developers.uniswap.org/docs/trading/swapping-api/integration-guide)
- [Uniswap no-Permit2 proxy flow](https://developers.uniswap.org/docs/trading/swapping-api/concepts/no-permit2-workflow)
- [Uniswap swap routing](https://developers.uniswap.org/docs/trading/swapping-api/concepts/swap-routing)
- `V2_SPEC.md`, `V2_THREAT_MODEL.md`
- `src/claims/AsyncClaimSettlement.sol`, `src/claims/ProductiveFundingAccount.sol`
