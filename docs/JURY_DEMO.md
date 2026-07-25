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
COMPANION PROOF | Aqua/SwapVM reserve swap passed in a separate fork test
LIVE E2E 1 | seller approved exactly 0.9 stETH
LIVE E2E 2 | canonical unstETH #... minted to factor
LIVE E2E 3 | claim shares acquired ...
LIVE E2E 4 | seller received exactly 0.89775 WETH
LIVE E2E 5 | remaining productive reserve NAV ... WETH
LIVE E2E PASS | exact release bytecode exercised against canonical Lido and Aave contracts at pinned fork state
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

## Asserted proofs

The rehearsal first gates on a separate companion fork test:

1. a complete canonical Aqua swap between Aave-backed reserves through the
   modified Reservoir SwapVM router.

It then starts a fresh disposable chain-1 fork for the settlement transaction
and requires:

1. WETH deposited through canonical StataWETH with zero idle reserve WETH;
2. stETH obtained from canonical Lido;
3. a valid target-chain-timestamped EIP-712 quote;
4. exact stETH adapter approval;
5. canonical unstETH minted directly to the factor;
6. request owner and Lido share amount equal the settlement receipt;
7. exact seller WETH delta;
8. factor NFT balance increased by one;
9. zero transaction-flow stETH dust and zero remaining seller allowance; and
10. nonzero productive StataWETH NAV remains after settlement.

The companion Aqua swap and the Lido/Aave fill are both required for the
command to pass, but they are deliberately described as separate proofs. They
are not claimed to be one transaction or one fork instance.

The full supporting fork suite is:

```sh
ETH_RPC_URL="$ETH_RPC_URL" make test-fork
```

It also tests browser-equivalent Lido request and finalized-claim calls,
canonical Aqua swaps between Aave-backed reserves, real Aave deposit gas, and
fixed-share NAV accrual. No file under `test/fork/` imports a protocol mock.

The deterministic ERC-7540/8161 suite remains a standards reference because no
reviewed production ERC-8161 endpoint is claimed.

## Browser fill for final judging

The public Vercel build provides a wallet-free replay and the canonical Lido
mainnet route. For the sponsor's onchain-transfer demonstration, start a
disposable browser-capable fork:

```sh
ETH_RPC_URL="https://your-archive-mainnet-rpc.example" make jury-ui
```

The command:

1. gates on the separate official Aqua/modified-SwapVM fork swap;
2. starts Anvil at chain ID 1 and block `25,604,561`;
3. deploys the exact Reservoir release contracts;
4. funds the factor through canonical Aave StataWETH and the seller through
   canonical Lido;
5. prints a disposable seller key and a single-use signed quote;
6. starts the frontend with the exact kernel and adapter build pins; and
7. keeps the fork alive until `Ctrl-C`, then deletes the key and quote.

Use a disposable browser wallet. Temporarily point its Ethereum RPC to
`http://127.0.0.1:8545`, import the printed disposable seller key, paste the
printed quote, then execute **Approve exact stETH** and **Fill atomically**.
Never import a real funded key into this flow, never fund the printed key on a
persistent network, and restore the wallet's normal Ethereum RPC afterward.

The browser action uses the same ABI, signature domain, quote envelope,
receipt decoding, canonical WETH balance check, and canonical Lido ownership
check as the terminal rehearsal. It is not a simulated UI replay.
