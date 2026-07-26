import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("the hero makes the stETH, unstETH, and direct-Lido source choices explicit", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");

  assert.match(
    page,
    /type ExitMode = (?=[^;]*"instant")(?=[^;]*"claim")(?=[^;]*"queue")[^;]+;/,
  );
  assert.match(page, /onClick=\{\(\) => selectMode\("instant"\)\}/);
  assert.match(page, /onClick=\{\(\) => selectMode\("claim"\)\}/);
  assert.match(page, /onClick=\{\(\) => selectMode\("queue"\)\}/);
  assert.match(page, />\s*Sell stETH\s*</);
  assert.match(page, />\s*Sell unstETH\s*</);
  assert.match(page, />\s*Wait & claim\s*</);
  assert.match(
    page,
    /snapshot\?\.requests\.filter\(\(request\) => !request\.isClaimed\)/,
  );
  assert.match(page, /aria-label="Owned unstETH claim"/);
  assert.match(page, /No unstETH claim found/);
  assert.match(page, /Sell an unstETH claim/);
  assert.match(page, /The claim and WETH payment move atomically/);
  assert.match(page, /Signed firm offer/);
  assert.match(page, /No estimate shown/);
  assert.match(page, /Connect wallet/);
  assert.match(page, /Join the official Lido queue and claim ETH after finalization/);

  // A disconnected visitor may choose a source, but must not be shown a
  // synthetic payout or offered a quote before connecting a wallet.
  assert.doesNotMatch(page, /requestLidoQuote/);
  assert.doesNotMatch(page, /\/api\/quote\/lido\/indicative/);
  assert.doesNotMatch(page, /Indicative · no wallet needed/);
  assert.doesNotMatch(page, /reservoir-indicative/);
  assert.doesNotMatch(page, /Finding your quote/);
});

test("the built product surface contains the owned-claim flow and no synthetic quote UI", async () => {
  const assetsDir = new URL("dist/client/assets/", projectRoot);
  const assetNames = await readdir(assetsDir);
  const pageAsset = assetNames.find((name) => name.startsWith("page-"));

  assert.ok(pageAsset, "client page bundle missing");
  const pageBundle = await readFile(
    join(assetsDir.pathname, pageAsset),
    "utf8",
  );

  for (const expected of [
    "Owned unstETH claim",
    "Sell an unstETH claim",
    "Sell stETH",
    "Sell unstETH",
    "Wait & claim",
    "0.0005 to 0.005 stETH",
    "Get firm offer",
    "Approve unstETH",
    "Sell for",
    "Signed firm offer",
    "No estimate shown",
  ]) {
    assert.match(pageBundle, new RegExp(expected));
  }

  assert.doesNotMatch(pageBundle, /\/api\/quote\/lido\/indicative/);
  assert.doesNotMatch(pageBundle, /reservoir-indicative/);
  assert.doesNotMatch(pageBundle, /Indicative · no wallet needed/);
  assert.doesNotMatch(pageBundle, /Paste signed quote JSON/);
});
