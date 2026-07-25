# Reservoir Uniswap payouts — buildable specification

> Version: 0.3.0-buildable (0.2.0-minimal and the complete 0.1.0 specification
> are in git history)
>
> Status: Gate 0 API-side passed 2026-07-25; fork-side spike remaining; contract
> surface frozen below and bound to verified source lines
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

**Product framing.** This is the step that turns Reservoir from a settlement
contract into a payouts primitive. The v2 kernel already pays a fixed,
signed amount rather than a swap output; this layer decouples the *payout
currency* from the *funding currency*, so the recipient is paid in what they
asked for while the factor continues to underwrite in WETH. §12 specifies the
remaining generalization to an arbitrary payout asset; it is deliberately not
in the build target below.

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

`UNISWAP_API_KEY` is present in the gitignored `.env`. Gate 0 is reproducible
without new credentials.

### 2.1 Fork-side spike (S-1) — required before contract work is frozen

Deliverable: `test/spikes/UniswapPayoutSpike.t.sol`, a throwaway harness with
no dependency on the payout contracts. It runs against a **current-head** chain-1
fork, because a live route is only valid against live pool state.

Procedure:

1. A Node helper fetches `/quote` then `/swap` for `WETH -> USDC`, with the
   harness address as `swapper` and a distinct address as `recipient`, and
   writes a fixture containing the route JSON, `swap.to`, `swap.data`,
   `swap.value`, the API-quoted output, and the block number observed at fetch
   time.
2. The test forks at that exact block, deals WETH to the harness, approves the
   proxy for exactly the funded amount, and calls `swap.to` with the unaltered
   `swap.data`.

Assertions, each of which answers an open question:

| # | Assertion | Question it closes |
|---|---|---|
| 1 | The call succeeds from a contract caller with no Permit2 signature | does the no-Permit2 proxy flow accept a contract swapper |
| 2 | The proxy pulls **exactly** the funded WETH — harness WETH balance returns to zero | is the pull exact, or does it leave residue |
| 3 | USDC arrives at the separate `recipient`, not at the harness | is `recipient` honored end-to-end |
| 4 | An excessive minimum enforced by the harness reverts the whole call | is the failure path clean |
| 5 | Post-success harness allowance to the proxy is zero after an explicit clear, and USDC and native balances are zero | can the executor be dustless |
| 6 | The deadline encoded in `swap.data` is at least `MAX_QUOTE_LIFETIME` ahead of `block.timestamp` at fetch time | can the API deadline sit inside Reservoir's 15-minute lifetime |
| 7 | The minimum encoded in `swap.data` is recorded and compared against the API-quoted minimum | does the calldata's own minimum match the quoted one |

Assertions 6 and 7 are recorded as findings, not hard gates: the executor
enforces the signed minimum regardless of what the calldata encodes, and a
short signing deadline (§11.1) is the mitigation if the API deadline is tight.

If assertion 2 fails — the proxy pulls less than the funded amount — the
executor gains one refund step (return the unspent WETH to the funding account
before the dust assertion) and the exact-spend rule in §6 is relaxed to
exact-or-refunded. This is the only anticipated design change and it is
contained to the executor.

## 3. Scope and deployment topology

New contracts are deployed as siblings. **No existing source file is
modified**; v1 and the reviewed v2 release are untouched.

### 3.1 What is new source, what is a new instance, what is reused

Verified against source, not assumed:

| Component | Source change | Deployment | Why |
|---|---|---|---|
| `UniswapPayoutSettlement` | **new file** | new | copy of the reviewed kernel with one payout branch |
| `UniswapPayoutExecutor` | **new file** | new | the swap boundary |
| `IPayoutExecutor` | **new file** | — | interface |
| `ProductiveFundingAccount` | **none** | **new instance** | `settlement` is set once and sealed (`ProductiveFundingAccount.sol:105-113,183`). `materializeAndPay` already pays an arbitrary non-zero, non-self recipient under a balance-delta check (`:214-242`), so the executor is a valid recipient with no edit. |
| `ERC4626ReserveAdapter` | **none** | **new instance** | `makerAccount` is immutable (`ERC4626ReserveAdapter.sol:26,40`) and `configureReserve` requires `makerAccount() == address(this)` (`ProductiveFundingAccount.sol:86`). The existing mainnet adapter is bound to the existing funding account and cannot be shared. |
| `LidoWithdrawalClaimAdapter` | **none** | **new instance** | `settlement` is immutable (`LidoWithdrawalClaimAdapter.sol:62,74`) and binds one kernel. |
| Aave StataWETH, Lido queue, stETH, WETH, USDC | — | canonical | unchanged |

