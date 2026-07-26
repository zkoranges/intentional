#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

const expectedKernel = "0x1111111111111111111111111111111111111111";
const expectedAdapter = "0x2222222222222222222222222222222222222222";
const expectedUnstETHAdapter = "0x4444444444444444444444444444444444444444";
const assetsDirectory = new URL("../dist/client/assets/", import.meta.url);
const assetNames = await readdir(assetsDirectory);
const pageAsset = assetNames.find((name) => name.startsWith("page-"));

assert.ok(pageAsset, "pinned client page bundle is missing");
const pageBundle = await readFile(join(assetsDirectory.pathname, pageAsset), "utf8");
assert.match(pageBundle, /Factoring markets/);
assert.match(pageBundle, /Sell now/);
assert.match(pageBundle, /Wait & claim/);
assert.match(pageBundle, /Asset to sell/);
assert.match(pageBundle, /Owned unstETH claim/);
assert.match(pageBundle, /Firm offer size is determined by live reserve capacity/);
assert.match(pageBundle, /Get firm offer/);
assert.match(pageBundle, /Approve unstETH/);
assert.match(pageBundle, /Sell for/);
assert.match(pageBundle, /originate/);
assert.doesNotMatch(pageBundle, /reservoir-indicative|Indicative · no wallet needed/);
assert.match(pageBundle, new RegExp(expectedKernel, "i"));
assert.match(pageBundle, new RegExp(expectedAdapter, "i"));
assert.match(pageBundle, new RegExp(expectedUnstETHAdapter, "i"));

console.log(
  "PINNED FRONTEND BUILD PASS | firm-quote flow and deployment bindings compiled",
);
