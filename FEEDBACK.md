# Uniswap Trading API — integration feedback

> From building Reservoir's payout layer at ETHGlobal Lisbon 2026: a
> settlement contract funds an exact WETH amount and the API route converts it
> to the seller's chosen payout asset inside one atomic factoring transaction.
> Every observation below was hit for real; request IDs are retained in
> `test/spikes/fixtures/` and `deployments/`.

## Setup experience

- Key onboarding was smooth; `x-api-key` + `/v1/quote` worked first try.
- The integration guide's no-Permit2 flow (`x-permit2-disabled: true`) is
  exactly what a contract-swapper integration needs — but it is easy to miss
  that `/swap` then requires `permitData` to be **omitted entirely**. Sending
  `permitData: null` returns
  `RequestValidationError: "permitData" must be of type object` (request
  `7723a700…` succeeded after omission). Accepting explicit `null` — or
  documenting the omission — would save integrators a round-trip.

## What worked better than expected

- **Contract swapper, no signature**: with Permit2 disabled, a contract
  address as `swapper` is accepted end-to-end, including a swapper address
  that did not exist on-chain yet (we quoted for a CREATE-predicted executor
  address and deployed it afterwards on a fork — request `1398e976…`).
- **Separate `recipient` honored end-to-end**: output lands on the recipient,
  never the swapper. This enables our third-party-payout settlement shape.
- **Exact pull**: the proxy pulled exactly the approved input in every run —
  zero residue — which lets our executor enforce strict entry/exit
  dustlessness (`test/spikes/UniswapPayoutSpike.t.sol` assertions 2 and 5).
- **Quote accuracy**: in both the spike and the canonical fork proof, the
  delivered output equaled the `/quote` output to the unit (9348354 and
  9349109 micro-USDC respectively) when replayed at the fetch block.

## Friction worth fixing

1. **Zero-balance simulation gap**: `/swap` with `simulateTransaction: true`
   fails with `FAILED_TO_ESTIMATE_GAS: TRANSFER_FROM_FAILED` when the swapper
   does not yet hold the input (request `15942d10…`). For contract
   integrations that fund the swapper inside the same transaction that
   executes the route, simulation can never succeed server-side. A flag to
   skip balance checks during simulation would make the simulated gas figure
   usable.
2. **Calldata is opaque**: the proxy calldata (selector `0x2894adf9`) has no
   published ABI, so the embedded deadline and minimum-output cannot be
   decoded and cross-checked by the integrator. We compensate by enforcing
   our own signed minimum from the measured recipient delta, but publishing
   the calldata layout would let integrators verify what they are signing
   over.
3. **`permitData: null` rejection** — see setup above.

## What we shipped on top

- `src/payouts/UniswapPayoutExecutor.sol` — immutable-proxy executor:
  settlement-only caller, exact approval, unconditional allowance clear,
  measured-delta minimum, entry/exit dustlessness, no payable entry point.
- `src/payouts/UniswapPayoutSettlement.sol` — fill-or-kill factoring kernel
  whose payout leg routes through the API; payout asset is a signed quote
  field behind a factor-controlled allowlist (any-asset by design).
- Live-route proofs: `test/spikes/UniswapPayoutSpike.t.sol` (7 assertions)
  and `test/fork/UniswapPayoutMainnet.t.sol` (success + atomic forced
  failure) replay retained fixtures deterministically without a live key.
