# Architecture

Four contracts, one invariant.

```
              signed quote
                   │
                   ▼
        ┌──────────────────────┐
        │ AsyncClaimSettlement │   payment iff acquisition
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

## AsyncClaimSettlement

The settlement kernel. It holds the invariant and knows nothing about Lido, Aave, or any specific vault. It checks:

- a valid factor signature, bound to this chain and this contract
- the caller is the named seller
- the nonce is unused, the deadline is live, and the quote is at most 15 minutes old
- funding covers the payment exactly; there are no partial fills
- the claim was measurably acquired before any payment moves
- one settlement per quote

Protocol-specific logic lives in adapters. Supporting a new claim type means writing an adapter; the kernel does not change.

## ProductiveFundingAccount

Keeps the factor's capital in an ERC-4626 vault and withdraws the exact payment on demand. It answers one question for the kernel: can this payment be delivered in full, right now? If anything is uncertain — the vault reverts, capacity is short, the account is paused — it reports zero and the fill never starts.

## Adapters

| Adapter | Claim | Action |
|---|---|---|
| `LidoWithdrawalClaimAdapter` | Lido withdrawal request | Creates a new request owned by the factor |
| `ERC8161RedeemClaimAdapter` | ERC-7540 redemption request | Transfers the Pending portion, redeems the Claimable portion |

Adapters confirm every acquisition by measuring balances before and after rather than trusting return values, because the underlying standards permit transfer fees and return nothing useful.

## 1inch Aqua

The funding layer is an Aqua / SwapVM application. A custom VM instruction (`0x92`) lets a maker keep inventory in yield vaults and withdraw the exact amount needed at settlement. Reservoir uses that engine as the factor's treasury.

## Testing

187 deterministic tests (unit, integration, invariant) and 10 mainnet-fork suites pass. An invariant test moves a claim between Pending and Claimable between quote and fill; across 4096 randomized sequences, payment never occurs without complete acquisition. The Lido path runs against real mainnet contracts on a pinned fork: real stETH, the real withdrawal queue, real Aave.

---

**Next:** [Limits →](limits.md)
