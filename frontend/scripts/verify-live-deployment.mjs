#!/usr/bin/env node

import {
  createPublicClient,
  getAddress,
  http,
  isHex,
  keccak256,
  parseAbi,
} from "viem";
import { mainnet } from "viem/chains";

const CANONICAL = {
  stEth: getAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"),
  weth: getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
  queue: getAddress("0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"),
  stataWeth: getAddress("0x0bfc9d54Fc184518A81162F8fB99c2eACa081202"),
};
const EXPECTED_ADAPTER_COUNT = 2n;
const EXPECTED_NONCE_FLOOR = 0n;

const settlementAbi = parseAbi([
  "function factorSigner() view returns (address)",
  "function fundingAccount() view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool)",
  "function adapterCount() view returns (uint256)",
  "function nonceFloor() view returns (uint256)",
  "function isSealed() view returns (bool)",
  "function isPaused() view returns (bool)",
]);
const fundingAbi = parseAbi([
  "function factor() view returns (address)",
  "function reserveAdapter() view returns (address)",
  "function paymentAsset() view returns (address)",
  "function vault() view returns (address)",
  "function settlement() view returns (address)",
  "function isSealed() view returns (bool)",
  "function isPaused() view returns (bool)",
  "function availableFor(uint256 wanted) view returns (uint256)",
]);
const reserveAbi = parseAbi([
  "function makerAccount() view returns (address)",
  "function asset() view returns (address)",
  "function vault() view returns (address)",
  "function idleThreshold(address asset) view returns (uint256)",
  "function liquidityBufferAssets() view returns (uint256)",
]);
const lidoAdapterAbi = parseAbi([
  "function settlement() view returns (address)",
  "function stETH() view returns (address)",
  "function queue() view returns (address)",
]);
const erc20Abi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
]);
const vaultAbi = parseAbi([
  "function asset() view returns (address)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
]);

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function requiredAddress(name) {
  return getAddress(required(name));
}

function requiredCodeHash(name) {
  const value = required(name);
  if (!isHex(value) || value.length !== 66) {
    throw new Error(`${name} must be a 32-byte 0x-prefixed runtime code hash`);
  }
  return value.toLowerCase();
}

