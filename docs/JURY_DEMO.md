# Reservoir v2 jury demo

## One command

```sh
ETH_RPC_URL="https://your-archive-mainnet-rpc.example" make live-product-e2e
```

This is the production dress rehearsal, not a mock protocol test. It starts a
disposable chain-1 fork at mainnet block `25,604,561`, generates fresh
single-use accounts, deploys the exact release contracts, and executes the
same signed quote envelope and ABI used by the frontend.

## What the jury sees

```text
LIVE E2E 1 | canonical Aqua reserve swap passed
LIVE E2E 2 | seller approved exactly 0.9 stETH
LIVE E2E 3 | canonical unstETH #... minted to factor
LIVE E2E 4 | claim shares acquired ...
LIVE E2E 5 | seller received exactly 0.89775 WETH
LIVE E2E 6 | remaining productive reserve NAV ... WETH
LIVE E2E PASS | exact release bytecode exercised against production Lido and Aave state
```

Suggested narration:

> The factor's WETH starts entirely in real Aave StataWETH shares. The seller
> obtained stETH through real Lido and approved exactly the amount in the
> factor-signed quote. Reservoir first creates a canonical Lido withdrawal NFT
> directly for the factor and proves its owner and share amount. Only then does
> the reserve withdraw from Aave and pay the seller exactly. The remaining
> capital is still productive. Every later failure would revert the NFT,
> payment, and quote nonce together.

The payment is an illustrative fixed quote, not an oracle or fair-price claim.

## Production boundary

Canonical mainnet code/state:

- Aqua;
- stETH and Lido WithdrawalQueueERC721;
- WETH;
- Aave StataWETH and aWETH; and
- Aave V3 Pool.

Disposable rehearsal components:

- newly deployed Reservoir v2 contracts;
- freshly generated factor and seller accounts;
- the signed quote and temporary output files.

The Lido/Aave transaction uses no `deal`, storage mutation, call mocking,
protocol impersonation, oracle replacement, or finalizer replacement. Its
accounts are prefunded by the local fork node and obtain WETH/stETH only through
canonical payable entry points. The companion Aqua proof uses `deal` only to
give a disposable taker canonical USDC, then executes the real Aqua and Aave
contracts. The script refuses the wrong chain or fork block and deletes all
temporary keys and quote files on exit.

## Asserted chain

The pass requires:

1. a complete canonical Aqua swap between Aave-backed reserves;
2. WETH deposited through canonical StataWETH with zero idle reserve WETH;
3. stETH obtained from canonical Lido;
4. a valid target-chain-timestamped EIP-712 quote;
5. exact stETH adapter approval;
6. canonical unstETH minted directly to the factor;
7. request owner and Lido share amount equal the settlement receipt;
8. exact seller WETH delta;
9. factor NFT balance increased by one;
10. zero transaction-flow stETH dust and zero remaining seller allowance; and
11. nonzero productive StataWETH NAV remains after settlement.

The full supporting fork suite is:

```sh
ETH_RPC_URL="$ETH_RPC_URL" make test-fork
```

It also tests browser-equivalent Lido request and finalized-claim calls,
canonical Aqua swaps between Aave-backed reserves, real Aave deposit gas, and
fixed-share NAV accrual. No file under `test/fork/` imports a protocol mock.

The deterministic ERC-7540/8161 suite remains a standards reference because no
reviewed production ERC-8161 endpoint is claimed.
