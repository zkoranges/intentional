# The factor

The factor is the buyer: it has capital now, waits out the queue, and charges for the wait.

## What the factor does

1. Holds WETH in a funding account, deposited in an Aave ERC-4626 vault.
2. Signs price quotes offchain. There is no oracle for a withdrawal claim; the factor sets the price.
3. Never sends the settlement transaction. The seller does, so the factor's key stays offline.
4. Collects the eventual payout when the queue finalizes — impairment risk stays with the factor.

## Pricing

For a claim worth 2.6 ETH finalizing in about 5 days:

```
funding cost    10% APR × 5 days    ≈ 0.0018 ETH
risk margin     0.15%               ≈ 0.0039 ETH
collection gas                      ≈ 0.003  ETH
                                     ────────────
quote                               ~2.59 ETH
redeemed in ~5 days                  2.60 ETH
factor's return                     ~0.01 ETH
```

Funding rate, risk margin, and gas are explicit configuration values, not illustrations.

## What the discount pays for

- Duration: the queue can take 13 days instead of 5, and capital is locked meanwhile.
- Impairment: the claim can settle below face value.
- Protocol risk: the withdrawal queue can pause.
- Opportunity cost: the capital could be deployed elsewhere.

The seller transfers all of these risks to the factor.

## Why the funding account earns yield

Factoring demand is episodic stress liquidity: in externally produced sample data (reported, not reproduced in this repository — see [`docs/V2_ECONOMICS.md`](https://github.com/zkoranges/intentional/blob/main/docs/V2_ECONOMICS.md)), opportunities clustered on a minority of days and the factor sat idle most of the time. Keeping the reserve in an ERC-4626 vault means the same capital earns lending yield on idle days and the factoring spread when a deal appears. Without that yield, holding standby capital would rarely be worth it.

## One factor today

Each deployment binds a single factor address: one funding account, one payment asset, and the administrative controls (pause, adapter allowlist, quote cancellation, withdrawals). The mainnet proof deployment is retired — see [Status](status.md).

The design targets multiple factors competing on the same claim. A withdrawal claim has no reference price; each factor prices from its own cost of capital and its own estimate of queue time, so competitive quoting is how a price forms. This is why settlement is built around signed quotes rather than pool pricing.

---

**Next:** [Architecture →](architecture.md)
