import {
  getAddress,
  stringToHex,
  type Address,
  type EIP1193Provider,
  type Hex,
} from "viem";

export const QUOTE_REQUEST_AUTH_VERSION = "intentional-quote-request-v1";
export const QUOTE_REQUEST_AUTH_CHAIN_ID = 1;
export const QUOTE_REQUEST_AUTH_TTL_SECONDS = 60;

export type QuoteRequestMode = "originate" | "existing-unsteth";

export type QuoteRequestAuthorization = {
  version: typeof QUOTE_REQUEST_AUTH_VERSION;
  chainId: typeof QUOTE_REQUEST_AUTH_CHAIN_ID;
  seller: Address;
  mode: QuoteRequestMode;
  requestedStEth: string | null;
  requestId: string | null;
  nonce: Hex;
  issuedAt: string;
  expiresAt: string;
};

export type SignedQuoteRequestAuthorization = {
  authorization: QuoteRequestAuthorization;
  authorizationSignature: Hex;
};

export type QuoteRequestAuthorizationInput =
  | {
      mode: "originate";
      seller: Address;
      requestedStEth: bigint;
    }
  | {
      mode: "existing-unsteth";
      seller: Address;
      requestId: bigint;
    };

function randomNonce(): Hex {
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

/**
 * A stable, human-readable EIP-191 payload. Keep this byte-for-byte aligned
 * with services/quote-signer/request-authorization.mjs.
 */
export function quoteRequestAuthorizationMessage(
  authorization: QuoteRequestAuthorization,
) {
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

export function createQuoteRequestAuthorization(
  input: QuoteRequestAuthorizationInput,
  options: {
    nowSeconds?: number;
    ttlSeconds?: number;
    nonce?: Hex;
  } = {},
): QuoteRequestAuthorization {
  const issuedAt = options.nowSeconds ?? Math.floor(Date.now() / 1_000);
  const ttlSeconds =
    options.ttlSeconds ?? QUOTE_REQUEST_AUTH_TTL_SECONDS;
  if (!Number.isSafeInteger(issuedAt) || issuedAt < 0) {
    throw new Error("Quote authorization time is invalid");
  }
  if (!Number.isSafeInteger(ttlSeconds) || ttlSeconds < 1) {
    throw new Error("Quote authorization lifetime is invalid");
  }

  if (input.mode === "originate" && input.requestedStEth <= 0n) {
    throw new Error("The requested stETH amount must be positive");
  }
  if (input.mode === "existing-unsteth" && input.requestId <= 0n) {
    throw new Error("The unstETH request ID must be positive");
  }

  return {
    version: QUOTE_REQUEST_AUTH_VERSION,
    chainId: QUOTE_REQUEST_AUTH_CHAIN_ID,
    seller: getAddress(input.seller),
    mode: input.mode,
    requestedStEth:
      input.mode === "originate" ? input.requestedStEth.toString() : null,
    requestId:
      input.mode === "existing-unsteth" ? input.requestId.toString() : null,
    nonce: options.nonce ?? randomNonce(),
    issuedAt: issuedAt.toString(),
    expiresAt: (issuedAt + ttlSeconds).toString(),
  };
}

/**
 * Requests a short-lived EIP-191 signature from the connected seller. A fresh
 * nonce is generated for every deliberate quote request. Retrying the same
 * returned object is safe and idempotent until its expiry.
 */
export async function signQuoteRequestAuthorization(
  provider: EIP1193Provider,
  input: QuoteRequestAuthorizationInput,
  options: {
    nowSeconds?: number;
    ttlSeconds?: number;
    nonce?: Hex;
  } = {},
): Promise<SignedQuoteRequestAuthorization> {
  const authorization = createQuoteRequestAuthorization(input, options);
  const message = quoteRequestAuthorizationMessage(authorization);
  const signature = await provider.request({
    method: "personal_sign",
    params: [stringToHex(message), authorization.seller],
  });
  if (
    typeof signature !== "string" ||
    !/^0x[0-9a-fA-F]{130}$/.test(signature)
  ) {
    throw new Error("The wallet returned an invalid quote authorization");
  }
  return {
    authorization,
    authorizationSignature: signature as Hex,
  };
}
