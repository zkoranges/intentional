# Reservoir v2 web app

The public Reservoir v2 interface is a dark, minimal, non-custodial mainnet
application. It does not contain a private key, custody funds, or manufacture a
quote in the browser.

## User flows

With an injected wallet on Ethereum mainnet, the page:

1. verifies runtime code for canonical Aqua, SwapVM, stETH, WETH, Lido
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

The public frontend is live, but the current build keeps Reservoir fills
disabled because no Reservoir contract is persistently deployed or funded.
Canonical Lido queue operations remain live. There is deliberately no
unauthenticated quote API or browser-held factor key.

## Quote validation

Before enabling settlement, the browser requires
`NEXT_PUBLIC_RESERVOIR_KERNEL` and `NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER` to be
compiled into the build. It then checks:

- chain ID 1 and exact equality to those reviewed addresses;
- kernel and adapter bytecode;
- canonical stETH, Lido queue, WETH, and immutable adapter bindings;
- sealed kernel/funding account and allowlisted adapter;
- EIP-712 signature from the factor EOA or ERC-1271 contract wallet;
- claim and bounds hashes;
- seller, factor, receiver, nonce, and deadline;
- productive reserve capacity for the exact payment;
- the seller's current stETH balance and allowance; and
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
deadline is ten minutes from the target chain's latest block timestamp. Never
commit the output, environment, RPC credential, or factor key.

An EOA factor must have no EIP-7702 delegation code unless the delegated
implementation validates the quote through ERC-1271. Otherwise use a reviewed
ERC-1271 smart account.

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
EXPECTED_FUNDING_CODEHASH=0x... \
EXPECTED_RESERVE_CODEHASH=0x... \
EXPECTED_KERNEL_CODEHASH=0x... \
EXPECTED_LIDO_ADAPTER_CODEHASH=0x... \
EXPECTED_RELEASE_STATE=paused-unfunded \
npm run verify:deployment
```

Use `EXPECTED_RELEASE_STATE=funded-paused` or `active` with a nonzero
`MIN_CAPACITY_WEI` only after separately authorized funding. See
[`docs/LIVE_ACTIVATION.md`](../docs/LIVE_ACTIVATION.md).

The frontend has no persistent backend. Local `.env*`, `.vercel`, build
outputs, raw broadcast records, and quote files are ignored and must not be
committed. A sanitized public deployment manifest is committed only through
the review procedure in the activation runbook.
