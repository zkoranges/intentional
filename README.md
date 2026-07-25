# Reservoir v2

> **Future protocol cash flow → immediate WETH, atomically.**

Reservoir v2 is a state-contingent settlement engine for asynchronous claims.
A seller receives an exact, factor-signed payment if and only if the complete
quoted claim is irrevocably acquired in the same transaction. The factor's
standby WETH stays productive in Aave StataWETH until that payment is needed.

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
matrix, frontend checks, and final independent review.

**Current deployment status:** no Reservoir contract is deployed or funded on
a persistent network. The public build enables the canonical Lido
originate/claim flows and keeps instant Reservoir fills disabled. After the
reviewed kernel and Lido adapter are deployed, their exact public addresses
must be compiled into the frontend before that route can request approval.

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
  StataUSDC, Aqua, and SwapVM. Fork acceptance imports no protocol mock.
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

The rehearsal refuses any chain other than chain 1 and any block other than
`25,604,561`. It generates fresh disposable signers, deploys the release
contracts, wraps and deposits real WETH into canonical Aave StataWETH, obtains
real stETH through canonical Lido, generates a target-chain-timestamped quote,
and fills it through the same ABI/envelope used by the web app.

The asserted output is intentionally short:

```text
canonical Aqua reserve swap passed
exact stETH approval
canonical unstETH minted to factor
Lido shares acquired
exact WETH seller payment
remaining productive reserve NAV
```

This is not a mocked simulation. The only disposable pieces are the newly
deployed Reservoir contracts and user accounts. Protocol calls target
production bytecode and state.

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
| Deterministic Foundry suites | 186 passed, 0 failed, 0 skipped |
| Production-contract fork suites | 9 passed, 0 failed, 0 skipped |
| Exact deploy/sign/approve/fill rehearsal | passed |
| Frontend rendered tests | 5 passed |
| Vinext/Sites build | passed |
| Native Next.js/Vercel build | passed |

Fork methodology and every canonical/disposable boundary are documented in
[`docs/V2_FORK_REALISM.md`](docs/V2_FORK_REALISM.md).

## Web app

The frontend connects an injected wallet and enforces Ethereum mainnet. It:

- reads canonical Aqua, SwapVM, stETH, WETH, Lido queue, and StataWETH code and
  state;
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
sealed configuration, seller, signature, hashes, deadline, nonce, adapter, and
full payment capacity. It consumes the nonce before external calls, acquires
and verifies the claim, then materializes and pays exactly. Any later failure
rolls the entire transaction back.

[`ProductiveFundingAccount`](src/claims/ProductiveFundingAccount.sol) holds
only WETH or StataWETH shares. It exposes view-safe capacity, exact
materialization, reinvestment/top-up, pause, and paused recovery.

[`LidoWithdrawalClaimAdapter`](src/claims/adapters/LidoWithdrawalClaimAdapter.sol)
pulls the signed maximum stETH, requests only the measured receipt, enforces
live Lido limits and a signed shares floor, mints directly to the factor, and
returns any transaction-relative residue.

[`ERC8161RedeemClaimAdapter`](src/claims/adapters/ERC8161RedeemClaimAdapter.sol)
handles both Pending and Claimable balances. It never assumes those states are
exclusive and never trusts preview functions or return values in place of
measured postconditions.

## Scope and risk

v2 does not build a marketplace, solver network, indexer, price oracle,
predictive model, quote backend, custody wallet, cross-currency settlement,
request-ID-zero support, generic multi-ID routing, or live ERC-8161
integration.

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

The final post-development Opus 5 release review is recorded in
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
