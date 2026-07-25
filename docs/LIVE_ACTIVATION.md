# Reservoir v2 live activation runbook

> Status: prepared and rehearsed on disposable chain-1 forks; **not deployed
> or funded on a persistent network**.
>
> Deployment, funding, and activation are separate decisions. Deploying cannot
> move reserve capital. Funding cannot enable settlement. Activation cannot
> deploy, transfer, approve, or reinvest capital.

## 1. Release identity

Only activate a clean, reviewed commit whose deterministic suite,
production-contract fork suite, `make live-product-e2e`, frontend builds, and
exact-model Opus 5 review have passed.

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

First simulate. This example uses a Foundry keystore named `reservoir-factor`:

```sh
RESERVOIR_MAINNET_ACK=DEPLOY_PAUSED_UNFUNDED_RESERVOIR_V2 \
FACTOR_ADDRESS="0x..." \
forge script script/DeployV2Mainnet.s.sol:DeployV2Mainnet \
  --rpc-url "$ETH_RPC_URL" \
  --sender "$FACTOR_ADDRESS" \
  --account reservoir-factor \
  -vvvv
```

An authorized human may separately add `--broadcast --slow` after reviewing
the simulation. `--ledger`, `--trezor`, or `--interactive` can replace
`--account reservoir-factor`.

The script refuses non-chain-1 execution, checks the canonical endpoints and
StataWETH asset, seals all single-assignment bindings, and leaves funding and
settlement paused with zero WETH and zero vault shares.

Extract the JSON between
`RESERVOIR_MAINNET_DEPLOYMENT_BEGIN/END`. Create
`deployments/mainnet-v2.json` containing:

- the exact Git commit;
- the four Reservoir addresses;
- the factor address;
- all four runtime code hashes emitted by the script;
- deployment transaction hashes and block numbers; and
- explorer source-verification links.

Do not fund yet. Commit that public manifest on a review branch, reproduce the
hashes from at least two independent Ethereum RPC providers, verify all four
contracts' source on a block explorer, and request exact-model Opus 5 review.
The manifest—not operator-supplied getters—is the reviewed identity used by
the next two scripts.

## 4. Verify the paused deployment

Run the read-only verifier once per independent RPC:

```sh
ETH_RPC_URL="$FIRST_ETH_RPC_URL" \
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

Repeat with `SECOND_ETH_RPC_URL`. The verifier checks:

- chain ID, a code-free factor, and runtime code at every dependency;
- exact equality to the four independently reviewed runtime code hashes;
- factor, funding, reserve, settlement, and Lido-adapter bindings;
- sealed configuration, adapter count, nonce floor, and allowlisting;
- zero idle threshold and zero liquidity buffer;
- canonical WETH/StataWETH/stETH/queue endpoints; and
- paused state, zero WETH, zero shares, and zero capacity.

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

Run the verifier against both independent RPCs with
`EXPECTED_RELEASE_STATE=funded-paused` and `MIN_CAPACITY_WEI` set. Confirm the
funding transaction and StataWETH share balance in the block explorer. Do not
activate until both outputs agree.

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
Then verify `EXPECTED_RELEASE_STATE=active` from both RPCs and inspect the
activation transaction on the explorer.

## 7. Pin and redeploy the frontend

Only after active verification:

1. set `NEXT_PUBLIC_RESERVOIR_KERNEL` and
   `NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER` as public build-time values;
2. rebuild and redeploy the exact reviewed frontend commit;
3. confirm the page visibly renders both exact pinned addresses with explorer
   links and no longer says `Awaiting reviewed deployment`;
4. create a short-lived, seller-specific, nonce-bound quote offline;
5. execute one deliberately small seller fill; and
6. verify the public transaction, exact WETH delta, unstETH ownership and share
   amount, zero seller allowance, and remaining reserve NAV.

The factor signer never enters the frontend or a hosting provider.
