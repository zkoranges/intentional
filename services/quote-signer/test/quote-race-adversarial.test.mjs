// Adversarial regression coverage for the production quote reservation
// primitives. These tests deliberately use the real SQLite ReservationStore
// and SerialExecutor; no HTTP, chain, or database mocks are involved.
//
// Important boundary: a wallet rejecting an approval/fill prompt is not
// observable by the signer. The signed quote remains executable until its
// deadline (or until its nonce is consumed). Therefore "requote" for the exact
// same economic request must recover the existing envelope. A new nonce is
// only safe after expiry/consumption, or after onchain invalidation.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ReservationStore } from "../reservations.mjs";
import { SerialExecutor } from "../serial-executor.mjs";

const NOW = 1_800_000_000n;
const SELLER_A = "0x528C4E1d59fD4b187461BE9c61C668928C3cf9c3";
const SELLER_B = "0x894E65c06722162A98bd7ed2A2aBDe1Aa6F1fc99";

function tempStore(t) {
  const dir = mkdtempSync(join(tmpdir(), "quote-race-adversarial-"));
  const path = join(dir, "reservations.sqlite");
  const store = new ReservationStore(path);
  t.after(() => {
    store.close();
    rmSync(dir, { recursive: true, force: true });
  });
  return { store, path };
}

function reservation(overrides = {}) {
  const nonce = overrides.nonce ?? 101n;
  const seller = overrides.seller ?? SELLER_A;
  const mode = overrides.mode ?? "originate";
  const requestId =
    overrides.requestId === undefined
      ? mode === "existing-unsteth"
        ? 130880n
        : null
      : overrides.requestId;
  const claimAmountWei = overrides.claimAmountWei ?? 1_000_000_000_000_000n;
  const paymentWei = overrides.paymentWei ?? 997_500_000_000_000n;
  const deadlineUnix = overrides.deadlineUnix ?? NOW + 600n;
  return {
    nonce,
    seller,
    mode,
    requestId,
    claimAmountWei,
    paymentWei,
    envelope: {
      version: "reservoir-v2-lido-1",
      mode,
      quote: {
        seller,
        nonce: nonce.toString(),
        deadline: deadlineUnix.toString(),
        paymentAmount: paymentWei.toString(),
      },
      factorSignature: `0x${nonce.toString(16).padStart(2, "0")}`,
    },
    deadlineUnix,
    nowUnix: NOW,
  };
}

function recover(store, request, nowUnix = NOW) {
  return store.recover({
    nowUnix,
    seller: request.seller,
    mode: request.mode,
    requestId: request.requestId,
    claimAmountWei: request.mode === "originate" ? request.claimAmountWei : null,
  });
}

test("double-click serialization returns one durable quote, never two live nonces", async (t) => {
  const { store } = tempStore(t);
  const executor = new SerialExecutor();
  const request = reservation();
  let signatures = 0;

  async function issueOrRecover() {
    return executor.run(async () => {
      const recovered = recover(store, request);
      if (recovered) return recovered;

      signatures += 1;
      store.reserve(request);
      return request.envelope;
    });
  }

  const [first, second] = await Promise.all([issueOrRecover(), issueOrRecover()]);
  assert.equal(signatures, 1, "only one EIP-712 envelope may be signed");
  assert.deepEqual(second, first, "the second click recovers the first response");
  assert.equal(store.active(NOW).length, 1);
});

test("a delayed first caller and queued identical retry still share one nonce", async (t) => {
  const { store } = tempStore(t);
  const executor = new SerialExecutor();
  const request = reservation();
  let releaseFirst;
  const firstMayReserve = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  let signatures = 0;

  const first = executor.run(async () => {
    await firstMayReserve;
    signatures += 1;
    store.reserve(request);
    return request.envelope;
  });
  const second = executor.run(async () => {
    const recovered = recover(store, request);
    assert.ok(recovered, "queued retry must observe the durable reservation");
    return recovered;
  });

  releaseFirst();
  const [firstEnvelope, secondEnvelope] = await Promise.all([first, second]);
  assert.equal(signatures, 1);
  assert.deepEqual(secondEnvelope, firstEnvelope);
});

