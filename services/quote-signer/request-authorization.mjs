import {
  getAddress,
  isAddress,
  keccak256,
  recoverMessageAddress,
  stringToHex,
} from "viem";

export const QUOTE_REQUEST_AUTH_VERSION = "intentional-quote-request-v1";
export const QUOTE_REQUEST_AUTH_CHAIN_ID = 1;
export const QUOTE_REQUEST_AUTH_MAX_TTL_SECONDS = 90;
// Browser clocks are not chain clocks. Thirty seconds absorbs ordinary device
// skew without turning this short-lived authorization into a reusable permit.
export const QUOTE_REQUEST_AUTH_FUTURE_SKEW_SECONDS = 30;

const UINT = /^(0|[1-9]\d*)$/;
const POSITIVE_UINT = /^[1-9]\d*$/;
const NONCE = /^0x[0-9a-f]{64}$/;
const SIGNATURE = /^0x[0-9a-fA-F]{130}$/;

export class QuoteRequestAuthorizationError extends Error {
  constructor(code, message, status = 401) {
    super(message);
    this.name = "QuoteRequestAuthorizationError";
    this.code = code;
    this.status = status;
  }
}

function reject(code, message, status) {
  throw new QuoteRequestAuthorizationError(code, message, status);
}

function parseUnix(value, field) {
  if (typeof value !== "string" || !UINT.test(value)) {
    reject("INVALID_QUOTE_AUTH", `${field} must be an unsigned integer string`, 400);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    reject("INVALID_QUOTE_AUTH", `${field} exceeds the supported range`, 400);
  }
  return parsed;
}

function canonicalRequest(request) {
  if (!request || typeof request !== "object") {
    reject("INVALID_QUOTE_AUTH", "quote request is missing", 400);
  }
  if (typeof request.seller !== "string" || !isAddress(request.seller)) {
    reject("INVALID_QUOTE_AUTH", "seller must be a valid address", 400);
  }
  if (request.mode === "originate") {
    const amount =
      typeof request.requestedStEth === "bigint"
        ? request.requestedStEth.toString()
        : request.requestedStEth;
    if (typeof amount !== "string" || !POSITIVE_UINT.test(amount)) {
      reject("INVALID_QUOTE_AUTH", "requestedStEth must be a positive integer", 400);
    }
    return {
      seller: getAddress(request.seller),
      mode: request.mode,
      requestedStEth: amount,
      requestId: null,
    };
  }
  if (request.mode === "existing-unsteth") {
    const requestId =
      typeof request.requestId === "bigint"
        ? request.requestId.toString()
        : request.requestId;
    if (typeof requestId !== "string" || !POSITIVE_UINT.test(requestId)) {
      reject("INVALID_QUOTE_AUTH", "requestId must be a positive integer", 400);
    }
    return {
      seller: getAddress(request.seller),
      mode: request.mode,
      requestedStEth: null,
      requestId,
    };
  }
  reject("INVALID_QUOTE_AUTH", "quote mode is unsupported", 400);
}

export function parseQuoteRequestAuthorization(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    reject("INVALID_QUOTE_AUTH", "quote authorization is missing", 400);
  }
  if (value.version !== QUOTE_REQUEST_AUTH_VERSION) {
    reject("INVALID_QUOTE_AUTH", "quote authorization version is unsupported", 400);
  }
  if (value.chainId !== QUOTE_REQUEST_AUTH_CHAIN_ID) {
    reject("WRONG_QUOTE_AUTH_CHAIN", "quote authorization is not for Ethereum mainnet");
  }
  if (typeof value.seller !== "string" || !isAddress(value.seller)) {
    reject("INVALID_QUOTE_AUTH", "authorization seller is invalid", 400);
  }
  if (value.mode !== "originate" && value.mode !== "existing-unsteth") {
    reject("INVALID_QUOTE_AUTH", "authorization mode is unsupported", 400);
  }
  if (typeof value.nonce !== "string" || !NONCE.test(value.nonce)) {
    reject("INVALID_QUOTE_AUTH", "authorization nonce must be 32 lowercase bytes", 400);
  }

  const requestedStEth =
    value.requestedStEth === null ? null : value.requestedStEth;
  const requestId = value.requestId === null ? null : value.requestId;
  if (
    value.mode === "originate" &&
    (typeof requestedStEth !== "string" ||
      !POSITIVE_UINT.test(requestedStEth) ||
      requestId !== null)
  ) {
    reject("INVALID_QUOTE_AUTH", "originate authorization has invalid subject fields", 400);
  }
  if (
    value.mode === "existing-unsteth" &&
    (typeof requestId !== "string" ||
      !POSITIVE_UINT.test(requestId) ||
      requestedStEth !== null)
  ) {
    reject(
      "INVALID_QUOTE_AUTH",
      "existing-unsteth authorization has invalid subject fields",
      400,
    );
  }

  const issuedAt = parseUnix(value.issuedAt, "issuedAt");
  const expiresAt = parseUnix(value.expiresAt, "expiresAt");
  if (expiresAt <= issuedAt) {
    reject("INVALID_QUOTE_AUTH", "quote authorization expiry must follow issuance", 400);
  }
  if (expiresAt - issuedAt > QUOTE_REQUEST_AUTH_MAX_TTL_SECONDS) {
    reject("QUOTE_AUTH_TTL_TOO_LONG", "quote authorization lifetime is too long");
  }

  return {
    version: QUOTE_REQUEST_AUTH_VERSION,
    chainId: QUOTE_REQUEST_AUTH_CHAIN_ID,
    seller: getAddress(value.seller),
    mode: value.mode,
    requestedStEth,
    requestId,
    nonce: value.nonce,
    issuedAt: issuedAt.toString(),
    expiresAt: expiresAt.toString(),
  };
}