The correction relative to 0.2.0: that version said the new funding account
"reuses the existing `ERC4626ReserveAdapter`". It reuses the *bytecode*, not
the *instance*. Three fresh instances of reviewed, unmodified code are
required.

### 3.2 File layout

```text
src/payouts/UniswapPayoutSettlement.sol
src/payouts/UniswapPayoutExecutor.sol
src/payouts/interfaces/IPayoutExecutor.sol
script/DeployUniswapPayoutMainnet.s.sol
frontend/scripts/create-uniswap-payout-quote.mjs
frontend/scripts/fetch-uniswap-route.mjs
test/spikes/UniswapPayoutSpike.t.sol
test/unit/payouts/UniswapPayoutExecutor.t.sol
test/unit/payouts/UniswapPayoutSettlement.t.sol
test/integration/UniswapPayoutLido.t.sol
test/fork/UniswapPayoutMainnet.t.sol
```

### 3.3 Kernel bindings

`UniswapPayoutSettlement` keeps every sealed binding of the reviewed kernel and
adds one:

- `factorSigner` — immutable
- `fundingAccount` — immutable, WETH-funded
- `payoutExecutor` — immutable, **new**
- adapter allowlist — factor-mutable, unchanged in mechanism

Funding asset, payout asset, proxy target, and calldata selector are immutable
bindings on the executor. There is no payout-asset allowlist, no runtime asset
management, and no direct-WETH mode in this build target — WETH-direct
settlement remains the existing v2 kernel's job.

Quote creation stays offline in the existing CLI pattern: the operator fetches
the route server-side with the API key, validates it, and signs the Reservoir
quote with the factor key. API key and factor key remain separate secrets;
neither appears in the repository, frontend bundle, logs, or recordings.

Cut relative to the full 0.1.0 spec (deferred, not abandoned — see §13):
frontend USDC toggle (the demo is scripted on the jury fork), ERC-8161 payout
integration (Lido path only), payout-asset management, testnet leg (straight
to mainnet fork), RFC 8785 canonicalization (hash the exact retained JSON
string instead), and the monitoring/operations program.

## 4. Contract surface

### 4.1 `IPayoutExecutor`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPayoutExecutor {
    /// @notice Convert the funded input and deliver the payout asset to `recipient`.
    /// @dev The caller must have already transferred exactly `fundingAmount` of the
    ///      funding asset to this contract. Returns the recipient's measured payout
    ///      delta; the caller must not treat this as authoritative (see §7).
    function payout(
        address recipient,
        uint256 fundingAmount,
        uint256 minimumPayoutAmount,
        bytes calldata payoutData
    )
        external
        returns (uint256 delivered);

    function settlement() external view returns (address);
    function fundingAsset() external view returns (address);
    function payoutAsset() external view returns (address);
    function proxy() external view returns (address);
    function proxySelector() external view returns (bytes4);
}
```

### 4.2 `UniswapPayoutExecutor`

```solidity
constructor(
    address settlement_,   // immutable, sole permitted caller
    IERC20 fundingAsset_,  // WETH
    IERC20 payoutAsset_,   // USDC
    address proxy_,        // Gate 0 proxy target
    bytes4 proxySelector_  // Gate 0 selector
)
```

Every constructor argument is stored immutable and every one is validated as
nonzero, with `code.length != 0` required for `settlement_`, `proxy_`, and both
assets. There are no setters, no owner, no rescue methods, and no `receive`
or `payable` function anywhere on the contract — a contract that cannot receive
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
| `seal()` | additionally require `address(payoutExecutor) != address(0)` |
| quote struct | `PayoutTypes.Quote`, §5.1 |
| `fill()` signature | `+ bytes calldata payoutData` |
| `fill()` validation | `+ keccak256(payoutData) == quote.payoutDataHash`, `+ quote.minimumPayoutAmount != 0` |
| `fill()` payment branch | §6 |
| `ClaimSettled` event | `+ payoutAsset`, `+ minimumPayoutAmount`, `+ payoutDelivered` |
| new errors | `InvalidExecutor`, `PayoutDataHashMismatch`, `InvalidMinimumPayout`, `InsufficientPayout`, `PayoutResidue` |

Everything else — seller-only execution, factor signature via
`SignatureChecker` (EOA and ERC-1271), nonce, nonce floor, cancellation,
`MAX_QUOTE_LIFETIME`, pause, adapter allowlist, `ReentrancyGuardTransient`,
effects-before-interactions nonce consumption, exact capacity check,
acquisition validity check — is copied verbatim.

## 5. Signed quote

New EIP-712 domain (`Reservoir Uniswap Payouts`, version 1); v2 signatures are
invalid in the new kernel and vice versa. The quote is the reviewed v2 quote
shape plus two fields.

### 5.1 Struct and typehash

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
        uint256 minimumPayoutAmount;  // NEW: minimum measured seller USDC delta
        bytes32 payoutDataHash;       // NEW: keccak256 of the encoded payload
        uint256 nonce;
        uint256 deadline;
    }
}
```

