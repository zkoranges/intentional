# Limits

## For liquid assets, use an exchange

An externally produced sample suggested that economically attractive factoring
opportunities were episodic rather than continuous. The raw dataset and
analysis pipeline are not in this repository, so the public product does not
present those reported figures as reproduced evidence. The appendix in
[`docs/V2_ECONOMICS.md`](https://github.com/zkoranges/reservoir-v2-eth-lisbon/blob/main/docs/V2_ECONOMICS.md)
records the assumptions and reported results with that limitation.

For liquid stETH, a direct market sale will often be the better route because
stETH has deep pools, competing market makers, and purpose-built exit products.
Factoring is aimed at a different object: a claim that is not an ERC-20, a
position too large to sell without slippage, or stressed conditions where the
factor is willing to accept queue timing and impairment risk.

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

Unaudited hackathon software. The mainnet proof deployment is retired: both
pausable contracts are paused and its reserve was recovered. A future
deployment must use a fresh signer and starts paused and unfunded; funding and
activation remain separate, human-authorized steps with read-only verification
between them.

---

[← Back to start](README.md)
