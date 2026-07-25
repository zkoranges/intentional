# Reservoir v2 web app

The public Intentional interface is a dark, minimal, non-custodial mainnet
application. It does not contain a private key, custody funds, or manufacture a
quote in the browser.

## User flows

With an injected wallet on Ethereum mainnet, the page:

1. verifies runtime presence for canonical Aqua and SwapVM plus the complete
   canonical bindings for stETH, WETH, Lido
   WithdrawalQueueERC721, and Aave StataWETH;
2. reads the connected wallet's ETH, stETH, WETH, Lido queue state, and recent
   withdrawal requests;
3. approves the canonical Lido queue for an exact stETH amount, simulates, and
   originates a real unstETH request;
4. claims a finalized unstETH request through the canonical queue; and
5. after a reviewed deployment is build-pinned, parses a factor-signed
   Reservoir quote, requires the exact pinned kernel/adapter, validates every
   economic binding, requests exact adapter approval, simulates the fill, and
   verifies canonical WETH payment plus canonical Lido ownership/share state
   after the receipt.

The same-origin `/api/quote/lido` route is a keyless firm-quote proxy to the
operator desk. The kernel and both Lido adapters are build-pinned from the
reviewed deployment manifest. `/api/status` independently reads their current
state through a server-only RPC and exposes the firm path only when the fresh
deployment is sealed, active, allowlists both adapters, and has real reserve
capacity. The previous proof deployment is permanently retired and is never a
valid firm-quote target. Canonical Lido queue operations remain available, and
no signing key enters the browser or Vercel.

## Quote validation

Before enabling settlement, the browser requires
`NEXT_PUBLIC_RESERVOIR_KERNEL`, `NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER`, and
`NEXT_PUBLIC_RESERVOIR_LIDO_UNSTETH_ADAPTER` to be
compiled into the build. Copy `.env.example` to a local `.env.local` only
after the reviewed mainnet manifest exists. It then checks:

- chain ID 1 and exact equality to those reviewed addresses;
- kernel and adapter bytecode;
- canonical stETH, Lido queue, WETH, and immutable adapter bindings;
- sealed kernel/funding account and allowlisted adapter;
- EIP-712 signature from the factor EOA or ERC-1271 contract wallet;
- claim and bounds hashes;
- seller, factor, buyer-controlled claim destinations, nonce, and deadline;
- productive reserve capacity for the exact payment;
- the seller's current stETH balance and exact allowance for origination;
- ownership, immutable amounts, and ERC-721 approval for an existing unstETH;
- the signed stETH shortfall and Lido-share floor.

Each wallet write is simulated against current state. Approval is exact, not
unlimited. After fill, the app measures the seller's canonical WETH delta and
re-reads the canonical Lido request owner/share amount. No optimistic success
state is shown.

## Build and test

Node.js 22.13 or newer is required.

```sh
npm ci
npm run lint
npm test
npm run build:vercel
```

`npm test` builds the Vinext/Sites bundle and runs rendered-output assertions.
`build:vercel` independently compiles the native Next.js production target.

The authoritative no-mock chain rehearsal is run from the repository root:

```sh
ETH_RPC_URL="https://your-archive-mainnet-rpc.example" make live-product-e2e
```

It deploys the exact release contracts on a disposable chain-1 fork, funds the
reserve through canonical Aave StataWETH, obtains stETH through canonical Lido,
creates a target-chain-timestamped signed quote, and executes it using the same
ABI and quote envelope used by the web app.

## Quote operator CLI

The factor can create a quote without exposing its key to the frontend:

```sh
ETH_RPC_URL=... \
FACTOR_PRIVATE_KEY=... \
KERNEL_ADDRESS=... \
LIDO_ADAPTER_ADDRESS=... \
SELLER_ADDRESS=... \
REQUESTED_STETH=0.9 \
PAYMENT_WETH=0.89775 \
npm run quote:lido > /tmp/reservoir-quote.json
```

All values are validated against the target chain before signing. The default
deadline is ten minutes from the target chain's latest block timestamp. The
kernel rejects deadlines more than fifteen minutes ahead, so generate the live
quote only after the seller is ready to fill. The operator CLI and kernel both
reject any quote that leaves the claim controller or receiver with the seller.
Never commit the output, environment, RPC credential, or factor key.

