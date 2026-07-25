// Readiness derivation and the /health payload shape.
import test from "node:test";
import assert from "node:assert/strict";

import { buildHealthPayload, deriveReadiness } from "../health.mjs";

const CONFIG = {
  expectedChainId: 1,
  kernel: "0x1111111111111111111111111111111111111111",
  lidoAdapter: "0x2222222222222222222222222222222222222222",
  lidoUnstETHAdapter: "0x4444444444444444444444444444444444444444",
  weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  stETH: "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
  queue: "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
  manifestPath: "/etc/reservoir/manifest.json",
  factorAddress: "0x894E65c06722162A98bd7ed2A2aBDe1Aa6F1fc99",
  spreadBps: 25n,
  minQuoteWei: 1000000000000000n,
  maxQuoteWei: 6000000000000000n,
  maxPaymentWei: 5985000000000000n,
  quoteTtlSeconds: 120n,
};

const READY_SNAPSHOT = {
  fetchedAtUnix: 1_800_000_000,
  fetchedAtMs: 1_800_000_000_000,
  error: false,
  observedChainId: 1,
  factorSignerMatches: true,
  fundingAccount: "0xB87F5CE2b24439B6A74B1DfEf9311dd527087a37",
  originationAdapterAllowed: true,
  unstETHAdapterAllowed: true,
  kernelSealed: true,
  kernelPaused: false,
  paymentAssetOk: true,
  fundingSealed: true,
  capacityWei: 5985000000000000n,
  queuePaused: false,
  bunkerMode: false,
};

test("readiness: config refusals dominate everything else", () => {
  const readiness = deriveReadiness({
    refusals: ["deployment manifest releaseState is \"retired-paused\""],
    snapshot: READY_SNAPSHOT,
    expectedChainId: 1,
  });
  assert.equal(readiness.state, "refused");
  assert.match(readiness.reasons[0], /retired-paused/);
});

test("readiness: pending before the first chain read, error after a failed one", () => {
  assert.equal(deriveReadiness({ refusals: [], snapshot: null, expectedChainId: 1 }).state, "pending");
  assert.equal(
    deriveReadiness({ refusals: [], snapshot: { error: true }, expectedChainId: 1 }).state,
    "error",
  );
});

test("readiness: paused settlement is a first-class state", () => {
  const readiness = deriveReadiness({
    refusals: [],
    snapshot: { ...READY_SNAPSHOT, kernelPaused: true },
    expectedChainId: 1,
  });
  assert.equal(readiness.state, "paused");
  assert.match(readiness.reasons[0], /paused/);
});

test("readiness: chain-id or signer mismatch refuses at runtime too", () => {
  assert.equal(
    deriveReadiness({
      refusals: [],
      snapshot: { ...READY_SNAPSHOT, observedChainId: 31337 },
      expectedChainId: 1,
    }).state,
    "refused",
  );
  assert.equal(
    deriveReadiness({
      refusals: [],
      snapshot: { ...READY_SNAPSHOT, factorSignerMatches: false },
      expectedChainId: 1,
    }).state,
    "refused",
  );
});

test("readiness: live preconditions gate as not-ready", () => {
  for (const patch of [
    { kernelSealed: false },
    { originationAdapterAllowed: false },
    { unstETHAdapterAllowed: false },
    { fundingSealed: false },
    { paymentAssetOk: false },
    { queuePaused: true },
    { bunkerMode: true },
    { capacityWei: 0n },
  ]) {
    const readiness = deriveReadiness({
      refusals: [],
      snapshot: { ...READY_SNAPSHOT, ...patch },
      expectedChainId: 1,
    });
    assert.equal(readiness.state, "not-ready", Object.keys(patch).join(","));
    assert.ok(readiness.reasons.length > 0);
  }
});

test("readiness: everything green is ready", () => {
  const readiness = deriveReadiness({ refusals: [], snapshot: READY_SNAPSHOT, expectedChainId: 1 });
  assert.equal(readiness.state, "ready");
  assert.deepEqual(readiness.reasons, []);
});

test("/health payload shape: chain id, addresses, pause state, capacity, readiness", () => {
  const payload = buildHealthPayload({
    config: CONFIG,
    refusals: [],
    snapshot: READY_SNAPSHOT,
    activeReservations: 1,
  });

  assert.equal(payload.ok, true);
  assert.equal(payload.readiness.state, "ready");
  assert.equal(payload.chain.expectedChainId, 1);
  assert.equal(payload.chain.observedChainId, 1);
  assert.equal(payload.contracts.kernel, CONFIG.kernel);
  assert.equal(payload.contracts.lidoAdapter, CONFIG.lidoAdapter);
  assert.equal(payload.contracts.lidoUnstETHAdapter, CONFIG.lidoUnstETHAdapter);
  assert.equal(payload.contracts.fundingAccount, READY_SNAPSHOT.fundingAccount);
  assert.equal(payload.settlement.kernelPaused, false);
  assert.equal(payload.settlement.lidoQueuePaused, false);
  assert.equal(payload.capacity.availableWei, READY_SNAPSHOT.capacityWei);
  assert.equal(payload.capacity.coversMaxQuote, true);
  assert.equal(payload.reservations.active, 1);
  assert.equal(payload.outstanding, true, "legacy field preserved");
  assert.equal(payload.kernel, CONFIG.kernel, "legacy field preserved");

  // The fixed policy is never presented as a market price.
  assert.match(payload.pricing.basis, /not a market/);
  assert.equal(payload.pricing.mode, "operator-priced-firm-quote");
});

test("/health payload before the first chain read is honest about it", () => {
  const payload = buildHealthPayload({
    config: CONFIG,
    refusals: [],
    snapshot: null,
    activeReservations: 0,
  });
  assert.equal(payload.ok, false);
  assert.equal(payload.readiness.state, "pending");
  assert.equal(payload.chain.observedChainId, null);
  assert.equal(payload.capacity.availableWei, null);
  assert.equal(payload.outstanding, false);
});
