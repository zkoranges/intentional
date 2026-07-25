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
    "impatience",
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
    "Sell now",
    "Wait & claim",
    "0.00",
    "25%",
    "50%",
    "Max",
    "Finding your quote",
    "Use firm quote",
    "Firm · fillable",
    "CoW wins · executable quote",
    "Reservoir wins · modeled",
    "Request withdrawal",
    "Onchain claims",
    "Claim ETH",
    "Future value, liquid today.",
    "Powered by Reservoir",
    "Read the docs",
    "https://github.com/zkoranges/reservoir-v2-eth-lisbon",
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

test("firm Reservoir quotes fail closed before wallet execution", async () => {
  const page = await readFile(new URL("app/page.tsx", projectRoot), "utf8");
  const ethereum = await readFile(
    new URL("lib/ethereum.ts", projectRoot),
    "utf8",
  );
  const quoteClient = await readFile(
    new URL("lib/lido-quote.ts", projectRoot),
    "utf8",
  );
  const quoteCli = await readFile(
    new URL("scripts/create-lido-quote.mjs", projectRoot),
    "utf8",
  );

  for (const guard of [
    "disabled until the reviewed deployment is pinned",
    "does not use the reviewed Reservoir deployment",
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
  assert.match(page, /snapshot\.queueAllowance === amount/);
  assert.match(page, /quoteCheck\.allowance !== quoteCheck\.requestedStEth/);
  assert.match(page, /RESERVOIR_DEPLOYMENT/);
  assert.match(page, /requestLidoQuote/);
  assert.match(quoteClient, /api\/quote\/lido/);
  assert.match(quoteClient, /cow-live\+lido-live/);
  assert.match(page, /Live CoW and Lido data/);
  assert.match(page, /Paste signed quote JSON/);
  assert.match(ethereum, /claim\.requestedStETH < MIN_LIDO_REQUEST/);
  assert.match(ethereum, /claimController\.toLowerCase\(\)/);
  assert.match(ethereum, /claimReceiver\.toLowerCase\(\)/);
  assert.match(
    quoteCli,
    /SELLER_ADDRESS must differ from the factor claim destination/,
  );
  assert.match(ethereum, /hasExactAllowance\(currentAllowance, amount\)/);
  assert.match(ethereum, /hasExactAllowance\(fillAllowance, check\.requestedStEth\)/);
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

test("the public market route is live, keyless, and secret-safe", async () => {
  const route = await readFile(
    new URL("app/api/quote/lido/route.ts", projectRoot),
    "utf8",
  );

  assert.match(route, /api\.cow\.fi\/mainnet\/api\/v1\/quote/);
  assert.match(route, /wq-api\.lido\.fi\/v2\/request-time\/calculate/);
  assert.match(route, /priceQuality: "optimal"/);
  assert.match(route, /source: "cow-live\+lido-live"/);
  assert.match(
    route,
    /Live CoW\/Lido pricing is temporarily unavailable/,
  );
  assert.doesNotMatch(
    route,
    /PRIVATE_KEY|SIGNER_PRIVATE_KEY|FACTOR_PRIVATE_KEY|ETH_RPC_URL/,
  );
  assert.doesNotMatch(route, /error instanceof Error \? error\.message/);
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
  assert.match(pageBundle, /Use firm quote/);
  assert.match(pageBundle, /Future value, liquid today/);
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
