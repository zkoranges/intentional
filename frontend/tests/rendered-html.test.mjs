import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import {
  encodeFunctionData,
  getAddress,
  keccak256,
  parseAbi,
  stringToHex,
} from "viem";

const projectRoot = new URL("../", import.meta.url);
const zeroAddress = "0x0000000000000000000000000000000000000000";

test("the shipped page is a wallet-ready withdrawal product", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");

  for (const expected of [
    "Connect wallet",
    "Disconnect wallet",
    "intentional",
    "Onchain factoring",
    "Sell future payouts.",
    "Get paid now.",
    "Someone else waits.",
    "Factoring markets",
    "Queue time",
    "~10 days",
    "Checking live…",
    "Lido",
    "Ether.fi",
    "ERC-7540",
    "Sell stETH",
    "Sell unstETH",
    "Wait & claim",
    "Owned unstETH claim",
    "No unstETH claim found",
    "No estimate shown",
    "Claim notional",
    "Factoring discount",
    "0.00",
    "25%",
    "50%",
    "Max",
    "Get firm offer",
    "Getting firm offer…",
    "Signed firm offer",
    "Pre-alpha firm offers are capped to claims from 0.0005 to 0.005 stETH.",
    "Claim outside 0.0005–0.005 stETH pilot",
    "Approve unstETH",
    "Sell for",
    "not pinned in this app build",
    "Request withdrawal",
    "Onchain claims",
    "Claim ETH",
    "Onchain factoring for delayed claims.",
    "Read the docs",
    "https://github.com/zkoranges/intentional",
  ]) {
    assert.match(page, new RegExp(expected));
  }

  assert.ok(
    page.indexOf('className="exitCard"') <
      page.indexOf('className="marketsSection"'),
    "the primary withdrawal interface must appear before factoring markets",
  );
  assert.doesNotMatch(page, /jury|ETHGlobal|fork replay|Run on local Anvil/i);
  assert.doesNotMatch(page, /SkeletonPreview|codex-preview/);
  assert.doesNotMatch(
    page,
    /Sell now|Finding your quote|Indicative · no wallet needed|requestLidoQuote/,
  );
});

test("the three Lido routes have distinct source assets and settlement semantics", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");

  assert.match(
    page,
    /type ExitMode = (?=[^;]*"instant")(?=[^;]*"claim")(?=[^;]*"queue")[^;]+;/,
  );
  assert.match(
    page,
    /onClick=\{\(\) => selectMode\("instant"\)\}[\s\S]{0,180}>\s*Sell stETH\s*</,
  );
  assert.match(
    page,
    /onClick=\{\(\) => selectMode\("claim"\)\}[\s\S]{0,180}>\s*Sell unstETH\s*</,
  );
  assert.match(
    page,
    /onClick=\{\(\) => selectMode\("queue"\)\}[\s\S]{0,180}>\s*Wait & claim\s*</,
  );

  assert.match(page, /Lido · stETH → WETH/);
  assert.match(page, /Lido · unstETH → WETH/);
  assert.match(page, /Lido · stETH → unstETH/);
  assert.match(page, /Join the official Lido queue and claim ETH after finalization/);
});

