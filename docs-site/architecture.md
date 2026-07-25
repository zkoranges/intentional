# Architecture

Four contracts. Each does one thing.

```
              signed quote
                   │
                   ▼
        ┌──────────────────────┐
        │ AsyncClaimSettlement │   the rule: payment iff acquisition
        └──────────┬───────────┘
                   │
        ┌──────────┴───────────┐
        ▼                      ▼
┌────────────────┐    ┌─────────────────┐
│   Productive   │    │  claim adapter  │
│ FundingAccount │    │  (per protocol) │
└───────┬────────┘    └────────┬────────┘
        ▼                      ▼
  ERC-4626 vault         Lido  /  ERC-7540
   (Aave WETH)              vaults
```

## The kernel

`AsyncClaimSettlement` holds the invariant and knows nothing about Lido, Aave, or any specific vault.

It enforces:

- a valid factor signature, bound to this chain and this contract
- the seller is the caller
- the nonce is unused, the deadline is live, the quote is at most 15 minutes old
- funding covers the payment **exactly** — no partial fills
- the claim was measurably acquired **before** any payment moves
- one settlement per quote, ever

Protocol-specific knowledge lives entirely in adapters. Adding a new claim type means writing an adapter, not touching the kernel.

## The funding account

`ProductiveFundingAccount` keeps the factor's capital in an ERC-4626 vault and materializes the exact payment on demand.

It answers exactly one question for the kernel: *can this payment be delivered in full, right now?* If anything is uncertain — the vault reverts, capacity is short, the account is paused — it answers **zero**, and the fill never starts.

## The adapters

| Adapter | Claim | What it does |
|---|---|---|
| `LidoWithdrawalClaimAdapter` | Lido withdrawal ticket | Creates a new withdrawal request owned by the factor |
| `ERC8161RedeemClaimAdapter` | ERC-7540 redemption request | Transfers the Pending portion and redeems the Claimable portion |

Adapters never trust return values. Every acquisition is confirmed by **measuring balances before and after**, because the standards permit transfer fees and return nothing useful.

## Built on 1inch Aqua

The funding layer is a working Aqua / SwapVM application: a custom VM instruction (`0x92`) lets a maker keep inventory in yield vaults and withdraw the exact amount needed at settlement, rather than parking idle tokens.

Reservoir reuses that engine as the factor's treasury. It is what makes "capital earns while it waits" true rather than aspirational.

## Testing

```
186 tests passing — unit, integration, invariant, and mainnet-fork
```

Including a property test that hammers the hard case: a claim shifting between Pending and Claimable *between quote and fill*. Across 4096 randomized sequences, payment never occurs without complete acquisition.

The Lido path is exercised against **real mainnet contracts** on a pinned fork — real stETH, the real withdrawal queue, real Aave.

---

**Next:** [Honest limits →](limits.md)
