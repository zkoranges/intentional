# Reservoir v1 — independent final review

> Review requested by the project owner and required by
> `IMPLEMENTATION_PLAN.md` §12.
>
> Reviewed commit: `70df11c7dbfc319ee6501f88617dd6d4116812b5`
>
> Reviewer: Claude Opus 5 (`claude-opus-5`, maximum reasoning)
>
> Paseo review agent: `d71e433b-bc8d-4d08-9d49-67a726187123`
>
> Review date: 2026-07-24

## Initial verdict

**PASS WITH REQUIRED FIXES**

The reviewer found no High or Medium issue and no protocol, custody,
accounting, authorization, callback, or settlement defect. It identified one
required Low license-compliance correction and four recommended Low
regression/coverage corrections.

## Independent reproduction

The reviewer read the normative documents and implementation, inspected the
vendored upstream code at the exact pins, and independently reproduced:

| Gate | Result |
|---|---|
| `forge build` | passed |
| `forge fmt --check` | passed |
| fixed-seed non-fork campaign | 92 passed, 0 failed, 0 skipped |
| `make demo` | exactly six deterministic lines |
| all pinned fork tests via `https://eth.drpc.org` | 6 passed, 0 failed |
| `make demo-aave` | 3 passed, 0 failed |

It independently re-derived the hero math and verified the fork block hash,
timestamp, Aave runtime wiring, direct-deposit gas, complete adapter gas, share
amounts, and timestamp-based NAV growth.

## Confirmed findings and disposition

### L1 — required: SwapVM modification/date notice

The SwapVM-1.1 license requires modifications and their date to be clearly
marked. The repository preserved licenses, source, pins, and attribution, but
`THIRD_PARTY_NOTICES.md` did not identify the new extension files or their
authorship date.

**Disposition:** confirmed and fixed. `THIRD_PARTY_NOTICES.md` now identifies
every Reservoir file under `LicenseRef-Degensoft-SwapVM-1.1`, states that no
upstream file was modified in place, and records 2026-07-24.

### L2 — Low: CI omitted the primary judge demo

Build, formatting, and tests could remain green while a seventh output line or
broken filter violated the six-line demo contract.

**Disposition:** confirmed and fixed. CI now executes `make demo`.

### L3 — Low: invariant timeout missing from the frozen CI profile

The plan freezes a 120-second invariant timeout even though the current
invariant directory contains deterministic fuzz/property tests rather than a
stateful campaign.

**Disposition:** confirmed and fixed. `timeout = 120` is now explicit under
`[profile.ci.invariant]`.

### L4 — Low: two integration reverts were not selector-qualified

The withdrawal-atomicity and stale exact-in tests could have passed on an
unrelated earlier revert.

**Disposition:** confirmed and fixed. The tests now require
`ForcedVaultRevert` and the exact
`TakerTraitsInsufficientMinOutputAmount(actual, minOut)` payload.

### L5 — Low: adapter capacity boundary triple missing

The specification requires adapter-level checks immediately below, at, and
above buffered capacity.

**Disposition:** confirmed and fixed. The adapter suite now asserts
`1989 -> 1989`, `1990 -> 1990`, and `1991 -> 1990` for the existing
`safeAvailable = 1990` fixture.

## Rejected false positives / non-issues

The reviewer explicitly checked and rejected the following as findings:

1. restoring `isExactIn = true` is equivalent to restoring the saved value
   because only the exact-in branch can reach that assignment;
2. sweeping donated adapter underlying to the maker strictly strengthens
   liveness and custody;
3. local mock yield need not be timestamp-based; the real Aave proof uses
   `vm.warp`;
4. the demo's success boolean is unreachable unless its event assertion passed;
5. a fresh deployment for the broken-reinvest leg is at least as clean as a
   reverted snapshot;
6. arbitrary program bytes are controller-only and sealed into a disposable
   account's order hash;
7. unlimited approvals are intentionally limited to immutable Aqua/adapter
   spenders;
8. pre-call sealing rolls back atomically if `Aqua.ship` or hash identity fails;
9. the Aqua attribution wording is correct because Reservoir calls Aqua
   through its published interface and does not modify Aqua;
10. caller-induced low-gas reinvest failure strands no funds and leaves idle
    assets deliverable;
11. zero-capacity error ordering follows the pinned maker/taker validators; and
12. the default and CI compiler profiles are identical for the non-fuzz demo.

## Scope observations

Morpho, fee/spread economics, oracle gas recovery, gas comparison, a UI, and
persistent deployment remain correctly outside v1. Exact-out remains tested
but is not the presentation path. No scope expansion was recommended or
applied.

## Post-fix closure

All confirmed positives above were applied. The complete affected-gate rerun
then produced:

| Command | Post-fix result |
|---|---|
| `forge build` | passed |
| `forge fmt --check` | passed |
| fixed-seed non-fork campaign | 93 passed, 0 failed, 0 skipped |
| all pinned fork tests via `https://eth.drpc.org` | 6 passed, 0 failed |
| `make demo` | exactly six deterministic lines |
| `make demo-aave` | 3 passed, 0 failed |

The added adapter boundary test accounts for the local count increasing from
92 to 93. No fork behavior or measured gas constant changed.

## Final disposition

**PASS**

The required license notice and every recommended confirmed Low finding are
closed. No confirmed material finding remains open. The twelve rejected
false positives were recorded but did not change the implementation.
