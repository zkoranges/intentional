# Limits

## For liquid assets, use an exchange

We sampled a year of settlement data: 308,160 CoW settlements, 568 comparable stETH→ETH executions, and 42,074 Lido withdrawal requests across 364 finalization batches. Factoring beat the open market on 4.6% of trades and 5.3% of volume.

The rest of the time, a direct stETH sale is the better route: stETH has deep pools, competing market makers, and purpose-built exit products. Factoring applies when there is no market — a claim that is not an ERC-20, a position too large to sell without slippage, or a stressed market where the queue still pays par and the order book does not.

## Not built

- **Competing factors.** One factor, one funding account, one payment asset. Multi-factor bidding is the intended next step.
- **Secondary market.** The factor holds every claim to maturity.
- **Production ERC-8161 vault.** The standard is Final but adoption is early. The ERC-7540/8161 path is proven against a conformant reference vault; the Lido path runs against mainnet contracts.
- **`requestId == 0`.** ERC-7540 allows a vault to aggregate all of a user's requests under ID zero, which cannot identify a specific claim. The adapter rejects it, which excludes some vault designs.

## Risk stays with the factor

The queue can take longer than modelled, the claim can settle below face value, the withdrawal queue can pause, and capital stays locked meanwhile. There is no oracle, insurance, or pooled backstop. Each claim is a separate position; one impaired claim cannot affect another.

## Pricing is explicit policy

Quotes are built from disclosed inputs: funding rate, risk margin, gas. There is no predictive model and no fair-value oracle. A wrong price is the factor's error, not a mechanism failure.

## Deployment status

Unaudited hackathon software. Contracts deploy paused and unfunded; funding and activation are separate steps with read-only verification between them.

---

[← Back to start](README.md)
