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
