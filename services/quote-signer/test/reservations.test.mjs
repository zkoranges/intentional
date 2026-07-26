// Reservation store semantics: durable single-flight with fill-release.
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ReservationStore } from "../reservations.mjs";

function tempDbPath() {
  const dir = mkdtempSync(join(tmpdir(), "quote-reservations-"));
  return { dir, path: join(dir, "quote-reservations.sqlite") };
}

const NOW = 1_800_000_000n;
const RESERVATION = {
  nonce: 123456789012345678901234567890n,
  seller: "0x528C4E1d59fD4b187461BE9c61C668928C3cf9c3",
  mode: "existing-unsteth",
  requestId: 130880n,
  claimAmountWei: 5000000000000000n,
  paymentWei: 4987500000000000n,
  envelope: {
    version: "reservoir-v2-lido-1",
    mode: "existing-unsteth",
    quote: {
      nonce: "123456789012345678901234567890",
      paymentAmount: "4987500000000000",
    },
    factorSignature: "0x1234",
  },
  deadlineUnix: NOW + 120n,
  nowUnix: NOW,
};

test("a reservation survives a restart (reopen the same database file)", (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const first = new ReservationStore(path);
  first.reserve(RESERVATION);
  assert.equal(first.active(NOW).length, 1);
  first.close(); // the "restart": the process forgets, the file must not

  const second = new ReservationStore(path);
  const active = second.active(NOW);
  assert.equal(active.length, 1);
  assert.equal(active[0].nonce, RESERVATION.nonce);
  assert.equal(active[0].seller, RESERVATION.seller);
  assert.equal(active[0].mode, RESERVATION.mode);
  assert.equal(active[0].requestId, RESERVATION.requestId);
  assert.equal(active[0].claimAmountWei, RESERVATION.claimAmountWei);
  assert.equal(active[0].paymentWei, RESERVATION.paymentWei);
  assert.deepEqual(active[0].envelope, RESERVATION.envelope);
  second.close();
});

test("an identical request recovers the durable signed envelope", (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const store = new ReservationStore(path);
  t.after(() => store.close());
  store.reserve(RESERVATION);

  assert.deepEqual(
    store.recover({
      nowUnix: NOW,
      seller: RESERVATION.seller,
      mode: RESERVATION.mode,
      requestId: RESERVATION.requestId,
      claimAmountWei: null,
    }),
    RESERVATION.envelope,
  );
  assert.equal(
    store.recover({
      nowUnix: NOW,
      seller: RESERVATION.seller,
      mode: RESERVATION.mode,
      requestId: RESERVATION.requestId + 1n,
      claimAmountWei: null,
    }),
    null,
    "a different claim must remain blocked by single-flight",
  );
});

test("a deliberate requote replaces the envelope but preserves the nonce", (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const first = new ReservationStore(path);
  first.reserve(RESERVATION);
  const replacement = {
    ...RESERVATION,
    requestId: 130881n,
    claimAmountWei: 4_000_000_000_000_000n,
    paymentWei: 3_990_000_000_000_000n,
    envelope: {
      ...RESERVATION.envelope,
      quote: {
        nonce: RESERVATION.nonce.toString(),
        paymentAmount: "3990000000000000",
      },
      factorSignature: "0x5678",
    },
    deadlineUnix: NOW + 600n,
    nowUnix: NOW + 3n,
  };

  assert.equal(first.replace(replacement), true);
  assert.equal(first.active(NOW + 3n).length, 1, "replacement does not reserve twice");
  first.close();

  const restarted = new ReservationStore(path);
  t.after(() => restarted.close());
  const active = restarted.active(NOW + 3n);
  assert.equal(active.length, 1);
  assert.equal(active[0].nonce, RESERVATION.nonce, "the onchain mutual-exclusion nonce is stable");
  assert.equal(active[0].requestId, replacement.requestId);
  assert.equal(active[0].paymentWei, replacement.paymentWei);
  assert.equal(active[0].deadlineUnix, replacement.deadlineUnix);
  assert.deepEqual(active[0].envelope, replacement.envelope);
});

