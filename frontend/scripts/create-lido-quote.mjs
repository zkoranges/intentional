#!/usr/bin/env node

import { randomBytes } from "node:crypto";
import {
  createPublicClient,
  decodeFunctionData,
  encodeAbiParameters,
  getAddress,
  http,
  isAddress,
  keccak256,
  parseAbi,
  parseEther,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

const STETH = getAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
const WETH = getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
const QUEUE = getAddress("0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1");

const kernelAbi = parseAbi([
  "function factorSigner() view returns (address)",
  "function fundingAccount() view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool)",
  "function isSealed() view returns (bool)",
  "function isPaused() view returns (bool)",
  "function nonceUsed(uint256 nonce) view returns (bool)",
  "function nonceFloor() view returns (uint256)",
]);
const adapterAbi = parseAbi([
  "function settlement() view returns (address)",
  "function stETH() view returns (address)",
  "function queue() view returns (address)",
]);
const fundingAbi = parseAbi([
  "function paymentAsset() view returns (address)",
  "function availableFor(uint256 wanted) view returns (uint256)",
  "function isSealed() view returns (bool)",
]);
const stEthAbi = parseAbi([
  "function getSharesByPooledEth(uint256 amount) view returns (uint256)",
]);
const queueAbi = parseAbi([
  "function isPaused() view returns (bool)",
  "function isBunkerModeActive() view returns (bool)",
  "function unfinalizedStETH() view returns (uint256)",
  "function unfinalizedRequestNumber() view returns (uint256)",
]);

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
const factorKey = required("FACTOR_PRIVATE_KEY");
if (!/^0x[0-9a-fA-F]{64}$/.test(factorKey)) {
  throw new Error("FACTOR_PRIVATE_KEY must be 32-byte hex");
}

const account = privateKeyToAccount(factorKey);
const kernel = address("KERNEL_ADDRESS");
const adapter = address("LIDO_ADAPTER_ADDRESS");
const seller = address("SELLER_ADDRESS");
if (seller === account.address) {
  throw new Error("SELLER_ADDRESS must differ from the factor claim destination");
}
const requestedStEth = parseEther(required("REQUESTED_STETH"));
const testPaymentOverride = process.env.ALLOW_TEST_PAYMENT_OVERRIDE === "1";
const operatorFirmQuote = process.env.OPERATOR_FIRM_QUOTE === "1";
if (testPaymentOverride && operatorFirmQuote) {
  throw new Error(
    "Choose exactly one pricing mode: fork-only test override or operator firm quote",
  );
}
if (!testPaymentOverride && !operatorFirmQuote) {
  throw new Error(
    "Firm Lido quote issuance requires OPERATOR_FIRM_QUOTE=1 with the recorded Aqua intent proof, or the fork-only ALLOW_TEST_PAYMENT_OVERRIDE=1",
  );
}
const paymentAmountWei = parseEther(required("PAYMENT_WETH"));
const requestedForSpread = requestedStEth;
if (paymentAmountWei >= requestedForSpread) {
  throw new Error("PAYMENT_WETH must be below REQUESTED_STETH (positive gross spread)");
}
let pricing;
if (operatorFirmQuote) {
  const aquaIntentProofTx = required("AQUA_INTENT_PROOF_TX");
  if (!/^0x[0-9a-fA-F]{64}$/.test(aquaIntentProofTx)) {
    throw new Error("AQUA_INTENT_PROOF_TX must be a 32-byte transaction hash");
  }
  pricing = {
    paymentAmount: paymentAmountWei,
    evidence: {
      mode: "operator-priced-firm-quote",
      source: "factor-set gross factoring spread; not a market-price guarantee",
      evidenceNote:
        "informational metadata; only the EIP-712 ClaimQuote fields are factor-signed",
      grossSpreadBps: (
        ((requestedForSpread - paymentAmountWei) * 10_000n) / requestedForSpread
      ).toString(),
      aquaIntentProofTx,
      signedAtUnix: Math.floor(Date.now() / 1000).toString(),
    },
  };
} else {
  pricing = {
    paymentAmount: paymentAmountWei,
    evidence: {
      mode: "test-override",
      source: "explicit disposable-fork fixture",
    },
  };
}
const paymentAmount = pricing.paymentAmount;
const maxStEthShortfall = unsigned(
  process.env.MAX_STETH_SHORTFALL_WEI ?? "2",
  "MAX_STETH_SHORTFALL_WEI",
);
if (requestedStEth <= maxStEthShortfall) {
  throw new Error("REQUESTED_STETH must exceed MAX_STETH_SHORTFALL_WEI");
}
const nonce = process.env.QUOTE_NONCE
  ? unsigned(process.env.QUOTE_NONCE, "QUOTE_NONCE")
  : BigInt(`0x${randomBytes(16).toString("hex")}`);

const client = createPublicClient({ chain: mainnet, transport: http(rpcUrl) });
if ((await client.getChainId()) !== 1) {
  throw new Error("ETH_RPC_URL must point to Ethereum mainnet");
}

if (operatorFirmQuote) {
  if (process.env.AQUA_PROOF_ALLOW_UNVERIFIED === "1") {
    pricing.evidence.aquaProofVerification = "skipped-rehearsal-only";
  } else {
    const aquaRouter = address("AQUA_ROUTER_ADDRESS");
    const expectedStrategyHash = required("AQUA_STRATEGY_HASH").toLowerCase();
    if (!/^0x[0-9a-f]{64}$/.test(expectedStrategyHash)) {
      throw new Error("AQUA_STRATEGY_HASH must be a 32-byte hash");
    }
    const expectedTakerWstEth = BigInt(
      unsigned(required("AQUA_TAKER_WSTETH_WEI"), "AQUA_TAKER_WSTETH_WEI"),
    );
    const [receipt, proofTx] = await Promise.all([
      client.getTransactionReceipt({
        hash: pricing.evidence.aquaIntentProofTx,
      }),
      client.getTransaction({ hash: pricing.evidence.aquaIntentProofTx }),
    ]);
    if (
      receipt.status !== "success" ||
      getAddress(receipt.from) !== account.address ||
      !receipt.to ||
      getAddress(receipt.to) !== aquaRouter
    ) {
      throw new Error(
        "AQUA_INTENT_PROOF_TX is not a successful factor transaction to the reviewed Aqua router",
      );
    }
    const swapVmAbi = parseAbi([
      "function swap((address maker, uint256 traits, bytes data) order, uint256 amount, bytes takerTraits) returns (uint256, uint256, bytes32)",
      "function hash((address maker, uint256 traits, bytes data) order) view returns (bytes32)",
    ]);
    let decodedSwap;
    try {
      decodedSwap = decodeFunctionData({ abi: swapVmAbi, data: proofTx.input });
    } catch {
      throw new Error("AQUA_INTENT_PROOF_TX calldata is not a SwapVM swap call");
    }
    if (decodedSwap.functionName !== "swap") {
      throw new Error("AQUA_INTENT_PROOF_TX did not call swap on the router");
    }
    const [proofOrder, proofAmount] = decodedSwap.args;
    if (proofAmount !== expectedTakerWstEth) {
      throw new Error(
        "AQUA_INTENT_PROOF_TX swap amount does not match the recorded taker input",
      );
    }
    const proofOrderHash = await client.readContract({
      address: aquaRouter,
      abi: swapVmAbi,
      functionName: "hash",
      args: [proofOrder],
    });
    if (proofOrderHash.toLowerCase() !== expectedStrategyHash) {
      throw new Error(
        "AQUA_INTENT_PROOF_TX order does not hash to the recorded Aqua strategy",
      );
    }
    const transferTopic =
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
    const wethOutLog = receipt.logs.find(
      (log) =>
        getAddress(log.address) === WETH &&
        log.topics[0] === transferTopic &&
        log.topics[2] &&
        getAddress(`0x${log.topics[2].slice(26)}`) === account.address,
    );
    if (!wethOutLog || BigInt(wethOutLog.data) === 0n) {
      throw new Error(
        "AQUA_INTENT_PROOF_TX receipt lacks a WETH transfer to the factor recipient",
      );
    }
    pricing.evidence.aquaProofVerification = "receipt-and-calldata-verified";
    pricing.evidence.aquaRouter = aquaRouter;
    pricing.evidence.aquaStrategyHash = expectedStrategyHash;
    pricing.evidence.aquaTakerWstEthWei = expectedTakerWstEth.toString();
    pricing.evidence.aquaWethOutWei = BigInt(wethOutLog.data).toString();
  }
  const [queueUnfinalizedStEth, queueUnfinalizedRequests] = await Promise.all([
    client.readContract({
      address: QUEUE,
      abi: queueAbi,
      functionName: "unfinalizedStETH",
    }),
    client.readContract({
      address: QUEUE,
      abi: queueAbi,
      functionName: "unfinalizedRequestNumber",
    }),
  ]);
  pricing.evidence.queueUnfinalizedStEthWei = queueUnfinalizedStEth.toString();
  pricing.evidence.queueUnfinalizedRequests = queueUnfinalizedRequests.toString();
}
const latestBlock = await client.getBlock({ blockTag: "latest" });
const deadline = process.env.QUOTE_DEADLINE
  ? unsigned(process.env.QUOTE_DEADLINE, "QUOTE_DEADLINE")
  : latestBlock.timestamp + 10n * 60n;

const [factorSigner, fundingAccount, allowed, settlementSealed, settlementPaused, used, nonceFloor, adapterSettlement, adapterStEth, adapterQueue] =
  await Promise.all([
    client.readContract({ address: kernel, abi: kernelAbi, functionName: "factorSigner" }),
    client.readContract({ address: kernel, abi: kernelAbi, functionName: "fundingAccount" }),
    client.readContract({
      address: kernel,
      abi: kernelAbi,
      functionName: "isAdapterAllowed",
      args: [adapter],
    }),
    client.readContract({ address: kernel, abi: kernelAbi, functionName: "isSealed" }),
    client.readContract({ address: kernel, abi: kernelAbi, functionName: "isPaused" }),
    client.readContract({
      address: kernel,
      abi: kernelAbi,
      functionName: "nonceUsed",
      args: [nonce],
    }),
    client.readContract({ address: kernel, abi: kernelAbi, functionName: "nonceFloor" }),
    client.readContract({ address: adapter, abi: adapterAbi, functionName: "settlement" }),
    client.readContract({ address: adapter, abi: adapterAbi, functionName: "stETH" }),
    client.readContract({ address: adapter, abi: adapterAbi, functionName: "queue" }),
  ]);

if (
  factorSigner !== account.address ||
  !allowed ||
  !settlementSealed ||
  settlementPaused ||
  used ||
  nonce < nonceFloor ||
  adapterSettlement !== kernel ||
  adapterStEth !== STETH ||
  adapterQueue !== QUEUE
) {
  throw new Error("Kernel, signer, adapter, canonical Lido, or nonce validation failed");
}

const [paymentAsset, fundingSealed, capacity, minAmountOfShares, queuePaused, bunkerMode] = await Promise.all([
  client.readContract({
    address: fundingAccount,
    abi: fundingAbi,
    functionName: "paymentAsset",
  }),
  client.readContract({
    address: fundingAccount,
    abi: fundingAbi,
    functionName: "isSealed",
  }),
  client.readContract({
    address: fundingAccount,
    abi: fundingAbi,
    functionName: "availableFor",
    args: [paymentAmount],
  }),
  client.readContract({
    address: STETH,
    abi: stEthAbi,
    functionName: "getSharesByPooledEth",
    args: [requestedStEth - maxStEthShortfall],
  }),
  client.readContract({
    address: QUEUE,
    abi: queueAbi,
    functionName: "isPaused",
  }),
  client.readContract({
    address: QUEUE,
    abi: queueAbi,
    functionName: "isBunkerModeActive",
  }),
]);
if (paymentAsset !== WETH || !fundingSealed || capacity !== paymentAmount) {
  throw new Error("The productive WETH reserve cannot currently cover this payment");
}
if (queuePaused) {
  throw new Error("Canonical Lido withdrawals are currently paused");
}
if (bunkerMode) {
  throw new Error("Firm quotes are disabled while Lido bunker mode is active");
}

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
const quote = {
  factor: account.address,
  seller,
  adapter,
  claimController: account.address,
  claimReceiver: account.address,
  paymentAsset: WETH,
  paymentAmount,
  claimDataHash: keccak256(claimData),
  boundsHash: keccak256(boundsData),
  nonce,
  deadline,
};
const types = {
  ClaimQuote: [
    { name: "factor", type: "address" },
    { name: "seller", type: "address" },
    { name: "adapter", type: "address" },
    { name: "claimController", type: "address" },
    { name: "claimReceiver", type: "address" },
    { name: "paymentAsset", type: "address" },
    { name: "paymentAmount", type: "uint256" },
    { name: "claimDataHash", type: "bytes32" },
    { name: "boundsHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};
const factorSignature = await account.signTypedData({
  domain: {
    name: "Reservoir v2",
    version: "1",
    chainId: 1,
    verifyingContract: kernel,
  },
  types,
  primaryType: "ClaimQuote",
  message: quote,
});

const stringifyBigInts = (_, value) =>
  typeof value === "bigint" ? value.toString() : value;
process.stdout.write(
  `${JSON.stringify(
    {
      version: "reservoir-v2-lido-1",
      chainId: 1,
      kernel,
      quote,
      claimData,
      boundsData,
      factorSignature,
      pricing: pricing.evidence,
    },
    stringifyBigInts,
    2,
  )}\n`,
);
