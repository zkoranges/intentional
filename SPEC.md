# Reservoir

> Reviewed protocol specification, v1.0
>
> Status: ready for v1 implementation
> Target: ETH Lisbon hackathon
>
> Product and delivery scope is frozen in `V1_SCOPE.md`. This file defines the
> protocol behavior inside that scope. `IMPLEMENTATION_PLAN.md` defines gate
> sequencing and acceptance. `REVIEW.md` and `REVIEW_FINDINGS.md` are the
> evidence trail rather than additional requirement sources.

> **Reservoir separates trading liquidity from idle custody. Makers keep capital
> productive, while settlement sees only what can be safely delivered right now.**

Reservoir lets an Aqua maker keep inventory in ERC-4626 lending vaults between
trades. The exact output needed for a swap is withdrawn immediately before Aqua
settlement; the received input is reinvested after settlement.

The project is one proof, not an integration checklist:

> **Maker liquidity earns yield until the exact moment it is traded.**

## 0. Hero proof

The judge-facing path is one constrained **exact-in** trade:

1. **Rest:** maker idle underlying is zero; inventory is represented by vault
   shares.
2. **Earn:** time advances; the same share count is worth more while Aqua's
   virtual trading balance is unchanged.
3. **Challenge:** the taker's requested input would produce more output than
   the reserve can safely deliver.
4. **Adapt:** Reservoir clamps the output and inverse-recomputes the actual
   input. Universally, `actualInput <= requestedInput`; the selected demo
   fixture must show the strict, judge-visible case `actualInput <
   requestedInput`.
5. **Settle:** the exact output is materialized, Aqua settles, and the received
   input returns to its vault.
6. **Survive:** from a clean snapshot, a deliberately broken reinvestment leaves
   the received input idle without rolling back the settled trade.

The demo prints only:

```text
Vault NAV before -> after
Requested input
Candidate output
Safely deliverable output
Actual input / output
Reinvestment result
```

The deterministic mock-vault path proves this complete story. The Aave fork is
the required real-world compatibility proof. Morpho may replace the mock
constraint if time permits, but it is not part of Reservoir's identity or the
submission hard cut. Exact-out remains a tested correctness path, not the demo
centerpiece.

## 1. Upstream baseline

Implementation is pinned to the current upstream APIs reviewed for this specification:

