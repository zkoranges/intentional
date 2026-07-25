#!/usr/bin/env node

// Executes one existing-unstETH firm quote against a chain-1 endpoint. This is
// the non-browser counterpart of the wallet flow: exact ERC-721 approval,
// settlement, and receipt/state verification. It is used only with disposable
// fork keys by the production-contract rehearsal.

import { readFile } from "node:fs/promises";
import {
  createPublicClient,
  createWalletClient,
  decodeAbiParameters,
  decodeEventLog,
  getAddress,
  http,
  keccak256,
  parseAbi,
  parseAbiItem,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

const QUEUE = getAddress("0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1");
const STETH = getAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
const WETH = getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");

const queueAbi = parseAbi([
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function approve(address to,uint256 tokenId)",
  "function getWithdrawalStatus(uint256[] requestIds) view returns ((uint256 amountOfStETH,uint256 amountOfShares,address owner,uint256 timestamp,bool isFinalized,bool isClaimed)[] statuses)",
]);
const erc20Abi = parseAbi(["function balanceOf(address owner) view returns (uint256)"]);
const settlementAbi = parseAbi([
  "function nonceUsed(uint256 nonce) view returns (bool)",
  "function fill((address factor,address seller,address adapter,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,bytes32 boundsHash,uint256 nonce,uint256 deadline) quote,bytes claimData,bytes boundsData,bytes factorSignature) returns ((bytes32 positionKey,uint256 claimId,uint256 pendingUnits,uint256 pendingReceived,uint256 claimableUnits,uint256 assetsReceived) acquisition)",
]);
const settledEvent = parseAbiItem(
  "event ClaimSettled(bytes32 indexed quoteHash,address indexed adapter,address indexed seller,address factor,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 positionKey,uint256 claimId,uint256 pendingUnits,uint256 pendingReceived,uint256 claimableUnits,uint256 assetsReceived)",
);

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const rpcUrl = required("ETH_RPC_URL");
const sellerKey = required("SELLER_PRIVATE_KEY");
const envelope = JSON.parse(await readFile(required("QUOTE_FILE"), "utf8"));
const account = privateKeyToAccount(sellerKey);

if (
  envelope.version !== "reservoir-v2-lido-1" ||
  envelope.mode !== "existing-unsteth" ||
  envelope.chainId !== 1
) {
  throw new Error("expected an existing-unstETH chain-1 quote envelope");
}
if (
  getAddress(envelope.quote.seller) !== account.address ||
  getAddress(envelope.quote.paymentAsset) !== WETH ||
  getAddress(envelope.quote.claimReceiver) === account.address
) {
  throw new Error("seller, payment, or claim-destination binding is invalid");
}
if (
  keccak256(envelope.claimData) !== envelope.quote.claimDataHash ||
  keccak256(envelope.boundsData) !== envelope.quote.boundsHash
) {
  throw new Error("signed payload hashes do not match");
}

const [claim] = decodeAbiParameters(
  [
    {
      type: "tuple",
      components: [
        { name: "queue", type: "address" },
        { name: "stETH", type: "address" },
        { name: "requestId", type: "uint256" },
      ],
    },
  ],
  envelope.claimData,
);
const [bounds] = decodeAbiParameters(
  [
    {
      type: "tuple",
      components: [
        { name: "minAmountOfStETH", type: "uint256" },
        { name: "maxAmountOfStETH", type: "uint256" },
        { name: "minAmountOfShares", type: "uint256" },
        { name: "maxAmountOfShares", type: "uint256" },
      ],
    },
  ],
  envelope.boundsData,
);
if (
  claim.queue !== QUEUE ||
  claim.stETH !== STETH ||
  claim.requestId === 0n ||
  bounds.minAmountOfStETH !== bounds.maxAmountOfStETH ||
  bounds.minAmountOfShares !== bounds.maxAmountOfShares
) {
  throw new Error("claim endpoints or exact economic bounds are invalid");
}

const publicClient = createPublicClient({ chain: mainnet, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account, chain: mainnet, transport: http(rpcUrl) });
if ((await publicClient.getChainId()) !== 1) throw new Error("chain 1 required");

const [statusBefore] = await publicClient.readContract({
  address: QUEUE,
  abi: queueAbi,
  functionName: "getWithdrawalStatus",
  args: [[claim.requestId]],
});
if (
  statusBefore.isClaimed ||
  statusBefore.owner !== account.address ||
  statusBefore.amountOfStETH !== bounds.minAmountOfStETH ||
  statusBefore.amountOfShares !== bounds.minAmountOfShares
) {
  throw new Error("the live canonical claim does not match the quote");
}

const adapter = getAddress(envelope.quote.adapter);
if (
  (await publicClient.readContract({
    address: QUEUE,
    abi: queueAbi,
    functionName: "getApproved",
    args: [claim.requestId],
  })) !== adapter
) {
  const approveSimulation = await publicClient.simulateContract({
    account,
    address: QUEUE,
    abi: queueAbi,
    functionName: "approve",
    args: [adapter, claim.requestId],
  });
  const approvalHash = await walletClient.writeContract(approveSimulation.request);
  const approvalReceipt = await publicClient.waitForTransactionReceipt({ hash: approvalHash });
  if (approvalReceipt.status !== "success") throw new Error("unstETH approval reverted");
}

const quote = {
  ...envelope.quote,
  paymentAmount: BigInt(envelope.quote.paymentAmount),
  nonce: BigInt(envelope.quote.nonce),
  deadline: BigInt(envelope.quote.deadline),
};
const sellerWethBefore = await publicClient.readContract({
  address: WETH,
  abi: erc20Abi,
  functionName: "balanceOf",
  args: [account.address],
});
const fillArgs = [quote, envelope.claimData, envelope.boundsData, envelope.factorSignature];
const fillSimulation = await publicClient.simulateContract({
  account,
  address: getAddress(envelope.kernel),
  abi: settlementAbi,
  functionName: "fill",
  args: fillArgs,
});
const estimate = await publicClient.estimateContractGas({
  account,
  address: getAddress(envelope.kernel),
  abi: settlementAbi,
  functionName: "fill",
  args: fillArgs,
});
const fillHash = await walletClient.writeContract({
  ...fillSimulation.request,
  gas: (estimate * 15n) / 10n,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: fillHash });
if (receipt.status !== "success") throw new Error("existing-unstETH fill reverted");

const settled = receipt.logs
  .filter((log) => log.address.toLowerCase() === envelope.kernel.toLowerCase())
  .map((log) => {
    try {
      return decodeEventLog({ abi: [settledEvent], data: log.data, topics: log.topics });
    } catch {
      return null;
    }
  })
  .find((log) => log?.eventName === "ClaimSettled");
if (!settled || settled.eventName !== "ClaimSettled") {
  throw new Error("fill receipt is missing ClaimSettled");
}

const [sellerWethAfter, ownerAfter, statusAfter, nonceUsed] = await Promise.all([
  publicClient.readContract({
    address: WETH,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account.address],
  }),
  publicClient.readContract({
    address: QUEUE,
    abi: queueAbi,
    functionName: "ownerOf",
    args: [claim.requestId],
  }),
  publicClient
    .readContract({
      address: QUEUE,
      abi: queueAbi,
      functionName: "getWithdrawalStatus",
      args: [[claim.requestId]],
    })
    .then((statuses) => statuses[0]),
  publicClient.readContract({
    address: getAddress(envelope.kernel),
    abi: settlementAbi,
    functionName: "nonceUsed",
    args: [quote.nonce],
  }),
]);
if (
  sellerWethAfter - sellerWethBefore !== quote.paymentAmount ||
  ownerAfter !== getAddress(envelope.quote.claimReceiver) ||
  statusAfter.owner !== getAddress(envelope.quote.claimReceiver) ||
  statusAfter.isClaimed ||
  statusAfter.amountOfStETH !== bounds.minAmountOfStETH ||
  statusAfter.amountOfShares !== bounds.minAmountOfShares ||
  settled.args.claimId !== claim.requestId ||
  settled.args.pendingUnits + settled.args.claimableUnits !== bounds.minAmountOfShares ||
  !nonceUsed
) {
  throw new Error("post-settlement production invariants failed");
}

console.log(`EXISTING UNSTETH E2E PASS | request ${claim.requestId} transferred atomically`);
console.log(`PAYMENT | seller received exactly ${quote.paymentAmount} wei WETH`);
console.log(`RECEIPT | ${fillHash}`);