test("requote replacement requires the active nonce and the same seller", (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const store = new ReservationStore(path);
  t.after(() => store.close());
  store.reserve(RESERVATION);

  assert.equal(store.replace({ ...RESERVATION, nonce: RESERVATION.nonce + 1n }), false);
  assert.equal(
    store.replace({
      ...RESERVATION,
      seller: "0xC0E4928B05b795E1F9349b25944986A61C8F12A0",
    }),
    false,
  );
  assert.deepEqual(store.active(NOW)[0].envelope, RESERVATION.envelope);
});

test("an active reservation blocks a second quote (the 409 condition)", async (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const store = new ReservationStore(path);
  t.after(() => store.close());
  store.reserve(RESERVATION);

  // The nonce has NOT been consumed on chain — the reservation must hold.
  const swept = await store.sweep({ nowUnix: NOW, isNonceConsumed: async () => false });
  assert.equal(swept.released.length, 0);
  assert.equal(swept.active.length, 1, "server maps a non-empty active set to HTTP 409");
});

test("a reservation whose nonce the kernel reports consumed is released", async (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const store = new ReservationStore(path);
  t.after(() => store.close());
  store.reserve(RESERVATION);

  const asked = [];
  const swept = await store.sweep({
    nowUnix: NOW,
    isNonceConsumed: async (nonce) => {
      asked.push(nonce);
      return true; // the fill landed on chain
    },
  });
  assert.deepEqual(asked, [RESERVATION.nonce], "the kernel is asked about the reserved nonce");
  assert.equal(swept.released.length, 1);
  assert.equal(swept.released[0].reason, "consumed-on-chain");
  assert.equal(swept.released[0].nonce, RESERVATION.nonce);
  assert.equal(swept.active.length, 0, "a filled quote no longer blocks new quotes");

  // Idempotent: a second sweep releases nothing and asks nothing.
  const again = await store.sweep({
    nowUnix: NOW,
    isNonceConsumed: async () => {
      throw new Error("must not be asked about released reservations");
    },
  });
  assert.equal(again.released.length, 0);
  assert.equal(again.active.length, 0);
});

test("an expired reservation falls away without a chain read", async (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const store = new ReservationStore(path);
  t.after(() => store.close());
  store.reserve(RESERVATION);

  const afterDeadline = RESERVATION.deadlineUnix + 1n;
  assert.equal(store.active(afterDeadline).length, 0, "expired rows never count as active");

  const swept = await store.sweep({
    nowUnix: afterDeadline,
    isNonceConsumed: async () => {
      throw new Error("expired reservations must not trigger chain reads");
    },
  });
  assert.equal(swept.released.length, 1);
  assert.equal(swept.released[0].reason, "expired");
  assert.equal(swept.active.length, 0);

  const fresh = {
    ...RESERVATION,
    nonce: RESERVATION.nonce + 1n,
    deadlineUnix: afterDeadline + 120n,
    nowUnix: afterDeadline,
  };
  store.reserve(fresh);
  assert.equal(store.active(afterDeadline).length, 1, "expiration admits an independent fresh quote");
  assert.equal(store.active(afterDeadline)[0].nonce, fresh.nonce);
});

test("reserving the same nonce twice throws (primary key)", (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const store = new ReservationStore(path);
  t.after(() => store.close());
  store.reserve(RESERVATION);
  assert.throws(() => store.reserve(RESERVATION));
});

test("two store connections cannot create two open reservations", (t) => {
  const { dir, path } = tempDbPath();
  t.after(() => rmSync(dir, { recursive: true, force: true }));

  const first = new ReservationStore(path);
  const second = new ReservationStore(path);
  t.after(() => first.close());
  t.after(() => second.close());

  first.reserve(RESERVATION);
  assert.throws(
    () =>
      second.reserve({
        ...RESERVATION,
        nonce: RESERVATION.nonce + 1n,
      }),
    /UNIQUE constraint failed/,
    "the SQLite constraint backs up the in-process serial executor",
  );
  assert.equal(first.active(NOW).length, 1);
});
