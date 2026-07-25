# Aqua intent production proof

## The intent

Reservoir expresses one transaction-native exact-input intent:

```text
spend exactly 0.01 wstETH
receive at least the quoted WETH
send output to the named recipient
fill before the deadline
use only the Aqua-shipped maker strategy
```

The maker does not sign each fill. It authorizes a reusable order and its
virtual balances onchain with canonical `Aqua.ship`. The taker authorizes one
fill by sending the transaction. This release does not claim an offchain
taker-signature or relayer flow.

## Run the jury proof

Requirements:

- Foundry with Solidity 0.8.30 and Cancun support;
- an Ethereum mainnet RPC; and
- the repository's exact pinned Aqua and SwapVM submodules.

```sh
git submodule update --init --recursive
ETH_RPC_URL="https://your-mainnet-rpc.example" make demo-aqua-intent
```

The command forks the current mainnet head and:

1. checks canonical runtime code and Aave vault bindings;
2. obtains stETH through canonical Lido and wraps it through canonical wstETH;
3. obtains WETH through the canonical WETH deposit function;
4. deposits maker inventory into canonical Aave StatawstETH and StataWETH;
5. deploys only the new Reservoir router, maker account, and reserve adapters;
6. ships the maker strategy to canonical Aqua;
7. quotes an exact-input intent without changing vault shares;
8. fills it to a recipient distinct from the taker;
9. verifies canonical Aqua balance changes and exact wallet deltas; and
10. verifies output was materialized only for settlement, received input was
    reinvested, and maker/adapter idle balances are zero.

The paired negative test at the pinned archive block proves:

- minimum output above the quote fails;
- an expired deadline fails; and
- modifying one byte of the maker order changes its hash and canonical Aqua
  rejects it as an unshipped strategy.

## Real and disposable boundaries

Production contracts:

- Aqua `0x499943E74FB0cE105688beeE8Ef2ABec5D936d31`;
- stETH and wstETH;
- WETH;
- Aave V3 StatawstETH and StataWETH; and
- their underlying Aave aTokens and Pool behavior.

Disposable fork fixtures:

- maker and taker accounts;
- Reservoir router, maker account, and reserve adapters; and
- ETH used to acquire fork-local stETH and WETH.

No state is broadcast to a persistent network. This proves that the exact
release logic can execute against current production protocol bytecode; a
persistent deployment still requires the repository's separate activation,
verification, and funding procedure.

## What it does not claim

- no gasless or relayed taker signature;
- no private order restricted to one taker;
- no claim that the XYC price is a market oracle;
- no production audit; and
- no persistent deployment.

The next product layer can source a market-aware price before constructing the
minimum-output intent. Uniswap payout integration remains a separate second
priority and must pass its contract-as-swapper Gate 0 before it is advertised.
