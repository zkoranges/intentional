# Honest limits

Things that are easy to overclaim. We measured instead.

## Selling stETH? Use a normal exchange

We sampled a year of real settlement data — 308,160 CoW settlements, 568 comparable stETH→ETH executions, 42,074 Lido requests across 364 finalization batches.

**Factoring beat the open market on 4.6% of trades, and 5.3% of volume.**

The other ~95% of the time, a normal stETH sale is the better route.

That is not a bug in the design. stETH is the most liquid staking asset that exists — deep pools, competing market makers, purpose-built exit products. Nobody should route around that.

**Factoring earns its keep when there is no market:** a claim that is not an ERC-20, a position too large to sell without slippage, or a stressed market where the queue still pays par and the order book does not.

## What is not built

- **No competing factors yet.** One factor, one funding account, one payment asset. Multi-factor bidding is the natural next step, not a shipped feature.
- **No secondary market.** A factor holds to maturity. There is no exit before the queue finalizes.
- **No production ERC-8161 vault.** The standard is Final, but adoption is early. The ERC-7540/8161 path is proven against a **conformant reference vault**, not a live deployment. The Lido path is real.
- **`requestId == 0` is rejected.** ERC-7540 lets a vault lump all of a user's requests under ID zero, which cannot identify a specific claim. We refuse it rather than guess — and that does exclude some vault designs.

## Risks the factor accepts

Buying a claim means buying its problems:

- The queue takes longer than modelled.
- The claim settles below face value.
- The withdrawal queue pauses.
- Capital is locked for an unpredictable period.

No oracle, no insurance, no pooled backstop. **Each claim stands alone** — nothing is socialized between positions, so one bad claim cannot reach into another.

## Pricing is not automated

The factor's quote is a signed offer using explicit, disclosed policy inputs: funding rate, risk margin, gas. There is no predictive model and no fair-value oracle.

If the price is wrong, it is wrong because the factor priced it wrong — not because a mechanism failed.

## Deployment status

This is hackathon work. Contracts deploy **paused and unfunded**; funding and activation are separate, deliberate steps with read-only verification between each. Nothing has been audited.

---

[← Back to start](README.md)
