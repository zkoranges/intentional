# Reservoir v2 — AI-assisted release review

> Review date: 2026-07-25
>
> Reviewer: Claude Opus 5, exact provider `claude/claude-opus-5`
>
> Review agent: `bb0683d5-8979-46db-9fb2-168d3beaa379`
>
> Final verdict: **APPROVE**
>
> Nature: read-only Claude Opus 5 review requested by the team. This is not an
> external professional audit and is not presented as independent assurance.

## Scope

The final read-only review covered the exact live-beta release candidate:

- `AsyncClaimSettlement` and `ProductiveFundingAccount`;
- Lido and ERC-7540/8161 adapters;
- the production-contract fork suites;
- the exact chain-1 deploy/sign/approve/fill rehearsal;
- the injected-wallet frontend and operator quote tooling;
- deployment and funding footguns;
- normative docs, licenses, attribution, and repository hygiene; and
- the fact that no Reservoir contract is yet deployed or funded persistently.

The reviewer agent read the implementation rather than relying on design prose
and reran the relevant gates.

## Agent-reproduced gates

| Gate | Result |
|---|---:|
| Deterministic Foundry suites | 186 passed, 0 failed, 0 skipped |
| Production-contract fork suites | 9 passed, 0 failed, 0 skipped |
| Exact `make live-product-e2e` rehearsal | passed |
| Frontend lint | passed |
| Vinext build and rendered tests | 5 passed, 0 failed |
| Native Next.js/Vercel build | passed |
| Solidity formatting | clean |
| Secret/artifact check | ignored credentials/builds confirmed; no source key |

The rehearsal observed:

```text
companion Aqua/SwapVM reserve swap passed in a separate fork test
exact 0.9 stETH seller approval
canonical unstETH minted directly to factor
0.725747813572212141 Lido shares acquired
exact 0.89775 WETH seller payment
remaining productive Aave NAV
```

## Initial verdict: APPROVE AFTER

The reviewer found no contract-layer capital-safety defect. It found one Major
frontend trust-root issue and four Minor release issues.

### M-1 — arbitrary pasted deployment could impersonate Reservoir

The initial browser accepted `kernel` and `adapter` from pasted JSON. An
attacker could deploy contracts with matching view functions, solicit stETH
approval, emit a lookalike `ClaimSettled`, and cause the old UI to announce a
payment without independently measuring canonical WETH.

This was a real release blocker, not a contract defect.

Resolution:

- `RESERVOIR_DEPLOYMENT` exists only when both
  `NEXT_PUBLIC_RESERVOIR_KERNEL` and
  `NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER` are valid build-time addresses;
- quote verification rejects unset pins and any envelope address mismatch
  before a network read or approval;
- the current public build has neither pin, so its quote textarea, approval,
  and fill route are disabled with explicit copy;
- after a future pinned fill, the browser binds the locally derived EIP-712
  quote hash and every event party/asset;
- it independently measures the seller's canonical WETH balance delta;
- it re-reads the canonical Lido request owner, share amount, and claimed
  state; and
- it requires the seller-to-adapter stETH allowance to be zero.

The closure reviewer inspected the built client artifact and confirmed the
unset environment was statically compiled to a null deployment. No arbitrary
contract can solicit approval in the shipped build.

### m-1 — EIP-7702 factor edge

OpenZeppelin treats an address with delegation code as a contract signer.
Therefore a delegated factor EOA needs a compatible ERC-1271 delegate; a plain
ECDSA signature is insufficient.

Resolution: documented consistently in `V2_SCOPE.md`, `V2_SPEC.md`, and the
frontend runbook. The beta uses a code-free EOA or a reviewed ERC-1271 account.

### m-2 — bunker mode was informational but unexplained

Resolution: the UI now states that bunker mode changes timing and underwriting
risk; only a paused queue disables origination.

### m-3 — donated stETH-share accounting was described incorrectly

The adapter correctly preserves a transaction-entry share baseline, so a
donation cannot brick future fills, but donated shares are unrecoverable.

Resolution: the realism record now distinguishes zero transaction-flow custody
from preserved pre-existing donations.

### m-4 — deployment status was not explicit

Resolution: README, scope, and frontend docs now state that no Reservoir
contract is deployed or funded on a persistent network. The public page enables
canonical Lido operations and disables instant fills until reviewed addresses
are pinned.

## Confirmed contract conclusions

- Claim acquisition precedes payment.
- Nonce consumption precedes state-changing external calls and rolls back on
  any later failure.
- Pause, adapter revocation, nonce cancellation/floor, and funding recovery
  fail closed before acquisition.
- EOA and ERC-1271 quote validation use the same EIP-712 domain and fields.
- The Lido adapter measures stETH receipt, reads live pause/min/max bounds,
  reconciles the canonical NFT owner/share amount, and preserves only its
  transaction-entry donation baseline.
- The productive funding account pays exactly or reverts and supports
  factor-only pause, top-up, reinvestment, and paused recovery.
