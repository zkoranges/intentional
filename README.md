# Reservoir v2

> **Future protocol cash flow → immediate WETH, atomically.**

[Live demo](https://reservoir-v2-eth-lisbon.vercel.app) ·
[Source](https://github.com/zkoranges/reservoir-v2-eth-lisbon) ·
[Production fork proof](https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30159264327) ·
[ETHGlobal provenance and track record](docs/ETHGLOBAL_SUBMISSION.md)

Reservoir v2 is a state-contingent settlement engine for asynchronous claims.
A seller receives an exact, factor-signed payment if and only if the complete
quoted claim is irrevocably acquired in the same transaction. The factor's
standby WETH stays productive in Aave StataWETH until that payment is needed.

## Aqua intent proof

Reservoir also proves a production-shaped, transaction-native intent on
canonical Aqua:

```text
maker: ship one reusable wstETH/WETH strategy to Aqua
taker: exact wstETH input + fixed recipient + minimum WETH + deadline
fill:  quote and settle atomically while maker inventory stays in Aave vaults
```

Run it against the current Ethereum mainnet head:

```sh
ETH_RPC_URL="https://your-mainnet-rpc.example" make demo-aqua-intent
```

The proof uses production Aqua, Lido stETH/wstETH, WETH, and Aave
StatawstETH/StataWETH bytecode. It obtains test inventory through canonical
Lido and WETH deposit calls on a disposable fork; it does not replace any
protocol or mint protocol tokens with a test helper. The maker authorizes the
reusable strategy through `Aqua.ship`. The transaction sender is the taker,
and SwapVM enforces the exact input call, explicit output recipient, minimum
output, and deadline. See
[`docs/AQUA_INTENT_DEMO.md`](docs/AQUA_INTENT_DEMO.md).

The first live product is Lido:

```text
seller stETH
    -> canonical Lido withdrawal request minted directly to factor
    -> exact WETH materialized from canonical Aave StataWETH
    -> seller paid atomically
```

The standards-hard reference path handles an ERC-7540/ERC-8161 request that
changes after quote signing:

```text
quote:       100 Pending +  0 Claimable
fill:         60 Pending + 40 Claimable
settlement:   transfer 60 + redeem 40 + verify both
payment:      exact fixed WETH, only after complete acquisition
```

Reservoir v1—the earlier Aqua/SwapVM ERC-4626 reserve engine—remains in this
repository and green. v2 is a separate settlement kernel that reuses v1's
generic ERC-4626 reserve adapter.

This is an unaudited hackathon beta. Mainnet funding is deliberately separate
from deployment and occurs only after the exact chain-1 rehearsal, full test
matrix, frontend checks, and AI-assisted release review.

**Current deployment status: LIVE ON ETHEREUM MAINNET (2026-07-25).** The
mainnet end-to-end proof is complete — see
[`docs/MAINNET_MICRO_DEMO.md`](docs/MAINNET_MICRO_DEMO.md) and the manifests
in [`deployments/`](deployments/):

- Aqua intent fill through canonical Aqua:
  [`0xdfb6b280…f64d37`](https://etherscan.io/tx/0xdfb6b280dfe8255ee3d0c4c74243ab9d9d4637b412926f1a9731654340f64d37)
  — exact-input wstETH → WETH, output exactly equal to the router's quote.
- Factoring settlement:
  [`0x6c7dfd20…71d611`](https://etherscan.io/tx/0x6c7dfd20a40584cf2cb40baa27e98472599dbca62da470bab6bfd2b42071d611)
  — canonical unstETH #130880 minted to the factor, seller paid exactly
  0.0049875 WETH atomically.
- Kernel `0x50b619295e00990feB28E79fA939B5f42aF6AF53`, Lido adapter
  `0xfC2c5bcAeFF85E72f13ecf78101C4D4262eBd027` (both Etherscan-verified,
  compiled into the frontend build), Aqua router
  `0x15a82271F280D4D1485CCE1980AC3C3799b483D9`, maker
  `0x9B0B0b6a9fb88Dc556795fe02BE7A73c25b781F6`.

The public quote endpoint remains deliberately fail-closed: firm quotes are
signed by the operator CLI and pasted into the UI (operator-assisted beta).
The demo used controlled team wallets and operator pricing — it proves
machinery, atomicity, and real protocol integration, not market demand.

**Bytecode attestation for the two explorer-unverified contracts** (Etherscan
source verification remains pending despite byte-exact local creation and
runtime attestations; verify locally in seconds):

```sh
# Router — expect 0xd8ac4a51d5994d12b862a303c471237bd28a497b6360c382cab3752977bf0519
cast keccak "$(cast code 0x15a82271F280D4D1485CCE1980AC3C3799b483D9 --rpc-url "$ETH_RPC_URL")"
# Maker — expect 0x553ff057aaa9b0172b6720e7889fddaf575c3213febfe0472065a231be646937
cast keccak "$(cast code 0x9B0B0b6a9fb88Dc556795fe02BE7A73c25b781F6 --rpc-url "$ETH_RPC_URL")"
# Both creation transactions carry calldata equal to `forge inspect <artifact> bytecode`
# plus the constructor args recorded in deployments/mainnet-aqua.json.
```

The paused deployment, separately capped funding, Etherscan source
verification, one-operation activation, and read-only binding-verification
procedure is frozen in
[`docs/LIVE_ACTIVATION.md`](docs/LIVE_ACTIVATION.md). That procedure has now
been executed on Ethereum mainnet (receipts above); the contracts are live and
active, with reserve recovery and the unstETH #130880 claim tracked as the
remaining operational steps. This remains unaudited hackathon software.

## What is working

- Non-upgradeable EIP-712 settlement kernel with EOA and ERC-1271 signatures.
- Seller-called, fill-or-kill execution with nonce, nonce-floor, cancellation,
  15-minute maximum quote lifetime, pause, and mutable adapter allowlist.
- Productive WETH funding with pause, top-up, exact materialization, and
  paused asset/share recovery.
- Lido adapter that measures stETH transfer rounding, reads live queue bounds
  and pause state, reconciles the minted unstETH, and leaves no flow dust.
- ERC-7540/8161 adapter that acquires Pending and Claimable legs in one fill
  using measured deltas and signed rate floors.
- Canonical mainnet-fork tests for Lido, stETH, WETH, Aave V3 StataWETH/
  StataUSDC, and official Aqua through the modified Reservoir SwapVM router.
  Canonical SwapVM runtime presence is checked separately. Fork acceptance
  imports no protocol mock.
- Public dark frontend with injected-wallet connection and canonical Lido
  originate/claim flows. Signed Reservoir quote execution is implemented but
  fail-closed until the reviewed kernel/adapter addresses are build-pinned.
- Offline factor quote CLI; no factor key is present in the browser or repo.

No production ERC-8161 endpoint is claimed. That adapter remains a
standards-conformant reference until a reviewed live vault implements the
required interfaces.

## The live product rehearsal

Requirements:

- Foundry v1.7.1;
- Node.js 22.13 or newer;
- GNU Make; and
- an archive-capable Ethereum RPC.

Initialize the exact pinned dependencies:

```sh
git submodule update --init --recursive
npm --prefix frontend ci
```

Run the exact release contracts on a disposable chain-1 fork:

```sh
ETH_RPC_URL="https://your-archive-mainnet-rpc.example" make live-product-e2e
```

For the final live browser fill, use `make jury-ui`. It keeps the disposable
fork alive, starts a build-pinned local frontend, and prints a disposable
seller key plus single-use quote. Follow the safety instructions in
[`docs/JURY_DEMO.md`](docs/JURY_DEMO.md); never use or fund that key on a
persistent network.

The manually dispatched
[`production fork proof`](.github/workflows/production-fork-proof.yml)
workflow reproduces the complete fork suite and the same product rehearsal in
GitHub Actions. Its RPC input is used read-only; every state-changing call is
sent only to the disposable local Anvil fork.

The rehearsal refuses any chain other than chain 1 and any block other than
`25,604,561`. It generates fresh disposable signers, deploys the release
contracts, wraps and deposits real WETH into canonical Aave StataWETH, obtains
real stETH through canonical Lido, generates a target-chain-timestamped quote,
and fills it through the same ABI/envelope used by the web app.

The asserted output is intentionally short and distinguishes the separate
Aqua/SwapVM companion fork proof from the Lido/Aave settlement:

```text
companion Aqua/SwapVM reserve swap passed in a separate fork test
exact stETH approval
canonical unstETH minted to factor
Lido shares acquired
exact WETH seller payment
remaining productive reserve NAV
```

This is not a mocked simulation. The only disposable pieces are the newly
deployed Reservoir contracts and user accounts. Protocol calls target
production bytecode at pinned historical state.

## Complete verification

```sh
forge fmt --check
forge build
make test
ETH_RPC_URL="$ETH_RPC_URL" make test-fork
npm --prefix frontend run lint
npm --prefix frontend test
npm --prefix frontend run build:vercel
```

Release record on 2026-07-25:

| Surface | Result |
|---|---:|
| Deterministic Foundry suites | 187 passed, 0 failed, 0 skipped |
| Production-contract fork suites | 10 passed, 0 failed, 0 skipped |
| Exact deploy/sign/approve/fill rehearsal | passed |
| Frontend rendered tests | 5 passed |
| `npm test` Vinext build and rendered assertions | passed |
| Native Next.js/Vercel build | passed |

Fork methodology and every canonical/disposable boundary are documented in
[`docs/V2_FORK_REALISM.md`](docs/V2_FORK_REALISM.md).

## Web app

The frontend connects an injected wallet and enforces Ethereum mainnet. It:

- checks canonical Aqua and SwapVM runtime presence and reads live stETH, WETH,
  Lido queue, and StataWETH state;
- shows the wallet's balances and recent unstETH requests;
- uses exact approval and simulation before canonical Lido origination;
- claims finalized unstETH through the canonical queue;
- parses a factor-signed quote JSON envelope only after a reviewed deployment
  is build-pinned;
- requires the exact pinned kernel/adapter, then validates hashes, signature,
  seller, nonce, deadline, funding capacity, allowance, and balance; and
- simulates before fill, then independently checks the seller's canonical WETH
  delta and canonical Lido request owner/share amount in addition to the bound
  `ClaimSettled` event.

The factor creates quotes outside the browser:

```sh
ETH_RPC_URL=... \
FACTOR_PRIVATE_KEY=... \
KERNEL_ADDRESS=... \
LIDO_ADAPTER_ADDRESS=... \
SELLER_ADDRESS=... \
REQUESTED_STETH=0.9 \
PAYMENT_WETH=0.89775 \
npm --prefix frontend run quote:lido > /tmp/reservoir-quote.json
```

Never commit quote files, private keys, RPC URLs, Vercel credentials, or
deployment environments. See [`frontend/README.md`](frontend/README.md).

## Architecture

```text
factor signs exact quote
          |
seller --+--> AsyncClaimSettlement
                    |
          acquire first, pay second
             +------+------------------+
             |                         |
      IClaimAdapter          ProductiveFundingAccount
       |        |                       |
   ERC-8161   Lido             ERC4626ReserveAdapter
   reference  live                       |
                                   Aave StataWETH
```

[`AsyncClaimSettlement`](src/claims/AsyncClaimSettlement.sol) validates the
sealed core configuration, seller, buyer-side claim destinations, signature,
hashes, deadline, nonce, current mutable adapter allowlist, and full payment
capacity. It consumes the nonce before external calls, acquires and verifies
the claim, then materializes and pays exactly. Any later failure rolls the
entire transaction back.

[`ProductiveFundingAccount`](src/claims/ProductiveFundingAccount.sol) holds
only WETH or StataWETH shares. It exposes view-safe capacity, exact
materialization, reinvestment/top-up, pause, and paused recovery.

[`LidoWithdrawalClaimAdapter`](src/claims/adapters/LidoWithdrawalClaimAdapter.sol)
pulls the signed maximum stETH, requests only the measured receipt, enforces
live Lido limits and a signed shares floor, mints directly to the factor, and
returns any transaction-relative residue. Pre-existing donated stETH shares
remain untouched and are intentionally unrecoverable through the adapter.

[`ERC8161RedeemClaimAdapter`](src/claims/adapters/ERC8161RedeemClaimAdapter.sol)
handles both Pending and Claimable balances. It never assumes those states are
exclusive and never trusts preview functions or return values in place of
measured postconditions.

## Scope and risk

v2 does not build a marketplace, solver network, indexer, price oracle,
predictive model, custody wallet, cross-currency settlement, request-ID-zero
support, generic multi-ID routing, or live ERC-8161 integration. It includes a
minimal stateless Lido quote endpoint: indicative pricing by default and
capacity-checked, factor-signed quotes only after explicit live configuration.

The factor prices queue time, impairment, slashing, gas, and capital cost
offchain. Lido factoring is expected to be episodic stress liquidity, not an
always-on replacement for selling stETH. The UI should not imply a fair-price
guarantee.

The beta is non-upgradeable and operator-managed. Use a capped reserve, short
quotes, active pause/revocation monitoring, and preferably an ERC-1271 smart
account. The Lido queue is an upgradeable proxy; canonical address binding
does not freeze its implementation.

Normative v2 documents:

- [`V2_SCOPE.md`](V2_SCOPE.md)
- [`V2_SPEC.md`](V2_SPEC.md)
- [`V2_IMPLEMENTATION_PLAN.md`](V2_IMPLEMENTATION_PLAN.md)
- [`V2_THREAT_MODEL.md`](V2_THREAT_MODEL.md)
- [`V2_REVIEW_FINDINGS.md`](V2_REVIEW_FINDINGS.md)

The post-development Opus 5 AI-assisted release review is recorded in
[`FINAL_V2_REVIEW.md`](FINAL_V2_REVIEW.md). The previous review remains
historical until the current live-beta pass is complete.

## Repository map

```text
src/claims/             v2 kernel, funding account, types and interfaces
src/claims/adapters/    Lido live adapter and ERC-7540/8161 reference adapter
src/adapters/           reusable v1 ERC-4626 reserve adapter
test/unit/claims/       targeted and adversarial contract tests
test/integration/       atomic v2 vertical slices
test/invariants/        constant-total and payment/acquisition properties
test/fork/              production-contract mainnet fixtures
script/                 exact deployment and terminal demos
frontend/               wallet product and operator quote tooling
docs/                   jury, fork, and economics evidence
```

## Licensing and attribution

Reservoir's top-level MIT license applies only where a file does not state
different terms. SwapVM-derived v1 extension files use
`LicenseRef-Degensoft-SwapVM-1.1`; published ERC interface surfaces preserve
their upstream SPDX/provenance.

Immutable reviewed pins:

| Dependency | Commit |
|---|---|
| SwapVM | `0817db4a618d975648e018222aedcdeb1206959e` |
| Aqua | `7a5972a6b562e3e622f6e6b2a0befef659cd5386` |
| Solidity Utils | `2d91bb67665467afc06907a69513b0fa66c46f0d` |
| OpenZeppelin Contracts | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` |
| Forge Standard Library | `8e40513d678f392f398620b3ef2b418648b33e89` |

**Powered by SwapVM — © Degensoft Ltd 2025**

**Powered by Aqua — © Degensoft Ltd 2025**

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) before redistribution.