/**
 * Stable EIP-191 payload. Keep byte-for-byte aligned with
 * frontend/lib/quote-request-authorization.ts.
 */
export function quoteRequestAuthorizationMessage(authorization) {
  return [
    "Intentional firm quote request",
    "",
    "Signing this message requests a firm quote. It does not approve or transfer assets.",
    "",
    `Version: ${authorization.version}`,
    `Chain ID: ${authorization.chainId}`,
    `Seller: ${authorization.seller}`,
    `Mode: ${authorization.mode}`,
    `Requested stETH (wei): ${authorization.requestedStEth ?? "-"}`,
    `Request ID: ${authorization.requestId ?? "-"}`,
    `Nonce: ${authorization.nonce}`,
    `Issued at: ${authorization.issuedAt}`,
    `Expires at: ${authorization.expiresAt}`,
  ].join("\n");
}

/**
 * In-memory replay classification. An exact replay remains valid and returns
 * the same authorization result throughout its expiry; this is required for
 * double-click and lost-response retries. Reusing one nonce for a different
 * signed payload is rejected.
 */
export class QuoteRequestReplayGuard {
  #byNonce = new Map();

  accept({ nonce, authorizationId, expiresAt }, nowSeconds) {
    for (const [storedNonce, entry] of this.#byNonce) {
      if (entry.expiresAt <= nowSeconds) this.#byNonce.delete(storedNonce);
    }

    const existing = this.#byNonce.get(nonce);
    if (existing) {
      if (existing.authorizationId !== authorizationId) {
        reject(
          "QUOTE_AUTH_NONCE_REUSE",
          "quote authorization nonce was reused for a different request",
        );
      }
      return { replayed: true };
    }
    this.#byNonce.set(nonce, { authorizationId, expiresAt });
    return { replayed: false };
  }

  get size() {
    return this.#byNonce.size;
  }
}

export async function verifyQuoteRequestAuthorization({
  authorization: rawAuthorization,
  authorizationSignature,
  request,
  nowSeconds = Math.floor(Date.now() / 1_000),
  replayGuard,
}) {
  if (!Number.isSafeInteger(nowSeconds) || nowSeconds < 0) {
    throw new TypeError("nowSeconds must be a non-negative safe integer");
  }
  if (
    typeof authorizationSignature !== "string" ||
    !SIGNATURE.test(authorizationSignature)
  ) {
    reject("INVALID_QUOTE_AUTH_SIGNATURE", "quote authorization signature is invalid");
  }

  const authorization = parseQuoteRequestAuthorization(rawAuthorization);
  const expected = canonicalRequest(request);
  if (
    authorization.seller !== expected.seller ||
    authorization.mode !== expected.mode ||
    authorization.requestedStEth !== expected.requestedStEth ||
    authorization.requestId !== expected.requestId
  ) {
    reject("QUOTE_AUTH_REQUEST_MISMATCH", "quote authorization does not match this request");
  }

  const issuedAt = Number(authorization.issuedAt);
  const expiresAt = Number(authorization.expiresAt);
  if (issuedAt > nowSeconds + QUOTE_REQUEST_AUTH_FUTURE_SKEW_SECONDS) {
    reject("QUOTE_AUTH_NOT_YET_VALID", "quote authorization was issued in the future");
  }
  if (expiresAt <= nowSeconds) {
    reject("QUOTE_AUTH_EXPIRED", "quote authorization has expired");
  }

  const message = quoteRequestAuthorizationMessage(authorization);
  let recovered;
  try {
    recovered = await recoverMessageAddress({
      message,
      signature: authorizationSignature,
    });
  } catch {
    reject("INVALID_QUOTE_AUTH_SIGNATURE", "quote authorization signature is invalid");
  }
  if (getAddress(recovered) !== authorization.seller) {
    reject("QUOTE_AUTH_WRONG_SELLER", "quote authorization was not signed by the seller");
  }

  const authorizationId = keccak256(stringToHex(message));
  const replay =
    replayGuard?.accept(
      {
        nonce: authorization.nonce,
        authorizationId,
        expiresAt,
      },
      nowSeconds,
    ) ?? { replayed: false };

  return {
    authorization,
    authorizationId,
    replayed: replay.replayed,
  };
}
