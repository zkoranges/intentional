# Reservoir Uniswap payouts — buildable specification

> Version: 0.5.0-as-built (0.4.0-implementation-ready, 0.3.0-buildable,
> 0.2.0-minimal, and the complete 0.1.0 specification are in git history)
>
> Status: **S-1 through S-6 are built and green**, and the §12 any-payout-asset
> generalization — deferred in 0.4.0 — shipped with them. What remains is the
> seller-side CLI, the scripted demo, three Makefile targets, the submission
> surface, and the optional mainnet deployment. Every section below is bound to
> the code that now exists; §11 is the only forward-looking part, and it is
> written so the remainder needs no further design decisions.
>
> Target bounty: ETHGlobal Lisbon 2026 — Best Uniswap API Integration ($7,000
> pool: $4,000 / $2,000 / $1,000)
>
> **Source files reference this document by section number.** §2.1, §4.3, §5,
> §8, §10.4, §11.1, and §12 are cited in code comments. Section numbering is
> stable across versions — renumber nothing.

## 0. State of the build

Verified 2026-07-26 by running the suites, not by reading the git log.

| Step | Deliverable | State |
|---|---|---|
| S-1 | `test/fork/UniswapPayoutSpike.t.sol` | **built** — 2 tests green |
| S-2 | `src/payouts/` (4 files, 631 lines) | **built** — `forge build`, `forge fmt --check` clean |
| S-3 | `test/unit/payouts/` + `MockUniswapProxy` | **built** — 18 + 11 tests green |
| S-4 | `fetch-uniswap-route.mjs`, §10.3 integration, §10.4 fork proof | **built** — 3 + 3 tests green, both fixtures committed |
| S-5 | `create-uniswap-payout-quote.mjs` | **built** — 287 lines |
| S-5b | `execute-uniswap-payout-quote.mjs`, `UniswapPayoutDemo.s.sol`, Makefile targets | **remaining** — §11.3 |
| S-6 | Submission surface | **partial** — `FEEDBACK.md` and README done; §11.4 |
| S-7 | `DeployUniswapPayoutMainnet.s.sol` | **remaining, optional** — §11.2 |
| §12 | Any payout asset | **built, ahead of plan** |

Measured on 2026-07-26:

```text
make test                      252 passed, 0 failed, 0 skipped
forge test test/fork/UniswapPayout*    5 passed, 0 failed
  PAYOUT FORK | api quoted USDC:    9349109
  PAYOUT FORK | signed minimum USDC: 9255617
  PAYOUT FORK | delivered USDC:     9349109
```

Three as-built decisions diverge from 0.4.0 and are load-bearing. Read §16
before changing anything in `src/payouts/`.

## 1. Decision

A seller sells a delayed claim and receives their chosen payout asset instead
of WETH, in one transaction. The factor still underwrites and funds the claim
in WETH; a Uniswap Trading API route converts the exact WETH advance and
delivers the payout asset directly to the seller.

```text
seller stETH
    -> canonical Lido withdrawal request minted to factor
    -> exact WETH materialized from Aave StataWETH
    -> Uniswap API-produced CLASSIC route executes
    -> seller receives at least the signed minimum payout asset
```

The transaction reverts unless both hold: the complete claim is acquired, and
the seller's measured payout increase is at least the signed minimum.

The API is load-bearing: without its route calldata there is no payout. A
displayed quote without execution does not qualify and has not been shipped.
Uniswap prices only the WETH→payout conversion; the factor prices the claim.

**Product framing.** This is the step that turns Reservoir from a settlement
contract into a payouts primitive. The v2 kernel already pays a fixed, signed
amount rather than a swap output; this layer decouples the *payout currency*
from the *funding currency*, so the recipient is paid in what they asked for
while the factor continues to underwrite in WETH.

USDC is the demonstrated payout asset and the only one exercised by the fork
proof, but it is a *quote field behind a factor allowlist*, not a compiled-in
constant — see §12.

## 2. Gate 0 evidence

API-side probes ran 2026-07-25 with a valid key against
`trade-api.gateway.uniswap.org/v1`:

| Check | Result |
|---|---|
| `/quote`, contract as `swapper`, zero WETH balance | accepted, `routing: CLASSIC` (requestId `cfe8e6a4…`) |
| `recipient` different from `swapper` | accepted |
| `x-permit2-disabled: true` | `permitData: null` — no signature the executor cannot produce |
| `/swap` with `simulateTransaction: false` | usable transaction: `from` = contract swapper, `value: 0`, nonempty calldata |
| Observed proxy target | `0x02E5be68D46DAc0B524905bfF209cf47EE6dB2a9` |
| Observed calldata selector | `0x2894adf9` |
| `/swap` with `simulateTransaction: true` | fails for a zero-balance swapper (`FAILED_TO_ESTIMATE_GAS: TRANSFER_FROM_FAILED`, requestId `15942d10…`) |
| `/swap` with explicit `permitData: null` | **rejected** — `RequestValidationError: "permitData" must be of type object`; the field must be *omitted*, not nulled |

The last row was found after 0.4.0 was frozen and is recorded in `FEEDBACK.md`.
It is a request-shaping rule, not a design change: `post("/swap", { quote,
simulateTransaction: false })` omits the field naturally.

Consequences: request `/swap` with `simulateTransaction: false` and simulate
the complete fill on our own fork, as the existing tooling already does. The
simulation gap is `FEEDBACK.md` material, not a blocker.

`UNISWAP_API_KEY` is present in the gitignored `.env`. Gate 0 is reproducible
without new credentials.

### 2.1 Fork-side spike (S-1) — **PASSED**

Delivered as `test/fork/UniswapPayoutSpike.t.sol` (not `test/spikes/`, so that
the single `--no-match-path "test/fork/*"` exclusion in `Makefile` and `ci.yml`
keeps every live-route test out of the deterministic suite; there is exactly
one such boundary and the spike belongs on the fork side of it). It is a
throwaway harness with **no dependency on the payout contracts** — it calls the
proxy directly from an `vm.etch`-ed address.

Procedure, as built:

1. `frontend/scripts/fetch-uniswap-route.mjs` (default mode) fetches `/quote`
   then `/swap` for `WETH -> USDC`, with `makeAddr("uniswapPayoutSpikeHarness")`
   as `swapper` and `makeAddr("uniswapPayoutSpikeRecipient")` as `recipient`,
   and writes `test/fork/fixtures/uniswap-route.json`.
2. The test forks at `fetchedAtBlock`, `vm.etch`es one byte onto the harness so
   the proxy sees a contract caller, deals WETH, approves the proxy for exactly
   the funded amount, and calls `swapTo` with the unaltered `swapData`.

Findings:

| # | Assertion | Result |
|---|---|---|
| 1 | Call succeeds from a contract caller with no Permit2 signature | **PASS** — asserted |
| 2 | Proxy pulls exactly the funded WETH; harness balance returns to zero | **PASS** — asserted |
| 3 | USDC arrives at the separate `recipient`, not the harness | **PASS** — asserted, both directions |
| 4 | An excessive enforced minimum reverts the whole call | **PASS** — asserted in `test_SpikeExcessiveMinimumRevertsTheWholeCall` |
| 5 | Allowance clears to zero; USDC and native balances are zero | **PASS** — asserted |
| 6 | Deadline headroom by `vm.warp` sweep | **not measured** — see below |
| 7 | Route internal minimum by adverse-swap escalation | **not measured** — see below |
| — | API-quoted output vs. measured delivered | **equal to the unit**: 9348354 both sides |

