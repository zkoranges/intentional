import test from "node:test";
import assert from "node:assert/strict";

import { privateKeyToAccount } from "viem/accounts";

import {
  QUOTE_REQUEST_AUTH_CHAIN_ID,
  QUOTE_REQUEST_AUTH_VERSION,
  QuoteRequestAuthorizationError,
  QuoteRequestReplayGuard,
  quoteRequestAuthorizationMessage,
  verifyQuoteRequestAuthorization,
} from "../request-authorization.mjs";

const SELLER_KEY =
  "0x1000000000000000000000000000000000000000000000000000000000000001";
const OTHER_KEY =
  "0x2000000000000000000000000000000000000000000000000000000000000002";
const seller = privateKeyToAccount(SELLER_KEY);
const other = privateKeyToAccount(OTHER_KEY);
const NOW = 1_800_000_000;
const NONCE = `0x${"12".repeat(32)}`;

function authorization(overrides = {}) {
  return {
    version: QUOTE_REQUEST_AUTH_VERSION,
    chainId: QUOTE_REQUEST_AUTH_CHAIN_ID,
    seller: seller.address,
    mode: "originate",
    requestedStEth: "1500000000000000",
    requestId: null,
    nonce: NONCE,
    issuedAt: String(NOW - 1),
    expiresAt: String(NOW + 59),
    ...overrides,
  };
}

async function signedAuthorization(overrides = {}, signer = seller) {
  const value = authorization(overrides);
  return {
    authorization: value,
    authorizationSignature: await signer.signMessage({
      message: quoteRequestAuthorizationMessage(value),
    }),
  };
}

function originateRequest(overrides = {}) {
  return {
    seller: seller.address,
    mode: "originate",
    requestedStEth: "1500000000000000",
    ...overrides,
  };
}

async function expectCode(promise, code) {
  await assert.rejects(promise, (error) => {
    assert.equal(error instanceof QuoteRequestAuthorizationError, true);
    assert.equal(error.code, code);
    return true;
  });
}

test("accepts an exact originate authorization signed by the seller", async () => {
  const signed = await signedAuthorization();
  const result = await verifyQuoteRequestAuthorization({
    ...signed,
    request: originateRequest(),
    nowSeconds: NOW,
  });
  assert.equal(result.authorization.seller, seller.address);
  assert.equal(result.authorization.mode, "originate");
  assert.match(result.authorizationId, /^0x[0-9a-f]{64}$/);
  assert.equal(result.replayed, false);
});

test("accepts an exact existing-unsteth authorization", async () => {
  const signed = await signedAuthorization({
    mode: "existing-unsteth",
    requestedStEth: null,
    requestId: "130880",
  });
  const result = await verifyQuoteRequestAuthorization({
    ...signed,
    request: {
      seller: seller.address,
      mode: "existing-unsteth",
      requestId: 130880n,
    },
    nowSeconds: NOW,
  });
  assert.equal(result.authorization.requestId, "130880");
  assert.equal(result.authorization.requestedStEth, null);
});

test("rejects amount and request-id tampering", async () => {
  const originate = await signedAuthorization();
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...originate,
      request: originateRequest({ requestedStEth: "1500000000000001" }),
      nowSeconds: NOW,
    }),
    "QUOTE_AUTH_REQUEST_MISMATCH",
  );

  const existing = await signedAuthorization({
    mode: "existing-unsteth",
    requestedStEth: null,
    requestId: "130880",
  });
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...existing,
      request: {
        seller: seller.address,
        mode: "existing-unsteth",
        requestId: "130881",
      },
      nowSeconds: NOW,
    }),
    "QUOTE_AUTH_REQUEST_MISMATCH",
  );
});

