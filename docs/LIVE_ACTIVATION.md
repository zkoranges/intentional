# Reservoir v2 live activation runbook

> Status: this procedure **was executed on Ethereum mainnet on 2026-07-25**.
> The resulting v2 deployment completed its settlement proof and has since
> been **retired** (`retired-paused`): it cannot be reactivated, because the
> immutable factor signer key was exposed. The proof record is in
> [`docs/MAINNET_MICRO_DEMO.md`](MAINNET_MICRO_DEMO.md). This document
> remains the authoritative procedure for any **fresh** deployment, which
> requires a **fresh** key.
>
> Deployment, funding, and activation are separate decisions. Deploying cannot
> move reserve capital. Funding cannot enable settlement. Activation cannot
> deploy, transfer, approve, or reinvest capital.

## 1. Release identity

Only activate a clean, reviewed commit whose deterministic suite,
production-contract fork suite, `make live-product-e2e`, frontend builds, and
exact-model Opus 5 review have passed.

One healthy Ethereum mainnet RPC is sufficient. Source verification on
Etherscan is a separate required check before funding. A second RPC may be
used as an operator cross-check, but it is not an activation gate.

The first jury release is:

- Ethereum mainnet only;
- one code-free factor EOA;
- canonical WETH payment;
- canonical Aave V3 StataWETH custody;
- canonical stETH and Lido WithdrawalQueueERC721;
- one Lido adapter;
- paused and unfunded at deployment; and
- capped at 5 WETH during the first funding operation.

Do not put an RPC URL, signer secret, signed quote, raw broadcast artifact, or
hosting environment file in the repository. Public addresses, transaction
hashes, source-verification links, and runtime code hashes are safe to record.

## 2. Rehearse the exact release

The authoritative no-mock dress rehearsal requires an archive mainnet RPC:

```sh
ETH_RPC_URL="https://your-archive-mainnet-rpc.example" make live-product-e2e
```

It deploys on a disposable chain-1 fork, obtains assets through canonical
Lido/WETH entry points, keeps funding in canonical StataWETH, proves a
canonical Aqua swap, and executes the quote envelope used by the web app.

The deployment boundary has a separate current-head rehearsal:

```sh
ETH_RPC_URL="https://your-mainnet-rpc.example" make rehearse-live-activation
```

That rehearsal uses a fresh disposable factor, verifies exact failure reasons,
deploys paused and empty, compares runtime hashes, funds canonical StataWETH
while settlement stays paused, verifies the intermediate state, and then sends
the one-operation activation. Its broadcast directory and disposable key live
only in a temporary directory and are removed on exit.

## 3. Deploy paused and unfunded

Use an encrypted Foundry keystore, Ledger, Trezor, or interactive signing. Do
not export the permanent factor key as `FACTOR_PRIVATE_KEY`.

Load the non-secret operator inputs and run the read-only preflight:

```sh
set -a
source .env
set +a
make preflight-mainnet-v2
```

The preflight requires chain 1, the reviewed factor nonce, a code-free factor,
canonical dependency code and StataWETH binding, sufficient live gas headroom,
an Etherscan key, and a clean Git tree. It never signs or broadcasts.

Then simulate. This example uses a Foundry keystore named
`reservoir-factor`:

```sh
RESERVOIR_MAINNET_ACK=DEPLOY_PAUSED_UNFUNDED_RESERVOIR_V2 \
FACTOR_ADDRESS="0x..." \
forge script script/DeployV2Mainnet.s.sol:DeployV2Mainnet \
  --rpc-url "$ETH_RPC_URL" \
  --sender "$FACTOR_ADDRESS" \
  --account reservoir-factor \
  -vvvv
```

After reviewing the simulation, an authorized human may run the same command
with:

```text
--broadcast --slow --verify --verifier etherscan
```