function requiredUint(name) {
  const value = required(name);
  if (!/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${name} must be an unsigned base-10 integer`);
  }
  return BigInt(value);
}

function same(left, right) {
  return left.toLowerCase() === right.toLowerCase();
}

const rpcUrl = required("ETH_RPC_URL");
const expectedState = required("EXPECTED_RELEASE_STATE");
// Lifecycle: paused-unfunded -> funded-paused -> active -> retired-paused
// -> claim-collected. The last two are terminal retirement states.
const allowedStates = new Set([
  "paused-unfunded",
  "funded-paused",
  "active",
  "retired-paused",
  "claim-collected",
]);
if (!allowedStates.has(expectedState)) {
  throw new Error(
    `EXPECTED_RELEASE_STATE must be one of: ${[...allowedStates].join(", ")}`,
  );
}
const retiredStates = new Set(["retired-paused", "claim-collected"]);
const isRetired = retiredStates.has(expectedState);

const expectedFactor = requiredAddress("FACTOR_ADDRESS");
const kernel = requiredAddress("KERNEL_ADDRESS");
const expectedFunding = requiredAddress("FUNDING_ACCOUNT_ADDRESS");
const expectedReserve = requiredAddress("RESERVE_ADAPTER_ADDRESS");
const lidoAdapter = requiredAddress("LIDO_ADAPTER_ADDRESS");
const lidoUnstETHAdapter = requiredAddress("LIDO_UNSTETH_ADAPTER_ADDRESS");
const expectedCodeHashes = {
  fundingAccount: requiredCodeHash("EXPECTED_FUNDING_CODEHASH"),
  reserveAdapter: requiredCodeHash("EXPECTED_RESERVE_CODEHASH"),
  kernel: requiredCodeHash("EXPECTED_KERNEL_CODEHASH"),
  lidoAdapter: requiredCodeHash("EXPECTED_LIDO_ADAPTER_CODEHASH"),
  lidoUnstETHAdapter: requiredCodeHash("EXPECTED_LIDO_UNSTETH_ADAPTER_CODEHASH"),
};
const probe =
  expectedState === "paused-unfunded" || isRetired
    ? 1n
    : requiredUint("MIN_CAPACITY_WEI");
if (probe === 0n) throw new Error("Capacity probe must be nonzero");

const client = createPublicClient({ chain: mainnet, transport: http(rpcUrl) });
const chainId = await client.getChainId();
if (chainId !== 1) {
  throw new Error(`Ethereum mainnet required, received ${chainId}`);
}

const factorCode = await client.getCode({ address: expectedFactor });
if (factorCode && factorCode !== "0x") {
  throw new Error("Factor must be a code-free EOA");
}

const codeAddresses = {
  ...CANONICAL,
  kernel,
  fundingAccount: expectedFunding,
  reserveAdapter: expectedReserve,
  lidoAdapter,
  lidoUnstETHAdapter,
};
const codeEntries = await Promise.all(
  Object.entries(codeAddresses).map(async ([name, address]) => {
    const runtimeCode = await client.getCode({ address });
    if (!runtimeCode || runtimeCode === "0x") {
      throw new Error(`Missing code at ${name} ${address}`);
    }
    return [name, { address, codeHash: keccak256(runtimeCode) }];
  }),
);
const code = Object.fromEntries(codeEntries);
for (const [name, expectedHash] of Object.entries(expectedCodeHashes)) {
  if (!same(code[name].codeHash, expectedHash)) {
    throw new Error(
      `${name} runtime codehash mismatch: expected ${expectedHash}, received ${code[name].codeHash}`,
    );
  }
}

const [
  factor,
  fundingAccount,
  settlementSealed,
  settlementPaused,
  adapterAllowed,
  unstETHAdapterAllowed,
  adapterCount,
  nonceFloor,
] = await Promise.all([
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "factorSigner",
  }),
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "fundingAccount",
  }),
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "isSealed",
  }),
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "isPaused",
  }),
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "isAdapterAllowed",
    args: [lidoAdapter],
  }),
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "isAdapterAllowed",
    args: [lidoUnstETHAdapter],
  }),
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "adapterCount",
  }),
  client.readContract({
    address: kernel,
    abi: settlementAbi,
    functionName: "nonceFloor",
  }),
]);
if (!same(factor, expectedFactor)) throw new Error("Kernel factor mismatch");
if (!same(fundingAccount, expectedFunding)) {
  throw new Error("Kernel funding-account mismatch");
}
if (!settlementSealed || !adapterAllowed || !unstETHAdapterAllowed) {
  throw new Error("Kernel is not sealed with both Lido adapters allowed");
}
if (
  adapterCount !== EXPECTED_ADAPTER_COUNT ||
  nonceFloor !== EXPECTED_NONCE_FLOOR
) {
  throw new Error("Kernel adapter count or nonce floor mismatch");
}

const [
  fundingFactor,
  reserveAdapter,
  paymentAsset,
  vault,
  fundingSettlement,
  fundingSealed,
  fundingPaused,
  capacity,
  idleWeth,
  vaultShares,
] = await Promise.all([
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "factor",
  }),
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "reserveAdapter",
  }),
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "paymentAsset",
  }),
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "vault",
  }),
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "settlement",
  }),
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "isSealed",
  }),
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "isPaused",
  }),
  client.readContract({
    address: expectedFunding,
    abi: fundingAbi,
    functionName: "availableFor",
    args: [probe],
  }),
  client.readContract({
    address: CANONICAL.weth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [expectedFunding],
  }),
  client.readContract({
    address: CANONICAL.stataWeth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [expectedFunding],
  }),
]);
if (
  !same(fundingFactor, expectedFactor) ||
  !same(reserveAdapter, expectedReserve) ||
  !same(paymentAsset, CANONICAL.weth) ||
  !same(vault, CANONICAL.stataWeth) ||
  !same(fundingSettlement, kernel) ||
  !fundingSealed
) {
  throw new Error("Funding-account binding mismatch");
}

const [
  reserveMaker,
  reserveAsset,
  reserveVault,
  idleThreshold,
  liquidityBuffer,
  adapterSettlement,
  adapterStEth,
  adapterQueue,
  unstETHAdapterSettlement,
  unstETHAdapterStEth,
  unstETHAdapterQueue,
  vaultAsset,
] = await Promise.all([
  client.readContract({
    address: expectedReserve,
    abi: reserveAbi,
    functionName: "makerAccount",
  }),
  client.readContract({
    address: expectedReserve,
    abi: reserveAbi,
    functionName: "asset",
  }),
  client.readContract({
    address: expectedReserve,
    abi: reserveAbi,
    functionName: "vault",
  }),
  client.readContract({
    address: expectedReserve,
    abi: reserveAbi,
    functionName: "idleThreshold",
    args: [CANONICAL.weth],
  }),
  client.readContract({
    address: expectedReserve,
    abi: reserveAbi,
    functionName: "liquidityBufferAssets",
  }),
  client.readContract({
    address: lidoAdapter,
    abi: lidoAdapterAbi,
    functionName: "settlement",
  }),
  client.readContract({
    address: lidoAdapter,
    abi: lidoAdapterAbi,
    functionName: "stETH",
  }),
  client.readContract({
    address: lidoAdapter,
    abi: lidoAdapterAbi,
    functionName: "queue",
  }),
  client.readContract({
    address: lidoUnstETHAdapter,
    abi: lidoAdapterAbi,
    functionName: "settlement",
  }),
  client.readContract({
    address: lidoUnstETHAdapter,
    abi: lidoAdapterAbi,
    functionName: "stETH",
  }),
  client.readContract({
    address: lidoUnstETHAdapter,
    abi: lidoAdapterAbi,
    functionName: "queue",
  }),
  client.readContract({
    address: CANONICAL.stataWeth,
    abi: vaultAbi,
    functionName: "asset",
  }),
]);
if (
  !same(reserveMaker, expectedFunding) ||
  !same(reserveAsset, CANONICAL.weth) ||
  !same(reserveVault, CANONICAL.stataWeth) ||
  idleThreshold !== 0n ||
  liquidityBuffer !== 0n ||
  !same(adapterSettlement, kernel) ||
  !same(adapterStEth, CANONICAL.stEth) ||
  !same(adapterQueue, CANONICAL.queue) ||
  !same(unstETHAdapterSettlement, kernel) ||
  !same(unstETHAdapterStEth, CANONICAL.stEth) ||
  !same(unstETHAdapterQueue, CANONICAL.queue) ||
  !same(vaultAsset, CANONICAL.weth)
) {
  throw new Error("Reserve, Lido adapter, or canonical vault binding mismatch");
}

const warnings = [];
if (expectedState === "paused-unfunded") {
  if (
    !settlementPaused ||
    !fundingPaused ||
    capacity !== 0n ||
    idleWeth !== 0n ||
    vaultShares !== 0n
  ) {
    throw new Error("Deployment is not paused and unfunded");
  }
} else if (isRetired) {
  // Terminal retirement states assert HARD only what the holder of the
  // exposed factor key cannot cheaply fake from outside: both pausable
  // contracts paused. (The seal, adapter allowlist, and every binding above
  // are already hard checks for all states.)
  //
  // Balance checks are TOLERANT here. Exact-zero equality would be
  // donation-griefable: anyone can send 1 wei of WETH or StataWETH to the
  // funding account and permanently fail this verifier, and clearing that
  // dust would require the burned factor key. A nonzero residual is
  // therefore reported as a warning — possible donation dust, not a
  // live-capital claim — never as a failure.
  if (!settlementPaused || !fundingPaused) {
    throw new Error(
      `Deployment is not fully paused for terminal state ${expectedState}`,
    );
  }
  if (idleWeth !== 0n) {
    warnings.push(
      `funding account holds a residual ${idleWeth} wei WETH — possible donation dust; not a live-capital claim`,
    );
  }
  if (vaultShares !== 0n) {
    warnings.push(
      `funding account holds ${vaultShares} residual StataWETH shares — possible donation dust; not a live-capital claim`,
    );
  }
  if (capacity !== 0n) {
    warnings.push(
      `availableFor(${probe}) reported ${capacity} wei on a retired deployment — possible donation dust; not a live-capital claim`,
    );
  }
} else {
  if (
    fundingPaused ||
    capacity !== probe ||
    vaultShares === 0n
  ) {
    throw new Error(
      "Deployment is not active/funded with productive shares and exact probed capacity",
    );
  }
  // Idle WETH is not a safety failure and exact-zero enforcement would make
  // this verifier donation-griefable. Productive shares plus availableFor()
  // covering the explicit probe are the release properties that matter.
  if (idleWeth !== 0n) {
    warnings.push(
      `funding account holds ${idleWeth} wei idle WETH — possible donation dust; productive capacity remains independently verified`,
    );
  }
  if (
    (expectedState === "funded-paused" && !settlementPaused) ||
    (expectedState === "active" && settlementPaused)
  ) {
    throw new Error(`Settlement pause state does not match ${expectedState}`);
  }
}

const reserveNav =
  vaultShares === 0n
    ? 0n
    : await client.readContract({
        address: CANONICAL.stataWeth,
        abi: vaultAbi,
        functionName: "convertToAssets",
        args: [vaultShares],
      });

for (const warning of warnings) {
  console.error(`WARNING: ${warning}`);
}

console.log(
  JSON.stringify(
    {
      ok: true,
      chainId,
      expectedState,
      warnings,
      factor: expectedFactor,
      kernel,
      fundingAccount: expectedFunding,
      reserveAdapter: expectedReserve,
      lidoAdapter,
      lidoUnstETHAdapter,
      adapterCount: adapterCount.toString(),
      nonceFloor: nonceFloor.toString(),
      capacityProbeWei: probe.toString(),
      capacityWei: capacity.toString(),
      vaultShares: vaultShares.toString(),
      reserveNavWei: reserveNav.toString(),
      code,
    },
    null,
    2,
  ),
);