```solidity
bytes32 public constant PAYOUT_QUOTE_TYPEHASH = keccak256(
    "PayoutQuote(address factor,address seller,address adapter,address claimController,"
    "address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,"
    "bytes32 boundsHash,uint256 minimumPayoutAmount,bytes32 payoutDataHash,uint256 nonce,"
    "uint256 deadline)"
);
```

`paymentAsset` and `paymentAmount` retain their v2 meaning: the funding leg.
The payout asset is an immutable kernel binding in this build target, not a
quote field — see §12 for the generalization.

The matching CLI `types` array extends the existing one in
`frontend/scripts/create-lido-quote.mjs:364-377` with
`{ name: "minimumPayoutAmount", type: "uint256" }` and
`{ name: "payoutDataHash", type: "bytes32" }` inserted after `boundsHash`, and
renames `primaryType` to `PayoutQuote`.

All v2 validity rules carry over unchanged: factor signature (EOA or
ERC-1271), seller-only execution, nonce and nonce floor, 15-minute maximum
quote lifetime, exact funding capacity.

### 5.2 Payout payload

```solidity
struct UniswapPayoutData {
    bytes callData;       // exact /swap response data, never altered
    bytes32 apiQuoteHash; // keccak256 of the exact retained /quote JSON string
}
```

`payoutData` is the ABI encoding of this struct; `payoutDataHash` is
`keccak256` of that encoding, bound into the signature.

Target and value are not fields: the executor's proxy target is immutable and
the value is always zero. `apiQuoteHash` is evidence for auditability, not an
oracle — nothing onchain reads it.

### 5.3 Quote envelope

Emitted by the CLI on stdout, matching the shape at
`frontend/scripts/create-lido-quote.mjs:392-405`:

```json
{
  "version": "reservoir-uniswap-payout-1",
  "chainId": 1,
  "kernel": "<UniswapPayoutSettlement>",
  "quote": { "...PayoutTypes.Quote fields..." },
  "claimData": "0x…",
  "boundsData": "0x…",
  "payoutData": "0x…",
  "factorSignature": "0x…",
  "pricing": { "...factor evidence, informational..." },
  "route": {
    "quoteRequestId": "…",
    "swapRequestId": "…",
    "apiQuoteHash": "0x…",
    "apiQuotedOut": "…",
    "proxy": "0x…",
    "selector": "0x…",
    "fetchedAtUnix": "…",
    "fetchedAtBlock": "…"
  }
}
```

`route` is informational provenance for the jury and for replay; only the
EIP-712 `PayoutQuote` fields are factor-signed, and `payoutDataHash` is what
binds the calldata.

## 6. Settlement sequence

The v2 sequence with one branch swapped:

```text
validate quote (seller, factor, adapter allowlist, claim parties, funding asset,
    amounts, claimDataHash, boundsHash, payoutDataHash, deadline, lifetime,
    nonce floor, nonce, signature)
  -> consume nonce                                    [effects before interactions]
  -> check exact funding capacity
  -> acquire complete claim (measured)                [adapter]
  -> record seller payout-asset balance               [kernel-side measurement]
  -> materialize exact WETH to the executor           [fundingAccount]
  -> executor swaps and pays the seller               [executor]
  -> verify seller's measured payout delta >= minimum [kernel-side]
  -> verify executor holds no funding or payout asset [kernel-side]
  -> emit
```

Payment branch, replacing `AsyncClaimSettlement.sol:265-268`:

```solidity
uint256 payoutBefore = IERC20(payoutExecutor.payoutAsset()).balanceOf(quote.seller);

uint256 paid = fundingAccount.materializeAndPay(address(payoutExecutor), quote.paymentAmount);
if (paid != quote.paymentAmount) {
    revert InexactPayment(quote.paymentAmount, paid);
}

payoutExecutor.payout(quote.seller, quote.paymentAmount, quote.minimumPayoutAmount, payoutData);

uint256 payoutAfter = IERC20(payoutExecutor.payoutAsset()).balanceOf(quote.seller);
uint256 delivered = payoutAfter - payoutBefore;   // underflow-reverts on a decrease
if (delivered < quote.minimumPayoutAmount) {
    revert InsufficientPayout(delivered, quote.minimumPayoutAmount);
}
if (
    IERC20(payoutExecutor.fundingAsset()).balanceOf(address(payoutExecutor)) != 0
        || IERC20(payoutExecutor.payoutAsset()).balanceOf(address(payoutExecutor)) != 0
) {
    revert PayoutResidue();
}
```

The executor's return value is deliberately discarded. The kernel re-measures
the seller's balance itself, mirroring the existing house rule that the kernel
re-checks `paid != quote.paymentAmount` even though the funding account has
already asserted it.

Any failure reverts everything, including the acquired claim and the consumed
nonce.

Invariants, unchanged in spirit from v2:

- payout if and only if complete claim acquisition, same transaction;
- the factor spends exactly the signed WETH amount;
- price improvement above the minimum belongs to the seller; and
- the executor is dustless before and after.

## 7. Executor rules

1. Only the immutable settlement may call.
2. On entry: funding-asset balance equals exactly `fundingAmount`; payout-asset
   balance is zero. Unexpected dust fails closed. Native ETH cannot be held —
   the contract has no payable entry point.
3. Decode `payoutData`; require `callData.length >= 4` and that its first four
   bytes equal the immutable `proxySelector`.
4. Record the recipient's payout-asset balance.
5. `forceApprove` the immutable proxy for exactly `fundingAmount`.
6. Call the immutable proxy with the exact API calldata and zero value. Never
   alter `swap.data`. Bubble the revert reason on failure.
7. `forceApprove(proxy, 0)` — clear any remaining allowance unconditionally.
8. Require the recipient's measured payout increase is at least
   `minimumPayoutAmount`. Router return values never substitute for the
   balance delta.
9. Require the executor's funding-asset and payout-asset balances are both
   zero.
10. Return the measured delta.

No arbitrary targets, no native value, no rescue methods, no calldata
rewriting, no owner. A griefed executor is replaced, not patched: the kernel's
executor binding is immutable, so replacement means deploying a new
settlement/executor/funding triple, exactly as this build target already does
relative to v2.

Anyone may donate the payout asset to the executor between fills. Rule 2
therefore checks the payout-asset balance is zero **on entry** and fails
closed, which converts a griefing donation into a denial of service on that
executor rather than a value leak. This is the accepted trade; §9 records it.

## 8. API integration

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

Reject the bundle unless every one of these holds:

| Field | Required value |
|---|---|
| `routing` | `"CLASSIC"` |
| `permitData` | `null` |
| input token / amount | WETH, exactly the funding amount |
| output token / recipient | USDC, to the seller |
| `swapper` | the executor address |
| chain | `tokenInChainId == tokenOutChainId == 1` |
| `swap.to` | the configured immutable proxy |
| `swap.value` | `0` |
| `swap.data` selector | the configured immutable selector |

