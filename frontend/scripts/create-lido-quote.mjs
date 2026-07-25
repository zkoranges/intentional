#!/usr/bin/env node

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
const queueAbi = parseAbi(["function isPaused() view returns (bool)"]);

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
const requestedStEth = parseEther(required("REQUESTED_STETH"));
const paymentAmount = parseEther(required("PAYMENT_WETH"));
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

const [paymentAsset, fundingSealed, capacity, minAmountOfShares, queuePaused] = await Promise.all([
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
]);
if (paymentAsset !== WETH || !fundingSealed || capacity !== paymentAmount) {
  throw new Error("The productive WETH reserve cannot currently cover this payment");
}
if (queuePaused) {
  throw new Error("Canonical Lido withdrawals are currently paused");
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
    },
    stringifyBigInts,
    2,
  )}\n`,
);
