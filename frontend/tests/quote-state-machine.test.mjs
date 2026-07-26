import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const projectRoot = new URL("../", import.meta.url);

test("firm quote reads are cancellable and stale generations cannot commit", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");

  assert.match(page, /quoteGenerationRef = useRef\(0\)/);
  assert.match(page, /controller: new AbortController\(\)/);
  assert.match(page, /signal: request\.controller\.signal/g);
  assert.match(page, /active\?\.controller\.abort\(\)/);
  assert.match(page, /function isCurrentQuoteRequest/);

  const stEthFlow = page.slice(
    page.indexOf("async function requestStEthQuote"),
    page.indexOf("async function requestExistingClaimQuote"),
  );
  const unstEthFlow = page.slice(
    page.indexOf("async function requestExistingClaimQuote"),
    page.indexOf("async function fillQuote"),
  );
  for (const flow of [stEthFlow, unstEthFlow]) {
    assert.match(flow, /if \(!isCurrentQuoteRequest\(request\)\) return;/);
    assert.match(
      flow,
      /await verifyReservoirQuote\([\s\S]+if \(!isCurrentQuoteRequest\(request\)\) return;/,
    );
    assert.match(flow, /finishQuoteRequest\(request\)/);
  }
});

test("quote identity changes invalidate offers and seller binding is rechecked", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");

  assert.match(
    page,
    /claimQuoteCheck\?\.envelope\.quote\.seller\.toLowerCase\(\) ===\s*account\.toLowerCase\(\)/g,
  );
  assert.match(
    page,
    /checked\.envelope\.quote\.seller\.toLowerCase\(\) !==\s*requestedAccount\.toLowerCase\(\)/g,
  );
  assert.match(
    page,
    /onChange=\{\(event\) => \{\s*invalidateQuoteRequest\(\);\s*setAmountInput/,
  );
  assert.match(
    page,
    /const onChain = \(\) => \{\s*invalidateQuoteRequest\(\);/,
  );
  assert.match(
    page,
    /function selectSourceAsset[\s\S]+invalidateQuoteRequest\(\);/,
  );
  assert.match(
    page,
    /function selectMode[\s\S]+invalidateQuoteRequest\(\);/,
  );
});

test("Requote is explicit, loading is visible, and blocked quotes show a countdown", async () => {
  const [page, styles] = await Promise.all([
    readFile(new URL("app/page.tsx", projectRoot), "utf8"),
    readFile(new URL("app/globals.css", projectRoot), "utf8"),
  ]);

  assert.match(page, /Refreshing firm offer…/);
  assert.match(page, />\s*Requote\s*</g);
  assert.match(page, /requestStEthQuote\(true\)/);
  assert.match(page, /requestExistingClaimQuote\(selectedClaim, true\)/);
  assert.match(page, /replace,\s*\}\),/g);
  assert.match(page, /retryAtFromResponse/);
  assert.match(page, /Try again in \$\{wait\}/);
  assert.match(page, /quoteRetryBlocked/);
  assert.match(styles, /\.requoteButton/);
});

test("wallet rejection preserves the verified offer for retry", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const approvalFlow = page.slice(
    page.indexOf("async function approveReservoir"),
    page.indexOf("async function requestStEthQuote"),
  );
  const fillFlow = page.slice(
    page.indexOf("async function fillQuote"),
    page.indexOf("function selectMode"),
  );

  assert.doesNotMatch(approvalFlow, /setClaimQuoteCheck\(null\)/);
  assert.match(
    fillFlow,
    /error instanceof MinedTransactionVerificationError/,
  );
  assert.doesNotMatch(
    fillFlow,
    /if \(isExistingClaim\) \{\s*setClaimQuoteCheck\(null\)/,
  );
  assert.match(page, /setPending\(null\);\s*setAction\("idle"\)/);
});

test("expired offers become non-actionable and ask for a fresh quote", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");

  assert.match(
    page,
    /const expiresAt = Number\(claimQuoteCheck\.envelope\.quote\.deadline\) \* 1_000/,
  );
  assert.match(
    page,
    /current\?\.envelope\.quote\.nonce === nonce \? null : current/,
  );
  assert.match(page, /The firm offer expired\. Request a fresh quote\./);
  assert.match(page, /window\.setTimeout\(expire, remaining \+ 250\)/);
});