- The deployment rehearsal cannot broadcast to contemporary mainnet because it
  requires both chain ID 1 and historical block `25,604,561`.

## Confirmed fork realism

- No file under `test/fork/` imports or deploys a protocol mock.
- No fork test uses `vm.etch`, `vm.store`, or `vm.mockCall`.
- Canonical bindings were queried directly at the pinned block.
- The Aqua companion proof executes a real Aqua swap with both reserves in
  canonical Aave Stata vaults.
- The Lido/Aave rehearsal obtains stETH and WETH through canonical payable
  entry points, mints canonical unstETH directly to the factor, and pays from
  canonical StataWETH.
- Historical-owner impersonation is limited to a normal public claim call in
  the finalized-unstETH wallet test and is explicitly disclosed; no protocol,
  oracle, finalizer, keeper, or governance identity is impersonated.

## Rejected false positives

- New factor controls cannot strand a seller mid-fill; they act before
  acquisition and transaction atomicity restores all state on failure.
- The historical-owner claim test is not privileged protocol impersonation.
- The 15-minute frontend check matches the kernel constant.
- Mixed SPDX identifiers match the preserved upstream license families.
- `.env.local`, `.vercel`, generated builds, deployment outputs, and quote
  files are ignored; disposable rehearsal keys live only in a temporary
  directory deleted on exit.
- The fork-only deployment script cannot accidentally target current mainnet.

## Closure

After the fixes, Opus 5 reran the final gates, inspected the compiled frontend
artifact, and returned:

> **APPROVE — no remaining findings.**

One non-blocking observation remains: frontend guard tests combine rendered
artifact checks with source-level assertions rather than a full injected-wallet
automation harness. The release compensates with the exact receipt-backed
chain-1 rehearsal; a wallet automation harness is appropriate if the quote path
grows.

## Post-release wallet authorization addendum — 2026-07-25

An exact Claude Opus 5 delta review
(`claude/claude-opus-5`, agent
`30aa483c-3fda-4663-b90c-27ee52f69535`) examined the production wallet paths
after a residual-allowance audit.

Confirmed fixes:

- canonical Lido and Reservoir actions display an approval as ready only when
  the allowance equals the exact requested stETH amount;
- both request submission and Reservoir fill re-read that equality immediately
  before simulation;
- signed Reservoir amounts outside Lido's canonical 100-wei to 1,000-ETH
  bounds are rejected before approval;
- every mined wallet write checks receipt status;
- Lido request success requires the canonical unstETH mint;
- Lido claim success requires the canonical `WithdrawalClaimed` event, matching
  request/owner/receiver, a nonzero emitted ETH amount, and a claimed-state
  re-read; and
- any mined transaction that cannot satisfy its postconditions retains its
  hash in the interface, refreshes state, and is shown as a verification
  warning rather than optimistic success.

The reviewer agent reran the focused tests, TypeScript checking, and linting,
then returned:

> **APPROVE**

No persistent Reservoir deployment or funding was introduced by this addendum.

## Production-activation boundary addendum — 2026-07-25

An exact Claude Opus 5 activation review
(`claude/claude-opus-5`, agent
`dcf8aa6e-d710-4428-9f8d-ffc7c94cb6fb`) examined the three-phase live release
procedure and returned:

> **APPROVE — no blockers and no majors remain.**

The review confirmed:

- deployment creates the exact release paused and unfunded;
- funding and activation use separate scripts and acknowledgement phrases;
- funding deposits capped WETH into canonical StataWETH while settlement stays
  paused;
- activation performs only the final settlement unpause;
- all four Reservoir runtime code hashes are strict reviewed inputs in both
  the Solidity operations and independent JavaScript verifier;
- the verifier fixes the initial adapter count and nonce floor at one and zero,
  checks a code-free factor, and validates every canonical binding;
- permanent signing uses a Foundry keystore, hardware wallet, or interactive
  signer; raw keys appear only in disposable fork tooling;
- wrong acknowledgement, over-cap funding, and wrong runtime hash fail for
  their exact expected reasons;
- deployment identities are reproduced through live RPC reads and explorer
  source verification before capital moves; and
- no persistent transaction was broadcast.

The team later made a second RPC an optional operator cross-check rather than
a release gate. This procedural simplification does not change the verifier,
runtime-codehash bindings, Etherscan source-verification requirement, or
contract safety boundary.

The reviewer approved the non-persistent release for commit and push. Its
remaining low-severity suggestions were also folded in:

- the frontend renders the full checksummed kernel and Lido-adapter addresses
  with explorer links;
- a pinned production build asserts that both full addresses reach the client
  bundle, followed by an unpinned rebuild for the current public release;
- the rehearsal deliberately perturbs a runtime hash and proves rejection; and
- the runbook accurately distinguishes complete pre-broadcast simulation from
  the three separately recoverable funding transactions.

The only residual procedural property is unavoidable for contracts with
constructor immutables: the reviewed source-to-runtime-hash link is established
through the committed public deployment manifest and explorer source
verification after deployment and before funding.