**Assertions 6 and 7 were deliberately not run.** 0.4.0 already classified them
as findings rather than gates. The spike records the inputs to both questions —
quoted output, measured delivered, calldata length — and logs that the embedded
deadline and minimum are not decoded. The reasons the sweeps were skipped:

- The signed minimum is enforced from the *measured recipient delta* by both
  the executor and the kernel, so its correctness does not depend on knowing
  where the route's internal minimum sits.
- §11.1's 2-minute signing deadline is the mitigation for tight headroom
  regardless of what the sweep would have reported, and it is implemented.
- A warp sweep against a live head-block fork burns archive-RPC calls
  proportional to the headroom it finds.

The cost of not measuring them is that `MIN_PAYOUT_BUFFER_BPS` (§8.1) is set by
policy rather than by measurement. If a demo ever fails with an ambiguous
revert, running these two sweeps is the first diagnostic — the harness is
already in place and both are additive test functions.

**Never decode `swap.data`.** It is opaque under selector `0x2894adf9` and its
parameter layout is not documented. Do not hand-decode it, do not pattern-match
amounts inside it, and never rewrite it. This rule survives unchanged.

**RPC requirement.** The spike and the fork proof pin to the block observed at
route-fetch time. Most non-archive RPCs retain only ~128 blocks of state, so
either run within minutes of fetching or use the archive-capable endpoint the
repository already requires for `make test-fork`. The committed fixtures
(blocks 25611938 and 25612024) are already outside any non-archive window —
replaying them **requires** archive access.

### 2.2 Abort criteria — not triggered

Assertions 1 and 3 both passed, so neither abort condition fired. Assertion 2
passed, so the exact-spend rule in §6 was never relaxed to exact-or-refunded
and the executor carries no refund step. Retained for the record: had the proxy
pulled less than the funded amount, the fix was one refund step in the
executor, contained to that contract.

## 3. Scope and deployment topology

New contracts are deployed as siblings. **No existing source file was
modified**; v1 and the reviewed v2 release are untouched. This is verifiable:
`git log --stat` for the payout commits touches only new paths.

### 3.1 What is new source, what is a new instance, what is reused

| Component | Source change | Deployment | Why |
|---|---|---|---|
| `UniswapPayoutSettlement` | **new file** | new | copy of the reviewed kernel with the payout branch |
| `UniswapPayoutExecutor` | **new file** | new | the swap boundary |
| `IPayoutExecutor` | **new file** | — | interface |
| `PayoutTypes` | **new file** | — | quote + payload structs |
| `ProductiveFundingAccount` | **none** | **new instance** | `settlement` is set once and sealed (`ProductiveFundingAccount.sol:105-113,183`). `materializeAndPay` already pays an arbitrary non-zero, non-self recipient under a balance-delta check (`:214-242`), so the executor is a valid recipient with no edit. |
| `ERC4626ReserveAdapter` | **none** | **new instance** | `makerAccount` is immutable (`ERC4626ReserveAdapter.sol:26,40`) and `configureReserve` requires `makerAccount() == address(this)` (`ProductiveFundingAccount.sol:86`). The existing mainnet adapter is bound to the existing funding account and cannot be shared. |
| `LidoWithdrawalClaimAdapter` | **none** | **new instance** | `settlement` is immutable (`LidoWithdrawalClaimAdapter.sol:62,74`) and binds one kernel. |
| Aave StataWETH, Lido queue, stETH, WETH, USDC | — | canonical | unchanged |

Three fresh instances of reviewed, unmodified code are required. The bytecode
is reused; the instances cannot be.

### 3.2 File layout, as built

```text
src/payouts/UniswapPayoutSettlement.sol            440 lines   BUILT
src/payouts/UniswapPayoutExecutor.sol              135 lines   BUILT
src/payouts/interfaces/IPayoutExecutor.sol          26 lines   BUILT
src/payouts/types/PayoutTypes.sol                   30 lines   BUILT
frontend/scripts/fetch-uniswap-route.mjs           171 lines   BUILT
frontend/scripts/create-uniswap-payout-quote.mjs   287 lines   BUILT
test/mocks/payouts/MockUniswapProxy.sol             52 lines   BUILT
test/fork/fixtures/uniswap-route.json                          BUILT, committed
test/fork/fixtures/uniswap-payout-route.json                   BUILT, committed
test/fork/UniswapPayoutSpike.t.sol                 127 lines   BUILT
test/unit/payouts/UniswapPayoutExecutor.t.sol      282 lines   BUILT
test/unit/payouts/UniswapPayoutSettlement.t.sol    328 lines   BUILT
test/integration/UniswapPayoutLido.t.sol           219 lines   BUILT
test/fork/UniswapPayoutMainnet.t.sol               256 lines   BUILT

frontend/scripts/execute-uniswap-payout-quote.mjs              REMAINING  §11.3
script/UniswapPayoutDemo.s.sol                                 REMAINING  §11.3
script/DeployUniswapPayoutMainnet.s.sol                        REMAINING  §11.2 (optional)
```

Path deviations from 0.4.0, both deliberate:

- Fixtures live in `test/fork/fixtures/`, not `test/fixtures/`, because they
  are consumed only by fork tests and the directory keeps that coupling
  visible.
- **There are two fixtures, not one.** The spike and the fork proof need
  different `swapper` addresses — the spike swaps from a `makeAddr` harness,
  the fork proof swaps from the executor the test will deploy — and the route
  is fetched *for a specific swapper*. `MODE=payout` selects the second.

### 3.3 Kernel and executor bindings

`UniswapPayoutSettlement` keeps every sealed binding of the reviewed kernel and
adds one:

- `factorSigner` — immutable
- `fundingAccount` — immutable, WETH-funded
- `payoutExecutor` — immutable, **new**
- adapter allowlist — factor-mutable, unchanged in mechanism
- **payout-asset allowlist — factor-mutable, new** (§12)

`UniswapPayoutExecutor` immutables: `settlement`, `fundingAsset`, `proxy`,
`proxySelector`. **The payout asset is not an executor immutable** — it is
passed per call from the signed quote. There is no direct-WETH mode; WETH-direct
settlement remains the existing v2 kernel's job, and the executor explicitly
rejects a payout asset equal to the funding asset (§7 rule 2).

Quote creation stays offline in the existing CLI pattern: the operator fetches
the route server-side with the API key, validates it against the *on-chain*
executor bindings, and signs the Reservoir quote with the factor key. API key
and factor key remain separate secrets; neither appears in the repository,
frontend bundle, logs, or recordings.

Still cut, and still deferred (§14): frontend payout toggle (the demo is
scripted on the jury fork), ERC-8161 payout integration (Lido path only),
testnet leg (straight to mainnet fork), RFC 8785 canonicalization (the exact
retained JSON string is hashed instead), and the monitoring program.

