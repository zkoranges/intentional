# Reservoir v2 — economic calibration

> These figures were supplied from a separate workspace. They have not been
> reproduced from raw data in this repository and are presented as reported,
> not as an audited forecast.

## Reported sample

- 20% systematic time sample across July 2025–July 2026
- 308,160 CoW settlement events
- 568 comparable direct stETH-to-WETH/ETH executions
- 54,806 ETH of sampled sell volume
- 42,074 Lido requests mapped to 364 finalization batches
- actual Lido wait: 2.05-day median and 13.0-day p90

Under a model using 10% annual capital cost, 15 bps risk/margin, and 0.003 ETH
gas:

| Result | Reported value |
|---|---:|
| Comparable trades where factoring beats CoW | 4.6% |
| Comparable volume where factoring beats CoW | 5.3% |
| Active sampled days containing opportunities | 15 of 87 |
| Rough Lido-only factorable volume extrapolation | 14,500 ETH/year |
| Rough modeled edge above CoW before imperfect capture | 26 ETH/year |

## What Reservoir claims

The robust conclusion is qualitative:

> Lido claim factoring is episodic stress liquidity, not an always-on
> competitor to CoW.

Reservoir's ERC-4626 reserve improves the economics of **standing ready** for
those clustered opportunities. It does not reduce the factor's funding cost,
queue duration, slashing risk, or impairment after payment has been made and
the factor owns the claim.

## What Reservoir does not claim

The precise extrapolation is sensitive to:

- the assumed annual funding rate;
- fixed gas relative to ticket size;
- selection bias in revealed CoW flow;
- unobserved users who chose the Lido queue rather than a market sale;
- route and execution-quality methodology; and
- perfect-opportunity-capture assumptions.

The demo therefore does not hard-code a profitability promise. Its economic
inputs are explicit, and a normal stETH market sale is allowed to be the better
route.
