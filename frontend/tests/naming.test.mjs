import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// The decision this file enforces is written up in docs/NAMING.md:
// Impatience is the product, Reservoir is the protocol.

const projectRoot = new URL("../", import.meta.url);
const repoRoot = new URL("../../", import.meta.url);

const read = (path, base = projectRoot) => readFile(new URL(path, base), "utf8");

test("the EIP-712 domain name is frozen and matches the deployed kernel", async () => {
  const [ethereum, quoteCli, kernel] = await Promise.all([
    read("lib/ethereum.ts"),
    read("scripts/create-lido-quote.mjs"),
    read("src/claims/AsyncClaimSettlement.sol", repoRoot),
  ]);

  // Renaming this is not cosmetic: the domain separator is hashed into every
  // quote digest, so a mismatch makes each fill revert InvalidFactorSignature.
  assert.match(kernel, /EIP712\("Reservoir v2", "1"\)/);
  assert.match(ethereum, /name: "Reservoir v2"/);
  assert.match(quoteCli, /name: "Reservoir v2"/);
});

test("the quote envelope version is frozen across signer and verifier", async () => {
  const [ethereum, quoteCli, archived] = await Promise.all([
    read("lib/ethereum.ts"),
    read("scripts/create-lido-quote.mjs"),
    read("deployments/quote-envelope-unsteth-130880.json", repoRoot),
  ]);

  assert.match(ethereum, /"reservoir-v2-lido-1"/);
  assert.match(quoteCli, /"reservoir-v2-lido-1"/);
  assert.equal(JSON.parse(archived).version, "reservoir-v2-lido-1");
});

test("marketing metadata is Impatience, never the protocol name", async () => {
  const layout = await read("app/layout.tsx");

  assert.match(layout, /Impatience/);
  assert.doesNotMatch(
    layout,
    /Reservoir/,
    "app/layout.tsx is title, description and social-card copy — product voice only",
  );
});

test("user-facing failure text does not name the protocol", async () => {
  const ethereum = await read("lib/ethereum.ts");

  // errorMessage() in app/page.tsx renders error.message straight into the
  // status line, so anything thrown here is product copy.
  const thrown = [...ethereum.matchAll(/throw new Error\(\s*("(?:[^"\\]|\\.)*")/g)]
    .map((match) => match[1]);

  assert.ok(thrown.length > 0, "expected to find thrown error messages to check");
  const offenders = thrown.filter((message) => /reservoir/i.test(message));
  assert.deepEqual(
    offenders,
    [],
    "name what the person controls, not the settlement engine — see docs/NAMING.md",
  );
});

test("the footer keeps deliberate Reservoir attribution", async () => {
  const [page, docs] = await Promise.all([
    read("app/page.tsx"),
    read("app/docs/page.tsx"),
  ]);

  // Attribution, not a product name. Removing it is also a naming decision.
  assert.match(page, /Powered by Reservoir/);
  assert.match(docs, /Powered by Reservoir/);
});
