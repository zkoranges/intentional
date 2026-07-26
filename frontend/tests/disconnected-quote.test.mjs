import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("the hero has two routes and an explicit asset selector inside Sell now", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const tabsStart = page.indexOf('<div className="modeTabs"');
  const tabsEnd = page.indexOf("</div>", tabsStart);
  const routeTabs = page.slice(tabsStart, tabsEnd);

  assert.ok(tabsStart >= 0 && tabsEnd > tabsStart, "route tabs are missing");
  assert.equal(
    [...routeTabs.matchAll(/role="tab"(?!list)/g)].length,
    2,
    "the top level must contain exactly Sell now and Wait & claim",
  );
  assert.match(routeTabs, />\s*Sell now\s*</);
  assert.match(routeTabs, />\s*Wait & claim\s*</);
  assert.doesNotMatch(routeTabs, />\s*Sell stETH\s*</);
  assert.doesNotMatch(routeTabs, />\s*Sell unstETH\s*</);

  // The asset selector is a token dropdown with an icon per option, not a
  // native select that hides the assets behind an OS menu.
  assert.doesNotMatch(page, /<select[^>]*aria-label="Asset to sell"/);
  assert.match(page, /aria-label="Asset to sell"\s+aria-haspopup="listbox"/);
  assert.match(page, /role="option"/);
  assert.match(page, /id: "steth",\s*symbol: "stETH"/);
  assert.match(page, /id: "unsteth",\s*symbol: "unstETH"/);
  assert.match(
    page,
    /snapshot\?\.requests\.filter\(\(request\) => !request\.isClaimed\)/,
  );
  assert.match(page, /aria-label="Owned unstETH claim"/);
  assert.match(page, /No claims · Start a withdrawal/);
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
    "Sell now",
    "Asset to sell",
    "Wait & claim",
    "Firm offer size is determined by live reserve capacity.",
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
