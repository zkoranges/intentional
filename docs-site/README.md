# Reservoir

> **Factoring for onchain claims.** Sell a future payment, get paid today.

## The everyday version

A plumbing company finishes a job. The client owes them **£10,000 in 60 days**. But payroll is Friday.

So they sell that invoice to a **factor** for **£9,700 today**. The factor waits 60 days, collects £10,000, and keeps £300.

That business is centuries old. Reservoir does it onchain.

## The onchain version

Lots of DeFi positions are promises of *future* money:

- A Lido withdrawal ticket — "Lido owes you 2.6 ETH in about 5 days."
- An ERC-7540 redemption request — "this vault owes you assets after the next epoch."

The money is real. It just hasn't arrived yet. And while you wait, **you cannot spend it and you cannot sell it.**

Reservoir lets you sell it.

```
You hold:     a claim on 2.6 ETH, arriving in ~5 days
You get:      ~2.59 ETH, right now
The factor:   waits, then collects the 2.6 ETH
```

## Why this can't just be a swap

A normal exchange — Uniswap, CoW — trades **ERC-20 tokens**. Their orders literally have a `sellToken` field.

A withdrawal ticket is not an ERC-20. It is an NFT, or a balance sitting in vault storage. **There is no `sellToken` to name.** These orders cannot be expressed, let alone priced or routed.

So the person waiting in a queue has no market at all. That is the gap Reservoir fills.

## The one rule

Everything in the protocol enforces a single invariant:

> **Payment happens if and only if the claim is secured — in the same transaction.**

The seller cannot be paid without the factor receiving the claim. The factor cannot take the claim without paying. If any part fails, the whole transaction reverts and nothing moved.

---

**Next:** [How it works →](how-it-works.md)
