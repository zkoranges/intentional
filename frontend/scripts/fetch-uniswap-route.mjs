#!/usr/bin/env node
// S-1 route fetcher (uniswap_payouts_idea.md §2.1, §8): fetches a live
// WETH -> USDC route from the Uniswap Trading API with the spike harness as
// swapper and a distinct recipient, validates every §8 field, and writes a
// replayable fixture (route + block number) for test/spikes/UniswapPayoutSpike.
// The API key stays server-side; nothing here is committed except the fixture.

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, stringToBytes, getAddress } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const WETH = getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
const USDC = getAddress("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
const API_BASE = "https://trade-api.gateway.uniswap.org/v1";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

// forge-std makeAddr(name): private key = uint256(keccak256(bytes(name))).
function makeAddrCompatible(label) {
  return privateKeyToAccount(keccak256(stringToBytes(label))).address;
}

const apiKey = required("UNISWAP_API_KEY");
const rpcUrl = required("ETH_RPC_URL");
const amountWei = process.env.AMOUNT_WEI?.trim() || "4987500000000000";
if (!/^\d+$/.test(amountWei)) throw new Error("AMOUNT_WEI must be an integer");
const expectedProxy = getAddress(
  process.env.EXPECTED_PROXY?.trim() || "0x02E5be68D46DAc0B524905bfF209cf47EE6dB2a9",
);
const expectedSelector = (process.env.EXPECTED_SELECTOR?.trim() || "0x2894adf9").toLowerCase();

const swapper = makeAddrCompatible("uniswapPayoutSpikeHarness");
const recipient = makeAddrCompatible("uniswapPayoutSpikeRecipient");

const headers = {
  "content-type": "application/json",
  "x-api-key": apiKey,
  "x-permit2-disabled": "true",
};

async function post(path, body) {
  const response = await fetch(`${API_BASE}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${path} failed ${response.status}: ${text.slice(0, 300)}`);
  }
  return { text, json: JSON.parse(text) };
}

const quoteBody = {
  type: "EXACT_INPUT",
  amount: amountWei,
  tokenInChainId: 1,
  tokenOutChainId: 1,
  tokenIn: WETH,
  tokenOut: USDC,
  swapper,
  recipient,
  slippageTolerance: 0.5,
  routingPreference: "BEST_PRICE",
  protocols: ["V2", "V3", "V4"],
};

const { text: quoteText, json: quoteResponse } = await post("/quote", quoteBody);

// §8 rejection table — every row must hold or no fixture is written.
const q = quoteResponse.quote;
if (quoteResponse.routing !== "CLASSIC") throw new Error(`routing is ${quoteResponse.routing}, not CLASSIC`);
if (quoteResponse.permitData != null) throw new Error("permitData is not null under x-permit2-disabled");
if (getAddress(q.input.token) !== WETH) throw new Error("input token is not WETH");
if (String(q.input.amount) !== amountWei) throw new Error(`input amount ${q.input.amount} != ${amountWei}`);
if (getAddress(q.output.token) !== USDC) throw new Error("output token is not USDC");
if (getAddress(q.output.recipient) !== recipient) throw new Error("output recipient is not the spike recipient");
if (getAddress(q.swapper) !== swapper) throw new Error("swapper is not the spike harness");
if (q.chainId !== 1) throw new Error(`chainId ${q.chainId} != 1`);

const { json: swapResponse } = await post("/swap", {
  quote: q,
  simulateTransaction: false,
});

const swap = swapResponse.swap;
if (getAddress(swap.to) !== expectedProxy) {
  throw new Error(`swap.to ${swap.to} is not the expected proxy ${expectedProxy}`);
}
const swapValue = BigInt(swap.value ?? "0");
if (swapValue !== 0n) throw new Error(`swap.value ${swap.value} != 0`);
if (!swap.data || swap.data.slice(0, 10).toLowerCase() !== expectedSelector) {
  throw new Error(`swap.data selector ${swap.data?.slice(0, 10)} != ${expectedSelector}`);
}

const blockResponse = await fetch(rpcUrl, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }),
});
const fetchedAtBlock = parseInt((await blockResponse.json()).result, 16);
if (!Number.isSafeInteger(fetchedAtBlock) || fetchedAtBlock === 0) {
  throw new Error("could not read the current block number");
}

const fixture = {
  chainId: 1,
  fetchedAtBlock,
  fetchedAtUnix: Math.floor(Date.now() / 1000),
  swapper,
  recipient,
  amountInWei: amountWei,
  apiQuotedOut: String(q.output.amount),
  apiQuoteHash: keccak256(stringToBytes(quoteText)),
  quoteRequestId: quoteResponse.requestId ?? "",
  swapRequestId: swapResponse.requestId ?? "",
  swapTo: getAddress(swap.to),
  swapValue: swap.value ?? "0",
  swapData: swap.data,
};

const fixtureDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "test",
  "spikes",
  "fixtures",
);
mkdirSync(fixtureDir, { recursive: true });
const fixturePath = join(fixtureDir, "uniswap-route.json");
writeFileSync(fixturePath, JSON.stringify(fixture, null, 2) + "\n");
console.log(
  JSON.stringify(
    {
      fixture: "test/spikes/fixtures/uniswap-route.json",
      fetchedAtBlock,
      swapper,
      recipient,
      amountInWei: amountWei,
      apiQuotedOut: fixture.apiQuotedOut,
      quoteRequestId: fixture.quoteRequestId,
      swapRequestId: fixture.swapRequestId,
    },
    null,
    2,
  ),
);