Never alter `swap.data`. On any API failure or validation failure, no Reservoir
quote is issued — the existing WETH path is the fallback and the CLI exits
nonzero.

The exact `/quote` response body is retained byte-for-byte as a string; its
`keccak256` is `apiQuoteHash`. Both request IDs are retained in the envelope.

## 9. Threat model delta

Relative to `V2_THREAT_MODEL.md`, this layer adds exactly one new trust edge:
the kernel makes a call into an immutable executor which makes a call into an
immutable third-party proxy with factor-signed calldata.

| Risk | Mitigation | Residual |
|---|---|---|
| Malicious or wrong calldata | `payoutDataHash` is factor-signed and EIP-712-bound; the selector is immutable; the target is immutable | the factor can sign a bad route, and is the party who loses if it executes badly — the seller is protected by the minimum |
| Route degrades between signing and fill | seller's measured delta must clear the signed minimum; failure reverts the whole fill | no fill, never a bad fill; mitigated further by a short signing deadline (§11.1) |
| Proxy pulls more than approved | approval is exactly `fundingAmount` and is cleared unconditionally after the call | none |
| Proxy pulls less than approved | rule 9 zero-residue assertion reverts the fill | a partially-consuming route is unusable; §2.1 assertion 2 decides whether a refund step is needed |
| Executor donation griefing | rule 2 entry check fails closed | denial of service on one executor; replaceable, no value leak |
| Reentrancy via the proxy or payout token | `ReentrancyGuardTransient` on `fill`; executor is callable only by the settlement; all measurements are balance deltas | none identified |
| Native ETH stranded in the executor | no payable entry point; `swap.value == 0` enforced offchain and never sent onchain | none |
| API key leakage | server-side only; never in the frontend bundle, repo, logs, or recording; separate secret from the factor key | operator discipline, same as v2 |
| Kernel confusion between v2 and payout quotes | distinct EIP-712 domain; a v2 signature does not verify here and vice versa | none |

The payout layer does not change the factor's post-fill exposure: the factor
still owns the Lido claim and still bears queue duration, impairment, and
slashing risk.

## 10. Tests

### 10.1 `test/unit/payouts/UniswapPayoutExecutor.t.sol`

- only the settlement may call; every other caller reverts
- entry dust: nonzero payout-asset balance fails closed
- entry shortfall: funding balance below `fundingAmount` fails closed
- selector mismatch reverts before any approval is granted
- exact approve, exact spend, allowance cleared to zero after success
- allowance cleared to zero after a **reverting** proxy call (via a mock that
  reverts after pulling)
- below-minimum delivery reverts
- recipient measured by delta, not by router return value (mock returns a lie)
- exit residue in either asset reverts
- no payable entry point: a raw value transfer to the executor reverts

### 10.2 `test/unit/payouts/UniswapPayoutSettlement.t.sol`

- v2-domain signature is rejected; payout-domain signature is accepted
- `minimumPayoutAmount` and `payoutDataHash` are EIP-712-bound: mutating either
  invalidates the signature
- `payoutData` not matching `payoutDataHash` reverts
- zero `minimumPayoutAmount` reverts
- constructor rejects an executor bound to a different settlement or a
  different funding asset
- `seal()` requires the executor binding
- payout failure rolls back the acquired claim and the consumed nonce
- replay, nonce floor, cancellation, pause, adapter allowlist, lifetime bound,
  and capacity behavior identical to v2 (ported assertions)

### 10.3 `test/integration/UniswapPayoutLido.t.sol`

Deterministic, mock-proxy: full vertical slice with `MockLidoWithdrawalQueue`
and `MockStETH`, a mock ERC-4626, and a mock proxy that performs a
fixed-rate WETH→USDC transfer. Proves the ordering — acquire, then materialize,
then swap, then verify — and that a failure at each stage rolls back the
preceding ones.

### 10.4 `test/fork/UniswapPayoutMainnet.t.sol`

The canonical proof, on a **current-head** chain-1 fork pinned to the block
recorded at route-fetch time:

- factor starts holding StataWETH shares with zero idle WETH
- canonical Lido request is minted directly to the factor
- exact WETH is pulled by the canonical Uniswap proxy using the live
  API-produced route
- the seller receives at least the signed minimum USDC
- the executor is dustless in both assets
- forced-failure case: an excessive `minimumPayoutAmount` reverts and rolls
  back the Lido request, the nonce, and every token delta

Fixture handling: `fetch-uniswap-route.mjs` records the route **and** the block
number at fetch time. The test replays at that block, so a retained fixture
reproduces deterministically in CI without a live key. The test skips with a
clear message when no fixture is present.

### 10.5 Non-regression

The complete existing deterministic and fork suites stay green; v1 and v2 are
untouched. `forge fmt --check`, `forge build`, `make test`, `make test-fork`,
frontend lint, tests, and Vercel build all pass.

## 11. Build plan

| Step | Work | Estimate | Blocks |
|---|---|---|---|
| S-1 | Fork-side Gate 0 spike (§2.1) | 1–2 h | everything |
| S-2 | `IPayoutExecutor`, `UniswapPayoutExecutor`, `UniswapPayoutSettlement` | 2–3 h | S-1 |
| S-3 | Unit suites §10.1, §10.2 | 3 h | S-2 |
| S-4 | `fetch-uniswap-route.mjs`, integration §10.3, fork proof §10.4 | 2–3 h | S-2 |
| S-5 | `create-uniswap-payout-quote.mjs` with §8 validation | 1–2 h | S-2 |
| S-6 | `FEEDBACK.md`, README integration links, demo script | 1–2 h | S-4 |
| S-7 | *Optional* mainnet deployment (§11.2) | 2–4 h + budget | S-6 |

Fork-complete through S-6 is approximately one focused day. S-7 is a separate
decision with its own budget and authorization.

### 11.1 Deadline policy

The kernel's `MAX_QUOTE_LIFETIME` is 15 minutes, but the route is fetched at
signing time and executes against pool state that moves. The operator CLI signs
with a **2-minute** deadline by default for payout quotes, configurable
downward but never above the kernel bound. A stale route produces a revert, not
a bad fill; the short deadline reduces how often a demo hits that revert.

### 11.2 Mainnet deployment sequence, if S-7 is taken

Mirrors `script/DeployV2Mainnet.s.sol` exactly, with a distinct
acknowledgement constant (`DEPLOY_PAUSED_UNFUNDED_RESERVOIR_PAYOUTS`):

```text
new ProductiveFundingAccount(factor)
new ERC4626ReserveAdapter(fundingAccount, STATA_WETH, 0, 0)
fundingAccount.configureReserve(reserveAdapter)
new UniswapPayoutExecutor(<settlement predicted>, WETH, USDC, PROXY, SELECTOR)
new UniswapPayoutSettlement(factor, fundingAccount, executor)
new LidoWithdrawalClaimAdapter(settlement, STETH, QUEUE)
fundingAccount.configureSettlement(settlement); setPaused(true); seal()
settlement.allowAdapter(lidoAdapter); setPaused(true); seal()
```

The executor's `settlement` immutable and the settlement's `payoutExecutor`
immutable are mutually referential. Resolve with `vm.computeCreateAddress` on
the deployer nonce, as the existing preflight already does for the v2 stack
(`EXPECTED_DEPLOYER_NONCE`), and assert both bindings after deployment.
Deploy paused and unfunded; fund and activate with separate scripts and
separate acknowledgements, per `docs/LIVE_ACTIVATION.md`.

## 12. Path to any payout asset

Not in the build target. Specified here so the generalization is a scoped
change rather than a rewrite, and so the claim "the payout asset is a
one-parameter generalization" is checkable.

Delta from the USDC-immutable build target:

| Change | Detail |
|---|---|
| `payoutAsset` moves from executor immutable to signed quote field | add `address payoutAsset` to `PayoutTypes.Quote` and to the typehash |
| Executor generalizes | `payout(address recipient, IERC20 payoutAsset, uint256 fundingAmount, uint256 minimumPayoutAmount, bytes calldata payoutData)`; entry and exit dust assertions are taken against the passed asset |
| Operator rail | factor-controlled `mapping(address => bool) isPayoutAssetAllowed`, mirroring `isAdapterAllowed` including `allow`/`revoke`/events — the factor already signs each quote, so this is defence in depth, not the primary control |
| Kernel check | `if (!isPayoutAssetAllowed[quote.payoutAsset]) revert PayoutAssetNotAllowed(...)` alongside the existing adapter check |
| API request | `tokenOut` becomes the quote's payout asset; §8 validation compares against the quote rather than a constant |

Net size: roughly 30 lines of contract change plus the allowlist plumbing and
its tests.

Token behaviors, and why the existing design already handles them:

- **Fee-on-transfer** — the seller's *measured* delta must clear the signed
  minimum, so a transfer fee reduces the delta and reverts the fill rather than
  silently underpaying.
- **Blacklisting (USDC, USDT)** — a blocked recipient makes the transfer revert;
  fill-or-kill turns that into no fill, no claim, no consumed nonce.
- **Rebasing** — before and after are measured in the same transaction, so no
  rebase can occur between them.
- **Callback tokens (ERC-777 and similar)** — `ReentrancyGuardTransient` on
  `fill`, the settlement-only caller gate on the executor, and the zero-residue
  assertions bound the surface. An allowlist is nevertheless the right rail here.

**Native ETH stays excluded.** `swap.value == 0` and the absence of a payable
entry point on the executor are load-bearing for the dustlessness argument;
supporting native payouts means a payable executor, a recipient that may revert
on receive, and a new class of stranded-value failure. It is a separate design,
not a parameter.

## 13. Demo and submission

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

- [ ] Fork-side Gate 0 spike passed (§2.1), findings recorded for assertions 6–7.
- [ ] Live valid-key `/quote` and `/swap` produce the route used onchain.
- [ ] Canonical fork proof, success and forced failure.
- [ ] Retained route fixture replays the fork proof without a live key.
- [ ] `FEEDBACK.md`: key setup, contract-as-swapper behavior, no-Permit2
      proxy flow, separate recipient, routing restrictions, the
      zero-balance simulation gap, deadline headroom, error handling.
- [ ] Feedback form submitted linking `FEEDBACK.md`.
- [ ] README links the exact integration files and lines.
- [ ] Demo video shows API evidence and onchain execution.
- [ ] No API key or factor key in repository, build, or recording.

## 14. Deferred

Everything else in the 0.1.0 specification: frontend payout selection,
additional payout assets and allowlist management (§12), ERC-8161 payout
integration, UniswapX, cross-chain, native ETH, relayed fills, integrator
fees, monitoring program, and persistent-network activation beyond the
existing paused/unfunded discipline.

## 15. References

- [ETHGlobal Lisbon 2026 prizes](https://ethglobal.com/events/lisbon2026/prizes)
- [Uniswap Swapping API integration guide](https://developers.uniswap.org/docs/trading/swapping-api/integration-guide)
- [Uniswap no-Permit2 proxy flow](https://developers.uniswap.org/docs/trading/swapping-api/concepts/no-permit2-workflow)
- [Uniswap swap routing](https://developers.uniswap.org/docs/trading/swapping-api/concepts/swap-routing)
- `V2_SPEC.md`, `V2_THREAT_MODEL.md`, `docs/LIVE_ACTIVATION.md`
- `src/claims/AsyncClaimSettlement.sol` — kernel being copied; payment branch at
  `:265-268`
- `src/claims/ProductiveFundingAccount.sol` — `materializeAndPay` at `:214-242`,
  seal-once settlement binding at `:105-113,183`
- `src/adapters/ERC4626ReserveAdapter.sol` — immutable `makerAccount` at `:26,40`
- `src/claims/adapters/LidoWithdrawalClaimAdapter.sol` — immutable `settlement`
  at `:62,74`
- `script/DeployV2Mainnet.s.sol` — deployment pattern being mirrored
- `frontend/scripts/create-lido-quote.mjs` — CLI pattern being extended;
  EIP-712 types at `:364-377`, envelope at `:392-405`
