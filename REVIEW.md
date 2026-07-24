# Reservoir design review

> Review result: proceed with the Gate 0 mechanism spike; confirmed corrections
> are incorporated in `SPEC.md`.
>
> This is the design-decision trail. `V1_SCOPE.md`, `SPEC.md`, and
> `IMPLEMENTATION_PLAN.md` are the v1 normative documents.

The idea is strong and judge-friendly: Aqua proves shared virtual liquidity,
while Reservoir shows that the maker’s physical inventory can continue earning
lending yield until the moment of settlement. The project should be presented
as one proof—**maker liquidity earns yield until the exact moment it is
traded**—not as a list of protocol integrations.

The hero path is constrained exact-in: Reservoir cannot safely deliver the
candidate output, so it delivers less and never takes more than the input
required for that actual fill. The chosen demo fixture must make the reduction
strict and visible. The original draft had the right product boundary, but
several contract-level statements were incompatible with the pinned Aqua and
SwapVM implementations.

## 1. Blocking findings and resolutions

| Original statement | Problem | Resolution frozen in the spec |
|---|---|---|
| `[deadline][xyc][reserveClamp][flatFeeOut]` | Output-fee instructions wrap the remaining program and cannot run after both amounts are computed. `FlatFeeAmountOut` exists in base `Opcodes` but is not in the pinned `AquaOpcodes` dispatcher used by the Aqua router. | Use `[Deadline?][Salt?][ReserveClamp][XYCSwap]`. Implement no economic fee in the hackathon path. |
| Append a new opcode at the end | The pinned SwapVM uses a banked opcode map and dispatch, not the older function-pointer list. | A new `ReservoirSwapVMRouter` handles free slot `0x92` by overriding virtual `_runOpcode`, then delegates every other opcode to `super`; the pinned router's `_dispatch` is not virtual. |
| `_xycSwap2D` | That is not the current instruction name. | Use the `XYCSwap` opcode / `_xycSwapXD`. |
| `materialize` may deliver less | Hooks cannot change the already-computed output. Aqua pulls the exact output after the pre-hook. | `materialize` is exact-or-revert. Partial filling happens in the opcode. |
| One adapter argument for a bidirectional pair | A USDC/USDT order needs different single-asset vaults depending on direction. | The maker account is the canonical asset-to-adapter resolver used by both quote and hooks. |
| `availableFor <= maxWithdraw` | This ignores idle underlying deliberately left by the reinvest threshold or a failed reinvest. | Bound availability by idle underlying plus `maxWithdraw`, less an asset-unit buffer. |
| Post-hook failure cannot revert | Any ordinary reverting hook rolls back the transaction, and a gas-burning target or huge revert payload can starve the catch path. | Clear the transient phase first, then call reinvest with bounded gas, retained completion gas, and zero returndata copying. Emit an event and leave input idle on failure. |
| Successful quote makes materialization revert unreachable | An off-chain quote can become stale before inclusion. | Guarantee exact behavior only in unchanged state. Exact-in uses `minOut`; exact-out is best effort because `maxIn` caps absolute spend but does not protect minimum fill size or unit rate. |
| Quoted output is always greater than or equal to actual | This conflicts with exact settlement and safe deliverability. | Same-state quote equals swap. A successful swap’s recipient delta equals returned output. |
| Global symmetry must pass | A hard saturation cap is non-injective: multiple oversized requests can map to one fill. | Require symmetry only when the cap does not bind; add saturation and partial-input properties at the boundary. |
| Add exit cost to a later immutable fee | A dynamic instruction cannot rewrite a later opcode’s immutable arguments. | Keep `exitCostWad == 0` and omit spread math in the hackathon build. Any fee extension gets a separate reviewed instruction version. |
| “Aave unbounded” | Aave withdrawals are also limited by owner shares, pool liquidity, and pause state. | Describe Aave as non-binding at the chosen demo size. |
| “Morpho” | Morpho Blue is not ERC-4626, and Vault V1 and V2 have different `max*` behavior. | Use MetaMorpho / Vault V1. Explicitly exclude Vault V2 from v1. |
| Advance blocks to show yield | Lending interest is timestamp-based. | Use `vm.warp`, optionally with `vm.roll`. |

## 2. Essential custody decision

The maker account is the Aqua maker, share owner, underlying receiver, reserve resolver, and authenticated hook target.

The custom instruction derives the view-only `IAquaReserveResolver` from `ctx.query.maker`; adapter selection is not separately encoded in untrusted program arguments. A transient pre-in guard rejects input-first settlement before any input callback or transfer. Maker traits enable Aqua custody and all three maker hooks; taker traits select direction, exact mode, output-first order, push mode, callbacks, and threshold.

