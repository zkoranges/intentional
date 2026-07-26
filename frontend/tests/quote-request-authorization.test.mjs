import test from "node:test";
import assert from "node:assert/strict";

import { hexToString } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  createQuoteRequestAuthorization,
  quoteRequestAuthorizationMessage as browserAuthorizationMessage,
  signQuoteRequestAuthorization,
} from "../lib/quote-request-authorization.ts";
import {
  quoteRequestAuthorizationMessage as signerAuthorizationMessage,
  verifyQuoteRequestAuthorization,
} from "../../services/quote-signer/request-authorization.mjs";

const seller = privateKeyToAccount(
  "0x3000000000000000000000000000000000000000000000000000000000000003",
);
const NOW = 1_800_000_000;
const NONCE = `0x${"34".repeat(32)}`;

function providerFor(account) {
  return {
    async request({ method, params }) {
      assert.equal(method, "personal_sign");
      assert.equal(params[1], account.address);
      return account.signMessage({ message: hexToString(params[0]) });
    },
  };
}

test("browser and signer produce the same canonical authorization bytes", () => {
  const authorization = createQuoteRequestAuthorization(
    {
      seller: seller.address,
      mode: "originate",
      requestedStEth: 1_500_000_000_000_000n,
    },
    { nowSeconds: NOW, ttlSeconds: 60, nonce: NONCE },
  );
  assert.equal(
    browserAuthorizationMessage(authorization),
    signerAuthorizationMessage(authorization),
  );
});

test("browser-generated originate authorization verifies at the signer", async () => {
  const signed = await signQuoteRequestAuthorization(
    providerFor(seller),
    {
      seller: seller.address,
      mode: "originate",
      requestedStEth: 1_500_000_000_000_000n,
    },
    { nowSeconds: NOW, ttlSeconds: 60, nonce: NONCE },
  );
  const verified = await verifyQuoteRequestAuthorization({
    ...signed,
    request: {
      seller: seller.address,
      mode: "originate",
      requestedStEth: "1500000000000000",
    },
    nowSeconds: NOW,
  });
  assert.equal(verified.authorization.seller, seller.address);
});

test("browser-generated existing-unsteth authorization verifies at the signer", async () => {
  const signed = await signQuoteRequestAuthorization(
    providerFor(seller),
    {
      seller: seller.address,
      mode: "existing-unsteth",
      requestId: 130880n,
    },
    {
      nowSeconds: NOW,
      ttlSeconds: 60,
      nonce: `0x${"56".repeat(32)}`,
    },
  );
  const verified = await verifyQuoteRequestAuthorization({
    ...signed,
    request: {
      seller: seller.address,
      mode: "existing-unsteth",
      requestId: "130880",
    },
    nowSeconds: NOW,
  });
  assert.equal(verified.authorization.requestId, "130880");
});
