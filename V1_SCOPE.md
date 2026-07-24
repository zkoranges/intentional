# Reservoir v1 scope lock

> Status: submission-ready — Gates 0–3 and the independent final review are green
>
> Scope frozen: 2026-07-24
>
> Goal: deliver a repeatable hackathon demo, not a broad reserve-integration
> framework.

## 1. The product proof

Reservoir proves one idea:

> **Maker liquidity earns yield until the exact moment it is traded.**

Reservoir separates Aqua's virtual trading balance from physical custody.
Maker inventory remains represented by ERC-4626 shares between trades. At
settlement, Reservoir exposes only the output that can be safely withdrawn now,
materializes that exact output, and reinvests the received input on a
best-effort basis.

The judge-facing transaction is constrained exact-in:

1. maker idle underlying is zero and inventory is in vault shares;
2. a fixed share count gains NAV while Aqua's virtual balance is unchanged;
3. requested input produces a candidate output above safe capacity;
4. Reservoir reduces output to capacity and inverse-recomputes input;
5. the taker receives the exact returned output and pays no more than the
   returned input;
6. received input is reinvested; and
7. a clean-snapshot repeat with broken reinvestment still settles and leaves
   input idle.

The selected fixture must make `actualInput < requestedInput` visible. The
protocol-level guarantee remains `actualInput <= requestedInput`, because
integer rounding plateaus can produce equality.

## 2. v1 deliverables

### 2.1 Novel mechanism

- `ReservoirSwapVMRouter` extends the pinned Aqua router behavior.
- Raw opcode `0x92` is named `ReserveClamp`.
- `_runOpcode` handles `0x92` and delegates every other opcode to `super`.
- The instruction has zero argument bytes and rejects nonempty arguments.
- The program is:

```text
[Deadline?] [Salt?] [ReserveClamp] [XYCSwap]
```

- The tail is exactly one pure `XYCSwap`.
- Binding exact-in runs XYC once to find candidate output, clamps output, then
  runs XYC as exact-out to recompute the smaller input.
- Exact-out clamping remains tested, but is not part of the main demo.

### 2.2 Reserve custody

- One `ReservoirMakerAccount` is the Aqua maker, share owner, idle-underlying
  receiver, reserve resolver, and authenticated maker-hook target.
- One generic single-vault `ERC4626ReserveAdapter` is deployed per asset.
- `availableFor` is view-safe and reports buffered physical inventory:
  maker idle underlying plus `vault.maxWithdraw(maker)`.
- `materialize` is exact-or-revert. Partial filling happens before hooks.
- `reinvest` is thresholded and leaves no adapter dust on success.
- Output-first settlement is enforced with authenticated hooks and transient
  state.
- Post-input reinvestment uses bounded gas, preserves completion gas, copies no
  returndata, and cannot roll back an otherwise completed swap merely because
  the adapter call failed.
- Each asset has a sealed `uint32 reinvestGasLimit`. The scheme is frozen at
  bootstrap; real-vault values are measured later.

### 2.3 Proofs

- Deterministic local mock-vault hero flow.
- Local failed-reinvestment survival flow from the same clean snapshot.
- Targeted adapter, maker, instruction, accounting, and callback-safety tests.
- One pinned mainnet-fork Aave StataTokenV2 USDC compatibility proof.
- A positive Aave reinvestment calibration under its measured gas limit.
- Exact physical-token, share, and Aqua virtual-balance reconciliation.

### 2.4 Demo commands

`make demo` is the primary judge command. It must be deterministic and must not
require an RPC. It runs the local hero scenario and prints only:

```text
Vault NAV before -> after
Requested input
Candidate output
Safely deliverable output
Actual input / output
Reinvestment result
```

`make demo-aave` is the real-vault evidence command. It requires an
archive-capable `ETH_RPC_URL` and runs the pinned Aave fork proof. The local
judge demo must remain usable if that external RPC is unavailable at the venue.

## 3. Explicitly outside v1

- economic exit-cost, fee, or spread implementation;
- packed fee arguments, including `spreadBufferWad`;
- oracle-priced gas recovery or profitability claims;
- Morpho or a second real lending integration;
- exact-out as a presentation path;
- borrowing, leverage, pooling, or cross-chain support;
- production upgrades, recovery, or long-lived maker accounts;
- persistent-network deployment or funding;
- a browser UI; and
- gas optimization or vanilla-versus-Reservoir comparison.

