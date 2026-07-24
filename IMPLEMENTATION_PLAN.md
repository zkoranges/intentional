# Reservoir v1 implementation plan

> Implements `V1_SCOPE.md` and `SPEC.md` v1.0.
>
> Gate 3 is demo packaging, not a fee/Morpho feature wave. Morpho remains an
> optional post-v1 amplification.

This plan is organized around one judge-facing outcome: a constrained exact-in
trade that keeps inventory productive until settlement, reduces both output and
input safely, and survives reinvestment failure. Parallel agents start only
after the novel VM mechanism passes a minimal spike. Every wave ends in a
runnable slice.

The submission hard cut is the deterministic hero flow plus one real
Aave-backed fork swap. Morpho, fee economics, gas comparison, and presentation
polish are optional.

## 1. Working rules

- Use independent branches/worktrees for implementation agents.
- The integrator owns shared interfaces, dependency pins, configuration structs, and merge order.
- An agent does not edit another agent’s owned directories without an explicit handoff.
- Each branch must compile, format, and run its targeted tests before integration.
- Fork tests never become prerequisites for local deterministic tests.
- Maker accounts are disposable local/fork fixtures; never deploy or fund v1 on a persistent network.
- The exact-in hero path is implemented before exact-out completeness work.
- No economic fee or spread work is scheduled in the hackathon hard cut.
- Morpho is never allowed to delay correctness, the Aave path, or the demo.

## 2. Dependency graph

```text
Gate 0: bootstrap + vanilla Aqua + minimal VM mechanism spike
                              |
                        freeze contracts
                              |
          +-------------------+--------------------+
          |                   |                    |
          v                   v                    v
   Agent A: VM path    Agent B: custody     Agent C: fork/gas facts
          |                   |                    |
          +---------+---------+                    |
                    v                              |
        Gate 1: deterministic exact-in hero         |
                    |                              |
                    +------------------------------+
                              |
                   +----------+----------+
                   |                     |
                   v                     v
        Gate 2: real Aave proof   Gate 3: local demo package
                   |                     |
                   +----------+----------+
                              |
                              v
        Optional post-v1: Agent B Morpho adapter +
                          Agent C Morpho fork/demo
```

## 3. Proposed repository layout

```text
src/
  accounts/
    ReservoirMakerAccount.sol
  adapters/
    ERC4626ReserveAdapter.sol
    AaveStataReserveAdapter.sol    # optional: only if generic behavior is insufficient
    MorphoV1ReserveAdapter.sol     # optional stretch, same rule
  instructions/
    ReserveClamp.sol
  interfaces/
    IAquaReserveResolver.sol
    IAquaReserveAdapter.sol
  opcodes/
    ReservoirOpcodes.sol
  routers/
    ReservoirSwapVMRouter.sol

test/
  spikes/
    ReserveOpcodeSpike.t.sol       # Gate 0, integrator-owned
  unit/
    adapters/
    accounts/
    instructions/
  integration/
    ReservoirAqua.t.sol
  invariants/
    ReservoirInvariants.t.sol
  fork/
    AaveStataUSDC.t.sol
    MorphoV1USDT.t.sol             # optional stretch
  gas/
    ReservoirGas.t.sol             # optional stretch
  mocks/
    MockERC4626.sol
    RevertingERC4626.sol
    USDTLike.sol

script/
  Demo.s.sol

docs/
  FORK_FIXTURES.md

SPEC.md
REVIEW.md
REVIEW_FINDINGS.md
IMPLEMENTATION_PLAN.md
README.md
Makefile
```

Do not create empty protocol-named wrappers merely to claim “two adapters.”
Deploy the generic adapter against each compatible vault unless a compatibility
test proves that protocol-specific behavior is necessary. Optional wrapper
files are not part of the Gate 0 shell set.

## 4. Gate 0 — integrator bootstrap

Gate 0 is sequential because every later branch depends on it.

### Tasks