test("liquid stETH requests a real originate quote and verifies it independently", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const instantQuoteFlow = page.slice(
    page.indexOf("async function requestStEthQuote"),
    page.indexOf("async function requestExistingClaimQuote"),
  );
  assert.ok(instantQuoteFlow.length > 0, "stETH firm-quote handler is missing");

  assert.match(
    instantQuoteFlow,
    /body:\s*JSON\.stringify\(\{\s*mode: "originate",\s*seller: account,\s*requestedStEth: amount\.toString\(\)/s,
  );
  assert.match(
    instantQuoteFlow,
    /const checked = await verifyReservoirQuote\(/,
  );
  assert.match(
    instantQuoteFlow,
    /checked\.envelope\.mode !== "originate"[\s\S]{0,700}setClaimQuoteCheck\(checked\)/,
  );
  assert.match(page, /snapshot\.stEthBalance/);
  assert.match(page, /approveReservoir/);
  assert.match(page, /fillQuote/);
});

test("the pre-alpha pilot supports the real 0.005-stETH claim but no larger quote", async () => {
  const [page, ethereum, quoteRoute] = await Promise.all([
    readFile(new URL("app/page.tsx", projectRoot), "utf8"),
    readFile(new URL("lib/ethereum.ts", projectRoot), "utf8"),
    readFile(new URL("app/api/quote/lido/route.ts", projectRoot), "utf8"),
  ]);

  assert.match(
    ethereum,
    /MAX_LIVE_LIDO_QUOTE = 5_000_000_000_000_000n;\s*\/\/ 0\.005 stETH/,
  );
  assert.match(
    ethereum,
    /requestedStEth > MAX_LIVE_LIDO_QUOTE/,
  );
  assert.match(quoteRoute, /LIVE_QUOTE_RANGE = "0\.0005 to 0\.005 stETH"/);
  assert.match(
    quoteRoute,
    /amount < MIN_LIVE_LIDO_QUOTE \|\| amount > MAX_LIVE_LIDO_QUOTE/,
  );
  assert.match(page, /0\.0005 to 0\.005 stETH/);
  assert.match(page, /outside 0\.0005–0\.005 stETH pilot/);
});

test("market queue times distinguish live estimates from typical values", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const lidoWaitRoute = await readFile(
    new URL("app/api/wait/lido/route.ts", projectRoot),
    "utf8",
  );

  assert.match(page, /api\/wait\/lido/);
  assert.match(page, /lido-withdrawals-api/);
  assert.match(page, /Typical queued withdrawal/);
  assert.match(lidoWaitRoute, /wq-api\.lido\.fi\/v2\/request-time\/calculate\?amount=1/);
  assert.match(lidoWaitRoute, /Number\.isSafeInteger/);
  assert.match(lidoWaitRoute, /stale-while-revalidate=300/);
  assert.match(lidoWaitRoute, /Live Lido queue estimate unavailable/);
});

test("wallet writes are simulated, receipt-backed, and chain-bound", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const ethereum = await readFile(
    new URL("lib/ethereum.ts", projectRoot),
    "utf8",
  );

  assert.match(ethereum, /eth_requestAccounts/);
  assert.match(page, /wallet_revokePermissions/);
  assert.match(page, /WALLET_DISCONNECTED_KEY/);
  assert.match(ethereum, /wallet_switchEthereumChain/);
  assert.match(ethereum, /chainId: "0x1"/);
  assert.match(ethereum, /simulateContract/g);
  assert.match(ethereum, /waitForTransactionReceipt/g);
  assert.match(ethereum, /decodeEventLog/);
  assert.match(ethereum, /Settlement receipt is missing ClaimSettled/);
  assert.match(ethereum, /receipt did not contain the expected unstETH mint/);
  assert.doesNotMatch(ethereum, /privateKey|PRIVATE_KEY|localStorage/);
});

test("canonical production addresses and selectors are exact", async () => {
  const ethereum = await readFile(
    new URL("lib/ethereum.ts", projectRoot),
    "utf8",
  );
  const addresses = [
    "0x499943e74fb0ce105688beee8ef2abec5d936d31",
    "0x8fdd04dbf6111437b44bbca99c28882434e0958f",
    "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
    "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
    "0x0bfc9d54Fc184518A81162F8fB99c2eACa081202",
  ];
  for (const address of addresses) {
    assert.match(ethereum.toLowerCase(), new RegExp(address.toLowerCase()));
    assert.equal(getAddress(address).length, 42);
  }

  const queueAbi = parseAbi([
    "function requestWithdrawals(uint256[] amounts, address owner) returns (uint256[] requestIds)",
    "function claimWithdrawal(uint256 requestId)",
  ]);
  const calldata = encodeFunctionData({
    abi: queueAbi,
    functionName: "requestWithdrawals",
    args: [[1n], zeroAddress],
  });
  assert.equal(
    calldata.slice(0, 10),
    keccak256(stringToHex("requestWithdrawals(uint256[],address)")).slice(
      0,
      10,
    ),
  );
});