## 4. Contract surface, as built

### 4.1 `IPayoutExecutor`

```solidity
interface IPayoutExecutor {
    /// @notice Convert the funded input and deliver `payoutAsset` to `recipient`.
    /// @dev The caller must have already transferred exactly `fundingAmount` of
    ///      the funding asset to this contract. Returns the recipient's measured
    ///      payout delta; the caller must not treat the return value as
    ///      authoritative and re-measures the delta itself.
    function payout(
        address recipient,
        IERC20 payoutAsset,
        uint256 fundingAmount,
        uint256 minimumPayoutAmount,
        bytes calldata payoutData
    )
        external
        returns (uint256 delivered);

    function settlement() external view returns (address);
    function fundingAsset() external view returns (address);
    function proxy() external view returns (address);
    function proxySelector() external view returns (bytes4);
}
```

`payoutAsset` is a **parameter**, and there is no `payoutAsset()` getter — that
getter existed in 0.4.0 only because the asset was an immutable. Any tooling
that reads executor bindings reads the four getters above and nothing else;
`create-uniswap-payout-quote.mjs:85-96` does exactly this.

### 4.2 `UniswapPayoutExecutor`

```solidity
constructor(
    address settlement_,   // immutable, sole permitted caller
    IERC20 fundingAsset_,  // WETH
    address proxy_,        // Gate 0 proxy target
    bytes4 proxySelector_  // Gate 0 selector
)
```

Four arguments, not five. Every one is stored immutable and validated nonzero,
with `code.length != 0` required for `proxy_` and `fundingAsset_`.

**`settlement_` is checked nonzero but NOT for code.** This is deliberate and
load-bearing: the executor and settlement immutables are mutually referential,
so the executor is deployed *first* against a `vm.computeCreateAddress`
prediction and the settlement has no code yet. The mutual binding is verified
from the other side — `UniswapPayoutSettlement`'s constructor requires
`payoutExecutor_.settlement() == address(this)` (`:140`) — which is the check
that actually cannot be forged. Adding a code check here would make the
deployment sequence in §11.2 impossible.

There are no setters, no owner, no rescue methods, and no `receive` or
`payable` function anywhere on the contract — a contract that cannot receive
native ETH cannot hold native dust.

### 4.3 `UniswapPayoutSettlement`

Copy of `src/claims/AsyncClaimSettlement.sol` with these deltas and nothing
else:

| Location | Change |
|---|---|
| `EIP712` constructor | `"Reservoir Uniswap Payouts"`, version `"1"` |
| typehash constant | `PAYOUT_QUOTE_TYPEHASH`, §5.1 |
| immutables | `+ IPayoutExecutor public immutable payoutExecutor` |
| constructor | validate the executor: nonzero, has code, `executor.settlement() == address(this)`, `executor.fundingAsset() == address(fundingAccount.paymentAsset())` |
| storage | `+ mapping(address => bool) isPayoutAssetAllowed` |
| admin | `+ allowPayoutAsset`, `+ revokePayoutAsset` — `onlyFactor`, **not** `beforeSeal`, mirroring the adapter allowlist so emergency revocation survives sealing |
| `seal()` | additionally require `address(payoutExecutor) != address(0)` |
| quote struct | `PayoutTypes.Quote`, §5.1 |
| `fill()` signature | `+ bytes calldata payoutData`, between `boundsData` and `factorSignature` |
| `fill()` validation | `+ isPayoutAssetAllowed[quote.payoutAsset]`, `+ keccak256(payoutData) == quote.payoutDataHash`, `+ quote.minimumPayoutAmount != 0` |
| `fill()` payment branch | extracted to `_payOut`, §6 |
| validation | extracted to `_validate` — the stack-pressure escape hatch 0.4.0 anticipated was needed and taken |
| `ClaimSettled` | `+ payoutAsset`, `+ minimumPayoutAmount`, `+ payoutDelivered`, emitted from `_emitSettled` |
| new errors | `InvalidExecutor`, `InvalidPayoutAsset`, `PayoutAssetAlreadyAllowed`, `PayoutAssetNotAllowed`, `PayoutDataHashMismatch`, `InvalidMinimumPayout`, `InsufficientPayout`, `PayoutResidue` |
| new events | `PayoutAssetAllowed`, `PayoutAssetRevoked` |

Everything else — seller-only execution, factor signature via
`SignatureChecker` (EOA and ERC-1271), nonce, nonce floor, cancellation,
`MAX_QUOTE_LIFETIME`, pause, adapter allowlist, `ReentrancyGuardTransient`,
effects-before-interactions nonce consumption, exact capacity check,
acquisition validity check — is copied verbatim.

`allowPayoutAsset` additionally rejects the funding asset
(`asset == address(fundingAccount.paymentAsset())`), so the executor's own
guard is never the only thing standing between a mis-built quote and broken
baseline accounting.

## 5. Signed quote

New EIP-712 domain (`Reservoir Uniswap Payouts`, version 1); v2 signatures are
invalid in the new kernel and vice versa, asserted in
`test_WrongKeyAndWrongDomainSignaturesRejected`.

### 5.1 Struct and typehash, as built

```solidity
library PayoutTypes {
    struct Quote {
        address factor;
        address seller;
        address adapter;
        address claimController;
        address claimReceiver;
        address paymentAsset;         // funding asset (WETH) — kernel-checked
        uint256 paymentAmount;        // exact funding amount drawn from reserve
        bytes32 claimDataHash;
        bytes32 boundsHash;
        address payoutAsset;          // asset the seller is paid in (allowlisted)
        uint256 minimumPayoutAmount;  // minimum measured seller payout delta
        bytes32 payoutDataHash;       // keccak256 of the encoded payload
        uint256 nonce;
        uint256 deadline;
    }

    struct UniswapPayoutData {
        bytes callData;       // exact /swap response data, never altered
        bytes32 apiQuoteHash; // keccak256 of the exact retained /quote JSON string
    }
}
```

Fourteen fields — **three** added to the v2 shape, not two. `payoutAsset`,
`minimumPayoutAmount`, and `payoutDataHash` are inserted in that order
immediately after `boundsHash`.

```solidity
bytes32 public constant PAYOUT_QUOTE_TYPEHASH = keccak256(
    "PayoutQuote(address factor,address seller,address adapter,address claimController,"
    "address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,"
    "bytes32 boundsHash,address payoutAsset,uint256 minimumPayoutAmount,bytes32 payoutDataHash,"
    "uint256 nonce,uint256 deadline)"
);
```

The typehash string is a single unbroken literal in the source
(`UniswapPayoutSettlement.sol:88-90`) — the line breaks above are presentational
only, and concatenation across lines must reproduce the string byte-for-byte.

`paymentAsset` and `paymentAmount` retain their v2 meaning: the funding leg.
The matching CLI `types` array is at `create-uniswap-payout-quote.mjs:231-248`
and must stay field-for-field identical to the typehash, in order.

All v2 validity rules carry over unchanged: factor signature (EOA or ERC-1271),
seller-only execution, nonce and nonce floor, 15-minute maximum quote lifetime,
exact funding capacity.

### 5.2 Payout payload

