// Persistent quote reservations — the single-flight guard, made restart-proof.
//
// The desk hands out at most one outstanding unexpired quote at a time so that
// concurrent requests can never oversubscribe the reserve. The original
// implementation kept that reservation in process memory, which had two audit
// findings:
//   1. a restart forgot the outstanding quote, so two valid-looking quotes
//      could be live at once;
//   2. a FILLED quote kept blocking new quotes until its TTL expired, because
//      nothing released the reservation when the kernel consumed the nonce.
//
// This store fixes both: reservations are rows in a small SQLite database
// (node:sqlite, WAL mode) keyed by the quote nonce, and `sweep()` releases any
// reservation whose nonce the kernel reports consumed on-chain — the caller
// supplies the `nonceUsed` read the service already knows how to make.
//
// Nothing in this file touches secrets: rows hold only public quote metadata
// (nonce, seller, amounts, deadline) that already appears in the audit log.

import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS reservations (
  nonce               TEXT PRIMARY KEY,
  seller              TEXT NOT NULL,
  mode                TEXT NOT NULL DEFAULT 'originate',
  request_id          TEXT,
  requested_steth_wei TEXT NOT NULL,
  payment_wei         TEXT NOT NULL,
  envelope_json       TEXT,
  deadline_unix       INTEGER NOT NULL,
  created_unix        INTEGER NOT NULL,
  released_unix       INTEGER,
  release_reason      TEXT
) STRICT;
CREATE INDEX IF NOT EXISTS idx_reservations_open
  ON reservations (deadline_unix) WHERE released_unix IS NULL;
`;

function toRow(record) {
  return {
    nonce: BigInt(record.nonce),
    seller: record.seller,
    mode: record.mode,
    requestId: record.request_id === null ? null : BigInt(record.request_id),
    claimAmountWei: BigInt(record.requested_steth_wei),
    paymentWei: BigInt(record.payment_wei),
    envelope: record.envelope_json === null ? null : JSON.parse(record.envelope_json),
    deadlineUnix: BigInt(record.deadline_unix),
    createdUnix: BigInt(record.created_unix),
  };
}

export class ReservationStore {
  #db;

  constructor(path) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.#db = new DatabaseSync(path);
    // WAL + FULL: a signed quote must never outlive the desk's memory of it.
    this.#db.exec("PRAGMA journal_mode = WAL;");
    this.#db.exec("PRAGMA synchronous = FULL;");
    this.#db.exec(SCHEMA);
    const columns = new Set(
      this.#db.prepare("PRAGMA table_info(reservations)").all().map((column) => column.name),
    );
    if (!columns.has("mode")) {
      this.#db.exec("ALTER TABLE reservations ADD COLUMN mode TEXT NOT NULL DEFAULT 'originate';");
    }
    if (!columns.has("request_id")) {
      this.#db.exec("ALTER TABLE reservations ADD COLUMN request_id TEXT;");
    }
    if (!columns.has("envelope_json")) {
      this.#db.exec("ALTER TABLE reservations ADD COLUMN envelope_json TEXT;");
    }
  }

  /** Open, unexpired reservations — the ones that block a new quote. */
  active(nowUnix) {
    const rows = this.#db
      .prepare(
        "SELECT * FROM reservations WHERE released_unix IS NULL AND deadline_unix > ? ORDER BY deadline_unix",
      )
      .all(Number(nowUnix));
    return rows.map(toRow);
  }

  /**
   * Return the durable signed response for an identical active request.
   * Different requests remain blocked by the global single-flight guard.
   */
  recover({ nowUnix, seller, mode, requestId, claimAmountWei }) {
    const active = this.active(nowUnix);
    if (active.length !== 1) return null;
    const reservation = active[0];
    const sameClaim =
      mode === "existing-unsteth"
        ? reservation.requestId === requestId
        : reservation.requestId === null &&
          reservation.claimAmountWei === claimAmountWei;
    return reservation.envelope !== null &&
      reservation.seller === seller &&
      reservation.mode === mode &&
      sameClaim
      ? reservation.envelope
      : null;
  }

  /** Record a freshly signed quote. Throws on nonce collision (primary key). */
  reserve({
    nonce,
    seller,
    mode,
    requestId,
    claimAmountWei,
    paymentWei,
    envelope,
    deadlineUnix,
    nowUnix,
  }) {
    this.#db
      .prepare(
        `INSERT INTO reservations
           (nonce, seller, mode, request_id, requested_steth_wei, payment_wei, envelope_json, deadline_unix, created_unix)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        nonce.toString(),
        seller,
        mode,
        requestId === null ? null : requestId.toString(),
        claimAmountWei.toString(),
        paymentWei.toString(),
        envelope === undefined
          ? null
          : JSON.stringify(envelope, (_, value) =>
              typeof value === "bigint" ? value.toString() : value,
            ),
        Number(deadlineUnix),
        Number(nowUnix),
      );
  }

  /** Mark a reservation released. Returns true if a row changed. */
  release(nonce, reason, nowUnix) {
    const result = this.#db
      .prepare(
        "UPDATE reservations SET released_unix = ?, release_reason = ? WHERE nonce = ? AND released_unix IS NULL",
      )
      .run(Number(nowUnix), reason, nonce.toString());
    return result.changes > 0;
  }

  /**
   * Release reservations that no longer block quoting, then report the rest.
   *   - expired reservations (deadline passed) are released as "expired";
   *   - reservations whose nonce the kernel reports consumed are released as
   *     "consumed-on-chain" (the fill went through — the capacity it guarded
   *     is spent, not reserved).
   * `isNonceConsumed(nonce) -> Promise<boolean>` is the kernel `nonceUsed`
   * read, injected so this module stays chain-agnostic and testable.
   * Returns { released: [{nonce, reason}], active: [rows still blocking] }.
   */
  async sweep({ nowUnix, isNonceConsumed }) {
    const released = [];

    const expired = this.#db
      .prepare(
        "SELECT nonce FROM reservations WHERE released_unix IS NULL AND deadline_unix <= ?",
      )
      .all(Number(nowUnix));
    for (const { nonce } of expired) {
      if (this.release(BigInt(nonce), "expired", nowUnix)) {
        released.push({ nonce: BigInt(nonce), reason: "expired" });
      }
    }

    for (const row of this.active(nowUnix)) {
      if (await isNonceConsumed(row.nonce)) {
        if (this.release(row.nonce, "consumed-on-chain", nowUnix)) {
          released.push({ nonce: row.nonce, reason: "consumed-on-chain" });
        }
      }
    }

    return { released, active: this.active(nowUnix) };
  }

  close() {
    this.#db.close();
  }
}