test("owned unstETH firm offers are independently verified before exact approval and fill", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const ethereum = await readFile(
    new URL("lib/ethereum.ts", projectRoot),
    "utf8",
  );
  const quoteCli = await readFile(
    new URL("scripts/create-lido-quote.mjs", projectRoot),
    "utf8",
  );
  const existingQuoteFlow = page.slice(
    page.indexOf("async function requestExistingClaimQuote"),
    page.indexOf("async function fillQuote"),
  );
  assert.ok(
    existingQuoteFlow.length > 0,
    "existing unstETH quote handler is missing",
  );

  for (const guard of [
    "disabled until the reviewed deployment is pinned",
    "does not use the reviewed deployment",
    "different seller",
    "seller cannot remain the claim controller or receiver",
    "only accepts WETH",
    "quote has expired",
    "undeployed kernel or adapter",
    "bindings or nonce state are invalid",
    "reserve cannot currently deliver",
    "canonical Lido",
    "canonical payment or claim checks",
  ]) {
    assert.match(ethereum, new RegExp(guard));
  }
  assert.match(ethereum, /approveExact/);
  assert.match(ethereum, /NEXT_PUBLIC_RESERVOIR_KERNEL/);
  assert.match(ethereum, /sellerWethAfter - sellerWethBefore/);
  assert.match(ethereum, /statuses\[0\]\.owner/);
  assert.match(page, /sellableClaims/);
  assert.match(page, /aria-label="Owned unstETH claim"/);
  assert.match(page, /!selectedClaimOffer\.approvalSatisfied/);
  assert.match(page, /requestExistingClaimQuote/);
  assert.match(page, /Get firm offer/);
  assert.match(page, /Approve unstETH/);
  assert.match(page, /Sell for/);
  assert.match(page, /RESERVOIR_DEPLOYMENT/);
  assert.match(page, /The firm quote deployment is not pinned in this app build/);
  // The quote arrives over HTTP from the desk and is independently checked
  // against chain state; no envelope passes through a human.
  assert.match(
    existingQuoteFlow,
    /body:\s*JSON\.stringify\(\{\s*mode: "existing-unsteth",\s*seller: account,\s*requestId: request\.requestId\.toString\(\)/s,
  );
  assert.match(page, /"\/api\/quote\/lido"/);
  assert.match(
    existingQuoteFlow,
    /const checked = await verifyReservoirQuote\(\s*injected,\s*account,\s*JSON\.stringify\(payload\)/s,
  );
  assert.ok(
    existingQuoteFlow.indexOf("verifyReservoirQuote(") <
      existingQuoteFlow.indexOf("setClaimQuoteCheck(checked)"),
    "the HTTP envelope must be independently verified before it becomes actionable",
  );
  assert.doesNotMatch(page, /Paste signed quote JSON|quoteModalOpen|<textarea/);
  assert.doesNotMatch(
    page,
    /requestLidoQuote|\/api\/quote\/lido\/indicative|reservoir-indicative/,
  );
  assert.match(ethereum, /requestedStEth < MIN_LIDO_REQUEST/);
  assert.match(ethereum, /claimController\.toLowerCase\(\)/);
  assert.match(ethereum, /claimReceiver\.toLowerCase\(\)/);
  assert.match(
    quoteCli,
    /SELLER_ADDRESS must differ from the factor claim destination/,
  );
  assert.match(ethereum, /hasExactAllowance\(currentAllowance, amount\)/);
  assert.match(ethereum, /hasExactAllowance\(fillAllowance, check\.requestedStEth\)/);
  assert.match(ethereum, /approveUnstETH/);
  assert.match(ethereum, /existing-unsteth/);
  assert.match(ethereum, /ownerOf/);
  assert.match(ethereum, /functionName: "approve",\s*args: \[adapter, requestId\]/s);
  assert.match(
    ethereum,
    /if \(owner !== account\)[\s\S]*if \(approved !== adapter\)/,
  );
  assert.match(ethereum, /functionName: "fill"/);
  assert.match(ethereum, /waitForTransactionReceipt/);
  assert.match(ethereum, /Settlement receipt is missing ClaimSettled/);
  assert.match(
    ethereum,
    /sellerWethAfter - sellerWethBefore !== settled\.args\.paymentAmount/,
  );
  assert.match(
    ethereum,
    /statuses\[0\]\.owner !== envelope\.quote\.claimReceiver/,
  );
  assert.match(
    ethereum,
    /statuses\[0\]\.amountOfShares !== acquiredUnits/,
  );
  assert.match(ethereum, /functionName: "getApproved"/);
  assert.match(ethereum, /!approvalCleared/);
  assert.match(ethereum, /MAX_LIVE_LIDO_DISCOUNT_BPS/);
  assert.match(ethereum, /signed payment exceeds the pre-alpha discount limit/i);
  assert.match(page, /error instanceof MinedTransactionVerificationError/);
  assert.match(page, /Instant exit confirmed with a verification warning/);
  assert.match(ethereum, /event WithdrawalClaimed/);
  assert.match(ethereum, /claim\.args\.amountOfETH/);
  assert.match(ethereum, /Canonical Lido state does not mark the request claimed/);
  assert.match(
    page,
    /Lido claim #\$\{requestId\} confirmed with a verification warning/,
  );
  assert.doesNotMatch(ethereum, /type\\(uint256\\)\\.max|MaxUint256/);
});

test("the quote proxy route is keyless, validating, and fails closed", async () => {
  const route = await readFile(
    new URL("app/api/quote/lido/route.ts", projectRoot),
    "utf8",
  );

  // Proxies to the operator desk; the signing key never lives here.
  assert.match(route, /SIGNER_URL/);
  assert.match(route, /x-signer-secret/);
  assert.match(route, /Firm quote issuance is not configured in this deployment/);
  assert.match(route, /AbortSignal\.timeout/);
  assert.match(route, /force-dynamic/);
  assert.match(route, /no-store, max-age=0/);
  assert.match(route, /MIN_LIVE_LIDO_QUOTE/);
  assert.match(route, /MAX_LIVE_LIDO_QUOTE/);
  assert.match(route, /Pre-alpha firm quotes support/);
  assert.match(route, /mode: "existing-unsteth"/);
  assert.match(route, /requestId: body\.requestId/);
  assert.ok(route.includes("!/^[1-9]\\d*$/.test(body.requestId)"));
  // The signer hostname and secret must never reach the client bundle.
  assert.doesNotMatch(route, /NEXT_PUBLIC_SIGNER|NEXT_PUBLIC_.*SECRET/);
  assert.doesNotMatch(route, /api\.cow\.fi|cowprotocol|uniswap/i);
  assert.doesNotMatch(
    route,
    /PRIVATE_KEY|SIGNER_PRIVATE_KEY|FACTOR_PRIVATE_KEY|ETH_RPC_URL/,
  );
  assert.doesNotMatch(route, /error instanceof Error \? error\.message/);
});

test("market status is derived server-side and gates the complete firm path", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const statusRoute = await readFile(
    new URL("app/api/status/route.ts", projectRoot),
    "utf8",
  );

  assert.match(page, /fetch\("\/api\/status"/);
  assert.match(page, /marketStatus\.firmQuotesEnabled/);
  assert.match(page, /!marketLive/);
  assert.match(
    page,
    /!marketLive \?[\s\S]{0,700}marketStatus\.detail/,
    "disabled firm-quote actions must show the server-verified reason",
  );
  assert.match(page, /Lido: \{marketStatus\.state\}/);
  assert.doesNotMatch(page, /status:\s*"Open"/);
  assert.doesNotMatch(page, /One market open/);

  assert.match(statusRoute, /process\.env\.ETH_RPC_URL/);
  assert.match(
    statusRoute,
    /process\.env\.NEXT_PUBLIC_RESERVOIR_LIDO_UNSTETH_ADAPTER/,
  );
  assert.match(statusRoute, /functionName: "isPaused"/);
  assert.match(statusRoute, /functionName: "isSealed"/);
  assert.match(statusRoute, /functionName: "isAdapterAllowed"/);
  assert.match(statusRoute, /functionName: "availableFor"/);
  assert.match(statusRoute, /"Live"/);
  assert.match(statusRoute, /"Standby"/);
  assert.match(statusRoute, /"Retired"/);
  assert.match(statusRoute, /"Unavailable"/);
  assert.match(statusRoute, /state === "Live" && firmQuoteConfigured/);
  assert.match(
    statusRoute,
    /Onchain settlement is funded, but public firm quotes are unavailable/,
  );
  assert.match(
    statusRoute,
    /Mainnet proof completed; this deployment is permanently retired/,
  );
  assert.match(statusRoute, /Deployment status is not configured/);
  assert.match(statusRoute, /Live Ethereum status could not be verified/);
  assert.match(statusRoute, /!adapterAllowed \|\|\s*!unstETHAdapterAllowed/);
  assert.match(
    statusRoute,
    /!rpcUrl \|\| !kernel \|\| !expectedAdapter \|\| !expectedUnstETHAdapter/,
  );
  assert.doesNotMatch(
    statusRoute,
    /return Response\.json\([^)]*(ETH_RPC_URL|SIGNER_SECRET|SIGNER_URL)/s,
  );
});

test("the quote signer service holds the key and enforces its guards", async () => {
  const signer = await readFile(
    new URL("../services/quote-signer/server.mjs", projectRoot),
    "utf8",
  );

  assert.match(signer, /timingSafeEqual/);
  assert.match(signer, /MAX_QUOTE_WEI/);
  assert.match(signer, /SINGLE_FLIGHT/);
  assert.match(signer, /SETTLEMENT_PAUSED/);
  assert.match(signer, /LIDO_BUNKER/);
  assert.match(signer, /INSUFFICIENT_CAPACITY/);
  assert.match(signer, /SIGNER_SECRET must be at least 32 characters/);
  assert.match(
    signer,
    /QUOTE_TTL_SECONDS must be positive and stay inside the kernel/,
  );
  assert.match(signer, /audit/);
  // Binds localhost by default; the key is never echoed back.
  assert.match(
    signer,
    /process\.env\.HOST\?\.trim\(\) \|\| "127\.0\.0\.1"/,
  );
  assert.doesNotMatch(signer, /console\.log\([^)]*FACTOR_PRIVATE_KEY/);
});

test("the production build contains the dark responsive withdrawal interface", async () => {
  const assetsDir = new URL("dist/client/assets/", projectRoot);
  const assetNames = await readdir(assetsDir);
  const pageAsset = assetNames.find((name) => name.startsWith("page-"));
  const cssAsset = assetNames.find((name) => name.endsWith(".css"));

  assert.ok(pageAsset, "client page bundle missing");
  assert.ok(cssAsset, "client stylesheet missing");

  const pageBundle = await readFile(join(assetsDir.pathname, pageAsset), "utf8");
  const stylesheet = await readFile(join(assetsDir.pathname, cssAsset), "utf8");

  assert.match(pageBundle, /Connect wallet/);
  assert.match(pageBundle, /eth_requestAccounts/);
  assert.match(pageBundle, /Request withdrawal/);
  assert.match(pageBundle, /Sell stETH/);
  assert.match(pageBundle, /Sell unstETH/);
  assert.match(pageBundle, /Wait & claim/);
  assert.match(pageBundle, /Owned unstETH claim/);
  assert.match(pageBundle, /Get firm offer/);
  assert.match(pageBundle, /Approve unstETH/);
  assert.match(pageBundle, /Sell for/);
  assert.match(pageBundle, /existing-unsteth/);
  assert.match(pageBundle, /originate/);
  assert.match(pageBundle, /0\.0005 to 0\.005 stETH/);
  assert.match(pageBundle, /\/api\/quote\/lido/);
  assert.doesNotMatch(pageBundle, /Paste signed quote JSON/);
  assert.doesNotMatch(pageBundle, /\/api\/quote\/lido\/indicative/);
  assert.doesNotMatch(pageBundle, /reservoir-indicative/);
  assert.doesNotMatch(pageBundle, /Indicative · no wallet needed/);
  assert.match(pageBundle, /Onchain factoring for delayed claims/);
  assert.match(pageBundle, /Insufficient stETH balance/);
  assert.doesNotMatch(pageBundle, /jury|ETHGlobal|fork replay/i);
  assert.match(stylesheet, /#050505/);
  assert.match(stylesheet, /color-scheme:\s*dark/);
  assert.match(stylesheet, /#8b5cf6/);
  assert.doesNotMatch(stylesheet, /#fc72ff/);
  assert.match(stylesheet, /prefers-reduced-motion/);
  assert.match(stylesheet, /@media/);

  const socialCard = await readFile(
    new URL("public/og-factoring.png", projectRoot),
  );
  assert.ok(
    socialCard.length > 10_000,
    "social preview image is unexpectedly small",
  );
});
