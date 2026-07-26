# Intentional pre-alpha-001 live activation runbook

> Status: release candidate ready; fresh deployment is not yet broadcast.
> The previous proof deployment is permanently retired because its immutable
> factor key was exposed. It must never be reactivated.
>
> Deployment, funding, activation, quote-service launch, and frontend cutover
> are distinct gates. Passing one does not authorize the next.

## 1. Exact release

`pre-alpha-001` is Ethereum-mainnet only:

- a fresh, code-free factor EOA with nonce zero;
- canonical WETH payment and Aave V3 StataWETH reserve custody;
- canonical stETH and Lido WithdrawalQueueERC721;
- `LidoWithdrawalClaimAdapter` for originating a new request from stETH;
- `LidoUnstETHExitAdapter` for buying an existing seller-owned unstETH;
- one sealed settlement kernel with exactly those two adapters;
- a localhost-only quote desk behind `https://quotes.intentional.so`;
- a keyless Vercel frontend at `https://intentional.so`; and
- a maximum initial reserve of `0.006 WETH`.

The product demo is the existing-unstETH path. The user selects an NFT already
owned by their wallet, receives a request- and seller-bound firm quote, approves
that exact NFT, and atomically transfers the claim for WETH. The origination
adapter remains available, but is not evidence that an existing claim was
factored.

The public quote is operator-priced. It proves a firm executable offer, not
market-wide price discovery or demand. Aqua/SwapVM remains a separately
verifiable intent proof and is not presented as the factoring execution path.

## 2. Security and release identity

Never commit or print:

- private keys, RPC credentials, signer secrets, or hosting credentials;
- `.env` files, signed live quote envelopes, Foundry broadcast artifacts, or
  service audit logs.

Public addresses, runtime code hashes, transaction hashes, block numbers, and
explorer links belong in the release manifest.

The fresh factor key and quote-service secret live outside the repository with
mode `0600`. The factor key is used by the deployment operator and quote
service; it is never placed in the browser or Vercel. Vercel receives only the
shared proxy secret. A leaked immutable factor key permanently retires its
deployment.

Before any broadcast, require:

```sh
forge fmt --check
forge build
make test
ETH_RPC_URL="$ETH_RPC_URL" make test-fork
make existing-unsteth-e2e
npm --prefix services/quote-signer test
npm --prefix frontend test
npm --prefix frontend run lint
npm --prefix frontend run build:vercel
git diff --check
```

The canonical fork suites fail loudly when the RPC or fixtures are unavailable;
they must not report a vacuous pass.

## 3. Deployment rehearsal and preflight

The exact five-contract deployment has been simulated from the fresh nonce-zero
factor. Repeat simulation immediately before broadcast because predicted
addresses change if that account sends any earlier transaction.

Load non-secret inputs from the ignored local environment and use the measured
deployment gas baseline:

```sh
set -a
source .env
set +a

FACTOR_ADDRESS="0x..." \
EXPECTED_DEPLOYER_NONCE=0 \
DEPLOYMENT_GAS_UNITS=7885608 \
make preflight-mainnet-v2
```

The preflight checks chain 1, canonical runtime code, StataWETH's WETH binding,
the factor's code and nonce, gas headroom, source-verification configuration,
and a clean reviewed Git tree.

Simulate without `--broadcast`:

```sh
RESERVOIR_MAINNET_ACK=DEPLOY_PAUSED_UNFUNDED_RESERVOIR_V2 \
FACTOR_ADDRESS="0x..." \
forge script script/DeployV2Mainnet.s.sol:DeployV2Mainnet \
  --rpc-url "$ETH_RPC_URL" \
  --sender "$FACTOR_ADDRESS" \
  --private-key "$FACTOR_PRIVATE_KEY" \
  -vvvv
```

Use a secret-loading shell that does not echo `FACTOR_PRIVATE_KEY`. Review the
simulation output, then require an explicit human authorization before adding:

```text
--broadcast --slow --verify --verifier etherscan
```

If verification is delayed, resume verification for the same broadcast. Never
redeploy merely to obtain explorer verification.

The deploy script emits thirteen transactions and is intentionally not
resumable: several configuration calls are single-assignment. If broadcasting
stops partway through, do not rerun the script against the half-configured
addresses. Record the landed receipts, leave that stack paused and unfunded,
and restart from nonce `0` with a fresh code-free factor address after review.

## 4. Publish and verify the paused deployment

Copy the JSON emitted between
`RESERVOIR_MAINNET_DEPLOYMENT_BEGIN/END` into
`deployments/mainnet-pre-alpha-001.json`, using
[`deployments/mainnet-v2.example.json`](../deployments/mainnet-v2.example.json)
as the schema. The preferred path derives it from the successful broadcast and
independently checks every receipt and runtime code hash against mainnet:

```sh
FACTOR_ADDRESS="0x..." \
ETH_RPC_URL="$ETH_RPC_URL" \
ETHERSCAN_API_KEY="$ETHERSCAN_API_KEY" \
make create-pre-alpha-manifest
```

Record:

- the reviewed Git commit and `paused-unfunded` release state;
- factor, funding account, reserve adapter, kernel, origination adapter, and
  existing-unstETH adapter addresses;
- all five runtime code hashes;
- proof that each mainnet creation input starts with the matching bytecode from
  the reviewed local artifact and that every constructor argument matches the
  reviewed five-contract topology;
- deployment receipts, blocks, and source-verification links; and
- canonical WETH, StataWETH, stETH, and queue bindings.

Manifest generation fails unless all five contracts are already source
verified on Etherscan. It also fetches each real mainnet transaction and
receipt independently; the local broadcast file is never accepted as sole
evidence.

Commit and review the public manifest before funding. Then run:

```sh
ETH_RPC_URL="$ETH_RPC_URL" \
FACTOR_ADDRESS="0x..." \
FUNDING_ACCOUNT_ADDRESS="0x..." \
RESERVE_ADAPTER_ADDRESS="0x..." \
KERNEL_ADDRESS="0x..." \
LIDO_ADAPTER_ADDRESS="0x..." \
LIDO_UNSTETH_ADAPTER_ADDRESS="0x..." \
EXPECTED_FUNDING_CODEHASH="0x..." \
EXPECTED_RESERVE_CODEHASH="0x..." \
EXPECTED_KERNEL_CODEHASH="0x..." \
EXPECTED_LIDO_ADAPTER_CODEHASH="0x..." \
EXPECTED_LIDO_UNSTETH_ADAPTER_CODEHASH="0x..." \
EXPECTED_RELEASE_STATE=paused-unfunded \
npm --prefix frontend run verify:deployment
```

This must prove exact five-contract identity, two-adapter allowlisting, sealed
bindings, canonical endpoints, both pause flags, zero idle WETH, zero StataWETH
shares, and zero capacity.

## 5. Fund while settlement remains paused

The factor must hold `0.006 WETH` in addition to ETH for gas. After deployment
has completed and its nonce-derived addresses are final, wrap exactly the pilot
funding amount from the factor:

```sh
cast send 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  "deposit()" \
  --value 6000000000000000 \
  --rpc-url "$ETH_RPC_URL" \
  --private-key "$FACTOR_PRIVATE_KEY"
```

Do not perform this wrap before deployment: it would consume nonce `0` and
change every predicted contract address. Verify the factor now holds exactly
`0.006 WETH`. Then use the manifest values below, simulate first, and add
`--broadcast --slow` only after separate funding authorization:

```sh
RESERVOIR_MAINNET_ACK=FUND_PAUSED_RESERVOIR_V2 \
FUNDING_WETH_WEI=6000000000000000 \
MIN_CAPACITY_WEI=5000000000000000 \
FACTOR_ADDRESS="0x..." \
FUNDING_ACCOUNT_ADDRESS="0x..." \
RESERVE_ADAPTER_ADDRESS="0x..." \
KERNEL_ADDRESS="0x..." \
LIDO_ADAPTER_ADDRESS="0x..." \
LIDO_UNSTETH_ADAPTER_ADDRESS="0x..." \
EXPECTED_FUNDING_CODEHASH="0x..." \
EXPECTED_RESERVE_CODEHASH="0x..." \
EXPECTED_KERNEL_CODEHASH="0x..." \
EXPECTED_LIDO_ADAPTER_CODEHASH="0x..." \
EXPECTED_LIDO_UNSTETH_ADAPTER_CODEHASH="0x..." \
forge script script/FundV2Mainnet.s.sol:FundV2Mainnet \
  --rpc-url "$ETH_RPC_URL" \
  --sender "$FACTOR_ADDRESS" \
  --private-key "$FACTOR_PRIVATE_KEY" \
  -vvvv
```

The operation transfers exactly `0.006 WETH`, enables only the funding account,
deposits into canonical StataWETH, and asserts at least `0.005 WETH` of
deliverable capacity while settlement remains paused. Verify
`EXPECTED_RELEASE_STATE=funded-paused`, commit the receipt and manifest update,
and inspect the live StataWETH balance before activation.

## 6. Activate

Simulate the single-operation activation:

```sh
RESERVOIR_MAINNET_ACK=ACTIVATE_VERIFIED_RESERVOIR_V2 \
MIN_CAPACITY_WEI=5000000000000000 \
FACTOR_ADDRESS="0x..." \
FUNDING_ACCOUNT_ADDRESS="0x..." \
RESERVE_ADAPTER_ADDRESS="0x..." \
KERNEL_ADDRESS="0x..." \
LIDO_ADAPTER_ADDRESS="0x..." \
LIDO_UNSTETH_ADAPTER_ADDRESS="0x..." \
EXPECTED_FUNDING_CODEHASH="0x..." \
EXPECTED_RESERVE_CODEHASH="0x..." \
EXPECTED_KERNEL_CODEHASH="0x..." \
EXPECTED_LIDO_ADAPTER_CODEHASH="0x..." \
EXPECTED_LIDO_UNSTETH_ADAPTER_CODEHASH="0x..." \
forge script script/ActivateV2Mainnet.s.sol:ActivateV2Mainnet \
  --rpc-url "$ETH_RPC_URL" \
  --sender "$FACTOR_ADDRESS" \
  --private-key "$FACTOR_PRIVATE_KEY" \
  -vvvv
```

