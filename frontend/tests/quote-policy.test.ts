import assert from "node:assert/strict";
import test from "node:test";

import { underwriteLidoExit } from "../lib/quote-policy.ts";

const policy = {
  fundingAprBps: 1_000,
  riskBps: 15,
  userEdgeShareBps: 5_000,
  claimGasUnits: 120_000,
};

test("Reservoir is offered only when its measured underwriting cap beats the live market", () => {
  const quote = underwriteLidoExit({
    requestedStEth: 1_000_000_000_000_000_000n,
    cowBuyAmount: 990_000_000_000_000_000n,
    estimatedWaitMs: 3n * 24n * 60n * 60n * 1_000n,
    gasPriceWei: 1_000_000_000n,
    policy,
  });

  assert.equal(quote.reservoirAvailable, true);
  assert.ok(quote.reservoirPaymentAmount);
  assert.ok(quote.reservoirPaymentAmount > 990_000_000_000_000_000n);
  assert.ok(quote.reservoirPaymentAmount <= quote.underwritingCap);
  assert.equal(
    quote.reservoirPaymentAmount - 990_000_000_000_000_000n,
    quote.userImprovement,
  );
});

test("the live market wins when it is already above the underwriting cap", () => {
  const quote = underwriteLidoExit({
    requestedStEth: 1_000_000_000_000_000_000n,
    cowBuyAmount: 999_000_000_000_000_000n,
    estimatedWaitMs: 7n * 24n * 60n * 60n * 1_000n,
    gasPriceWei: 2_000_000_000n,
    policy,
  });

  assert.equal(quote.reservoirAvailable, false);
  assert.equal(quote.reservoirPaymentAmount, null);
  assert.equal(quote.userImprovement, 0n);
  assert.ok(quote.underwritingCap < 999_000_000_000_000_000n);
});

test("invalid policy and market inputs fail closed", () => {
  assert.throws(
    () =>
      underwriteLidoExit({
        requestedStEth: 1n,
        cowBuyAmount: 1n,
        estimatedWaitMs: 0n,
        gasPriceWei: 1n,
        policy: { ...policy, riskBps: 10_001 },
      }),
    /risk charge must be between/,
  );
  assert.throws(
    () =>
      underwriteLidoExit({
        requestedStEth: 0n,
        cowBuyAmount: 1n,
        estimatedWaitMs: 0n,
        gasPriceWei: 1n,
        policy,
      }),
    /invalid live quote inputs/,
  );
});