`payoutData` is `abi.encode(UniswapPayoutData)`; `payoutDataHash` is
`keccak256` of that encoding, bound into the signature.

Target and value are not fields: the executor's proxy target is immutable and
the value is always zero. `apiQuoteHash` is evidence for auditability, not an
oracle — nothing on-chain reads it.

### 5.3 Quote envelope

Emitted by the CLI on stdout (`create-uniswap-payout-quote.mjs:254-287`):

```json
{
  "version": "reservoir-uniswap-payout-1",
  "chainId": 1,
  "kernel": "<UniswapPayoutSettlement>",
  "quote": { "...14 PayoutTypes.Quote fields, bigints as decimal strings..." },
  "claimData": "0x…",
  "boundsData": "0x…",
  "payoutData": "0x…",
  "factorSignature": "0x…",
  "pricing": {
    "mode": "operator-priced-firm-quote",
    "evidenceNote": "…",
    "grossSpreadBps": "…",
    "signedAtUnix": "…"
  },
  "route": {
    "quoteRequestId": "…",
    "swapRequestId": "…",
    "apiQuoteHash": "0x…",
    "apiQuotedOut": "…",
    "minimumPayoutAmount": "…",
    "proxy": "0x…",
    "selector": "0x…",
    "fetchedAtUnix": "…",
    "fetchedAtBlock": "…"
  }
}
```

`route` is informational provenance for the jury and for replay; only the
EIP-712 `PayoutQuote` fields are factor-signed, and `payoutDataHash` is what
binds the calldata. This envelope is the input contract for the seller-side CLI
in §11.3 — that script must not require any field `create-uniswap-payout-quote.mjs`
does not emit.

## 6. Settlement sequence, as built

```text
validate quote (seller, factor, adapter allowlist, PAYOUT-ASSET ALLOWLIST,
    claim parties, funding asset, amounts, minimum != 0, claimDataHash,
    boundsHash, payoutDataHash, deadline, lifetime, nonce floor, nonce,
    signature)                                          [_validate]
  -> consume nonce                                      [effects before interactions]
  -> check exact funding capacity
  -> acquire complete claim (measured)                  [adapter]
  -> record seller payout balance + executor baselines  [kernel-side measurement]
  -> materialize exact WETH to the executor             [fundingAccount]
  -> executor swaps and pays the seller                 [executor]
  -> verify seller's measured payout delta >= minimum   [kernel-side]
  -> verify executor balances equal their baselines     [kernel-side]
  -> emit
```

Payment branch, as implemented in `_payOut` (`UniswapPayoutSettlement.sol:270-304`):

```solidity
IERC20 payoutAsset = IERC20(quote.payoutAsset);
IERC20 fundingAsset = IERC20(payoutExecutor.fundingAsset());
uint256 payoutBefore = payoutAsset.balanceOf(quote.seller);
uint256 executorFundingBaseline = fundingAsset.balanceOf(address(payoutExecutor));
uint256 executorPayoutBaseline = payoutAsset.balanceOf(address(payoutExecutor));

uint256 paid = fundingAccount.materializeAndPay(address(payoutExecutor), quote.paymentAmount);
if (paid != quote.paymentAmount) {
    revert InexactPayment(quote.paymentAmount, paid);
}

payoutExecutor.payout(quote.seller, payoutAsset, quote.paymentAmount, quote.minimumPayoutAmount, payoutData);

delivered = payoutAsset.balanceOf(quote.seller) - payoutBefore;   // underflow-reverts on a decrease
if (delivered < quote.minimumPayoutAmount) {
    revert InsufficientPayout(delivered, quote.minimumPayoutAmount);
}
if (
    fundingAsset.balanceOf(address(payoutExecutor)) != executorFundingBaseline
        || payoutAsset.balanceOf(address(payoutExecutor)) != executorPayoutBaseline
) {
    revert PayoutResidue();
}
```

**The change from 0.4.0 is baseline accounting instead of zero-residue.** The
final check compares against balances snapshotted before `materializeAndPay`,
not against literal zero. See §16 finding D-1 for why.

The executor's return value is deliberately discarded. The kernel re-measures
the seller's balance itself, mirroring the existing house rule that the kernel
re-checks `paid != quote.paymentAmount` even though the funding account has
already asserted it.

Any failure reverts everything, including the acquired claim and the consumed
nonce.

**Implementation notes, confirmed in the build.**

- Baselines must be recorded **after** claim acquisition and **before**
  `materializeAndPay`. Recording them after the executor call is a bug that
  silently disables the residue check.
- Stack pressure was real. `via_ir = true` alone did not carry it; validation
  moved to `_validate`, payment to `_payOut`, and the event to `_emitSettled`.
  This is the resolution 0.4.0 pre-authorized — do not re-inline them.
- The `ClaimSettled` topic0 **changed**. Any consumer decoding it by ABI needs
  the 17-field payout signature in §11.3. The v2 decode path does not work
  against this kernel.
- Measured fill gas at the canonical fork proof: ~862,807 for the success path
  (the full Uniswap route is inside the fill). The v2 fill's budget figure does
  not cover this path — feed this number into `scripts/check-gas-budget.sh`
  before any mainnet broadcast.

Invariants, unchanged in spirit from v2:

- payout if and only if complete claim acquisition, same transaction;
- the factor spends exactly the signed WETH amount;
- price improvement above the minimum belongs to the seller; and
- the executor ends every fill exactly where it started.

## 7. Executor rules, as built

1. Only the immutable settlement may call. Every other caller reverts
   `OnlySettlement`.
2. `payoutAsset` must be nonzero and **must not be the funding asset** —
   a funding-asset payout would make the two baselines alias and break the
   accounting. Reverts `InvalidPayoutAsset`.
3. On entry, require `fundingBalance >= fundingAmount` — a **shortfall** fails
   closed (`InsufficientEntryFunding`). Any excess is a donation: record
   `fundingBaseline = balance - fundingAmount` and carry it through untouched.
4. Snapshot `payoutBaseline` — the executor's own payout-asset balance —
   *before* approving or executing.
5. Decode `payoutData`; require `callData.length >= 4` and that its first four
   bytes equal the immutable `proxySelector`. Both checks precede any approval.
6. Record the recipient's payout-asset balance.
7. `forceApprove` the immutable proxy for exactly `fundingAmount` — never more,
   so a donation is unreachable by the route.
8. Call the immutable proxy with the exact API calldata and zero value. Never
   alter `swap.data`. Bubble the revert reason unaltered on failure.
9. `forceApprove(proxy, 0)` — clear any remaining allowance.
10. Require the recipient's measured payout increase is at least
    `minimumPayoutAmount`. Router return values never substitute for the
    balance delta.
11. Require exit balances **equal the entry baselines** in both assets.
12. Return the measured delta.

No arbitrary targets, no native value, no rescue methods, no calldata
rewriting, no owner. A griefed executor is replaced, not patched: the kernel's
executor binding is immutable, so replacement means deploying a new
settlement/executor/funding triple, exactly as this build target already does
relative to v2.