Require separate activation authorization before broadcasting. Then verify the
manifest with `EXPECTED_RELEASE_STATE=active` and the same capacity floor.

## 7. Launch the quote desk

`quotes.intentional.so` must resolve to the VPS. The service itself binds only
to `127.0.0.1:8791`; public TLS terminates in the existing Caddy instance.
Do not modify or restart unrelated containers, nginx, databases, or services.

Add one isolated Caddy site only after DNS resolves:

```caddy
quotes.intentional.so {
    @signer_endpoint path /health /quote
    handle @signer_endpoint {
        reverse_proxy 127.0.0.1:8791
    }
    handle {
        respond "Not Found" 404
    }
    header {
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        -Server
    }
}
```

Back up the Caddyfile, run `caddy validate`, and reload rather than restart.

With the active manifest committed and service dependencies installed:

```sh
DEPLOY_HOST="root@<vps>" \
DEPLOY_SSH_KEY="/absolute/path/to/key" \
DEPLOYMENT_MANIFEST_PATH=deployments/mainnet-pre-alpha-001.json \
ETH_RPC_URL="$ETH_RPC_URL" \
FACTOR_PRIVATE_KEY="$FACTOR_PRIVATE_KEY" \
SIGNER_SECRET="$SIGNER_SECRET" \
MAX_QUOTE_WEI=5000000000000000 \
MIN_QUOTE_WEI=500000000000000 \
SPREAD_BPS=25 \
MAX_SPREAD_BPS=100 \
QUOTE_TTL_SECONDS=120 \
./scripts/deploy-quote-signer.sh
```

The deployment script verifies the active mainnet identity before touching the
VPS, stages atomically with rollback, runs under the legacy isolated system
user, and requires a ready health response containing both adapters.

The deploy gate requires live capacity at least equal to `MAX_QUOTE_WEI`.
After a successful fill reduces capacity, either replenish the reserve before
redeploying the signer or deliberately lower `MAX_QUOTE_WEI` to the remaining
reviewed capacity. A post-fill signer redeploy with the original cap is
expected to fail closed.

Public checks:

- `GET https://quotes.intentional.so/health` reports ready without secrets;
- `POST /quote` without the shared secret is rejected;
- a valid existing-unstETH request returns a short-lived signed envelope;
- audit and reservation state is writable only inside the service directory.

## 8. Configure and deploy Vercel

Set these public build values from the reviewed active manifest:

```text
NEXT_PUBLIC_RESERVOIR_KERNEL
NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER
NEXT_PUBLIC_RESERVOIR_LIDO_UNSTETH_ADAPTER
```

Set these server-only values:

```text
ETH_RPC_URL
SIGNER_URL=https://quotes.intentional.so
SIGNER_SECRET
```

Never place the factor key in Vercel. Remove the retired contract pins before
deploying the reviewed commit to the existing `intentional` project.

Validate the immutable Vercel deployment URL first, then:

- `https://intentional.so/` and `/docs`;
- rendered active addresses and explorer links;
- no synthetic payout before a signed firm offer;
- wallet connect/disconnect and Ethereum-mainnet enforcement;
- owned, unclaimed unstETH discovery;
- seller/request-bound quote verification;
- exact ERC-721 approval and pre-fill simulation.

## 9. Jury transaction and release

Use a seller-controlled wallet holding one real unclaimed unstETH of at least
unstETH #130880 at `0.004999999999999999 stETH`, which remains below the
`0.005 stETH` quote cap.
The jury flow is:

1. select the existing NFT;
2. receive the live operator-signed offer;
3. approve only that token ID;
4. execute one atomic fill;
5. verify seller WETH increased by the signed amount;
6. verify the factor owns the same canonical unstETH;
7. verify the NFT approval cleared;
8. verify the settlement event and reserve's remaining StataWETH NAV.

Archive only the public quote envelope after its nonce is consumed and it is
inert. Record the transaction, block, exact deltas, token ID, owner, shares,
runtime hashes, and live UI deployment in the manifest and demo document.

Run an independent Claude Opus 5 ETHGlobal-judge review against the code,
receipts, live UI, service behavior, and claims. Fix every confirmed finding,
rerun the complete deterministic/fork/signer/frontend matrix, and publish the
review record.

Only then create and push the annotated `pre-alpha-001` tag.

## 10. Abort and retirement rules

Abort immediately on an unexpected factor nonce, codehash mismatch, adapter
count other than two, failed source verification, missing capacity, quote-desk
identity mismatch, or frontend pin mismatch.

To retire: pause settlement, pause funding, withdraw reserve capital, disable
the quote service, remove Vercel signer variables, update the manifest to
`retired-paused`, and never re-arm that deployment. Outstanding unstETH remains
factor-owned and must be claimed through canonical Lido after finalization.
