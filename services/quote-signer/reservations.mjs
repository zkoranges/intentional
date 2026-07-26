// Persistent quote reservations — aggregate capacity accounting, restart-proof.
//
// The desk can hand independent users simultaneous quotes only while their
// aggregate payment liability fits the productive reserve. The original
// implementation kept one global reservation in process memory, which had
// three audit findings:
//   1. a restart forgot the outstanding quote, so two valid-looking quotes
//      could be live at once;
//   2. a FILLED quote kept blocking new quotes until its TTL expired, because
//      nothing released the reservation when the kernel consumed the nonce.
//   3. one user globally blocked every other wallet, even when spare reserve
//      capacity existed.
//
// This store fixes all three: reservations are rows in a small SQLite database
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
DROP INDEX IF EXISTS idx_reservations_single_open;
CREATE TABLE IF NOT EXISTS reservation_state (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  version   INTEGER NOT NULL
) STRICT;
INSERT OR IGNORE INTO reservation_state (singleton, version) VALUES (1, 0);
`;

const MAX_UINT256 = (1n << 256n) - 1n;

export function maximumLiabilityWei(previousPaymentWei, nextPaymentWei) {
  return previousPaymentWei !== null &&
    previousPaymentWei > nextPaymentWei
    ? previousPaymentWei
    : nextPaymentWei;
}

function envelopeJson(envelope) {
  return envelope === undefined
    ? null
    : JSON.stringify(envelope, (_, value) =>
        typeof value === "bigint" ? value.toString() : value,
      );
}

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
    this.#db.exec("PRAGMA busy_timeout = 5000;");
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

  /** Open, unexpired reservations — the aggregate outstanding liability. */
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
   * Other active users do not affect idempotent recovery.
   */
  recover({ nowUnix, seller, mode, requestId, claimAmountWei }) {
    const active = this.active(nowUnix);
    const reservation = active.find((candidate) => {
      const sameClaim =
        mode === "existing-unsteth"
          ? candidate.requestId === requestId
          : candidate.requestId === null &&
            candidate.claimAmountWei === claimAmountWei;
      return candidate.seller === seller && candidate.mode === mode && sameClaim;
    });
    return reservation?.envelope ?? null;
  }

  version() {
    return this.#db
      .prepare("SELECT version FROM reservation_state WHERE singleton = 1")
      .get().version;
  }

  /** True only for a historical nonce already released for this seller. */
  isReleasedForSeller(nonce, seller) {
    const row = this.#db
      .prepare(
        "SELECT released_unix FROM reservations WHERE nonce = ? AND seller = ?",
      )
      .get(nonce.toString(), seller);
    return row !== undefined && row.released_unix !== null;
  }

  #insert({
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
    return this.#db
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
        envelopeJson(envelope),
        Number(deadlineUnix),
        Number(nowUnix),
      );
  }

  #update({
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
    return this.#db
      .prepare(
        `UPDATE reservations
            SET mode = ?,
                request_id = ?,
                requested_steth_wei = ?,
                payment_wei = ?,
                envelope_json = ?,
                deadline_unix = ?,
                created_unix = ?
          WHERE nonce = ? AND seller = ? AND released_unix IS NULL`,
      )
      .run(
        mode,
        requestId === null ? null : requestId.toString(),
        claimAmountWei.toString(),
        paymentWei.toString(),
        envelopeJson(envelope),
        Number(deadlineUnix),
        Number(nowUnix),
        nonce.toString(),
        seller,
      );
  }

  /**
   * Atomically admit a new or replacement reservation at a chain-observed
   * capacity. `expectedVersion` is an optimistic cross-process lock: if
   * another signer process changed the reservation set after the caller's
   * chain reads, this returns `race` and the caller must revalidate.
   *
   * Every envelope sharing a replacement nonce is mutually exclusive onchain,
   * but every one remains fillable until its deadline. The stored liability
   * therefore retains the maximum payment ever signed for that nonce rather
   * than merely tracking the newest envelope.
   */
  reserveWithinCapacity({
    reservation,
    expectedVersion,
    capacityWei,
    nowUnix,
    replaceNonce = null,
  }) {
    this.#db.exec("BEGIN IMMEDIATE;");
    try {
      const currentVersion = this.version();
      if (currentVersion !== expectedVersion) {
        this.#db.exec("ROLLBACK;");
        return { status: "race" };
      }

      const active = this.active(nowUnix);
      const replacement =
        replaceNonce === null
          ? null
          : active.find((row) => row.nonce === replaceNonce) ?? null;
      if (
        replaceNonce !== null &&
        (replacement === null || replacement.seller !== reservation.seller)
      ) {
        this.#db.exec("ROLLBACK;");
        return { status: "replacement-mismatch" };
      }

      const liabilityPaymentWei = maximumLiabilityWei(
        replacement?.paymentWei ?? null,
        reservation.paymentWei,
      );
      const liabilityDeadlineUnix =
        replacement !== null &&
        replacement.deadlineUnix > reservation.deadlineUnix
          ? replacement.deadlineUnix
          : reservation.deadlineUnix;
      const storedReservation =
        replacement === null
          ? reservation
          : {
              ...reservation,
              paymentWei: liabilityPaymentWei,
              deadlineUnix: liabilityDeadlineUnix,
            };
      const activeReservedWei = active.reduce(
        (total, row) =>
          row.nonce === replaceNonce ? total : total + row.paymentWei,
        0n,
      );
      const totalLiabilityWei = activeReservedWei + liabilityPaymentWei;
      if (totalLiabilityWei > capacityWei) {
        this.#db.exec("ROLLBACK;");
        return { status: "capacity", activeReservedWei, totalLiabilityWei };
      }

      if (replacement === null) {
        this.#insert(storedReservation);
      } else if (this.#update(storedReservation).changes !== 1) {
        this.#db.exec("ROLLBACK;");
        return { status: "race" };
      }
      this.#db
        .prepare("UPDATE reservation_state SET version = version + 1 WHERE singleton = 1")
        .run();
      this.#db.exec("COMMIT;");
      return { status: "reserved", activeReservedWei, totalLiabilityWei };
    } catch (error) {
      try {
        this.#db.exec("ROLLBACK;");
      } catch {
        // Preserve the original storage error.
      }
      throw error;
    }
  }

  /** Convenience API used by unit tests and migrations. */
  reserve(reservation) {
    const result = this.reserveWithinCapacity({
      reservation,
      expectedVersion: this.version(),
      capacityWei: MAX_UINT256,
      nowUnix: reservation.nowUnix,
    });
    if (result.status !== "reserved") {
      throw new Error(`reservation failed: ${result.status}`);
    }
  }

  /**
   * Replace an open reservation in place while preserving its nonce.
   *
   * Every envelope ever signed with this nonce is mutually exclusive onchain:
   * the first successful fill consumes the nonce. This lets a seller
   * deliberately refresh or change an abandoned quote without creating two
   * independently fillable claims against the same reserve capacity.
   *
   * The caller must prove knowledge of the current nonce and bind the
   * replacement to the same seller. Returns false if the row is no longer
   * open or either binding does not match.
   */
  replace({
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
    const result = this.reserveWithinCapacity({
      reservation: {
        nonce,
        seller,
        mode,
        requestId,
        claimAmountWei,
        paymentWei,
        envelope,
        deadlineUnix,
        nowUnix,
      },
      expectedVersion: this.version(),
      capacityWei: MAX_UINT256,
      nowUnix,
      replaceNonce: nonce,
    });
    return result.status === "reserved";
  }

  /** Mark a reservation released. Returns true if a row changed. */
  release(nonce, reason, nowUnix) {
    this.#db.exec("BEGIN IMMEDIATE;");
    try {
      const result = this.#db
        .prepare(
          "UPDATE reservations SET released_unix = ?, release_reason = ? WHERE nonce = ? AND released_unix IS NULL",
        )
        .run(Number(nowUnix), reason, nonce.toString());
      if (result.changes > 0) {
        this.#db
          .prepare("UPDATE reservation_state SET version = version + 1 WHERE singleton = 1")
          .run();
      }
      this.#db.exec("COMMIT;");
      return result.changes > 0;
    } catch (error) {
      try {
        this.#db.exec("ROLLBACK;");
      } catch {
        // Preserve the original storage error.
      }
      throw error;
    }
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

    return { released, active: this.active(nowUnix), version: this.version() };
  }

  close() {
    this.#db.close();
  }
}
