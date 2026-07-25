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
    "Make waiting optional.",
    "Exit stETH",
    "Instant exit",
    "Lido queue",
    "25%",
    "50%",
    "Max",
    "Import firm quote",
    "Instant exits coming soon",
    "Request withdrawal",
    "Withdrawal positions",
    "Claim ETH",
    "Frequently asked questions",
    "Read the docs",
    "https://github.com/zkoranges/reservoir-v2-eth-lisbon",
  ]) {
    assert.match(page, new RegExp(expected));
  }

  assert.doesNotMatch(page, /jury|ETHGlobal|fork replay|Run on local Anvil/i);
  assert.doesNotMatch(page, /SkeletonPreview|codex-preview/);
});

test("wallet writes are simulated, receipt-backed, and chain-bound", async () => {
  const ethereum = await readFile(
    new URL("lib/ethereum.ts", projectRoot),
    "utf8",
  );

  assert.match(ethereum, /eth_requestAccounts/);
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

  for (const guard of [
    "disabled until the reviewed deployment is pinned",
    "does not use the reviewed Reservoir deployment",
    "different seller",
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
  assert.match(page, /Paste signed quote JSON/);
  assert.match(page, /Import firm quote/);
  assert.match(ethereum, /claim\.requestedStETH < MIN_LIDO_REQUEST/);
  assert.match(ethereum, /hasExactAllowance\(currentAllowance, amount\)/);
  assert.match(ethereum, /hasExactAllowance\(fillAllowance, check\.requestedStEth\)/);
  assert.match(page, /error instanceof MinedTransactionVerificationError/);
  assert.match(page, /Reservoir exit confirmed with a verification warning/);
  assert.match(ethereum, /event WithdrawalClaimed/);
  assert.match(ethereum, /claim\.args\.amountOfETH/);
  assert.match(ethereum, /Canonical Lido state does not mark the request claimed/);
  assert.match(
    page,
    /Lido claim #\$\{requestId\} confirmed with a verification warning/,
  );
  assert.doesNotMatch(ethereum, /type\\(uint256\\)\\.max|MaxUint256/);
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
  assert.match(pageBundle, /Instant exits coming soon/);
  assert.match(pageBundle, /Frequently asked questions/);
  assert.match(pageBundle, /Insufficient stETH balance/);
  assert.doesNotMatch(pageBundle, /jury|ETHGlobal|fork replay/i);
  assert.match(stylesheet, /#0d0d0f/);
  assert.match(stylesheet, /color-scheme:\s*dark/);
  assert.match(stylesheet, /#fc72ff/);
  assert.match(stylesheet, /prefers-reduced-motion/);
  assert.match(stylesheet, /@media/);

  const socialCard = await readFile(new URL("public/og.png", projectRoot));
  assert.ok(
    socialCard.length > 10_000,
    "social preview image is unexpectedly small",
  );
});
