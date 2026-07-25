import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("the hero sells an owned unstETH claim and never fabricates a disconnected estimate", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");

  assert.match(page, /useState<ExitMode>\("claim"\)/);
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

  // A disconnected visitor may inspect the product, but must not be shown a
  // synthetic payout or offered a quote without an owned onchain request.
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