The restricted program tail is exactly one pure XYC instruction, so the
in-swap capacity read reaches `preTransferOut` before any taker callback or
state-changing instruction. That is the narrow, defensible quote/materialization
consistency argument; off-chain quotes still drift across blocks.

This gives one auditable settlement path:

```text
vault shares -> exact pre-out withdrawal -> maker -> Aqua.pull -> taker
taker -> Aqua.push -> maker -> best-effort post-in deposit -> vault shares
```

Because the frozen design keeps the maker and adapter as separate contracts, it requires:

- vault-share allowance so the adapter can burn maker-owned shares;
- underlying allowance or a transfer path for reinvestment;
- unlimited allowances to the immutable Aqua and adapter spenders so repeated swaps do not create quote/settlement drift;
- strict `onlyMakerAccount` authorization; and
- verification that the adapter always withdraws to its configured maker.

Those requirements are included in the adapter tests and remain part of the frozen custody model for the PoC.
The maker lifecycle is deliberately one-way and acceptable only for disposable
local/fork accounts. Persistent deployment and full fund recovery are not part
of this hackathon build.

## 3. Essential economic decision

The hackathon build does not recover gas or model an exit fee/spread. Both add
price conversion and inversion work without strengthening the just-in-time
liquidity proof.

`liquidityBufferAssets` remains a safety margin in underlying units; it is not
maker revenue. `exitCostWad` is retained only as a zero-valued interface
extension point. Reservoir v1 makes no profitability claim. Fee economics,
oracle-priced gas recovery, and production strategy configuration require a
separate post-hackathon review.

## 4. Invariant interpretation

### Required in the non-binding region

- the exact discrete XYC inverse property: exact-out returns the least integer
  input that reproduces the reachable exact-in output;
- monotonicity;
- maker-favoring rounding;
- same-state quote/swap equality;
- physical and Aqua balance sufficiency; and
- exact settlement accounting.

### Required when the clamp binds

- output is positive when positive safe capacity exists;
- output never exceeds safe capacity;
- actual input is recomputed for actual output;
- a clipped fill satisfies `actualInput <= requestedInput`; equality is
  possible on integer plateaus, while the hero fixture must show strict `<`;
- output saturates safely as requests grow;
- stale exact-in state either satisfies `minOut` or reverts;
- stale exact-out state may produce a smaller best-effort fill while `maxIn` only bounds absolute input spend; and
- every pre-settlement failure is atomic; the isolated post-settlement
  reinvest failure follows its explicit non-fatal policy.

### Deliberately skipped

- additivity, because capacity depends on state;
- global symmetry at hard saturation; and
- cross-block quote equality.

This is a stronger and more honest story for judges than marking mathematically inapplicable properties as passing.

## 5. Adapter choice

Build order:

1. deterministic mock ERC-4626;
2. Aave StataTokenV2 USDC;
3. stop and package the submission;
4. Morpho Vault V1 / MetaMorpho USDT only as optional amplification.

Aave is the first real adapter because its `maxWithdraw` reflects both owner shares and pool liquidity and it has ample liquidity at the pinned demo block.

Morpho V1 is a good optional replacement for the deterministic constraint
because its `maxWithdraw` simulates liquidity across its withdrawal queue. It
does not define the product. Morpho Vault V2 is incompatible with this generic
design because it intentionally returns zero from all ERC-4626 `max*`
functions.

## 6. Demo story

A focused 90-second demo should show:

1. maker inventory is represented by vault shares, not idle underlying;
2. before any trade, `vm.warp` increases `convertToAssets` for a fixed share count while Aqua virtual balances remain unchanged;
3. a constrained exact-in request has candidate output above safe capacity;
4. the actual output is clamped and the hero fixture charges strictly less
   input;
5. recipient and Aqua deltas equal the returned fill;
6. input is reinvested after settlement; and
7. from a clean snapshot, an intentionally failed reinvest leaves input idle
   without reverting the swap.

The deterministic mock path tells this complete story. A separate concise Aave
fork check proves that the same custody/materialization path works with a real
yield source. If Morpho is added, use independent snapshots so one trade's
reinvestment cannot erase the constrained fixture.

Report only six lines:

- vault NAV before → after;
- requested input;
- candidate output;
- safely deliverable output;
- actual input/output; and
- reinvestment result.

## 7. Final recommendation

First prove the raw `0x92` dispatch, nested XYC tail, and binding exact-in
second pass in a minimal spike. Then proceed with the local vertical slice while
fork fixture facts are gathered in parallel. Keep Morpho, fee economics, gas
comparison, and demo polish below the cut line until:

- exact materialization is proven;
- every clipped output has `actualInput <= requestedInput` and the hero fixture
  strictly reduces input;
- same-state quote equals swap;
- Aqua virtual deltas are exact; and
- failed or gas-burning reinvest is demonstrably bounded and non-fatal.