`exitCostWad` remains in the interface as a future extension point and must be
zero in v1. A nonzero value is rejected rather than ignored.

## 4. Gate contract

### Gate 0 — mechanism feasibility

```text
forge build
forge fmt --check
forge test --match-test VanillaAqua
forge test --match-test ReserveOpcodeSpike
```

The spike must cover raw `0x92` dispatch, nested `runLoop`, the binding
exact-in mode flip, correct register/PC restoration, public static quote, and
partial-fill taker validation.

### Gate 1 — deterministic vertical slice

```text
forge build
forge fmt --check
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*" \
  --fuzz-seed 0x5245534552564f4952
```

The local hero success, failed reinvestment, exact accounting, authorization,
same-state quote/swap equality, exact-out correctness, and targeted callback
tests must pass.

### Gate 2 — real Aave evidence

```text
forge test --match-path "test/fork/AaveStataUSDC.t.sol" \
  --fork-url "$ETH_RPC_URL"
```

If `ETH_RPC_URL` is absent, all fork code must still compile and the missing
external acceptance is reported honestly. Gate 2 is required for
submission-ready status, but it never blocks development or execution of the
local judge demo.

### Gate 3 — working demo package

```text
make demo
```

Gate 3 adds no new protocol behavior. It packages assertions already proven by
Gates 0–1 into the six-number narrative. With an RPC available:

```text
make demo-aave
```

## 5. Definition of ready

Reservoir v1 is:

- **demo-ready** when Gates 0, 1, and 3 pass from a clean local checkout; and
- **submission-ready** when Gate 2 also passes against the pinned fork and the
  independent final review below is closed.

After development gates are green, a Claude Opus 5 reviewer receives the
normative documents, implementation, and exact gate outputs. Confirmed findings
are fixed and the affected gates are rerun; false positives are recorded but do
not change the implementation. Completion is not claimed until that review is
closed.

Optional work begins only after both statuses are repeatable. The first
optional amplification is Morpho Vault V1 replacing the deterministic
constraint. Fee economics requires a separately reviewed instruction version
and is not an incremental v1 patch.

## 6. Current upstream facts

As verified on 2026-07-24, the upstream `main` heads are still the reviewed
commits:

- [SwapVM `0817db4a618d975648e018222aedcdeb1206959e`](https://github.com/1inch/swap-vm/tree/0817db4a618d975648e018222aedcdeb1206959e)
- [Aqua `7a5972a6b562e3e622f6e6b2a0befef659cd5386`](https://github.com/1inch/aqua/tree/7a5972a6b562e3e622f6e6b2a0befef659cd5386)

The pin is load-bearing. Current SwapVM still validates best-effort amounts
with `requested >= actual`, and the XYC guards still require `amountOut == 0`
for exact-in evaluation and `amountIn == 0` for exact-out evaluation. Gate 0
must recheck those facts from vendored source and execute the mechanism spike;
remote-head verification alone is not acceptance.

The Foundry project pins Solidity `0.8.30` and `evm_version = "cancun"`.
Upstream license files, third-party notices, corresponding-source obligations,
the truthful Aqua attribution, and prominent
`Powered by SwapVM — © Degensoft Ltd 2025` attribution must be preserved.

The current official
[Aave address book](https://github.com/bgd-labs/aave-address-book/blob/main/src/ts/AaveV3Ethereum.ts)
continues to list the specification's Ethereum USDC, aUSDC, StataTokenV2, and
Pool addresses. Fork setup still treats runtime `asset()`, `aToken()`, Pool,
code, block-number, and block-hash checks as authoritative. No
`ETH_RPC_URL` was configured during this scope freeze, so historical state at
the pinned block was not re-executed in this pass and remains a Gate 2 runtime
acceptance rather than a claimed fresh result.

## 7. Document authority

For v1:

1. this file controls product and delivery scope;
2. `SPEC.md` controls protocol behavior inside that scope;
3. `IMPLEMENTATION_PLAN.md` controls sequencing and acceptance;
4. `REVIEW.md` and `REVIEW_FINDINGS.md` are the evidence and decision trail,
   not independent sources of new requirements.

Any conflict among the first three documents blocks implementation until the
documents are reconciled. Earlier runbooks requiring `ReserveClampAndFee`, a
packed `spreadBufferWad`, mandatory Morpho, or fee economics are superseded by
this v1 scope.
