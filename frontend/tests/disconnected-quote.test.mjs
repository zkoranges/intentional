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