An EOA factor must have no EIP-7702 delegation code unless the delegated
implementation validates the quote through ERC-1271. Otherwise use a reviewed
ERC-1271 smart account.

## In-app quote service

The app requests an indicative quote automatically after a valid stETH amount
is entered. `/api/quote/lido/indicative` prices with fixed policy constants
compiled into the route — a 10% APR funding assumption, a 20 bps
risk-and-operations fee, and a 500 bps overall cap — applied to the live (or
clearly labelled fallback) Lido wait estimate. That is a fixed operator
policy, not a market price; stETH:WETH is assumed 1:1 and no depeg is priced.
The response also reports whether firm quotes are currently available,
derived server-side from the desk configuration. `/api/status` additionally
requires a sealed, unpaused deployment with real reserve capacity before the
UI can expose the firm path. This preview cannot be
filled.

Firm quotes go through `/api/quote/lido`, a keyless proxy to the operator's
quote desk configured by the server-only `SIGNER_URL` and `SIGNER_SECRET`
environment variables. With no desk configured, the proxy fails closed with
503. No signing key exists in the frontend or in Vercel.

## Production environment boundary

For `intentional.so`, configure Vercel with exactly these classes of values:

| Scope | Variables |
| --- | --- |
| Public build pins | `NEXT_PUBLIC_RESERVOIR_KERNEL`, `NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER`, `NEXT_PUBLIC_RESERVOIR_LIDO_UNSTETH_ADAPTER` |
| Server only | `ETH_RPC_URL`, `SIGNER_URL=https://quotes.intentional.so`, `SIGNER_SECRET` |
| Never in Vercel | `FACTOR_PRIVATE_KEY`, deployer keys, SSH keys, raw quote envelopes |

The same `SIGNER_SECRET` is installed on the VPS and in Vercel as a
server-only value. The VPS signer remains bound to `127.0.0.1`; a named tunnel
for `quotes.intentional.so` is the only public route to it. Never prefix the
RPC URL, signer URL, or signer secret with `NEXT_PUBLIC_`.

## Security boundary

This is an unaudited hackathon beta. The settlement contracts—not the page—are
the final enforcement boundary. The beta should use a deliberately capped
reserve, short quotes, active pause/revocation monitoring, and preferably an
ERC-1271 smart account as factor. Real funding is a separate operator action
performed only after the exact fork rehearsal and release review pass.

The public-address and canonical-binding verifier is:

```sh
ETH_RPC_URL=... \
FACTOR_ADDRESS=0x... \
KERNEL_ADDRESS=0x... \
FUNDING_ACCOUNT_ADDRESS=0x... \
RESERVE_ADAPTER_ADDRESS=0x... \
LIDO_ADAPTER_ADDRESS=0x... \
LIDO_UNSTETH_ADAPTER_ADDRESS=0x... \
EXPECTED_FUNDING_CODEHASH=0x... \
EXPECTED_RESERVE_CODEHASH=0x... \
EXPECTED_KERNEL_CODEHASH=0x... \
EXPECTED_LIDO_ADAPTER_CODEHASH=0x... \
EXPECTED_LIDO_UNSTETH_ADAPTER_CODEHASH=0x... \
EXPECTED_RELEASE_STATE=paused-unfunded \
npm run verify:deployment
```

Use `EXPECTED_RELEASE_STATE=funded-paused` or `active` with a nonzero
`MIN_CAPACITY_WEI` only after separately authorized funding.
`retired-paused` and `claim-collected` are terminal states and cannot be
reactivated. See
[`docs/LIVE_ACTIVATION.md`](../docs/LIVE_ACTIVATION.md).

The Vercel proxy route is stateless and stores no requests or signatures. The
VPS desk persists only reservation and audit state; it never exposes the
factor key. Local `.env*`, `.vercel`, build outputs, raw broadcast records,
and quote files are ignored and must not be committed. A sanitized public
deployment manifest is committed only through the review procedure in the
activation runbook.