Foundry reads `ETHERSCAN_API_KEY` through the checked-in `mainnet` verifier
configuration. If automatic verification is delayed, rerun the identical
script command with `--resume --verify --verifier etherscan`; do not redeploy.
`--ledger`, `--trezor`, or `--interactive` can replace `--account
reservoir-factor`.

The script refuses non-chain-1 execution, checks the canonical endpoints and
StataWETH asset, seals all single-assignment bindings, and leaves funding and
settlement paused with zero WETH and zero vault shares.

Extract the JSON between
`RESERVOIR_MAINNET_DEPLOYMENT_BEGIN/END`. Create
`deployments/mainnet-v2.json` from
[`deployments/mainnet-v2.example.json`](../deployments/mainnet-v2.example.json),
containing:

- the exact Git commit;
- the four Reservoir addresses;
- the factor address;
- all four runtime code hashes emitted by the script;
- deployment transaction hashes and block numbers; and
- explorer source-verification links.

Do not fund yet. Commit that public manifest on a review branch, reproduce the
hashes through the configured Ethereum RPC, verify all four contracts' source
on Etherscan, and request exact-model Opus 5 review. The manifest—not
operator-supplied getters—is the reviewed identity used by the next two
scripts.

## 4. Verify the paused deployment

Run the read-only verifier:

```sh
ETH_RPC_URL="$ETH_RPC_URL" \
FACTOR_ADDRESS="0x..." \
KERNEL_ADDRESS="0x..." \
FUNDING_ACCOUNT_ADDRESS="0x..." \
RESERVE_ADAPTER_ADDRESS="0x..." \
LIDO_ADAPTER_ADDRESS="0x..." \
EXPECTED_FUNDING_CODEHASH="0x..." \
EXPECTED_RESERVE_CODEHASH="0x..." \
EXPECTED_KERNEL_CODEHASH="0x..." \
EXPECTED_LIDO_ADAPTER_CODEHASH="0x..." \
EXPECTED_RELEASE_STATE=paused-unfunded \
npm --prefix frontend run verify:deployment
```

The verifier checks:

- chain ID, a code-free factor, and runtime code at every dependency;
- exact equality to the four manifest-reviewed runtime code hashes;
- factor, funding, reserve, settlement, and Lido-adapter bindings;
- sealed core configuration plus the current factor-controlled adapter count,
  nonce floor, and allowlisting;
- zero idle threshold and zero liquidity buffer;
- canonical WETH/StataWETH/stETH/queue endpoints; and
- paused state, zero WETH, zero shares, and zero capacity.

`EXPECTED_RELEASE_STATE` uses the manifest lifecycle vocabulary:
`paused-unfunded` → `funded-paused` → `active` → `retired-paused` →
`claim-collected`. The first three are the activation path in this runbook.
`retired-paused` marks a deployment permanently taken out of service (paused,
unfunded, never to be re-armed — the state of the v2 deployment), and
`claim-collected` is the terminal state once its last outstanding withdrawal
claim has been collected.

## 5. Fund while settlement stays paused

Set `MIN_CAPACITY_WEI` to the smallest jury fill that must remain deliverable;
do not assume a fixed one-wei ERC-4626 rounding adjustment.

First simulate with the reviewed manifest values:

```sh
RESERVOIR_MAINNET_ACK=FUND_PAUSED_RESERVOIR_V2 \
FUNDING_WETH_WEI="<0.1 to 5 WETH, in wei>" \
MIN_CAPACITY_WEI="<explicit minimum, in wei>" \
FACTOR_ADDRESS="0x..." \
FUNDING_ACCOUNT_ADDRESS="0x..." \
RESERVE_ADAPTER_ADDRESS="0x..." \
KERNEL_ADDRESS="0x..." \
LIDO_ADAPTER_ADDRESS="0x..." \
EXPECTED_FUNDING_CODEHASH="0x..." \
EXPECTED_RESERVE_CODEHASH="0x..." \
EXPECTED_KERNEL_CODEHASH="0x..." \
EXPECTED_LIDO_ADAPTER_CODEHASH="0x..." \
forge script script/FundV2Mainnet.s.sol:FundV2Mainnet \
  --rpc-url "$ETH_RPC_URL" \
  --sender "$FACTOR_ADDRESS" \
  --account reservoir-factor \
  -vvvv
```