**Donations are inert, not fatal.** Anyone may send either asset to the
executor between fills. Because every check measures against a pre-fill
baseline and the approval is exactly `fundingAmount`, donated funds can neither
block a fill nor be captured by one — they sit there untouched. Rules 3, 7, and
11 together are what make this true; weakening any one of them reintroduces
either a griefing DoS or a value leak. Eight of the eighteen executor unit tests
exist to hold this line.

## 8. API integration

Server-side request (key in a server secret, `.env` is gitignored):

```json
{
  "type": "EXACT_INPUT",
  "amount": "<paymentAmount>",
  "tokenInChainId": 1, "tokenOutChainId": 1,
  "tokenIn": "<WETH>", "tokenOut": "<quote payout asset>",
  "swapper": "<UniswapPayoutExecutor>",
  "recipient": "<seller>",
  "slippageTolerance": 0.5,
  "routingPreference": "BEST_PRICE",
  "protocols": ["V2", "V3", "V4"]
}
```

with `x-permit2-disabled: true` on `/quote` and `/swap`. The `/swap` body is
`{ quote, simulateTransaction: false }` and **omits `permitData` entirely** —
sending it explicitly as `null` is rejected (§2).

Reject the bundle unless every one of these holds:

| Field | Required value | Enforced at |
|---|---|---|
| `routing` | `"CLASSIC"` | `create-uniswap-payout-quote.mjs:134` |
| `permitData` | `null` in the response | `:135` |
| input token / amount | WETH, exactly `paymentAmount` | `:136-137` |
| output token | the quote's payout asset | `:138` |
| output recipient | the seller | `:139` |
| `swapper` | the executor address | `:140` |
| chain | `chainId == 1` | `:141` |
| `swap.to` | the executor's **on-chain** `proxy()` | `:145` |
| `swap.value` | `0` | `:148` |
| `swap.data` selector | the executor's **on-chain** `proxySelector()` | `:149` |

The last three compare against values read from the deployed executor, not
against constants — a quote can never be signed for a proxy the executor will
refuse. `fetch-uniswap-route.mjs` runs the same table against
`EXPECTED_PROXY`/`EXPECTED_SELECTOR` env defaults, because at fixture-fetch
time no executor is deployed yet.

Never alter `swap.data`. On any API failure or validation failure, no Reservoir
quote is issued — the existing WETH path is the fallback and the CLI exits
nonzero.

The exact `/quote` response body is retained byte-for-byte as a string; its
`keccak256` is `apiQuoteHash`. Both request IDs are retained in the envelope.

### 8.1 Setting `minimumPayoutAmount`

Two minimums are in play:

1. the route's **internal** minimum, encoded inside `swap.data` and derived
   from the `slippageTolerance` sent to the API; and
2. our **signed** `minimumPayoutAmount`, enforced by the executor and
   re-checked by the kernel against a measured balance delta.

Policy: **the route's internal minimum binds first in normal operation; ours is
a backstop.** As implemented (`create-uniswap-payout-quote.mjs:74-76,154`):

```text
minimumPayoutAmount = apiQuotedOut × (10_000 − MIN_PAYOUT_BUFFER_BPS) / 10_000
MIN_PAYOUT_BUFFER_BPS default = 100      (route slippage 50 bps + 50 cushion)
```

so the signed minimum sits slightly *looser* than the calldata's own. The
default is 100 bps rather than 0.4.0's proposed 75 because S-1 assertions 6–7
were not measured (§2.1) — the extra 25 bps buys margin for an unmeasured
internal minimum. Tighten it only after running those sweeps.

The consequences are deliberate:

- **Normal fill** — the route delivers at or above its internal minimum, which
  is above ours, so our check passes and price improvement flows to the seller.
  The fork proof shows delivered == quoted exactly.
- **Degraded route** — Uniswap's own check reverts first, attributing the
  failure to the route rather than surfacing an ambiguous Reservoir error.
- **Router misbehavior or an unexpected transfer fee** — the route reports
  success but the seller's *measured* delta comes in low, and our check catches
  what Uniswap's cannot. This is the case the backstop exists for.

The forced-failure demo (§13 act 4) deliberately inverts this: sign a minimum
*above* `apiQuotedOut` so the route succeeds, delivers, and **our**
`InsufficientPayout` is the revert the audience sees. That is the only case
where the signed minimum should exceed the quoted output. The fork proof does
this with `type(uint256).max`
(`test_UnmeetableMinimumRevertsEverythingAtomically`).

**Decimals.** USDC has 6 decimals. Every other amount in this repository is
18-decimal wei, including `paymentAmount` on the same struct.
`minimumPayoutAmount` is in the payout asset's own units — it is derived from
`apiQuotedOut` by integer arithmetic and **never** passed through `parseEther`.
The CLI guards only against rounding to zero (`:155`); an order-of-magnitude
sanity bound in the fork proof is still an open hardening item (§11.4).

## 9. Threat model delta

Relative to `V2_THREAT_MODEL.md`, this layer adds exactly one new trust edge:
the kernel calls an immutable executor which calls an immutable third-party
proxy with factor-signed calldata.

| Risk | Mitigation | Residual |
|---|---|---|
| Malicious or wrong calldata | `payoutDataHash` is factor-signed and EIP-712-bound; selector and target immutable | the factor can sign a bad route and is the party who loses; the seller is protected by the minimum |
| Route degrades between signing and fill | seller's measured delta must clear the signed minimum; failure reverts the whole fill | no fill, never a bad fill; mitigated further by the 2-minute deadline (§11.1) |
| Proxy pulls more than approved | approval is exactly `fundingAmount`, cleared unconditionally after the call | none |
| Proxy pulls less than approved | exit balances must equal entry baselines | a partially-consuming route is unusable — measured not to occur (S-1 assertion 2) |
| **Executor donation griefing** | **baseline accounting: donations are inert and carried through** | **none — neither DoS nor capture** |
| Payout asset equals funding asset | rejected by the executor *and* by `allowPayoutAsset` | none |
| Reentrancy via the proxy or payout token | `ReentrancyGuardTransient` on `fill`; executor callable only by the settlement; all measurements are balance deltas | none identified |
| Native ETH stranded in the executor | no payable entry point; `swap.value == 0` enforced offchain, never sent onchain | none |
| Unexpected payout asset in a quote | factor allowlist + factor signature, both required | factor error only |
| API key leakage | server-side only; never in the frontend bundle, repo, logs, or recording | operator discipline, same as v2 |
| Kernel confusion between v2 and payout quotes | distinct EIP-712 domain | none |

The donation row is the one that improved relative to 0.4.0, which accepted a
denial-of-service residual. It no longer exists — see §16 D-1.

The payout layer does not change the factor's post-fill exposure: the factor
still owns the Lido claim and still bears queue duration, impairment, and
slashing risk.

## 10. Tests, as built

### 10.1 `test/unit/payouts/UniswapPayoutExecutor.t.sol` — 18 tests

Caller gate; payout asset zero-or-funding rejection; entry funding shortfall;
selector mismatch before any approval; exact approve / exact spend / cleared
allowance; allowance cleared after a reverting proxy call; below-minimum
delivery; recipient measured by delta not by router return value; exit residue;
partial pull with a donation present; no payable entry point.