test("rejects mode and chain tampering", async () => {
  const signed = await signedAuthorization();
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...signed,
      request: {
        seller: seller.address,
        mode: "existing-unsteth",
        requestId: "130880",
      },
      nowSeconds: NOW,
    }),
    "QUOTE_AUTH_REQUEST_MISMATCH",
  );

  const wrongChain = await signedAuthorization({ chainId: 11155111 });
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...wrongChain,
      request: originateRequest(),
      nowSeconds: NOW,
    }),
    "WRONG_QUOTE_AUTH_CHAIN",
  );
});

test("rejects a valid signature from the wrong seller", async () => {
  const signed = await signedAuthorization({}, other);
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...signed,
      request: originateRequest(),
      nowSeconds: NOW,
    }),
    "QUOTE_AUTH_WRONG_SELLER",
  );
});

test("rejects stale, future, and overlong authorizations", async () => {
  const expired = await signedAuthorization({
    issuedAt: String(NOW - 61),
    expiresAt: String(NOW),
  });
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...expired,
      request: originateRequest(),
      nowSeconds: NOW,
    }),
    "QUOTE_AUTH_EXPIRED",
  );

  const future = await signedAuthorization({
    issuedAt: String(NOW + 31),
    expiresAt: String(NOW + 60),
  });
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...future,
      request: originateRequest(),
      nowSeconds: NOW,
    }),
    "QUOTE_AUTH_NOT_YET_VALID",
  );

  const overlong = await signedAuthorization({
    issuedAt: String(NOW),
    expiresAt: String(NOW + 91),
  });
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...overlong,
      request: originateRequest(),
      nowSeconds: NOW,
    }),
    "QUOTE_AUTH_TTL_TOO_LONG",
  );
});

test("exact authorization replay is idempotent throughout its live window", async () => {
  const guard = new QuoteRequestReplayGuard();
  const signed = await signedAuthorization();
  const input = {
    ...signed,
    request: originateRequest(),
    replayGuard: guard,
  };

  const first = await verifyQuoteRequestAuthorization({
    ...input,
    nowSeconds: NOW,
  });
  const second = await verifyQuoteRequestAuthorization({
    ...input,
    nowSeconds: NOW + 30,
  });
  const third = await verifyQuoteRequestAuthorization({
    ...input,
    nowSeconds: NOW + 58,
  });

  assert.equal(first.replayed, false);
  assert.equal(second.replayed, true);
  assert.equal(third.replayed, true);
  assert.equal(first.authorizationId, second.authorizationId);
  assert.equal(second.authorizationId, third.authorizationId);
  assert.equal(guard.size, 1);
});

test("reusing one nonce for a different signed request is rejected", async () => {
  const guard = new QuoteRequestReplayGuard();
  const first = await signedAuthorization();
  await verifyQuoteRequestAuthorization({
    ...first,
    request: originateRequest(),
    nowSeconds: NOW,
    replayGuard: guard,
  });

  const conflicting = await signedAuthorization({
    requestedStEth: "1600000000000000",
  });
  await expectCode(
    verifyQuoteRequestAuthorization({
      ...conflicting,
      request: originateRequest({ requestedStEth: "1600000000000000" }),
      nowSeconds: NOW,
      replayGuard: guard,
    }),
    "QUOTE_AUTH_NONCE_REUSE",
  );
});

test("expired replay entries are swept and do not poison a reused nonce", async () => {
  const guard = new QuoteRequestReplayGuard();
  const first = await signedAuthorization({
    issuedAt: String(NOW - 10),
    expiresAt: String(NOW + 1),
  });
  await verifyQuoteRequestAuthorization({
    ...first,
    request: originateRequest(),
    nowSeconds: NOW,
    replayGuard: guard,
  });

  const later = await signedAuthorization({
    requestedStEth: "1600000000000000",
    issuedAt: String(NOW + 2),
    expiresAt: String(NOW + 62),
  });
  const result = await verifyQuoteRequestAuthorization({
    ...later,
    request: originateRequest({ requestedStEth: "1600000000000000" }),
    nowSeconds: NOW + 2,
    replayGuard: guard,
  });
  assert.equal(result.replayed, false);
  assert.equal(guard.size, 1);
});