An authorized human may separately add `--broadcast --slow`. This operation:

1. transfers only the capped WETH to the bound funding account;
2. unpauses the funding account while settlement remains paused;
3. deposits all WETH into canonical StataWETH; and
4. asserts zero idle WETH, nonzero shares, and the explicit minimum capacity.

Foundry simulates the complete script before sending anything, so a failing
preflight or postcondition aborts before broadcast. An authorized broadcast
still consists of three sequential transactions; if contemporary chain state
causes one to fail after an earlier transaction lands, settlement remains
paused and the factor uses the documented pause/recovery controls.

Run the verifier with
`EXPECTED_RELEASE_STATE=funded-paused` and `MIN_CAPACITY_WEI` set. Confirm the
funding transaction and StataWETH share balance in Etherscan. Do not activate
until both checks agree.

## 6. Activate one verified release

Activation contains one onchain operation: unpause the already-funded
settlement kernel.

```sh
RESERVOIR_MAINNET_ACK=ACTIVATE_VERIFIED_RESERVOIR_V2 \
MIN_CAPACITY_WEI="<same explicit minimum>" \
FACTOR_ADDRESS="0x..." \
FUNDING_ACCOUNT_ADDRESS="0x..." \
RESERVE_ADAPTER_ADDRESS="0x..." \
KERNEL_ADDRESS="0x..." \
LIDO_ADAPTER_ADDRESS="0x..." \
EXPECTED_FUNDING_CODEHASH="0x..." \
EXPECTED_RESERVE_CODEHASH="0x..." \
EXPECTED_KERNEL_CODEHASH="0x..." \
EXPECTED_LIDO_ADAPTER_CODEHASH="0x..." \
forge script script/ActivateV2Mainnet.s.sol:ActivateV2Mainnet \
  --rpc-url "$ETH_RPC_URL" \
  --sender "$FACTOR_ADDRESS" \
  --account reservoir-factor \
  -vvvv
```

Simulate first; an authorized human may separately add `--broadcast --slow`.
Then verify `EXPECTED_RELEASE_STATE=active` through the configured RPC and
inspect the activation transaction on Etherscan.

## 7. Pin and redeploy the frontend

Only after active verification:

1. use [`frontend/.env.example`](../frontend/.env.example) as the template for
   local or hosting build variables, then set `NEXT_PUBLIC_RESERVOIR_KERNEL` and
   `NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER` from the reviewed manifest;
2. rebuild and redeploy the exact reviewed frontend commit;
3. confirm the page visibly renders both exact pinned addresses with explorer
   links and no longer says `Awaiting reviewed deployment`;
4. configure the stateless quote route with the reviewed addresses, RPC,
   discount policy, and a dedicated capped quote signer (preferably authorized
   by a reviewed ERC-1271 factor account); never use a permanent deployer or
   unrestricted treasury key in hosting;
5. when the seller is ready, request a seller-specific, nonce-bound quote with
   the default target-chain deadline of approximately ten minutes; the kernel
   accepts only deadlines no more than fifteen minutes ahead, so do not
   pre-sign the live quote earlier in the day;
6. execute the rehearsed `0.9 stETH`-scale seller fill rather than using
   Lido's rounding-sensitive protocol minimum; and
7. verify the public transaction, exact WETH delta, unstETH ownership and share
   amount, zero seller allowance, and remaining reserve NAV.

The factor signer never enters the browser. Hosting may hold only the dedicated
capped quote signer described above; administrative and unrestricted treasury
keys remain offline.