Donation-specific: entry payout dust neither blocks nor enriches; donated
funding inert; donated payout inert; both inert; repeated fills keep dust
inert; an excessive pull cannot reach donated funding; baselines survive a
reverted fill.

### 10.2 `test/unit/payouts/UniswapPayoutSettlement.t.sol` — 11 tests

Valid fill acquires then pays; mutating any payout field invalidates the
signature; `payoutData` must match its signed hash; zero minimum reverts;
unallowed payout asset reverts; wrong key and wrong domain rejected;
constructor rejects a foreign or mis-asseted executor; payout failure rolls
back claim and nonce; executor donations inert through a settlement fill and
through a reverted one; replay / pause / floor / cancellation / lifetime ported
from v2.

### 10.3 `test/integration/UniswapPayoutLido.t.sol` — 3 tests

Deterministic, mock-proxy vertical slice with `MockLidoWithdrawalQueue`,
`MockStETH`, a mock ERC-4626, and a fixed-rate mock proxy. Proves the ordering
— acquire, then materialize, then swap, then verify — that a swap failure rolls
back origination tokens and the nonce, and that an acquisition failure moves
nothing.

### 10.4 `test/fork/UniswapPayoutMainnet.t.sol` — 3 tests

The canonical proof, on a chain-1 fork pinned to the route-fetch block:

- factor starts holding StataWETH shares with zero idle WETH;
- canonical Lido request minted directly to the factor;
- exact WETH pulled by the canonical Uniswap proxy using the live route;
- seller receives at least the signed minimum USDC;
- executor dustless in both assets, funding account left with no idle WETH;
- forced failure: `type(uint256).max` minimum reverts and rolls back the Lido
  request, the nonce, and every token delta;
- donations cannot brick the canonical route.

#### Fixture schema, as built

`fetch-uniswap-route.mjs` writes the fixture after applying every §8 rule; an
invalid bundle is never written. Both files are **committed** — they contain no
secret, only a public API response and public addresses, and committing them is
what lets CI and the jury replay the proof without a key.

```json
{
  "chainId": 1,
  "fetchedAtBlock": 25612024,
  "fetchedAtUnix": 1785009448,
  "swapper": "0x9De87Ff90b4a9cFDd173f5d191a1B2677976837b",
  "recipient": "0xd0b382382742D065AB2560B2B78105CF11cC880C",
  "amountInWei": "4987500000000000",
  "apiQuotedOut": "9349109",
  "apiQuoteHash": "0xbf08251b…",
  "quoteRequestId": "1398e976…",
  "swapRequestId": "5394e1e6…",
  "swapTo": "0x02E5be68D46DAc0B524905bfF209cf47EE6dB2a9",
  "swapValue": "0x00",
  "swapData": "0x2894adf9…"
}
```

Deviations from the 0.4.0 schema, all deliberate:

- Flat `swapTo` / `swapValue` / `swapData`, not a nested `swap` object — struct
  decoding is order-sensitive, and flat keys read individually via
  `readAddress` / `readBytes` are not.
- No `schemaVersion`, `tokenIn`, `tokenOut`, or `slippageToleranceBps`. The
  token pair and slippage are fixed by the fetching script and re-validated at
  fetch time; carrying them into the fixture would imply the test checks them,
  which it does not.
- **Amounts are decimal strings; block numbers and timestamps are JSON
  numbers.** Amounts exceed 2^53 and are read with
  `vm.parseUint(fixture.readString(".amountInWei"))`; `fetchedAtBlock` is safely
  under it and read with `readUint`. Keep that split — a decimal-string block
  number breaks `readUint` and a numeric amount loses precision.

The addresses are derived, not arbitrary. `recipient` is
`makeAddr("payoutForkSeller")`, asserted on load. `swapper` is
`CREATE(factor, nonce 2)` where the factor key is
`keccak256("reservoir.payout.fork.factor")` — the fetch script computes it at
`:45-51` and the test reproduces it by deploying in that exact order. Change
the deployment order in the fork test and the fixture must be refetched.

**Known gap.** The fork test does *not* re-assert the §8 table against the
fixture before use — it constructs the executor with `swapTo` and
`bytes4(swapData)` taken *from* the fixture, so a hand-edited target would be
adopted rather than rejected. `swapValue` is never read at all. Closing this is
a §11.4 hardening item, not a correctness bug in the proof as run: the fixture
is generated by a script that does enforce the table.

The retained `apiQuoteHash` is bound into `payoutDataHash` at signing time, so
the demo cannot drift from the evidence it displays.

### 10.5 Non-regression — holding

Complete existing deterministic and fork suites stay green; v1 and v2 are
untouched. Measured 2026-07-26: `make test` → 252 passed, 0 failed, 0 skipped.

## 11. Remaining build plan

Everything below is unbuilt. Estimates assume the existing code is not
re-litigated.

| Step | Work | Est. | Blocks | Done when |
|---|---|---|---|---|
| S-5b | §11.3 — seller CLI, demo script, Makefile targets | 2 h | — | `make demo-uniswap-payout` runs the four acts unattended |
| S-6 | §11.4 — submission surface and hardening | 1–2 h | S-5b | §13 checklist fully ticked |
| S-7 | §11.2 — *optional* mainnet deployment | 2–4 h + budget | S-6 | bindings asserted on-chain |

**Non-regression gate, run before declaring any step done:** the full command
list in `README.md` under "Complete verification". This leg adds files and
never edits existing ones.

### 11.1 Deadline policy — implemented

The kernel's `MAX_QUOTE_LIFETIME` is 15 minutes, but the route is fetched at
signing time and executes against pool state that moves. The operator CLI signs
with a **2-minute** deadline by default (`QUOTE_DEADLINE_SECONDS`, capped at
900 s by the CLI itself). A stale route produces a revert, not a bad fill.

### 11.2 Mainnet deployment sequence, if S-7 is taken

`script/DeployUniswapPayoutMainnet.s.sol` mirrors `script/DeployV2Mainnet.s.sol`
with acknowledgement constant `DEPLOY_PAUSED_UNFUNDED_RESERVOIR_PAYOUTS`. The
ordering below is not a suggestion — it is the order proven in
`test/fork/UniswapPayoutMainnet.t.sol:100-118`, and two constraints make it the
only order that works:

```text
nonce 0   new ProductiveFundingAccount(factor)
nonce 1   new ERC4626ReserveAdapter(fundingAccount, STATA_WETH, 0, 0)
nonce 2   new UniswapPayoutExecutor(predictedSettlement, WETH, PROXY, SELECTOR)
   call   fundingAccount.configureReserve(reserveAdapter)      // consumes no nonce
nonce 3   new UniswapPayoutSettlement(factor, fundingAccount, executor)
nonce 4   new LidoWithdrawalClaimAdapter(settlement, STETH, QUEUE)
   calls  fundingAccount.configureSettlement(settlement); setPaused(true); seal()
   calls  settlement.allowAdapter(lidoAdapter)
   calls  settlement.allowPayoutAsset(USDC)
   calls  settlement.setPaused(true); seal()
```

- `predictedSettlement = vm.computeCreateAddress(deployer, deployerNonce + 3)`.
  The executor's `settlement` and the settlement's `payoutExecutor` are mutually
  referential; the executor deliberately omits a code check on `settlement_`
  (§4.2) so it can be deployed first.
