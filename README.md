# Reservoir

> **Maker liquidity earns yield until the exact moment it is traded.**

Reservoir separates Aqua's virtual trading liquidity from idle custody.
Between trades, a disposable maker account owns ERC-4626 shares instead of
underlying tokens. At settlement, a SwapVM instruction limits output to what
the vault can safely deliver now, the maker materializes exactly that output,
and the received input is reinvested on a bounded best-effort path.

The v1 proof is intentionally narrow: one constrained exact-in trade, one
generic ERC-4626 adapter, and one real Aave StataTokenV2 USDC fork integration.
It is a production-style proof of the custody and settlement mechanism, not an
audited production deployment.

## See it in one command

Requirements: Git, GNU Make, and
[Foundry v1.7.1](https://github.com/foundry-rs/foundry/releases/tag/v1.7.1).

```sh
git submodule update --init --recursive
make demo
```

The RPC-free demo runs the same asserted scenario as the integration suite and
prints exactly:

```text
Vault NAV before -> after 1000000000000000000000 1099999999999999999999
Requested input 1000000000000000000000
Candidate output 500000000000000000000
Safely deliverable output 100000000000000000000
Actual input / output 111111111111111111112 100000000000000000000
Reinvestment result success; forced failure survived
```

Those values tell the complete story:

1. maker inventory starts entirely in vault shares;
2. the fixed shares gain NAV without changing Aqua's balance;
3. the XYC curve proposes 500 tokens of output;
4. current vault liquidity safely supports only 100;
5. Reservoir gives the taker 100 and charges about 111.11 instead of the
   requested 1,000; and
6. normal reinvestment succeeds, while a clean-fixture repeat with a broken
   vault still settles and leaves the input safely idle.

All local gates run with:

```sh
make build
make fmt
make test
```

## Architecture

```text
quote
  Taker -> ReservoirSwapVMRouter
             ReserveClamp -> maker.availableFor -> ERC4626ReserveAdapter
             XYCSwap      -> candidate output / inverse-recomputed input

output-first settlement
  maker.preTransferOut -> adapter.materialize -> vault.withdraw -> maker
  Aqua.pull(maker -> taker)
  Aqua.push(taker -> maker)
  maker.postTransferIn -> bounded adapter.reinvest -> vault.deposit shares to maker
```

The components are:

- [`ReservoirSwapVMRouter`](src/routers/ReservoirSwapVMRouter.sol), which
  extends the pinned Aqua router and handles raw opcode `0x92`;
- [`ReserveClamp`](src/instructions/ReserveClamp.sol), a zero-argument wrapper
  whose tail must be exactly one pure `XYCSwap`;
- [`ReservoirMakerAccount`](src/accounts/ReservoirMakerAccount.sol), the Aqua
  maker, share owner, reserve resolver, and authenticated hook target; and
- [`ERC4626ReserveAdapter`](src/adapters/ERC4626ReserveAdapter.sol), one
  immutable maker/vault/asset binding per reserve.

The canonical program is:

```text
[Deadline?] [Salt?] [ReserveClamp] [XYCSwap]
```

Every non-`0x92` opcode delegates to the upstream `AquaOpcodes` dispatcher.
For binding exact-in trades, `ReserveClamp` evaluates XYC once to get candidate
output, caps that output, then evaluates the same XYC tail as exact-out to find
the least input required for the capped amount. It restores the mode and
program-counter state required by the pinned
`XYCSwapRecomputeDetected` guards. The hero therefore guarantees
`actualInput <= requestedInput`, with a visible strict reduction in this
fixture.

## Reserve interface and custody

The frozen interface is
[`IAquaReserveAdapter`](src/interfaces/IAquaReserveAdapter.sol):

```solidity
function availableFor(address asset, uint256 wanted)
    external view returns (uint256 canDeliver, uint256 exitCostWad);
function materialize(address asset, uint256 amount)
    external returns (uint256 delivered);
function reinvest(address asset) external;
function idleThreshold(address asset) external view returns (uint256);
```

For v1:

```text
canDeliver =
  min(wanted, max(0, maker idle + vault.maxWithdraw(maker) - asset buffer))
exitCostWad = 0
```

A nonzero exit cost is rejected rather than silently ignored.
`availableFor` is view-safe and conservatively treats a failed vault view as
zero withdrawable inventory. `materialize` is exact-or-revert; partial filling
happens before hooks. `reinvest` transfers eligible maker idle assets through
the adapter, deposits shares directly to the maker, uses zero-first approvals,
and leaves no adapter dust after success.

The account is deliberately disposable and seals one router, two reserves, one
strategy hash, and per-asset reinvest gas limits. Hooks authenticate the
configured router, maker, pair, and order hash. A transient phase machine
enforces output-first settlement. The pinned SwapVM per-order transient lock
rejects same-order callback reentrancy; tests also cover caught and propagated
nested calls, static callback quotes, and inactive different-order calls.

Post-input reinvestment forwards at most the sealed asset limit, retains
completion gas, and copies zero returndata. A reverting, gas-burning, or
large-revert-data vault cannot roll back a settled swap. Failure emits
`ReinvestFailed` and leaves input idle; success emits `ReinvestSucceeded`,
while `AssetsReinvested` records the asset/share amounts.

## Correctness and quote consistency

The local campaign covers:

- exact physical token, recipient, vault-share, and Aqua virtual-balance
  deltas;
- view-safe capacity and exact materialization;
- maker-favoring XYC floor/ceil rounding;
- the exact discrete non-binding inverse;
- monotonic pricing and binding saturation;
- `actualInput <= requestedInput` for every constrained exact-in fill;
- exact-out correctness and best-effort partial fill;
- authorization, output-first ordering, callbacks, and atomic withdrawal
  failure; and
- normal, failed, gas-burning, and revert-bomb reinvestment.

Same-state quote and swap returns are exactly equal. Across blocks, vault
liquidity and share value may change. Exact-in users protect worsening output
with `minOut`; exact-out users cap absolute spend with `maxIn`, but v1 does not
promise a minimum exact-out fill or unit rate across blocks. A failed
materialization reverts atomically.

The intentional non-properties are documented in
[`SPEC.md §9`](SPEC.md#9-correctness-properties):

- additivity is not expected because capacity is state-dependent;
- global symmetry is not expected at a saturating clamp, although the
  non-binding discrete inverse is exact; and
- cross-block quote equality is not promised.

No Forge test is skipped. The CI profile fixes fuzz runs, invariant depth, and
the seed used by the gate command.

## Real Aave proof

Gate 2 uses a disposable mainnet fork at block `25,604,561`, hash
`0x95ca77908413d71bd01cada1ece52b6c2f35467dbbb8f2367144cd0ffbe7888d`.
It validates the USDC, StataTokenV2, aUSDC, and Aave Pool code and runtime
links before testing.

```sh
ETH_RPC_URL="https://your-archive-mainnet-rpc.example" make demo-aave
```

The fork proof:

- deposits maker USDC into the real StataTokenV2 vault;
- shows fixed-share NAV growth after a 30-day timestamp warp;
- restores a clean snapshot and settles a real Stata-backed output;
- reconciles recipient, maker, share, adapter, and Aqua deltas;
- runs the reverse USDC-input trade and positively observes real
  `ReinvestSucceeded`; and
- measures the complete reinvest path at 293,771 gas first/cold and 151,071
  repeat/warm, then verifies the sealed 500,000-gas USDC limit.

The fork command needs an archive-capable endpoint. It fails with a clear
preflight message rather than treating header-only access as proof. Full
fixture evidence and methodology are in
[`docs/FORK_FIXTURES.md`](docs/FORK_FIXTURES.md).

## Repository map

```text
src/interfaces/       frozen reserve interfaces
src/instructions/     ReserveClamp VM instruction
src/opcodes/          opcode dispatch and canonical program builder
src/routers/          Aqua router extension
src/accounts/         sealed disposable maker account and hooks
src/adapters/         generic single-vault ERC-4626 adapter
test/unit/            targeted instruction, adapter, and account tests
test/invariants/      deterministic math and quote properties
test/integration/     local Aqua vertical slice and adversarial paths
test/fork/            pinned Aave fixture and end-to-end proof
script/Demo.s.sol     shared-scenario six-line presentation
```

The normative documents are
[`V1_SCOPE.md`](V1_SCOPE.md), [`SPEC.md`](SPEC.md), and
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md). [`REVIEW.md`](REVIEW.md)
and [`REVIEW_FINDINGS.md`](REVIEW_FINDINGS.md) preserve the review trail.

## v1 cut scope

Reservoir v1 does not implement economic exit fees/spreads, gas-price oracles,
Morpho, borrowing, leverage, pooling, cross-chain support, upgrades, recovery
for long-lived accounts, a browser UI, or persistent-network deployment.
Exact-out remains tested but is not the presentation path. Morpho is the first
optional amplification only after the local and Aave gates remain repeatable.

## Upstream pins and licensing

The repository vendors immutable Git submodules:

- SwapVM `0817db4a618d975648e018222aedcdeb1206959e`
- Aqua `7a5972a6b562e3e622f6e6b2a0befef659cd5386`
- Solidity Utils `2d91bb67665467afc06907a69513b0fa66c46f0d`
- OpenZeppelin Contracts `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0`
- Forge Standard Library `8e40513d678f392f398620b3ef2b418648b33e89`

**Powered by SwapVM — © Degensoft Ltd 2025**

Aqua — © Degensoft Ltd 2025

Reservoir's SwapVM-derived extension files use
`LicenseRef-Degensoft-SwapVM-1.1`. Complete upstream licenses, notices, and
corresponding source remain in the pinned submodules. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for details. These terms,
not a generic permissive-license assumption, govern use and distribution.

No contract in this repository has been deployed or funded on a persistent
network.
