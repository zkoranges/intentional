import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("indicative Lido quotes do not require a wallet address", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const quoteClient = await readFile(
    new URL("lib/lido-quote.ts", projectRoot),
    "utf8",
  );
  const quoteRoute = await readFile(
    new URL("app/api/quote/lido/indicative/route.ts", projectRoot),
    "utf8",
  );

  assert.match(page, /requestLidoQuote\(amountInput, controller\.signal\)/);
  assert.match(page, /Indicative · no wallet needed/);
  assert.match(page, /Connect wallet to continue/);
  assert.ok(
    page.indexOf('mode === "instant"') < page.indexOf(") : !account ? ("),
    "instant quote state must be resolved before the wallet gate",
  );

  assert.match(quoteClient, /api\/quote\/lido\/indicative/);
  assert.doesNotMatch(quoteClient, /isAddress\(seller\)/);
  assert.match(quoteRoute, /requestedStEth/);
  assert.doesNotMatch(quoteRoute, /seller/);
  assert.match(quoteRoute, /reservoir-indicative\+lido-live/);
  assert.match(quoteRoute, /reservoir-indicative\+lido-fallback/);
});

test("the indicative route returns policy-labelled estimates, not a market", async () => {
  const quoteClient = await readFile(
    new URL("lib/lido-quote.ts", projectRoot),
    "utf8",
  );
  const quoteRoute = await readFile(
    new URL("app/api/quote/lido/indicative/route.ts", projectRoot),
    "utf8",
  );

  // What the route must say about itself: a fixed policy applied to the live
  // (or clearly labelled fallback) Lido wait, an honest firm-quote
  // availability signal derived server-side, and the 1:1 peg assumption.
  assert.match(quoteRoute, /fixed-policy/);
  assert.match(quoteRoute, /never a market price/);
  assert.match(quoteRoute, /firmQuoteAvailability/);
  assert.match(quoteRoute, /SIGNER_URL/);
  assert.match(quoteRoute, /assumed 1:1/);
  assert.match(quoteClient, /firmQuoteAvailability/);
  assert.match(quoteClient, /pegAssumption/);

  // The six fabricated CoW-comparison leftovers must never return. These
  // regressions necessarily contain the banned names — the release-gate grep
  // excludes this test file for exactly that reason.
  for (const removedField of [
    "recommendedRoute",
    "cowPaymentAmount",
    "reservoirPaymentAmount",
    "underwritingCap",
    "claimGasCost",
    "userImprovement",
  ]) {
    assert.doesNotMatch(quoteRoute, new RegExp(removedField));
    assert.doesNotMatch(quoteClient, new RegExp(removedField));
  }

  // The comparison flow's unreachable source value and firm-envelope
  // leftovers stay deleted with it.
  assert.doesNotMatch(quoteRoute, /cow-live\+lido-live/);
  assert.doesNotMatch(quoteClient, /cow-live\+lido-live/);
  assert.doesNotMatch(quoteClient, /expiresAt|envelope|"firm"/);
});