1. Initialize the Foundry repository.
2. Pin SwapVM and Aqua to the reviewed commits.
3. Pin the implementation toolchain:
   - Foundry `1.7.1` (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`) in CI/bootstrap;
   - `solc_version = "0.8.30"`; and
   - `evm_version = "cancun"` (or a deliberately documented later EVM target)
     so transient storage is enabled.
4. Preserve upstream licenses, notices, and attribution.
5. Add CI commands for build, format, unit, integration, invariant, and fork suites.
   Commit a bounded CI invariant profile (`runs = 128`, `depth = 32`,
   `timeout = 120`) and run the gating campaign with fixed seed
   `0x5245534552564f4952`. Runs/depth bound runtime; the fixed seed makes the
   gate reproducible.
6. Port the smallest upstream vanilla Aqua swap test and make it pass unchanged
   in behavior under the pinned EVM; this also smoke-tests SwapVM's transient
   order lock.
7. Before freezing the production architecture, add one disposable,
   test-only mechanism spike. It must:
   - dispatch raw opcode `0x92` through an `_runOpcode` override while stock
     opcodes still delegate to `super`;
   - call a one-instruction `XYCSwap` tail through nested `ctx.runLoop()`;
   - make a binding exact-in quote reset `nextPC`, flip to exact-out, zero
     `amountIn`, set the clamped `amountOut`, and run the tail a second time;
   - restore `ctx.query.isExactIn`, retain the recomputed registers and consumed
     end-of-program PC, and prove unrelated context fields are unchanged;
   - exercise the public `asView().quote` static-call path so the pin's exact-in
     `requestedInput >= actualInput` taker validation is covered; and
   - assert `actualOutput == safeCapacity` and
     `actualInput < requestedInput`. The strict fixture is required so this
     spike would fail against a later equality validator.
8. Only after that spike passes, freeze:
   - `IAquaReserveResolver` and `IAquaReserveAdapter`;
   - `ReserveConfig`, including a sealed nonzero per-asset
     `uint32 reinvestGasLimit` field but not its numeric real-vault values;
   - adapter resolver rules;
   - maker controller, custody, authorization, and immutable allowance policy;
   - opcode `0x92`, implicit maker resolver, and zero instruction arguments;
   - program order;
   - capacity and zero-fee partial-fill math;
   - the bounded reinvest/retained-gas accounting scheme, but not unmeasured
     gas-cap constants;
   - event and error names; and
   - maker and taker traits, including Aqua custody, sorted tokens, direction, transfer order, and thresholds.
9. Add required contract/test shells so file ownership is clear. Do not add
   empty Aave/Morpho specialization shells.

### Gate 0 acceptance

```text
forge build
forge fmt --check
forge test --match-test VanillaAqua
forge test --match-test ReserveOpcodeSpike
```

All pass, the spike's context-transition assertions are green, and no
implementation agent has an unresolved interface question.

## 5. Parallel wave 1 — essential local PoC

### Agent A — SwapVM instruction and router

Owns:

```text
src/instructions/
src/opcodes/
src/routers/
test/unit/instructions/
test/invariants/
```

Tasks:

1. Promote the proven spike into production `ReserveClamp`.
2. Implement exact-in cap detection and inverse input recomputation first.
3. Implement exact-out clamping as a tested, non-demo path.
4. Reject a nonzero resolver `exitCostWad`; v1 does not silently ignore an
   economic cost it does not price.
5. Restrict/document the downstream tail to pure `XYCSwap`.
6. Add opcode dispatch at `0x92` while delegating all upstream Aqua opcodes.
7. Add program-building helpers.
8. Emit `ReserveClamped` only on a binding non-static exact-in swap, carrying
   the requested input, candidate output, safe capacity, and actual fill. No
   exact-out telemetry event is needed.
9. Pin and test the exact `isExactIn` / `nextPC` / `amountIn` / `amountOut`
   transition and prove all unrelated context fields remain unchanged.
10. Prove:
   - the exact non-binding minimal-input inverse property;
   - maker-favoring rounding;
   - monotonicity;
   - binding output saturation;
   - input recomputation;
   - `actualInput <= requestedInput` for every clipped exact-in fill;
   - strict `actualInput < requestedInput` for the hero fixture;
   - a constrained public exact-out quote returns
     `actualOutput < requestedOutput`, covering the pin's second
     partial-fill validation branch;
   - deterministic behavior at `balanceOut == 0` and `balanceOut == 1`; and
   - safe capping when exact-out requests reach or exceed the full virtual reserve.

Instruction-local resolver doubles belong under
`test/unit/instructions/` (or in the test file) and do not depend on Agent B's
`test/mocks/`.

Acceptance:

```text
forge test --match-path "test/unit/instructions/*"
FOUNDRY_PROFILE=ci forge test --match-path "test/invariants/*" \
  --fuzz-seed 0x5245534552564f4952
```

### Agent B — maker account and adapters

Owns:

```text
src/accounts/
src/adapters/
test/unit/accounts/
test/unit/adapters/
test/mocks/
```

`src/interfaces/` is integrator-owned and read-only to Agent B. The integrator must approve and apply any interface edit.

Tasks:

1. Implement deterministic mock ERC-4626 vaults:
   - normal;
   - hero vault with independently controlled share-price growth and
     `maxWithdraw`, allowing rest → earn → clamp in one scenario;
   - reverting `maxWithdraw`;
   - reverting deposit;
   - USDT-like approval behavior;
   - gas-burning reinvest; and
   - huge revert-data reinvest.
2. Implement the one-vault adapter:
   - view-safe availability;
   - idle plus withdrawable inventory;
   - asset-unit capacity buffer;
   - exact materialization;
   - thresholded reinvestment; and
   - strict `onlyMakerAccount` authorization.
   Reinvestment must transfer underlying maker → adapter, force-approve
   adapter → vault, deposit shares to the maker, and leave no adapter dust.
3. Implement the maker account:
   - immutable controller and controller-only pre-seal setup;
   - single-assignment router, token, and asset/adapter slots;
   - sealed per-asset reinvest gas limits;
   - pre-seal `prepareInventory` through the configured adapter;
   - unlimited approvals to immutable Aqua and adapter spenders;
   - atomic configuration sealing and strategy shipping with exact `abi.encode(order)`;
   - `router.hash(order) == Aqua.ship(...)` identity assertion;
   - sorted/aligned ship arrays and pre-ship NAV-backing checks;
   - authenticated pre-out materialization;
   - transient output-first ordering guard in `preTransferIn`;
   - clear-before-call transient phase handling;
   - bounded-gas, retained-reserve, zero-returndata post-in reinvest; and
   - amount-less maker `ReinvestSucceeded` / `ReinvestFailed` events, plus an
     adapter event carrying deposited assets and shares.
4. Cover wrong asset, wrong caller/controller, wrong order, balance delta, share delta,
   idle-only materialization, reverting deposit previews, no adapter dust,
   gas-burning and huge-revert-data deposits, and sequential
   maker/Aqua/adapter/vault allowance tests, plus post-hook gas just below,
   at, and above the retained-reserve boundary.
5. Provide a configurable malicious-taker mock for Gate 1 that can attempt a
   same-order or different-order nested swap and either catch or propagate the
   inner failure. The different-order Aqua path normally fails on its inactive
   strategy before hooks; Agent B separately unit-tests wrong-hash maker-hook
   authorization. The integrator owns the full pinned-router callback
   scenarios.

Acceptance:

```text
forge test --match-path "test/unit/accounts/*"
forge test --match-path "test/unit/adapters/*"
```

### Agent C — fork fixture spike and demo data

Owns:

```text
test/fork/
script/
docs/FORK_FIXTURES.md
```

This agent does not wait for the local implementation. It validates external
assumptions with isolated, disposable fork harnesses. Mutating measurements use
a fresh snapshot/test and never contaminate another fixture.
It records fixture evidence in `docs/FORK_FIXTURES.md`; the integrator alone
folds those notes into `README.md`.

Tasks:

1. Require an archive-capable RPC and pin Ethereum block `25,604,561` plus
   block hash
   `0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d`.
   Add a clear archive/preflight failure.
2. Assert code, `asset()`, and `aToken()` for Aave StataTokenV2 USDC; verify the
   referenced aUSDC underlying and Pool.
3. Record `maxWithdraw`, `maxDeposit`, `previewDeposit`, `previewWithdraw`, and liquidity at that block.
4. Verify `vm.warp` changes share asset value.
5. Measure first and repeat direct vault deposits as lower bounds for the
   eventual full adapter reinvest call. Record call setup, warm/cold state, gas,
   and a proposed margin; do not freeze a production cap yet.
6. Produce reusable constants and fixture setup without implementing production adapters.

Morpho fixture work does not begin in Wave 1.

Acceptance:

```text
forge test --match-path "test/fork/*Fixture*" --fork-url "$ETH_RPC_URL"
```

when an RPC URL is configured. The branch must still compile without running fork tests.

### Integrator during wave 1

The integrator:

- protects the frozen interfaces;
- answers cross-agent questions;
- keeps a small mock E2E harness ready;
- reviews math and authorization before merging; and
- merges Agent B before Agent A’s end-to-end wiring.

## 6. Gate 1 — local vertical slice

The integrator builds `test/integration/ReservoirAqua.t.sol`.

Required scenarios:

1. vanilla Aqua baseline;
2. hero setup has zero maker idle underlying for both assets and maker-owned
   vault shares;
3. fixed shares gain NAV while Aqua's virtual balance stays fixed;
4. an exact-in request produces a candidate output above safe capacity;
5. actual output equals safe capacity and never exceeds it;
6. `actualInput <= requestedInput`, with strict reduction in the hero fixture;
7. exact output materializes only in `preTransferOut`;
8. recipient/token/Aqua/share deltas reconcile exactly;
9. received input is reinvested after `Aqua.push`;
10. from the same pre-trade snapshot, broken reinvest still settles and leaves
    input idle;
11. normal vault-backed exact-out and constrained exact-out remain green as
    non-demo correctness cases;
12. both A→B and B→A resolve the correct output and input adapters;
13. pre-withdraw failure is atomic;
14. gas-burning and huge-revert-data post-hooks preserve the retained gas reserve;
15. input-first taker traits revert before any token delta;
16. enabled callback nested swaps follow the pinned same-order lock and
    different-order inactive-strategy behavior, while a callback
    `asView().quote` remains static;
17. same-state quote equals swap;
18. stale exact-in capacity decrease is stopped by `minOut`;
19. stale exact-out may settle a smaller best-effort fill under `maxIn`; and
20. two sequential swaps retain all required allowances.

Gate 1 acceptance:

```text
forge build
forge fmt --check
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*" \
  --fuzz-seed 0x5245534552564f4952
```

There are no unexplained skips. Additivity and global binding symmetry skips
link to `SPEC.md`. The hero test asserts `ReserveClamped` telemetry against the
resolver read, swap return values, and physical deltas so the later demo script
does not duplicate settlement math.

## 7. Parallel wave 2 — first real path

### Agent B — Aave adapter

Tasks:

1. Run the generic adapter compatibility suite against StataTokenV2. Add a
   named specialization only if a test proves generic behavior is insufficient.
2. Validate `asset()`, maker ownership, and compatible `maxWithdraw`.
3. Treat `maxWithdraw` as authoritative.
4. Cover deposit-floor/withdraw-ceil rounding.
5. Keep exit cost zero.
6. Hand Agent C a complete first/repeat adapter `reinvest` path and the expected
   success events/deltas. Agent C owns the pinned-fork calibration test; Agent B
   reviews the chosen limit against the implementation.

The integrator also deploys the already-tested generic adapter against a deterministic mock vault for the non-USDC token. Gate 2 therefore has a real Aave output leg and a mock input leg; it does not pretend one USDC adapter can reinvest another asset.

### Agent C — Aave fork integration

Tasks:

1. Measure the complete first and repeat Aave adapter `reinvest` path, including
   maker transfer and approval work, using a disposable calibration account
   rather than mutating the sealed demo account. Choose a documented limit from
   the worst measurement plus margin and add a positive smoke asserting idle
   decreases, shares increase, `ReinvestSucceeded` is emitted, and
   `ReinvestFailed` is not.
2. Configure both adapters and all required approvals. Seal the measured Aave
   limit only for USDC; use the separately tested local limit for the mock
   asset.
3. Fund the maker with small deterministic amounts of USDC and the mock asset.
4. Run `prepareInventory` for both assets.
5. Derive each shipped virtual balance from actual post-deposit idle assets plus
   `convertToAssets(makerShares)`, allowing for vault rounding.
6. Atomically `sealAndShip` the Aqua strategy.
7. From the post-ship snapshot, record a fixed share count and Aqua balance,
   warp time, and assert that `convertToAssets(shares)` rises while the share
   count and Aqua balance stay fixed.
8. Restore the post-ship snapshot before any trade.
9. Quote and execute a non-binding swap.
10. Assert:
   - maker idle USDC was zero immediately before the trade;
   - output was in shares before the swap;
   - exact underlying appeared only for settlement;
   - recipient delta equals returned output;
   - Aqua deltas are exact;
   - input is reinvested; and
   - same-state quote delta is zero.
11. Run the calibrated Aave-input reinvest smoke if the showcased trade's input
    token is the mock asset; do not infer real Stata deposit success from a mock
    input-vault swap.

## 8. Gate 2 — Aave-backed project

Gate 2 is the real-vault evidence gate. Section 9 may package the already-proven
local path after Gate 1 while an external RPC is unavailable, but
submission-ready status requires this Aave gate as well.

Acceptance:

```text
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*" \
  --fuzz-seed 0x5245534552564f4952
forge test --match-path "test/fork/AaveStataUSDC.t.sol" --fork-url "$ETH_RPC_URL"
```

The demo can already prove the project if:

- the local clamp is deterministic;
- the real Aave swap is end to end;
- yield is visible after `vm.warp`;
- failed reinvest is non-fatal; and
- accounting is exact.

## 9. Gate 3 — working demo package

After Gate 1 is green, Agent C connects the already-tested local hero scenario
to its owned `script/Demo.s.sol`. Gate 2 evidence may proceed in parallel and
does not make the local judge command depend on an external RPC. The integrator
reviews that handoff and owns the top-level `Makefile` targets. The script must
not implement separate swap math or setup logic; it reads `ReserveClamped`,
swap returns, maker reinvestment events, and NAV state.

Required output, and no additional numeric dashboard:

```text
Vault NAV before -> after
Requested input
Candidate output
Safely deliverable output
Actual input / output
Reinvestment result
```

The narration is: rest, earn, challenge, adapt, settle, survive. The Aave fork
is identified as the real compatibility proof; the deterministic mock is
identified honestly as the controlled liquidity constraint. Exact-out, VM
registers, gas micro-details, and optional protocols stay out of the main
presentation.

Acceptance:

```text
make demo
```

The command runs from a documented clean environment without an RPC, emits the
six values in a stable order, and links each value to an assertion already
covered by Gate 1. It is the primary judge command.

When an archive RPC is configured:

```text
make demo-aave
```

That command runs the pinned Gate 2 compatibility proof. It is separate so a
venue RPC failure cannot break the deterministic local presentation.

## 10. Optional post-v1 wave — real constrained liquidity

Do not begin this wave unless the local demo and Aave submission proof can both
be run repeatedly without intervention.

### Agent B — Morpho V1 adapter

1. Explicitly accept only compatible MetaMorpho/Vault V1 behavior.
2. Defensively catch expensive/reverting view paths.
3. Cover withdrawal-queue liquidity bounds and deposit caps.
4. Keep Vault V2 rejected/documented.
5. Prefer the generic adapter; add a named wrapper only for behavior proven
   necessary by these tests.
6. Hand Agent C the complete Morpho reinvest path and expected success
   events/deltas; Agent C owns fork calibration.

### Agent C — Morpho fork and demo script

1. On a disposable account, measure first/repeat full Morpho reinvest calls,
   choose a separate measured limit plus margin, then exercise the maker's
   bounded post-hook at that sealed limit. Assert idle decreases, shares rise,
   `ReinvestSucceeded` is emitted, and `ReinvestFailed` is not.
2. From a fresh snapshot, configure the pinned Morpho and Aave adapters on a
   fresh maker account.
3. Fund and `prepareInventory` for USDC only.
4. Transfer existing Morpho shares to the maker; do not prepare fresh USDT.
5. Derive both post-setup NAV balances and atomically `sealAndShip`.
6. Assert maker idle USDT is zero and the raw pinned `maxWithdraw` before any
   warp or trade.
7. Request output above `idle + maxWithdraw - liquidityBufferAssets`.
8. Show:
   - requested output;
   - raw vault max;
   - buffered capacity;
   - actual filled input and output; and
   - exact post-settlement deltas.
9. Snapshot before mutating the fork.
10. Run the yield proof, Aave leg, and Morpho leg from independent fork snapshots
   so USDT reinvestment cannot erase the Morpho constraint.
11. Replace the deterministic clamp in an optional demo mode; do not add more
    headline metrics to the six-number story.

### Agent A — optional gas comparison

Owns:

```text
test/gas/ReservoirGas.t.sol
```

1. Add a vanilla Aqua baseline using the same pair and trade size.
2. Record Reservoir quote and swap overhead outside the hero output.
3. Do not optimize unless a measured regression threatens the demo.

## 11. Final review

Required hard-cut run:

```text
forge build
forge fmt --check
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/*" \
  --fuzz-seed 0x5245534552564f4952
make demo
forge test --match-path "test/fork/AaveStataUSDC.t.sol" --fork-url "$ETH_RPC_URL"
make demo-aave
```

The local commands establish demo-ready status. The fork commands establish
submission-ready status and are pending—not faked—when `ETH_RPC_URL` is absent.
Run optional Morpho/gas suites only when their post-v1 wave was deliberately
enabled.

Review checklist:

- no mutable adapter configuration after strategy shipping;
- no unauthenticated unwind/materialization surface;
- all token operations use `SafeERC20`;
- USDT approvals use zero-first semantics;
- no hook can silently choose a different adapter than the quote;
- every clipped exact-in fill has `actualInput <= requestedInput`, and the hero
  fixture has strict `<`;
- recipient, Aqua, maker, vault-share, and idle deltas reconcile;
- reinvest failure is caught only after valid auth/config decoding;
- the real Aave reinvest path succeeds under its measured gas limit;
- callback nested-swap safety is asserted against the pinned same-order lock,
  different-order inactive-strategy behavior, and direct wrong-hash maker
  authorization—not inferred from disabled demo callbacks;
- stale exact-in quotes are protected by `minOut`;
- exact-out `maxIn` semantics are tested and documented outside the hero demo;
- fork assertions validate code and assets;
- upstream licenses and attribution are present;
- v1 has not been deployed or funded on a persistent network; and
- all documented skips have a mathematical or scope justification.

## 12. Independent final review

After Gates 0–3 are green, request an independent review from Claude Opus 5.
The reviewer receives:

- `V1_SCOPE.md`, `SPEC.md`, `IMPLEMENTATION_PLAN.md`, `REVIEW.md`, and
  `REVIEW_FINDINGS.md`;
- all Reservoir source, tests, scripts, notices, and dependency pins; and
- the exact local, fork, and demo acceptance outputs.

The review must cover frozen-architecture compliance, two-pass VM semantics,
custody and authorization, physical/Aqua accounting, bounded reinvestment,
callback safety, fork-fixture validity, license compliance, test coverage, and
demo reproducibility. Record its disposition in `FINAL_REVIEW.md`.

Apply only confirmed findings. Record false positives with evidence, rerun every
affected gate after fixes, and do not claim completion while a confirmed
material finding remains open.

## 13. Cut order

Already cut from the hard path:

1. economic exit-cost/spread implementation;
2. oracle-priced gas recovery;
3. Morpho real-vault demo;
4. gas comparison;
5. protocol-specific wrapper contracts when the generic adapter suffices; and
6. terminal polish beyond the six hero values.

Do not cut:

- the Gate 0 mechanism spike;
- vanilla Aqua baseline;
- deterministic adapter tests;
- the deterministic rest → earn → exact-in clamp → settle hero;
- `actualInput <= requestedInput` and strict reduction in the hero fixture;
- exact-out unit and local integration correctness outside the demo;
- one real Aave-backed fork swap and a positive real reinvest calibration;
- exact physical and Aqua accounting;
- authorization;
- adversarial callback/reentrancy tests;
- atomic pre-withdraw failure;
- non-fatal reinvest failure; or
- same-state quote/swap equality.

## 14. Agent task template

Every implementation-agent prompt should include:

```text
Read SPEC.md, REVIEW.md, and your gate in IMPLEMENTATION_PLAN.md first.
REVIEW_FINDINGS.md is an audit trail; resolved requirements live in the
normative documents above.
State the files you own.
Do not change frozen interfaces or dependency pins.
Implement only the assigned gate.
Add targeted tests before integration tests.
Run forge fmt --check and the owned test paths.
Report:
  - files changed;
  - tests run;
  - assumptions;
  - invariant skips;
  - integration notes;
  - blockers.
```

An agent is done only when its branch is independently reviewable and its acceptance commands pass.