- **`configureReserve` must run before the settlement constructor**, because
  that constructor reads `fundingAccount.paymentAsset()` and compares it to
  `executor.fundingAsset()`. Pranked/broadcast *calls* consume no EOA nonce —
  only creations do — so this call sits nonce-free between creations without
  disturbing the prediction. Assert `address(settlement) == predictedSettlement`
  immediately after deployment and fail the script if it differs.
- `allowPayoutAsset(USDC)` is required for any fill but is **not** checked by
  `seal()`. Forgetting it produces a `PayoutAssetNotAllowed` revert at the first
  fill, not at deployment. Both allowlist setters stay callable after sealing by
  design.

Deploy paused and unfunded; fund and activate with separate scripts and
separate acknowledgements, per `docs/LIVE_ACTIVATION.md`.

Two known hazards carried over from the v2 and Aqua mainnet runs, both recorded
in `docs/MAINNET_MICRO_DEMO.md`:

- **Etherscan verification under `via_ir`.** The Aqua router's mainnet
  verification failed on a bytecode mismatch despite a proven byte-exact local
  match. Budget time for it, use `--resume --verify` rather than redeploying,
  and treat an unverified contract as a submission problem.
- **Constructor-argument encoding.** `forge`'s broadcast encoder
  nondeterministically mis-decoded a string constructor argument when a parent
  artifact shared a creation-code prefix. Neither payout contract takes a string
  argument, so this should not recur — but if it does, deploy via
  `cast send --create` (flags **before** `--create`) and pass the resulting
  address into the script.

### 11.3 S-5b — the seller side and the demo

**`frontend/scripts/execute-uniswap-payout-quote.mjs`.** Copy
`frontend/scripts/execute-lido-quote.mjs` and change exactly four things; keep
its approval flow, its simulate-before-send, and the 50 % gas cushion at `:167`
unchanged. The cushion matters more here, not less — the fill now contains a
full Uniswap route at ~863k gas.

1. Envelope guard: require `envelope.version === "reservoir-uniswap-payout-1"`.
2. The `fill` ABI string (`:29-31` in the original) becomes:

```text
function fill((address factor,address seller,address adapter,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,bytes32 boundsHash,address payoutAsset,uint256 minimumPayoutAmount,bytes32 payoutDataHash,uint256 nonce,uint256 deadline) quote,bytes claimData,bytes boundsData,bytes payoutData,bytes factorSignature) returns ((bytes32 positionKey,uint256 claimId,uint256 pendingUnits,uint256 pendingReceived,uint256 claimableUnits,uint256 assetsReceived) acquisition)
```

   and the args array gains `envelope.payoutData` between `boundsData` and
   `factorSignature`.

3. The `ClaimSettled` event (`:40-42`) becomes the 17-field payout signature:

```text
event ClaimSettled(bytes32 indexed quoteHash,address indexed adapter,address indexed seller,address factor,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,address payoutAsset,uint256 minimumPayoutAmount,uint256 payoutDelivered,bytes32 positionKey,uint256 claimId,uint256 pendingUnits,uint256 pendingReceived,uint256 claimableUnits,uint256 assetsReceived)
```

4. Post-fill verification: measure the seller's **payout-asset** balance
   before and after and assert the delta is `>= quote.minimumPayoutAmount` and
   equals `payoutDelivered` from the event. Assert the executor holds nothing.
   Read `envelope.quote.payoutAsset` for the token — do not hardcode USDC, and
   read its `decimals()` for display rather than assuming 6.

The quote struct passed to `simulateContract` must carry all three new fields
with `nonce`, `deadline`, `paymentAmount`, and `minimumPayoutAmount` coerced to
`BigInt` — the envelope serializes them as decimal strings.

**`script/UniswapPayoutDemo.s.sol`.** Mirror `script/V2Demo.s.sol`: a
`forge script` with mocks and no RPC, printing the four acts of §13 as `console2`
lines with hard `require`s behind each. It shares its scenario with
`test/integration/UniswapPayoutLido.t.sol` — build it from those mocks rather
than writing new ones. RPC-free is the point: it must run on a laptop with no
network, so the jury sees the shape even if the venue Wi-Fi dies.

**Makefile targets**, mirroring the existing `demo-aqua-intent` pattern —
guard on the required env var, capture output, and scrub RPC URLs from any
failure output with the `perl -pe 's#https?://[^[:space:]]+#<RPC_URL>#g'` filter
already used there:

```make
fetch-uniswap-route:   # requires UNISWAP_API_KEY + ETH_RPC_URL; writes BOTH fixtures
                       #   node frontend/scripts/fetch-uniswap-route.mjs
                       #   MODE=payout node frontend/scripts/fetch-uniswap-route.mjs
demo-uniswap-payout:   # forge script script/UniswapPayoutDemo.s.sol -vv, logs only
test-payout-fork:      # forge test --match-path "test/fork/UniswapPayout*.t.sol" \
                       #   --fork-url "$(ETH_RPC_URL)" -vv
```

`test-fork` already gates on both fixtures and runs these suites;
`test-payout-fork` is the narrow loop for iterating on the payout leg alone.

### 11.4 S-6 — submission surface and hardening

1. **`docs/ETHGLOBAL_SUBMISSION.md` has no Uniswap or payout content at all.**
   It needs a section covering the bounty: what the integration is, which files
   are load-bearing, how to replay the proof, and the request IDs.
2. **Fix the `FEEDBACK.md` evidence paths.** Its header claims request IDs are
   retained in `test/spikes/fixtures/` and `deployments/`. Neither is true —
   `test/spikes/fixtures/` is empty and untracked, and `deployments/` holds no
   payout record. The real location is `test/fork/fixtures/`. A broken evidence
   link in the document the feedback form points at is worth more than the five
   minutes it takes to fix.
3. **README line-level links.** §13 asks for exact files *and lines*; the README
   currently links files only.
4. **Fixture hardening** (§10.4 known gap): re-assert the §8 table inside
   `UniswapPayoutMainnet.t.sol` before using the fixture — check `swapValue` is
   zero, `swapTo` equals the expected canonical proxy constant, and the selector
   matches — so a hand-edited fixture fails loudly instead of being adopted.
5. **Decimals sanity bound** (§8.1): assert in the fork proof that
   `apiQuotedOut` sits within an order-of-magnitude band for a ~0.005 ETH input,
   so a decimals error fails loudly rather than signing a minimum a trillion
   times too small.
6. Demo video and feedback-form submission.

## 12. Any payout asset — **built**

Shipped with the main build rather than deferred, because the allowlist
plumbing was cheaper than maintaining a USDC-shaped executor that would need
rewriting. The 0.4.0 estimate of "roughly 30 lines plus allowlist plumbing"
held.

