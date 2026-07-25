# Reservoir

> **Factoring for onchain claims.** Sell a future payment, get paid today.

## The problem

Many DeFi positions are claims on future payments:

- a Lido withdrawal request — for example, 2.6 ETH finalizing in about 5 days
- an ERC-7540 redemption request — assets owed after the vault's next epoch

While a claim waits in a queue it cannot be spent, and it cannot be sold on a normal exchange. Uniswap and CoW orders name an ERC-20 `sellToken`; a withdrawal claim is an NFT or an entry in vault storage, so the order cannot even be expressed.

## What Reservoir does

A factor — a buyer with capital — signs a priced offer for the claim. The seller accepts it, and in a single transaction the claim moves to the factor and payment moves to the seller. The factor waits out the queue and redeems the claim at full value; the discount is its return.

```
You hold:     a claim on 2.6 ETH, arriving in ~5 days
You get:      ~2.59 ETH now
The factor:   waits, then redeems 2.6 ETH
```

The production demo factors Lido withdrawals. The settlement kernel is claim-agnostic: supporting a new claim type means writing an adapter, not changing the kernel. An ERC-7540/8161 adapter ships alongside the Lido one to demonstrate this.

## The invariant

Every contract in the protocol enforces one rule:

> Payment happens if and only if the claim is secured, in the same transaction.

The seller cannot be paid without the factor receiving the claim. The factor cannot take the claim without paying. If any step fails, the whole transaction reverts.

---

**Next:** [How it works →](how-it-works.md)
