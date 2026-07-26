import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("header uses standard wallet and Ethereum network controls", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const stylesheet = await readFile(
    new URL("app/globals.css", projectRoot),
    "utf8",
  );

  assert.match(page, /className=\{`networkPill/);
  assert.match(page, /src="\/icons\/eth\.svg"/);
  assert.match(page, /className="walletAddress"/);
  assert.match(page, /className="walletChevron"/);
  assert.match(page, />\s*Connect wallet\s*</);
  assert.doesNotMatch(page, /walletIdenticon/);
  assert.doesNotMatch(stylesheet, /\.walletIdenticon/);
  assert.match(stylesheet, /\.walletButton\.connected/);
  assert.match(stylesheet, /font-variant-numeric: tabular-nums/);
});

test("wallet account and chain events refresh the active account in place", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const stylesheet = await readFile(
    new URL("app/globals.css", projectRoot),
    "utf8",
  );

  assert.match(page, /accountsChanged/);
  assert.match(page, /chainChanged/);
  assert.match(page, /loadWalletAccount\(next\)/);
  assert.match(page, /walletRefreshIdRef/);
  assert.match(
    page,
    /\[\s*clearReplaceableQuote,\s*clearWalletState,\s*invalidateQuoteRequest,\s*loadWalletAccount,\s*\]/,
  );
  assert.doesNotMatch(
    page,
    /Ethereum contracts verified\. Choose an exit route\./,
  );
  assert.doesNotMatch(page, /statusDot ready/);
  assert.doesNotMatch(stylesheet, /\.statusDot/);
});