- [SwapVM `0817db4`](https://github.com/1inch/swap-vm/tree/0817db4a618d975648e018222aedcdeb1206959e)
- [Aqua `7a5972a`](https://github.com/1inch/aqua/tree/7a5972a6b562e3e622f6e6b2a0befef659cd5386)

These pins matter. The reviewed SwapVM pin uses a banked opcode map and
dispatch functions, and its fee instructions are wrappers. Older examples that
append function pointers or place an output fee after a curve are not
compatible with this baseline.

The pin also accepts best-effort amounts: `TakerTraitsLib.validate` checks the
caller's amount with `requested >= actual` in both modes. Reservoir's clamp
depends on that inequality. A later SwapVM revision that changes it to equality
is incompatible until the mechanism is redesigned.

Any SwapVM extension must preserve the upstream license, notices, source-availability requirements, and prominent “Powered by SwapVM” attribution.

## 2. Scope ladder

### 2.1 Essential local PoC

The first mergeable vertical slice contains:

- a local Aqua deployment;
- a `ReservoirSwapVMRouter`, which is the Aqua app;
- one custom reserve instruction;
- one `ReservoirMakerAccount`, which is the Aqua maker and maker-hook target;
- one ERC-4626-compatible adapter implementation, deployed once per token against deterministic mock vaults;
- a deterministic output vault whose share value and withdrawable liquidity can
  be controlled independently, so one scenario proves earn-then-clamp;
- one constrained exact-in vault-backed swap whose actual input is lower than
  the requested input;
- one repeat from a snapshot with deliberately broken reinvestment;
- exact Aqua, token, share, and hook accounting tests; and
- the non-binding subset of SwapVM core invariants plus bespoke clamp-boundary tests.

The local PoC uses zero exit cost and implements no economic spread model.
Exact-out is covered by unit/integration tests after the exact-in hero path is
green.

### 2.2 First real integration

After the local PoC is green:

- add Aave StataTokenV2 USDC;
- use a deterministic mock ERC-4626 for the other token on that fork;
- run a pinned Ethereum mainnet-fork swap;
- show that the requested trade is below Aave’s available liquidity;
- use `vm.warp`, then show increased vault-share asset value; and
- keep Aqua virtual balances and maker NAV reporting separate.

### 2.3 Submission hard cut

The submission is credible when the deterministic hero flow and the real Aave
swap are both reliable. After that, add only the instrumentation needed to
print the six hero values and explain the result in one command.

### 2.4 Optional amplification

Only after the hard cut is green:

- replace the deterministic constraint with Morpho Vault V1 / MetaMorpho USDT;
- report a vanilla-versus-Reservoir gas comparison; and
- add presentation polish that does not change the settlement path.

### 2.5 Non-goals

- borrowing or leverage;
- pooled or multi-maker accounting;
- multiple Aqua strategies per maker account;
- cross-chain support;
- economic exit-fee or spread modeling in the hackathon build;
- automatic oracle-priced gas recovery;
- fee-on-transfer or rebasing underlying tokens;
- Morpho Vault V2 in v1;
- production upgradeability;
- deployment or custody on a persistent network;
- a UI beyond terminal/demo output; and
- claiming stale off-chain quotes can never revert.

## 3. Frozen architecture

```text
                         quote / swap
                              |
                              v
                 ReservoirSwapVMRouter
                    (the Aqua app)
                    |             |
       static view  |             | maker hooks
                    v             v
             ReservoirMakerAccount
              (the Aqua maker and
               reserve resolver)
                    |
             adapterOf[asset]
                    |
                    v
        ERC4626ReserveAdapter
          /        |         \
         v         v          v
       mock   Aave Stata   Morpho V1
              required      optional
```

The maker account is the only address Aqua treats as the maker. It holds idle underlying and vault shares, approves Aqua to pull underlying, resolves the adapter for each asset, and implements authenticated maker hooks.

The maker account exposes `IAquaReserveResolver.availableFor` as a routing facade. The custom instruction calls the order maker, and the maker forwards the view to `adapterOf[tokenOut]`. If that adapter call fails, the facade returns `(0, 0)`. Settlement hooks use the same mapping for state-changing adapter calls.

Each adapter deployment is bound to exactly one:

- maker account;
- underlying asset; and
- ERC-4626 vault.

Adapter state-changing methods are callable only by its maker account. The configured vault must report the expected `asset()` during setup. Configuration is sealed atomically with Aqua strategy shipping and is immutable before hooks can be used.

For a two-token order, the maker account is the canonical resolver. Both the quote instruction and settlement hooks must resolve through the same `adapterOf[asset]` mapping.

Both order tokens must have a sealed, nonzero adapter before the strategy is shipped. An unsupported asset returns zero during quoting; settlement never silently substitutes a different adapter.

## 4. Reserve contracts

```solidity
interface IAquaReserveResolver {
    /// Must not revert during a normal quote.
    ///
    /// canDeliver is bounded by wanted and by buffered physical inventory:
    /// idle underlying + vault.maxWithdraw(maker) - liquidityBufferAssets.
    ///
    /// Reserved for a later economic extension. MUST be zero in the
    /// hackathon build.
    function availableFor(address asset, uint256 wanted)
        external
        view
        returns (uint256 canDeliver, uint256 exitCostWad);
}

interface IAquaReserveAdapter is IAquaReserveResolver {
    /// Exact-or-revert.
    ///
    /// If unchanged state previously reported canDeliver >= amount, this call
    /// must leave at least amount underlying at the maker for Aqua to pull.
    /// On success, delivered == amount, including when existing idle assets
    /// made a vault withdrawal unnecessary. This is not shares burned.
    function materialize(address asset, uint256 amount)
        external
        returns (uint256 delivered);

    /// Deposits eligible idle inventory. A no-op below idleThreshold.
    /// The maker hook catches any failure and leaves the assets idle.
    function reinvest(address asset) external;

    function idleThreshold(address asset) external view returns (uint256);
}
```

The maker account implements only `IAquaReserveResolver`. Each single-vault adapter implements `IAquaReserveAdapter`. This prevents the maker’s quote facade from accidentally exposing a second public materialization or reinvestment path.

### 4.1 `availableFor`

For the configured asset:

```text
idle            = asset.balanceOf(makerAccount)
withdrawable    = try vault.maxWithdraw(makerAccount), otherwise 0
grossAvailable  = saturatingAdd(idle, withdrawable)
safeAvailable   = saturatingSub(grossAvailable, liquidityBufferAssets)
canDeliver      = min(wanted, safeAvailable)
```

Rules:

- a wrong or unsupported asset returns `(0, 0)`;
- a failed `maxWithdraw` contributes zero withdrawable assets rather than reverting; safely measured idle inventory may still be returned;
- a failed resolver-to-adapter call returns `(0, 0)`;
- `canDeliver <= wanted`;
- `canDeliver <= idle + maxWithdraw - liquidityBufferAssets`;
- `exitCostWad == 0` in the hackathon build.

Including idle assets is intentional. Reinvestment leaves an idle threshold, and a failed best-effort reinvest may leave more underlying at the maker. The original rule “never more than `maxWithdraw`” is therefore replaced by the physical-inventory bound above.

The second return value remains in the interface only to preserve the reviewed
extension point. Reservoir v1 neither prices nor charges exit cost. Supporting
a nonzero value requires a new reviewed fee specification and is outside the
submission hard cut.

### 4.2 `materialize`

```text
idle       = asset.balanceOf(makerAccount)
shortfall  = saturatingSub(amount, idle)
```

If `shortfall > 0`, the adapter re-reads `maxWithdraw`, requires it to cover the shortfall, and withdraws exactly the shortfall to the maker account. It then verifies the maker has at least `amount` underlying and returns `delivered == amount`.

Important:

- ERC-4626 `withdraw(assets, receiver, owner)` returns shares burned, not assets delivered;
- an idle-only success still returns `amount`, not zero;
- returning less than `amount` is not useful because hooks cannot change SwapVM’s already-computed output;
- a short materialization would make the subsequent exact Aqua pull revert; and
- partial filling must happen in the reserve instruction before hooks execute.

The same-state success property assumes an allowlisted, operational vault and token with intact approvals. A paused/blacklisted token, broken vault, lost allowance, or other external failure may still make exact materialization revert atomically.

### 4.3 `reinvest`

```text
idle          = asset.balanceOf(makerAccount)
excess        = saturatingSub(idle, idleThreshold)
depositAmount = min(excess, vault.maxDeposit(makerAccount))
```

The adapter no-ops when:

- `excess == 0`;
- `maxDeposit == 0`; or
- `previewDeposit(depositAmount)` would mint zero shares.

The adapter uses `SafeERC20` and `forceApprove`/zero-first approvals. A failure may leave input assets idle. The maker account’s post-hook catches that failure and emits `ReinvestFailed`.

Because the maker owns the incoming underlying while the adapter calls the vault, a successful reinvest explicitly performs:

```text
asset.safeTransferFrom(makerAccount, adapter, depositAmount)
asset.forceApprove(vault, depositAmount)
vault.deposit(depositAmount, makerAccount)
```

The maker-to-adapter allowance is configured before shipping. On success, no underlying remains on the adapter. If a view or deposit call reverts, the adapter call is reverted as one unit, the maker retains the underlying, and the maker hook catches the failure.

## 5. Maker account

`ReservoirMakerAccount`:

- has one immutable demo controller;
- is `order.maker`;
- owns idle underlying and vault shares;
- grants unlimited underlying allowance to Aqua;
- grants unlimited underlying and vault-share allowances to each immutable configured adapter;
- implements `IMakerHooks`;
- implements the view-only `IAquaReserveResolver`;
- resolves `adapterOf[asset]`;
- builds and ships the Aqua strategy; and
- seals its token, adapter, router, and strategy configuration before use.

Each token uses:

```solidity
struct ReserveConfig {
    IAquaReserveAdapter adapter;
    uint32 reinvestGasLimit;
}
```

Both fields are single-assignment and nonzero before sealing. The integer type
bounds configuration without pretending the numeric limit is known before
measurement.

The controller may configure adapters and call `prepareInventory(asset)` only
before sealing. `prepareInventory` makes the maker account call the configured
adapter's normal `reinvest` path, allowing pre-funded underlying to become
maker-owned vault shares. `sealAndShip` is controller-only and one-shot.
Router, token, and adapter slots are single-assignment even before sealing, so
reconfiguration cannot leave a superseded contract with a live unlimited
allowance.

The controller cannot call maker hooks or adapter state-changing entry points
directly, and v1 exposes no controller materialization or unwind function.
Post-seal rescue and production fund-recovery design are explicitly outside the
hackathon scope. V0 accounts are disposable local/fork fixtures only: they must
never be deployed or funded on a persistent network and must not custody
unrelated funds.

Every enabled hook validates:

```text
msg.sender == configured ReservoirSwapVMRouter
maker      == address(this)
orderHash  == configured strategy hash
token pair == configured token pair
adapter    == adapterOf[relevant asset]
```

“Token pair” is unordered for validation:

```text
(tokenIn == tokenA && tokenOut == tokenB)
    || (tokenIn == tokenB && tokenOut == tokenA)
```

Direct external calls, wrong assets, wrong orders, and wrong routers revert.

The maker account also enforces output-first settlement. A successful `preTransferOut` sets a transient flag keyed by order hash. An enabled `preTransferIn` guard requires that flag. `postTransferIn` validates and clears the flag before making any external reinvest call. A taker that selects input-first ordering therefore reverts before transferring input or invoking a taker input callback.

Callback safety does not depend on the demo disabling callbacks. At the pinned
commit, `SwapVM.swap` locks by `orderHash` before running the program and keeps
that lock through both transfers and all hooks/callbacks. A same-order nested
`swap` from a callback therefore fails at the router lock. `quote` is not
locked. The supported call is `router.asView().quote(...)` /
`ISwapVM(address(router)).quote(...)`, whose interface `view` modifier enforces
a `STATICCALL`; Reservoir tests never use a low-level mutable call to the
concrete non-view implementation. In either case Reservoir's quote branch does
not materialize inventory. V0 ships only one strategy hash, so a
different-order nested swap has no second Reservoir strategy to consume; if any
wrong-hash path reaches a maker hook, the maker rejects it before
materialization. The output-first transient flag protects transfer ordering; it
is not the reentrancy lock. Demo callbacks remain disabled only to keep the
narration deterministic.

Each sealed asset configuration contains its adapter and a
`reinvestGasLimit`. The limit is calibrated on the complete adapter path for
that vault, including transfer and approval overhead; it is not guessed at Gate
0. Reinvestment preserves a fixed post-hook gas reserve. The maker performs an
assembly-level `call` with zero output-data bytes so a gas-burning vault or huge
revert payload cannot force unbounded returndata copying. If too little gas
remains to preserve the reserve, reinvestment is skipped and a compact failure
event is emitted.

```text
if gasleft <= POST_HOOK_GAS_RESERVE + CALL_OVERHEAD:
    emit ReinvestFailed(asset, LOW_GAS)
else:
    gasToForward = min(reserveConfig[asset].reinvestGasLimit,
                       gasleft - POST_HOOK_GAS_RESERVE - CALL_OVERHEAD)
    success = call(gasToForward, adapter, reinvest(asset),
                   outOffset = 0, outSize = 0)
    emit ReinvestSucceeded(asset, adapter)
      or ReinvestFailed(asset, CALL_FAILED)
```

Because the call intentionally requests zero return bytes, the maker-level
success event has no amount field. The adapter emits
`AssetsReinvested(asset, assets, shares)`, and the vault emits its canonical
`Deposit` event; tests use those events plus physical balance/share deltas for
amount accounting. The retained-reserve constants and each real-vault gas limit
are frozen only after measurement, then tested below, at, and above their
boundaries. A positive fork calibration must prove successful reinvestment; a
failure-only test is insufficient.

Unlimited approvals are accepted in v1 because every spender is immutable, allowlisted, and state-changing adapter entry points are `onlyMakerAccount`. Sequential-swap tests must prove share, adapter, and Aqua allowances do not decay into an availability/settlement mismatch.

The final setup operation is an atomic `sealAndShip`: build the exact order,
compute and store its expected hash, seal configuration, then call:

```text
ReservoirSwapVMRouter.hash(order)
    == AQUA.ship(address(router), abi.encode(order), tokens, balances)
```

The operation reverts as a unit if the hashes differ. The returned Aqua strategy
hash is the only order hash accepted by maker hooks.
The `tokens` and `balances` arrays passed to `Aqua.ship` must contain exactly
the sorted order tokens with amounts aligned to the same indices.

At shipping, each virtual balance must also be NAV-backed:

```text
idle underlying + vault.convertToAssets(vault.balanceOf(maker))
    >= shipped Aqua virtual balance
```

This backing check is deliberately different from immediate availability.
Morpho may have enough maker-owned asset claim to back the virtual balance while
`maxWithdraw` is temporarily lower; that gap is exactly what the clamp exposes.
Demo fixtures derive shipped balances from post-`prepareInventory` NAV, never
from the nominal amount originally funded. ERC-4626 deposit rounding can make
the resulting claim one base unit smaller than the deposit.

## 6. Custom SwapVM instruction

### 6.1 Wiring

The custom router handles a free, currently unallocated raw opcode before delegating to upstream Aqua opcodes:

```text
0x92 ReserveClamp
```

`0x92` (`Opcode._92`) is the first free balance-tuning slot in the reviewed banked opcode map. No existing opcode value changes. It is not part of SwapVM's reserved `0xf0–0xff` bank.

The router is a new `ReservoirSwapVMRouter`; upstream `AquaOpcodes` is not rewritten in place. On the pinned code, `AquaSwapVMRouter._dispatch` is not virtual, so the subclass overrides the inherited virtual `_runOpcode`: handle `0x92` locally and call `super._runOpcode(ctx, opcode, args)` for every other value.

The resolver address is not supplied by program bytecode. The instruction always queries `IAquaReserveResolver(ctx.query.maker)`, making the quote resolver identical to the Aqua maker and hook target.

The PoC instruction takes zero argument bytes and rejects any nonempty argument.
Per-asset liquidity buffers live in the resolved adapters. Economic fee
arguments are deliberately not reserved in v1; adding them requires a new
reviewed instruction version.

### 6.2 Program

The PoC program is:

```text
[Deadline?] [Salt?] [ReserveClamp] [XYCSwap]
```

The reserve instruction is a wrapper. It must run immediately before the curve and may call the pure tail through `ctx.runLoop()`. Optional no-op uniqueness instructions such as `Salt` belong before the wrapper so the re-runnable tail is exactly one `XYCSwap`.

The following original program is invalid and must not be used:

```text
[Deadline] [XYCSwap] [ReserveClamp] [FlatFeeAmountOut]
```

An output-fee wrapper placed after `XYCSwap` sees both amount registers already
computed and reverts. `FlatFeeAmountOut` exists and base `Opcodes` dispatches
it, but it is not in the pinned `AquaOpcodes` dispatcher used by
`AquaSwapVMRouter`.

The optional program `Deadline` is a maker-selected strategy expiry. It is
separate from the taker's finite `deadline`, which
`TakerTraitsLib.validate` enforces even when the program omits `Deadline`. If
both are present, both must pass.

### 6.3 PoC restrictions

For the first vertical slice:

- the downstream tail is exactly one pure `XYCSwap`;
- no stateful opcode, token-transfer fee, callback, or backward jump appears after the reserve wrapper;
- `exitCostWad == 0`;
- both exact-in and exact-out are tested.

These restrictions make an exact-in inverse recomputation safe when the cap binds.
They also close the intra-transaction quote/materialization gap: during
`swap`, the reserve read is followed only by the pure XYC tail and SwapVM
validation before `preTransferOut` runs. No taker callback or state-changing
program instruction can consume vault liquidity between that read and exact
materialization.

### 6.4 Partial-fill semantics

The returned `amountIn` and `amountOut` are the actual filled amounts.

- Exact-out: clamp the requested output before running the curve, then compute the input for the clamped output.
- Exact-in, non-binding: run the curve and retain the requested input.
- Exact-in, binding: cap output and inverse-recompute the input required for
  that capped output. The universal guarantee is `actualInput <=
  requestedInput`. Equality is possible on an integer rounding plateau; the
  hero fixture is deliberately sized so `actualInput < requestedInput`.

For a binding exact-in swap only (`isStaticContext == false`), the router
emits:

```solidity
event ReserveClamped(
    bytes32 indexed orderHash,
    address indexed tokenOut,
    uint256 requestedInput,
    uint256 candidateOutput,
    uint256 safeCapacity,
    uint256 actualInput,
    uint256 actualOutput
);
```

The static quote path emits nothing. This event is demo telemetry, not a source
of settlement truth; its fields are asserted against the returned amounts,
resolver read, balances, and token deltas.

The zero-fee PoC algorithm is frozen as follows:

```text
tailPC       = program counter immediately after ReserveClamp
curveMaxOut  = balanceOut == 0 ? 0 : balanceOut - 1

exact-out:
    requestedOut = amountOut
    (availableOut, exitCostWad) =
        maker.availableFor(tokenOut, requestedOut)
    require exitCostWad == 0
    amountOut     = min(requestedOut, availableOut, curveMaxOut)
    run pure XYCSwap tail once to compute amountIn

exact-in:
    requestedIn = amountIn
    run pure XYCSwap tail once to compute candidateOut
    (availableOut, exitCostWad) =
        maker.availableFor(tokenOut, candidateOut)
    require exitCostWad == 0

    if availableOut < candidateOut:
        reset the tail program counter to tailPC
        temporarily evaluate the pure tail as exact-out
        amountOut = min(availableOut, curveMaxOut)
        amountIn  = 0
        run pure XYCSwap tail again to compute the input for amountOut
        restore the exact-in query flag
    else:
        retain requestedIn and candidateOut
```

`curveMaxOut` prevents an exact-output request from reaching the XYC singularity at `amountOut == balanceOut`. The implementation must restore every temporarily changed context field before returning except the final actual fill registers and the consumed program counter.

The two-pass branch depends on the pinned `XYCSwapRecomputeDetected` guards:
exact-in requires `amountOut == 0`, while exact-out requires `amountIn == 0`.
The transition contract is therefore exact:

1. save `tailPC`, the original exact-in flag, and `requestedInput`;
2. start the first tail evaluation with `amountOut == 0`;
3. if binding, set `nextPC = tailPC`, set `isExactIn = false`, set
   `amountOut = clampedOutput`, and set `amountIn = 0`;
4. run the one-instruction tail again;
5. restore only the original exact-in flag; and
6. retain the recomputed `amountIn`, clamped `amountOut`, and consumed
   end-of-program `nextPC`.

`balanceIn`, `balanceOut`, `amountNetPulled`, the resolver identity, token
identity, program pointer, and taker-argument pointer must not change. A
regression test pins these guards and transitions. A future upstream guard or
context-layout change requires re-running the mechanism spike before upgrading
the dependency.

Why the input cannot increase: if clamped output `c` is below the exact-in
candidate for requested input `a`, then
`c * balanceIn < a * (balanceOut - c)`. Therefore
`ceil(c * balanceIn / (balanceOut - c)) <= a`, exactly the inverse value
computed by the second XYC pass. Integer plateaus explain why equality can
still occur.

The capacity query in the zero-fee build is directly on candidate output. A
future constant-fee design could query gross output and apply capacity to net
output because `min(N, min(G, A)) == min(N, A)` when `N <= G`; that equivalence
depends on an amount-independent fee. No such fee path is implemented for the
hackathon.

### 6.5 Revert guarantee

“Partial fill, never revert” is narrowed to:

> An oversized request with positive buffered capacity, positive curve output, and a valid XYC domain (`balanceIn > 0`, `balanceOut > 1`) is reduced without an intentional insufficient-liquidity revert.

Zero capacity, taker thresholds, deadlines, stale cross-block state, token failures, invalid configuration, and failed exact materialization may still revert.

Taker protection differs by mode:

- exact-in uses the ordinary `minOut` threshold; a stale capacity decrease either still satisfies `minOut` or reverts atomically;
- exact-out is a best-effort request for up to the supplied output amount; `maxIn` caps absolute input spend only, while current SwapVM traits express neither a minimum partial-fill output nor a minimum unit rate; and
- v1 does not claim that an exact-out caller can protect fill size across blocks.

Adding a taker-supplied `minFillOut` instruction argument is a possible later extension, not part of the essential PoC.

An off-chain `quote` is a separate transaction and therefore does not inherit
the intra-transaction guarantee. `swap` re-evaluates current capacity; the
threshold behavior above is the complete cross-block consistency claim.

## 7. Order traits and settlement flow

Maker order construction is fixed to:

```text
maker                           = ReservoirMakerAccount
receiver                        = ReservoirMakerAccount
tokenA, tokenB                  = sorted so tokenA < tokenB
useAquaInsteadOfSignature       = true
shouldUnwrapWeth                = false
allowZeroAmountIn               = false
hasPreTransferOutHook           = true
hasPreTransferInHook            = true  # ordering guard
hasPostTransferInHook           = true
hasPostTransferOutHook          = false
all enabled hook targets        = maker account
```

The Aqua flag is mandatory: without it the router does not load the shipped Aqua virtual balances and the XYC curve cannot execute. The exact `Order` built with these traits is the value encoded for `Aqua.ship`.

Demo taker traits are fixed per direction and quote mode to:

```text
isAToB                         = direction relative to sorted tokenA/tokenB
isExactIn                      = selected quote mode
isFirstTransferFromTaker      = false
useTransferFromAndAquaPush    = true
threshold                     = minOut for exact-in, maxIn for exact-out
isStrictThresholdAmount       = false
to                            = taker (or zero, which defaults to taker)
deadline                      = finite in the demo
taker callbacks               = disabled
shouldUnwrapWeth               = false
```

Execution is:

```text
1. SwapVM computes current capacity and actual fill.
2. maker.preTransferOut:
      adapter(tokenOut).materialize(tokenOut, amountOut) exactly
      set transient output-first flag
3. Aqua.pull:
      maker -> taker, and Aqua output virtual balance decreases
4. maker.preTransferIn:
      require transient output-first flag
5. Aqua.push:
      taker/router -> maker, and Aqua input virtual balance increases
6. maker.postTransferIn:
      clear transient output-first flag
      bounded-gas, zero-returndata call adapter(tokenIn).reinvest(tokenIn)
      failure/low gas -> emit ReinvestFailed and leave input idle
```

A normal hook revert rolls back the entire transaction. “Post-hook failure does not revert” is achieved by isolating the adapter call inside the authenticated maker hook with a gas cap, retained completion gas, and no returndata copy. Caller-level transaction out-of-gas remains outside this guarantee.

## 8. Accounting model

Reservoir has two ledgers:

1. Aqua virtual balances are trading and risk limits.
2. Maker NAV is idle underlying plus the asset value of vault shares.

Lending yield increases maker NAV. It does not automatically increase Aqua’s virtual strategy balances. Yield remains maker surplus unless the strategy is explicitly docked and re-shipped with new virtual balances.

For every successful swap:

```text
Aqua virtual tokenIn   delta = +actualAmountIn
Aqua virtual tokenOut  delta = -actualAmountOut
taker tokenIn          delta = -actualAmountIn
taker tokenOut         delta = +actualAmountOut
adapter underlying dust       = 0 after successful reinvest
maker tokenOut NAV delta      = -actualAmountOut, plus only bounded vault rounding
                                for the zero-exit-cost PoC paths
```

Tests reconcile idle-asset deltas, the exact share count returned/burned by the
vault, and `convertToAssets` rounding separately. “Exact accounting” means every
token movement and Aqua delta is exact; it does not pretend an ERC-4626 share
conversion is free of its documented floor/ceil rounding.

## 9. Correctness properties

| Property | Required result |
|---|---|
| Adapter availability | `canDeliver <= wanted` and `<= buffered physical inventory` |
| View safety | Unsupported adapters return zero; a broken vault view contributes zero withdrawable assets while safely measured idle inventory may remain available |
| Exact materialization | Same-state accepted amount is made fully available or reverts |
| Same-state quote/swap | Returned input and output match exactly |
| Stale exact-in quote | `minOut` protects the user; worsening state may revert |
| Stale exact-out quote | `maxIn` caps absolute input spend, not minimum fill size or unit rate |
| Non-binding inverse | Exact-out returns the least integer input that produces the exact-in output; use the exact discrete property below, not a universal constant tolerance |
| Binding behavior | Output never exceeds buffered capacity; input is recomputed and `actualInput <= requestedInput` |
| Hero clamp | The selected economic-size fixture additionally proves `actualInput < requestedInput` |
| Monotonicity | Larger non-binding trades do not receive a better effective price |
| Rounding | Floors output and ceils required input |
| Balance sufficiency | Recipient delta equals returned output and never exceeds materialized inventory |
| Additivity | Skipped: capacity is state-dependent by design |
| Best-effort reinvest | Deposit failure emits an event, leaves assets idle, and does not revert settlement |
| Authorization | Only the configured router/maker path may move reserve inventory |

Global exact-in/out symmetry is not claimed at a hard saturation boundary: multiple oversized requests can map to the same capped fill, so the mapping is not one-to-one. Core symmetry tests run only in the non-binding region; clamp behavior has separate saturation properties.

For XYC reserves `x`, `y`, define:

```text
F(a) = floor(a * y / (x + a))
G(b) = ceil(b * x / (y - b))
```

If `b = F(a) > 0`, then the exact, data-dependent inverse property is:

```text
G(b) <= a
F(G(b)) == b
G(b) == 0 or F(G(b) - 1) < b
```

There is no universal one-unit round-trip bound; integer output buckets can be
much wider. For the committed `CoreInvariants` smoke matrix, use balanced
reserves of `1_000_000 * 10**decimals`, inputs of `[1, 10, 50] *
10**decimals`, both 6- and 18-decimal variants, and
`symmetryTolerance = 0`. Wider fuzzing asserts the exact minimal-input property
above instead of tuning a tolerance until it passes.

## 10. Essential tests

### 10.1 Adapter unit tests

- wrong asset returns zero;
- wanted `0` and `1`;
- zero vault liquidity;
- `maxWithdraw` revert returns a conservative quote;
- `canDeliver` around `max - buffer - 1`, equality, and `+1`;
- idle underlying is included;
- exact materialization uses idle first and withdraws only the shortfall;
- idle-only and mixed-idle materialization both return the full requested `amount`;
- return value is never shares burned;
- maker and share balance deltas are exact;
- reinvest below threshold is a no-op;
- reinvest caps at `maxDeposit`;
- reverting `maxDeposit` and `previewDeposit` leave maker funds untouched;
- zero-share preview is a no-op;
- repeated reinvest works with USDT-style zero-first approval;
- repeated reinvest does not exhaust the maker-to-adapter allowance;
- two sequential materializations retain sufficient share allowance;
- successful reinvest leaves zero underlying stranded on the adapter and emits
  the exact deposited assets/shares;
- a quote after failed reinvest counts the maker’s stranded idle underlying; and
- 6- and 18-decimal assets.

### 10.2 Maker and hook tests

- direct hook and adapter calls are rejected;
- wrong-controller setup calls are rejected;
- `prepareInventory` is pre-seal only and produces maker-owned shares;
- wrong router, order hash, asset, or pair is rejected;
- both A→B and B→A resolve the output and input adapters correctly;
- pre-withdraw failure leaves all balances unchanged;
- post-deposit failure still settles, emits `ReinvestFailed`, and leaves input idle;
- successful bounded reinvest emits amount-less `ReinvestSucceeded`; deposited
  amounts are taken from adapter/vault events and physical deltas;
- gas-burning and huge-revert-data reinvest mocks cannot consume the post-hook reserve;
- input-first taker traits fail at the ordering guard before any token delta;
- configuration cannot change after sealing;
- shipped token arrays are sorted/aligned and every virtual balance is NAV-backed;
- router order hash equals the strategy hash returned by `Aqua.ship`;
- enabled pre-out and pre-in callbacks cannot create a quote/materialization gap;
- a callback's same-order nested swap fails at the pinned SwapVM order-hash
  lock; if caught, the outer swap settles exactly once, and if propagated, the
  outer swap reverts atomically;
- a callback's `asView().quote` static call cannot materialize inventory; and
- a callback's different-order nested swap cannot materialize inventory, and a
  wrong hash reaching the hook fails maker authorization.

### 10.3 Instruction tests

- exact-in and exact-out below capacity;
- public `asView().quote` exact-out request above capacity returns
  `actualOutput < requestedOutput`, covering the pinned partial-fill validator;
- exact-in curve output above capacity with input recomputation;
- nonzero `exitCostWad` is rejected as an unsupported v1 configuration;
- zero capacity;
- `balanceOut` equal to `0` and `1`;
- exact-out request equal to and above the full Aqua virtual output reserve;
- output never exceeds current safe capacity;
- every clipped exact-in result satisfies `actualInput <= requestedInput`;
- the hero fixture satisfies the stricter `actualInput < requestedInput`;
- the two-pass register/flag/PC transition satisfies the pinned
  `XYCSwapRecomputeDetected` guards and leaves all unrelated context fields
  unchanged;
- the exact non-binding minimal-input property, monotonicity, and
  maker-favoring rounding;
- binding saturation properties; and
- exact-out correctness after the exact-in hero path is green.

### 10.4 Aqua end-to-end tests

- vanilla Aqua swap baseline;
- one mock-vault-backed swap;
- output exists in vault before the swap and is withdrawn only in `preTransferOut`;
- input arrives at maker through Aqua and is deposited in `postTransferIn`;
- Aqua virtual deltas equal returned amounts;
- recipient balance delta equals returned output;
- same-state quote equals swap;
- a constrained exact-in fill satisfies `actualInput <= requestedInput`, and
  the hero fixture strictly reduces it;
- two sequential swaps retain Aqua, adapter, and vault-share allowances;
- stale exact-in liquidity test reverts atomically at `minOut`;
- stale exact-out test documents that a smaller best-effort fill may succeed under `maxIn`.

The upstream `CoreInvariants` suite is necessary but not sufficient; its balance-sufficiency helper does not prove the physical-vault and recipient delta properties above.

## 11. Fork fixtures

### 11.1 Aave, first real path

Pinned fork block:

```text
25,604,561
block hash 0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d
```

Ethereum addresses:

```text
USDC                 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
Aave StataTokenV2    0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E
aUSDC                0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c
Aave V3 Pool         0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
```

The fork runner requires an archive-capable Ethereum RPC. Its preflight must
validate the exact block number and hash above and fail with an explicit
`archive RPC required for block 25,604,561` message when historical code or
state is unavailable.

The test must assert code exists, `vault.asset() == USDC`, and
`vault.aToken() == aUSDC` rather than trusting constants alone. It also checks
that aUSDC reports USDC as its underlying and the listed Aave V3 Pool. aUSDC is
reference-only wiring evidence: Reservoir's ERC-4626 vault is the static
StataTokenV2, the maker owns non-rebasing Stata shares, and the vault's
underlying asset is non-rebasing USDC. aUSDC is held internally by Stata and is
not the adapter vault or maker inventory token. This leg is “non-binding at
demo size,” not unbounded.

For Gate 2, USDC is the real Aave-backed output. The other token uses a
deterministic mock ERC-4626 deployed on the fork, so the same transaction can
still prove post-settlement input reinvestment. An optional Morpho leg can
replace this mock with a second real lending vault.
Set the Aave demo's USDC idle threshold to zero and assert maker idle USDC is
zero immediately before the trade, making the pre-hook-only materialization
visible without ambiguity.

### 11.2 Morpho, optional real constraint

Use Morpho Vault V1 / MetaMorpho, not Vault V2:

```text
USDT                         0xdAC17F958D2ee523a2206206994597C13D831ec7
Steakhouse USDT Vault V1     0xbEef047a543E45807105E51A8BBEFCc5950fcfBa
large share holder fixture   0x96B22EB7178d116797e57197e586b70FedAE8Fdd
```

At the pinned block, the holder’s claim is larger than the vault’s approximately 17.249 million USDT withdrawable liquidity, giving a deterministic clamp fixture. Transfer enough existing shares to the maker before `sealAndShip`; do not call `prepareInventory(USDT)` for this fixture. Before any warp or trade, assert:

```text
USDT.balanceOf(maker) == 0
convertToAssets(vault.balanceOf(maker)) > vault.maxWithdraw(maker)
vault.maxWithdraw(maker) == 17_249_152_905_331
safeCapacity = saturatingSub(
    USDT.balanceOf(maker) + vault.maxWithdraw(maker),
    liquidityBufferAssets
)
requestedOut > safeCapacity
```

Do not create the constrained case with a fresh deposit: a new deposit adds fresh liquidity and can remove the condition being demonstrated.

If the optional two-real-vault demo is built, it must not run the Aave-output trade into the Morpho input
vault before measuring the Morpho clamp. That reinvestment adds USDT liquidity
and can erase the fixture. Use independent fork snapshots for the Aave and
Morpho legs (preferred), or execute and assert the Morpho-output clamp first.

Morpho Vault V2 is excluded because its ERC-4626 `max*` methods intentionally return zero and therefore do not satisfy this adapter design.

For yield demonstrations, use `vm.warp`; rolling block number alone does not accrue timestamp-based lending interest. Isolate the proof from trading:

```text
record fixed share count S
record convertToAssets(S)
record Aqua virtual balance
warp before any trade
assert share count is still S
assert convertToAssets(S) increased
assert Aqua virtual balance is unchanged
```

Run the yield proof and each trade leg in separate snapshots. Withdrawals and
input reinvestments mutate shared liquidity and must not contaminate either the
yield-only NAV delta or the Morpho clamp fixture.

## 12. Definition of done

### Essential PoC

- [ ] dependencies pinned and project builds reproducibly;
- [ ] the minimal `0x92` / nested-loop / two-pass mechanism spike passes before
  the production architecture is frozen;
- [ ] disposable-account constraint is documented; no persistent deployment is used;
- [ ] vanilla Aqua swap passes;
- [ ] adapter unit suite passes;
- [ ] the deterministic exact-in hero swap begins with zero maker idle
  underlying for both assets and settles end to end;
- [ ] oversized candidate output clamps, with `actualInput <= requestedInput`
  universally and strict reduction in the hero fixture;
- [ ] exact-out unit and local integration correctness tests pass outside the
  demo path;
- [ ] the same hero flow with failed reinvest still settles and leaves input
  idle;
- [ ] exact physical and Aqua accounting assertions pass;
- [ ] non-binding core invariants pass; and
- [ ] binding/additivity exceptions are documented.

### Submission hard cut

- [ ] Aave Stata USDC fork swap passes;
- [ ] `vm.warp` shows increased maker NAV;
- [ ] real-vault reinvest gas is measured and a positive Aave reinvest smoke
  succeeds under its sealed gas limit;
- [ ] the six hero values are printed without requiring VM knowledge;
- [ ] one-command demo is deterministic; and
- [ ] README explains interfaces, custody, invariants, quote consistency, licenses, and cut scope.

### Optional stretch

- [ ] Morpho V1 USDT replaces the deterministic clamp on a pinned fork;
- [ ] the second real-vault reinvest path is calibrated and succeeds;
- [ ] gas delta versus vanilla Aqua is reported.

The hard cut line is one real Aave-backed fork swap plus the deterministic local
hero clamp. Morpho, fee economics, and presentation polish never displace the
core accounting, atomicity, and six-number story.
