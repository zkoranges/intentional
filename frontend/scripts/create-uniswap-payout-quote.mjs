#!/usr/bin/env node
// Operator CLI for Reservoir Uniswap payout quotes (uniswap_payouts_idea.md
// §5, §8): fetches a live Trading API route with the payout executor as
// swapper and the seller as recipient, validates every §8 field against the
// on-chain executor bindings, signs the EIP-712 PayoutQuote with the factor
// key, and emits the §5.3 envelope on stdout. On ANY API or validation
// failure no quote is issued and the process exits nonzero — the plain WETH
// path through the v2 kernel is the fallback.

import { randomBytes } from "node:crypto";
import {
  createPublicClient,
  encodeAbiParameters,
  getAddress,
  http,
  isAddress,
  keccak256,
  parseAbi,
  parseEther,
  stringToBytes,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

const WETH = getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
const STETH = getAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
const QUEUE = getAddress("0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1");
const API_BASE = "https://trade-api.gateway.uniswap.org/v1";

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function address(name) {
  const value = required(name);
  if (!isAddress(value)) throw new Error(`${name} is not an address`);
  return getAddress(value);
}

function unsigned(value, name) {
  if (!/^\d+$/.test(value)) throw new Error(`${name} must be an unsigned integer`);
  return BigInt(value);
}

const rpcUrl = required("ETH_RPC_URL");
const apiKey = required("UNISWAP_API_KEY");
const factorKey = required("FACTOR_PRIVATE_KEY");
if (!/^0x[0-9a-fA-F]{64}$/.test(factorKey)) {
  throw new Error("FACTOR_PRIVATE_KEY must be 32-byte hex");
}
const account = privateKeyToAccount(factorKey);
const kernel = address("KERNEL_ADDRESS");
const lidoAdapter = address("LIDO_ADAPTER_ADDRESS");
const executorAddress = address("EXECUTOR_ADDRESS");
const seller = address("SELLER_ADDRESS");
const payoutAsset = address("PAYOUT_ASSET");
if (seller === account.address) {
  throw new Error("SELLER_ADDRESS must differ from the factor claim destination");
}
const requestedStEth = parseEther(required("REQUESTED_STETH"));
const paymentWethWei = parseEther(required("PAYMENT_WETH"));
if (paymentWethWei >= requestedStEth) {
  throw new Error("PAYMENT_WETH must be below REQUESTED_STETH (positive gross spread)");
}
const maxGrossSpreadBps = BigInt(
  unsigned(process.env.MAX_GROSS_SPREAD_BPS ?? "100", "MAX_GROSS_SPREAD_BPS"),
);
const grossSpreadBps = ((requestedStEth - paymentWethWei) * 10_000n) / requestedStEth;
if (grossSpreadBps > maxGrossSpreadBps) {
  throw new Error(`Gross spread ${grossSpreadBps} bps exceeds MAX_GROSS_SPREAD_BPS ${maxGrossSpreadBps}`);
}
const minPayoutBufferBps = BigInt(
  unsigned(process.env.MIN_PAYOUT_BUFFER_BPS ?? "100", "MIN_PAYOUT_BUFFER_BPS"),
);
const maxStEthShortfall = unsigned(process.env.MAX_STETH_SHORTFALL_WEI ?? "2", "MAX_STETH_SHORTFALL_WEI");

const client = createPublicClient({ chain: mainnet, transport: http(rpcUrl) });
if ((await client.getChainId()) !== 1) {
  throw new Error("ETH_RPC_URL must point to Ethereum mainnet");
}

// On-chain executor bindings are the validation reference, not env config.
const executorAbi = parseAbi([
  "function settlement() view returns (address)",
  "function fundingAsset() view returns (address)",
  "function proxy() view returns (address)",
  "function proxySelector() view returns (bytes4)",
]);
const [execSettlement, execFundingAsset, execProxy, execSelector] = await Promise.all([
  client.readContract({ address: executorAddress, abi: executorAbi, functionName: "settlement" }),
  client.readContract({ address: executorAddress, abi: executorAbi, functionName: "fundingAsset" }),
  client.readContract({ address: executorAddress, abi: executorAbi, functionName: "proxy" }),
  client.readContract({ address: executorAddress, abi: executorAbi, functionName: "proxySelector" }),
]);
if (getAddress(execSettlement) !== kernel) throw new Error("executor is not bound to the kernel");
if (getAddress(execFundingAsset) !== WETH) throw new Error("executor funding asset is not WETH");

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

const { text: quoteText, json: quoteResponse } = await post("/quote", {
  type: "EXACT_INPUT",
  amount: paymentWethWei.toString(),
  tokenInChainId: 1,
  tokenOutChainId: 1,
  tokenIn: WETH,
  tokenOut: payoutAsset,
  swapper: executorAddress,
  recipient: seller,
  slippageTolerance: 0.5,
  routingPreference: "BEST_PRICE",
  protocols: ["V2", "V3", "V4"],
});

const q = quoteResponse.quote;
if (quoteResponse.routing !== "CLASSIC") throw new Error(`routing is ${quoteResponse.routing}, not CLASSIC`);
if (quoteResponse.permitData != null) throw new Error("permitData is not null under x-permit2-disabled");
if (getAddress(q.input.token) !== WETH) throw new Error("input token is not WETH");
if (String(q.input.amount) !== paymentWethWei.toString()) throw new Error("input amount mismatch");
if (getAddress(q.output.token) !== payoutAsset) throw new Error("output token is not the payout asset");
if (getAddress(q.output.recipient) !== seller) throw new Error("output recipient is not the seller");
if (getAddress(q.swapper) !== executorAddress) throw new Error("swapper is not the executor");
if (q.chainId !== 1) throw new Error(`chainId ${q.chainId} != 1`);

const { json: swapResponse } = await post("/swap", { quote: q, simulateTransaction: false });
const swap = swapResponse.swap;
if (getAddress(swap.to) !== getAddress(execProxy)) {
  throw new Error(`swap.to ${swap.to} is not the executor's immutable proxy ${execProxy}`);
}
if (BigInt(swap.value ?? "0") !== 0n) throw new Error(`swap.value ${swap.value} != 0`);
if (!swap.data || swap.data.slice(0, 10).toLowerCase() !== execSelector.toLowerCase()) {
  throw new Error(`swap.data selector ${swap.data?.slice(0, 10)} != ${execSelector}`);
}

const apiQuotedOut = BigInt(q.output.amount);
const minimumPayoutAmount = (apiQuotedOut * (10_000n - minPayoutBufferBps)) / 10_000n;
if (minimumPayoutAmount === 0n) throw new Error("minimum payout rounded to zero");

const payoutData = encodeAbiParameters(
  [
    {
      type: "tuple",
      components: [
        { name: "callData", type: "bytes" },
        { name: "apiQuoteHash", type: "bytes32" },
      ],
    },
  ],
  [{ callData: swap.data, apiQuoteHash: keccak256(stringToBytes(quoteText)) }],
);

const claimData = encodeAbiParameters(
  [
    {
      type: "tuple",
      components: [
        { name: "queue", type: "address" },
        { name: "stETH", type: "address" },
        { name: "requestedStETH", type: "uint256" },
      ],
    },
  ],
  [{ queue: QUEUE, stETH: STETH, requestedStETH: requestedStEth }],
);
const minAmountOfShares = await client.readContract({
  address: STETH,
  abi: parseAbi(["function getSharesByPooledEth(uint256 amount) view returns (uint256)"]),
  functionName: "getSharesByPooledEth",
  args: [requestedStEth - maxStEthShortfall],
});
const boundsData = encodeAbiParameters(
  [
    {
      type: "tuple",
      components: [
        { name: "maxStETHShortfall", type: "uint256" },
        { name: "minAmountOfShares", type: "uint256" },
      ],
    },
  ],
  [{ maxStETHShortfall: maxStEthShortfall, minAmountOfShares }],
);

const nonce = process.env.QUOTE_NONCE
  ? unsigned(process.env.QUOTE_NONCE, "QUOTE_NONCE")
  : BigInt(`0x${randomBytes(16).toString("hex")}`);
const latestBlock = await client.getBlock({ blockTag: "latest" });
// §11.1 deadline policy: 2 minutes by default — the route executes against
// live pool state; a stale route reverts rather than fills badly.
const deadlineSeconds = BigInt(unsigned(process.env.QUOTE_DEADLINE_SECONDS ?? "120", "QUOTE_DEADLINE_SECONDS"));
if (deadlineSeconds > 900n) throw new Error("QUOTE_DEADLINE_SECONDS exceeds the kernel's 15-minute lifetime");
const deadline = latestBlock.timestamp + deadlineSeconds;

const quote = {
  factor: account.address,
  seller,
  adapter: lidoAdapter,
  claimController: account.address,
  claimReceiver: account.address,
  paymentAsset: WETH,
  paymentAmount: paymentWethWei,
  claimDataHash: keccak256(claimData),
  boundsHash: keccak256(boundsData),
  payoutAsset,
  minimumPayoutAmount,
  payoutDataHash: keccak256(payoutData),
  nonce,
  deadline,
};

const factorSignature = await account.signTypedData({
  domain: { name: "Reservoir Uniswap Payouts", version: "1", chainId: 1, verifyingContract: kernel },
  types: {
    PayoutQuote: [
      { name: "factor", type: "address" },
      { name: "seller", type: "address" },
      { name: "adapter", type: "address" },
      { name: "claimController", type: "address" },
      { name: "claimReceiver", type: "address" },
      { name: "paymentAsset", type: "address" },
      { name: "paymentAmount", type: "uint256" },
      { name: "claimDataHash", type: "bytes32" },
      { name: "boundsHash", type: "bytes32" },
      { name: "payoutAsset", type: "address" },
      { name: "minimumPayoutAmount", type: "uint256" },
      { name: "payoutDataHash", type: "bytes32" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  },
  primaryType: "PayoutQuote",
  message: quote,
});

const stringifyBigInts = (_, value) => (typeof value === "bigint" ? value.toString() : value);
process.stdout.write(
  `${JSON.stringify(
    {
      version: "reservoir-uniswap-payout-1",
      chainId: 1,
      kernel,
      quote,
      claimData,
      boundsData,
      payoutData,
      factorSignature,
      pricing: {
        mode: "operator-priced-firm-quote",
        evidenceNote:
          "informational metadata; only the EIP-712 PayoutQuote fields are factor-signed",
        grossSpreadBps: grossSpreadBps.toString(),
        signedAtUnix: Math.floor(Date.now() / 1000).toString(),
      },
      route: {
        quoteRequestId: quoteResponse.requestId ?? "",
        swapRequestId: swapResponse.requestId ?? "",
        apiQuoteHash: keccak256(stringToBytes(quoteText)),
        apiQuotedOut: apiQuotedOut.toString(),
        minimumPayoutAmount: minimumPayoutAmount.toString(),
        proxy: getAddress(execProxy),
        selector: execSelector,
        fetchedAtUnix: Math.floor(Date.now() / 1000).toString(),
        fetchedAtBlock: latestBlock.number.toString(),
      },
    },
    stringifyBigInts,
    2,
  )}\n`,
);