test("wallet rejection leaves the quote recoverable because it remains executable", (t) => {
  const { store } = tempStore(t);
  const request = reservation();
  store.reserve(request);

  // There is intentionally no `walletRejected` release reason. A rejected
  // wallet prompt does not invalidate the factor signature onchain.
  const afterWalletRejected = recover(store, request);
  assert.deepEqual(afterWalletRejected, request.envelope);
  assert.equal(store.active(NOW).length, 1);
});

test("amount, asset, claim, and account switches cannot recover an unrelated envelope", (t) => {
  const { store } = tempStore(t);
  const original = reservation();
  store.reserve(original);

  const changedAmount = reservation({ claimAmountWei: original.claimAmountWei + 1n });
  const changedMode = reservation({
    mode: "existing-unsteth",
    requestId: 130880n,
    claimAmountWei: original.claimAmountWei,
  });
  const changedAccount = reservation({ seller: SELLER_B });

  assert.equal(recover(store, changedAmount), null);
  assert.equal(recover(store, changedMode), null);
  assert.equal(recover(store, changedAccount), null);
  assert.deepEqual(recover(store, original), original.envelope);
});

test("expired quote is released before a fresh quote is reserved", async (t) => {
  const { store } = tempStore(t);
  const expired = reservation({ deadlineUnix: NOW + 10n });
  store.reserve(expired);

  const nextBlockTime = NOW + 11n;
  const swept = await store.sweep({
    nowUnix: nextBlockTime,
    isNonceConsumed: async () => {
      throw new Error("expired nonces must not require an RPC read");
    },
  });
  assert.deepEqual(swept.released, [{ nonce: expired.nonce, reason: "expired" }]);

  const fresh = reservation({
    nonce: 102n,
    deadlineUnix: nextBlockTime + 600n,
    nowUnix: nextBlockTime,
  });
  store.reserve(fresh);
  assert.deepEqual(recover(store, fresh, nextBlockTime), fresh.envelope);
});

test("consumed nonce is released before a fresh quote is reserved", async (t) => {
  const { store } = tempStore(t);
  const filled = reservation();
  store.reserve(filled);

  const swept = await store.sweep({
    nowUnix: NOW + 1n,
    isNonceConsumed: async (nonce) => nonce === filled.nonce,
  });
  assert.deepEqual(swept.released, [
    { nonce: filled.nonce, reason: "consumed-on-chain" },
  ]);

  const fresh = reservation({ nonce: 102n, nowUnix: NOW + 1n });
  store.reserve(fresh);
  assert.deepEqual(recover(store, fresh, NOW + 1n), fresh.envelope);
});

test("reservation survives signer restart and identical retry recovers its envelope", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "quote-race-restart-"));
  const path = join(dir, "reservations.sqlite");
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const request = reservation();

  const beforeRestart = new ReservationStore(path);
  beforeRestart.reserve(request);
  beforeRestart.close();

  const afterRestart = new ReservationStore(path);
  t.after(() => afterRestart.close());
  assert.deepEqual(recover(afterRestart, request), request.envelope);
});

test("the store exposes every active payment needed for aggregate capacity accounting", (t) => {
  const { store } = tempStore(t);
  const first = reservation({
    nonce: 101n,
    seller: SELLER_A,
    paymentWei: 2_000n,
  });
  const second = reservation({
    nonce: 102n,
    seller: SELLER_B,
    paymentWei: 3_000n,
  });
  store.reserve(first);
  store.reserve(second);

  const committed = store
    .active(NOW)
    .reduce((sum, active) => sum + active.paymentWei, 0n);
  assert.equal(committed, 5_000n);

  const onchainCapacity = 6_000n;
  const safeRemaining = onchainCapacity - committed;
  assert.equal(safeRemaining, 1_000n);
  assert.equal(1_001n <= safeRemaining, false, "oversubscribed quote must be refused");
  assert.equal(1_000n <= safeRemaining, true, "a second user may use remaining capacity");
});
