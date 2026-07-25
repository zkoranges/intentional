#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

const expectedKernel = "0x1111111111111111111111111111111111111111";
const expectedAdapter = "0x2222222222222222222222222222222222222222";
const assetsDirectory = new URL("../dist/client/assets/", import.meta.url);
const assetNames = await readdir(assetsDirectory);
const pageAsset = assetNames.find((name) => name.startsWith("page-"));

assert.ok(pageAsset, "pinned client page bundle is missing");
const pageBundle = await readFile(join(assetsDirectory.pathname, pageAsset), "utf8");
assert.match(pageBundle, /Use a firm quote/);
assert.match(pageBundle, /WETH now/);
assert.match(pageBundle, /Approve stETH/);
assert.match(pageBundle, new RegExp(expectedKernel, "i"));
assert.match(pageBundle, new RegExp(expectedAdapter, "i"));

console.log(
  "PINNED FRONTEND BUILD PASS | firm-quote flow and deployment bindings compiled",
);