| Change | As built |
|---|---|
| `payoutAsset` in the signed quote | `PayoutTypes.Quote` field 10; in `PAYOUT_QUOTE_TYPEHASH`; in the CLI `types` array |
| Executor generalized | `payout(address recipient, IERC20 payoutAsset, …)`; baselines taken against the passed asset; no `payoutAsset()` getter |
| Operator rail | `isPayoutAssetAllowed` + `allowPayoutAsset` / `revokePayoutAsset` + `PayoutAssetAllowed` / `PayoutAssetRevoked`, mirroring the adapter allowlist |
| Kernel check | `if (!isPayoutAssetAllowed[quote.payoutAsset]) revert PayoutAssetNotAllowed(...)` in `_validate` |
| API request | `tokenOut` is the quote's payout asset; §8 validation compares against it |
| Extra guard | funding asset rejected as a payout asset in both `allowPayoutAsset` and the executor |

Token behaviors, and why the design handles them:

- **Fee-on-transfer** — the seller's *measured* delta must clear the signed
  minimum, so a transfer fee reduces the delta and reverts the fill rather than
  silently underpaying.
- **Blacklisting (USDC, USDT)** — a blocked recipient makes the transfer revert;
  fill-or-kill turns that into no fill, no claim, no consumed nonce.
- **Rebasing** — before and after are measured in the same transaction.
- **Callback tokens (ERC-777 and similar)** — `ReentrancyGuardTransient` on
  `fill`, the settlement-only caller gate, and the baseline assertions bound the
  surface. The allowlist is the right rail here and it exists.

Only USDC has been exercised end-to-end. Adding a second asset is one
`allowPayoutAsset` call plus a fixture fetched with a different `tokenOut` — no
contract change.

**Native ETH stays excluded.** `swap.value == 0` and the absence of a payable
entry point are load-bearing for the dustlessness argument; supporting native
payouts means a payable executor, a recipient that may revert on receive, and a
new class of stranded-value failure. It is a separate design, not a parameter.

## 13. Demo and submission

Four acts, scripted on the jury fork:

1. **Productive capital** — factor holds StataWETH shares, zero idle WETH.
2. **API is load-bearing** — show the live server request and validated
   response fields (contract swapper, separate recipient, CLASSIC, no-Permit2),
   with the key redacted; show request IDs and the signed route hash.
3. **Atomic cashout** — one seller transaction: Lido claim to factor, WETH from
   StataWETH, route through Uniswap, at least the signed USDC minimum to the
   seller, executor empty.
4. **Failure is atomic** — a quote with an unmeetable minimum: no claim
   created, no nonce consumed, no reserve assets moved.

Acts 1, 3, and 4 are already proven by `test/fork/UniswapPayoutMainnet.t.sol`;
§11.3's demo script is what turns them into something watchable.

Submission checklist:

- [x] Fork-side Gate 0 spike passed (§2.1); assertions 1–5 asserted, 6–7
      consciously deferred with the reasoning recorded.
- [x] Live valid-key `/quote` and `/swap` produce the route used on-chain.
- [x] Canonical fork proof, success and forced failure.
- [x] Retained route fixtures replay the fork proof without a live key
      (archive RPC required — §2.1).
- [x] `FEEDBACK.md`: key setup, contract-as-swapper behavior, no-Permit2 proxy
      flow, separate recipient, the zero-balance simulation gap, the
      `permitData: null` rejection, opaque calldata.
- [ ] `FEEDBACK.md` evidence paths corrected (§11.4 item 2).
- [ ] Feedback form submitted linking `FEEDBACK.md`.
- [x] README links the integration files.
- [ ] README links exact lines (§11.4 item 3).
- [ ] `docs/ETHGLOBAL_SUBMISSION.md` covers this bounty (§11.4 item 1).
- [ ] Demo video shows API evidence and on-chain execution.
- [x] No API key or factor key in repository, build, or recording.

## 14. Deferred

Frontend payout selection, ERC-8161 payout integration, UniswapX, cross-chain,
native ETH, relayed fills, integrator fees, the monitoring program, and
persistent-network activation beyond the existing paused/unfunded discipline.

## 15. References

- [ETHGlobal Lisbon 2026 prizes](https://ethglobal.com/events/lisbon2026/prizes)
- [Uniswap Swapping API integration guide](https://developers.uniswap.org/docs/trading/swapping-api/integration-guide)
- [Uniswap no-Permit2 proxy flow](https://developers.uniswap.org/docs/trading/swapping-api/concepts/no-permit2-workflow)
- [Uniswap swap routing](https://developers.uniswap.org/docs/trading/swapping-api/concepts/swap-routing)
- `V2_SPEC.md`, `V2_THREAT_MODEL.md`, `docs/LIVE_ACTIVATION.md`, `FEEDBACK.md`
- `src/claims/AsyncClaimSettlement.sol` — kernel that was copied; v2 payment
  branch at `:265-268`
- `src/claims/ProductiveFundingAccount.sol` — `materializeAndPay` at `:214-242`,
  seal-once settlement binding at `:105-113,183`
- `src/adapters/ERC4626ReserveAdapter.sol` — immutable `makerAccount` at `:26,40`
- `src/claims/adapters/LidoWithdrawalClaimAdapter.sol` — immutable `settlement`
  at `:62,74`
- `script/DeployV2Mainnet.s.sol` — deployment pattern to mirror
- `script/V2Demo.s.sol` — demo pattern to mirror
- `frontend/scripts/create-lido-quote.mjs` — CLI pattern that was extended
- `frontend/scripts/execute-lido-quote.mjs` — seller CLI to copy for §11.3;
  gas cushion at `:167`

## 16. As-built deviations register

Design changes made during the build that a reader of 0.4.0 would not expect.
Each one is load-bearing; none should be reverted without reading the reasoning.

| # | Change | Reason |
|---|---|---|
| D-1 | Executor and kernel use **baseline accounting** instead of entry-zero / exit-zero residue checks | 0.4.0's rule 2 ("payout-asset balance is zero on entry, fail closed") converted a 1-wei donation into a permanent DoS on the executor, and the executor is immutable — recovery meant redeploying the whole triple. Baselines make donations inert instead: unspendable, because the approval is exactly `fundingAmount`, and uncapturable, because exit must equal entry. Cost: two extra SLOADs. Covered by nine executor tests and two settlement tests. |
| D-2 | Executor constructor does **not** require `settlement_.code.length != 0` | The two contracts' immutables are mutually referential. The executor must be deployed against a predicted CREATE address, at which point the settlement has no code. The binding is verified from the settlement side (`:140`), where it cannot be forged. Restoring the check makes §11.2 undeployable. |
| D-3 | §12 any-payout-asset shipped in the main build; `payoutAsset` is a quote field, not an executor immutable | Cheaper than shipping a USDC-shaped executor and rewriting it. Consequence: `IPayoutExecutor` has no `payoutAsset()` getter, and `payout()` takes five arguments. |
| D-4 | S-1 assertions 6 and 7 measured as findings only, not swept | See §2.1. Consequence: `MIN_PAYOUT_BUFFER_BPS` defaults to 100 rather than 75. |
| D-5 | Two fixtures, in `test/fork/fixtures/`, with flat swap keys and mixed number/string typing | The spike and the fork proof need different swappers, and a route is fetched for one specific swapper. Typing split explained in §10.4. |
| D-6 | `fill()` internals split into `_validate` / `_payOut` / `_emitSettled` | Stack pressure that `via_ir` alone did not carry — the escape hatch 0.4.0 pre-authorized. |
