#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import {
  createPublicClient,
  createWalletClient,
  decodeAbiParameters,
  decodeEventLog,
  formatEther,
  getAddress,
  http,
  parseAbi,
  parseAbiItem,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

const STETH = getAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
const WETH = getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
const STATA_WETH = getAddress("0x0bfc9d54Fc184518A81162F8fB99c2eACa081202");
const QUEUE = getAddress("0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1");
const AQUA = getAddress("0x499943e74fb0ce105688beee8ef2abec5d936d31");

const erc20Abi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function approve(address spender,uint256 amount) returns (bool)",
]);
const settlementAbi = parseAbi([
  "function fill((address factor,address seller,address adapter,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,bytes32 boundsHash,uint256 nonce,uint256 deadline) quote,bytes claimData,bytes boundsData,bytes factorSignature) returns ((bytes32 positionKey,uint256 claimId,uint256 pendingUnits,uint256 pendingReceived,uint256 claimableUnits,uint256 assetsReceived) acquisition)",
]);
const queueAbi = parseAbi([
  "function getWithdrawalStatus(uint256[] requestIds) view returns ((uint256 amountOfStETH,uint256 amountOfShares,address owner,uint256 timestamp,bool isFinalized,bool isClaimed)[] statuses)",
  "function balanceOf(address owner) view returns (uint256)",
]);
const vaultAbi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
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
const quotePath = required("QUOTE_FILE");
if (required("AQUA_PROOF_PASSED") !== "1") {
  throw new Error("canonical Aqua companion proof is required");
}
const envelope = JSON.parse(await readFile(quotePath, "utf8"));
const account = privateKeyToAccount(sellerKey);
if (getAddress(envelope.quote.seller) !== account.address) {
  throw new Error("SELLER_PRIVATE_KEY does not match the quote seller");
}
if (envelope.chainId !== 1 || getAddress(envelope.quote.paymentAsset) !== WETH) {
  throw new Error("The quote is not the chain-1 WETH product");
}

const publicClient = createPublicClient({ chain: mainnet, transport: http(rpcUrl) });
const walletClient = createWalletClient({
  account,
  chain: mainnet,
  transport: http(rpcUrl),
});
if ((await publicClient.getChainId()) !== 1) {
  throw new Error("chain 1 required");
}
for (const address of [AQUA, STETH, WETH, STATA_WETH, QUEUE, envelope.kernel, envelope.quote.adapter]) {
  const code = await publicClient.getCode({ address });
  if (!code || code === "0x") throw new Error(`missing production code at ${address}`);
}

const [claim] = decodeAbiParameters(
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
  envelope.claimData,
);
if (claim.queue !== QUEUE || claim.stETH !== STETH) {
  throw new Error("quote is not bound to canonical Lido");
}

const requested = claim.requestedStETH;
const payment = BigInt(envelope.quote.paymentAmount);
const sellerWethBefore = await publicClient.readContract({
  address: WETH,
  abi: erc20Abi,
  functionName: "balanceOf",
  args: [account.address],
});
const factorNftsBefore = await publicClient.readContract({
  address: QUEUE,
  abi: queueAbi,
  functionName: "balanceOf",
  args: [getAddress(envelope.quote.claimReceiver)],
});

const preexistingAllowance = await publicClient.readContract({
  address: STETH,
  abi: erc20Abi,
  functionName: "allowance",
  args: [account.address, getAddress(envelope.quote.adapter)],
});
if (preexistingAllowance === requested) {
  console.log(
    "LIVE E2E 0 | exact stETH approval already in place before the quote window",
  );
} else {
  const approveSimulation = await publicClient.simulateContract({
    account,
    address: STETH,
    abi: erc20Abi,
    functionName: "approve",
    args: [getAddress(envelope.quote.adapter), requested],
  });
  const approveHash = await walletClient.writeContract(approveSimulation.request);
  const approveReceipt = await publicClient.waitForTransactionReceipt({ hash: approveHash });
  if (approveReceipt.status !== "success") throw new Error("exact stETH approval reverted");
}

