# The factor

The factor is the **buyer**. The one with money now, willing to wait, charging for the wait.

Everyone else in the system is a seller who wants out early.

## What the factor does

1. **Holds capital** — WETH in a funding account.
2. **Keeps it earning** — that WETH sits in an Aave ERC-4626 vault, not idle.
3. **Quotes prices** — signs offers off-chain. There is no oracle for a withdrawal ticket; the factor decides what it is worth.
4. **Never sends the transaction** — the seller does. The factor's signing key stays offline.
5. **Waits, then collects** — redeems the claim at full value when the queue finalizes.

## The pricing

A claim worth **2.6 ETH** finalizing in about 5 days:

```
funding cost      10% APR × 5 days       ≈ 0.0018 ETH
risk margin       0.15%                  ≈ 0.0039 ETH
gas to collect later                     ≈ 0.003  ETH
                                          ────────────
factor offers                            ~2.59 ETH now
factor collects in ~5 days                2.60 ETH
factor keeps                             ~0.01 ETH
```

These are real configuration values, not illustrations — funding rate, risk margin, and gas are set as explicit policy. **The seller is buying certainty. The factor is selling it.**

## What the factor is risking

The discount is not free money. It is payment for:

- **Duration** — the queue might take 13 days, not 5. Capital is locked, unpredictably.
- **Impairment** — the claim might settle slightly below face value.
- **Protocol risk** — the withdrawal queue can pause.
- **Opportunity cost** — that capital could be elsewhere.

The seller offloads all of this. That is what they are paying for.

## Why the yield vault is essential, not a bonus

Measured from real settlement data: opportunities appeared on **15 out of 87 active days**.

The factor is idle roughly **83% of the time**.

| | Return |
|---|---|
| Idle wallet | thin spread on 17% of days, **nothing** on the rest |
| Reservoir funding account | **lending yield always**, plus the spread when deals appear |

That is the whole reason the ERC-4626 reserve exists. **Standing ready is only affordable if waiting pays.** A factoring desk whose capital earns nothing between deals is not a business.

## Who the factor is

**Today** — a single address. One funding account, one payment asset, and the administrative controls: pause, adapter allowlist, quote cancellation, withdrawals.

**Later** — several factors competing on the same claim.

That last part matters more than it sounds. A withdrawal ticket has **no reference price**. Its value depends on each factor's own cost of capital and their own read on how long the queue will take — so different factors genuinely arrive at different numbers.

When buyers value an asset differently and no market price exists, **competitive quoting is the only way a price can form at all**. That is why this belongs in an intent system, and why it isn't just a swap with extra steps.

---

**Next:** [Architecture →](architecture.md)