const quote = {
  ...envelope.quote,
  paymentAmount: payment,
  nonce: BigInt(envelope.quote.nonce),
  deadline: BigInt(envelope.quote.deadline),
};
const fillSimulation = await publicClient.simulateContract({
  account,
  address: getAddress(envelope.kernel),
  abi: settlementAbi,
  functionName: "fill",
  args: [
    quote,
    envelope.claimData,
    envelope.boundsData,
    envelope.factorSignature,
  ],
});
// Execution can cost more than the simulation estimate (Aave interest
// accrual and Lido checkpoint growth take colder, longer paths at mining
// time). A flat 50% cushion prevents the OutOfGas-revert observed live.
const estimatedFillGas = await publicClient.estimateContractGas({
  account,
  address: getAddress(envelope.kernel),
  abi: settlementAbi,
  functionName: "fill",
  args: [
    quote,
    envelope.claimData,
    envelope.boundsData,
    envelope.factorSignature,
  ],
});
const fillGasLimit = (estimatedFillGas * 15n) / 10n;
const fillHash = await walletClient.writeContract({
  ...fillSimulation.request,
  gas: fillGasLimit,
});
const fillReceipt = await publicClient.waitForTransactionReceipt({ hash: fillHash });
if (fillReceipt.status !== "success") throw new Error("Reservoir fill reverted");

const decoded = fillReceipt.logs
  .filter((log) => log.address.toLowerCase() === envelope.kernel.toLowerCase())
  .map((log) => {
    try {
      return decodeEventLog({
        abi: [settledEvent],
        data: log.data,
        topics: log.topics,
      });
    } catch {
      return null;
    }
  })
  .find((log) => log?.eventName === "ClaimSettled");
if (!decoded || decoded.eventName !== "ClaimSettled") {
  throw new Error("fill receipt is missing ClaimSettled");
}

const requestId = decoded.args.claimId;
const [sellerWethAfter, factorNftsAfter, statuses, adapterStEth, allowance] = await Promise.all([
  publicClient.readContract({
    address: WETH,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account.address],
  }),
  publicClient.readContract({
    address: QUEUE,
    abi: queueAbi,
    functionName: "balanceOf",
    args: [getAddress(envelope.quote.claimReceiver)],
  }),
  publicClient.readContract({
    address: QUEUE,
    abi: queueAbi,
    functionName: "getWithdrawalStatus",
    args: [[requestId]],
  }),
  publicClient.readContract({
    address: STETH,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [getAddress(envelope.quote.adapter)],
  }),
  publicClient.readContract({
    address: STETH,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account.address, getAddress(envelope.quote.adapter)],
  }),
]);

if (
  sellerWethAfter - sellerWethBefore !== payment ||
  factorNftsAfter !== factorNftsBefore + 1n ||
  statuses.length !== 1 ||
  statuses[0].owner !== getAddress(envelope.quote.claimReceiver) ||
  statuses[0].amountOfShares !== decoded.args.pendingReceived ||
  adapterStEth !== 0n ||
  allowance !== 0n
) {
  throw new Error("post-settlement production invariants failed");
}

const fundingAccount = getAddress(required("FUNDING_ACCOUNT"));
const shares = await publicClient.readContract({
  address: STATA_WETH,
  abi: vaultAbi,
  functionName: "balanceOf",
  args: [fundingAccount],
});
const nav = await publicClient.readContract({
  address: STATA_WETH,
  abi: vaultAbi,
  functionName: "convertToAssets",
  args: [shares],
});

console.log("COMPANION PROOF | Aqua/SwapVM reserve swap passed in a separate fork test");
console.log(`LIVE E2E 1 | seller approved exactly ${formatEther(requested)} stETH`);
console.log(`LIVE E2E 2 | canonical unstETH #${requestId} minted to factor`);
console.log(`LIVE E2E 3 | claim shares acquired ${formatEther(decoded.args.pendingReceived)}`);
console.log(`LIVE E2E 4 | seller received exactly ${formatEther(payment)} WETH`);
console.log(`LIVE E2E 5 | remaining productive reserve NAV ${formatEther(nav)} WETH`);
