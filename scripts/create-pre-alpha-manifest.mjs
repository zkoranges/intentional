#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const broadcastPath =
  process.env.DEPLOYMENT_BROADCAST_PATH ??
  "broadcast/DeployV2Mainnet.s.sol/1/run-latest.json";
const outputPath =
  process.env.DEPLOYMENT_MANIFEST_PATH ??
  "deployments/mainnet-pre-alpha-001.json";
const rpcUrl = required("ETH_RPC_URL");
const factor = checksum(required("FACTOR_ADDRESS"));

const contracts = [
  ["fundingAccount", "ProductiveFundingAccount"],
  ["reserveAdapter", "ERC4626ReserveAdapter"],
  ["kernel", "AsyncClaimSettlement"],
  ["lidoAdapter", "LidoWithdrawalClaimAdapter"],
  ["lidoUnstETHExitAdapter", "LidoUnstETHExitAdapter"],
];

if (!existsSync(broadcastPath)) {
  fail(`deployment broadcast is missing: ${broadcastPath}`);
}
if (existsSync(outputPath) && process.env.ALLOW_MANIFEST_OVERWRITE !== "1") {
  fail(
    `${outputPath} already exists; set ALLOW_MANIFEST_OVERWRITE=1 only after reviewing it`,
  );
}
if (run("git", ["status", "--porcelain", "--untracked-files=no"]).trim()) {
  fail("tracked Git changes exist; generate the release manifest from a clean commit");
}
if (run("cast", ["chain-id", "--rpc-url", rpcUrl]).trim() !== "1") {
  fail("ETH_RPC_URL is not Ethereum mainnet");
}

const broadcast = JSON.parse(readFileSync(broadcastPath, "utf8"));
if (Number(broadcast.chain) !== 1) {
  fail(`broadcast chain is ${broadcast.chain}; expected Ethereum mainnet`);
}

const manifestContracts = {};
for (const [manifestName, contractName] of contracts) {
  const creations = broadcast.transactions.filter(
    (transaction) =>
      transaction.transactionType === "CREATE" &&
      transaction.contractName === contractName,
  );
  if (creations.length !== 1) {
    fail(
      `expected exactly one ${contractName} creation, found ${creations.length}`,
    );
  }

  const creation = creations[0];
  if (
    checksum(creation.transaction.from).toLowerCase() !== factor.toLowerCase()
  ) {
    fail(`${contractName} was not deployed by the reviewed factor`);
  }

  const receipt = JSON.parse(
    run("cast", [
      "receipt",
      creation.hash,
      "--rpc-url",
      rpcUrl,
      "--json",
    ]),
  );
  if (receipt.status !== "0x1") {
    fail(`${contractName} deployment receipt is not successful`);
  }
  if (
    checksum(receipt.contractAddress).toLowerCase() !==
    checksum(creation.contractAddress).toLowerCase()
  ) {
    fail(`${contractName} receipt address does not match the broadcast`);
  }
  if (checksum(receipt.from).toLowerCase() !== factor.toLowerCase()) {
    fail(`${contractName} receipt sender does not match the reviewed factor`);
  }

  const address = checksum(receipt.contractAddress);
  const runtimeCode = run("cast", ["code", address, "--rpc-url", rpcUrl]).trim();
  if (runtimeCode === "0x") {
    fail(`${contractName} has no mainnet runtime code`);
  }
  const runtimeCodeHash = run("cast", ["keccak", runtimeCode]).trim();
  if (!/^0x[0-9a-fA-F]{64}$/.test(runtimeCodeHash)) {
    fail(`${contractName} runtime code hash is malformed`);
  }

  manifestContracts[manifestName] = {
    address,
    runtimeCodeHash,
    deploymentTxHash: creation.hash,
    blockNumber: Number(BigInt(receipt.blockNumber)),
    sourceVerificationUrl: `https://etherscan.io/address/${address}#code`,
  };
}

const fundingCreation = broadcast.transactions.find(
  (transaction) =>
    transaction.transactionType === "CREATE" &&
    transaction.contractName === "ProductiveFundingAccount",
);
if (
  !Array.isArray(fundingCreation.arguments) ||
  fundingCreation.arguments.length !== 1 ||
  checksum(fundingCreation.arguments[0]).toLowerCase() !== factor.toLowerCase()
) {
  fail("ProductiveFundingAccount constructor is not bound to the reviewed factor");
}

const manifest = {
  schemaVersion: 2,
  network: "ethereum-mainnet",
  chainId: 1,
  gitCommit: run("git", ["rev-parse", "HEAD"]).trim(),
  releaseState: "paused-unfunded",
  factor,
  contracts: manifestContracts,
  canonical: {
    weth: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    stataWeth: "0x0bfc9d54Fc184518A81162F8fB99c2eACa081202",
    stETH: "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
    lidoWithdrawalQueue: "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
  },
  releaseLimits: {
    reserveFundingWei: "2000000000000000",
    minimumCapacityWei: "1500000000000000",
    minimumClaimWei: "500000000000000",
    maximumClaimWei: "1500000000000000",
    spreadBps: 25,
  },
};

writeFileSync(outputPath, `${JSON.stringify(manifest, null, 2)}\n`, {
  mode: 0o644,
  flag: existsSync(outputPath) ? "w" : "wx",
});
console.log(`PRE-ALPHA MANIFEST CREATED | ${outputPath}`);
console.log(`factor=${factor} commit=${manifest.gitCommit}`);
for (const [name, contract] of Object.entries(manifestContracts)) {
  console.log(
    `${name}=${contract.address} block=${contract.blockNumber} codehash=${contract.runtimeCodeHash}`,
  );
}

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) fail(`${name} is required`);
  return value;
}

function checksum(address) {
  if (typeof address !== "string") fail("encountered a missing address");
  try {
    return run("cast", ["to-check-sum-address", address]).trim();
  } catch {
    fail(`encountered an invalid address: ${address}`);
  }
}

function run(command, args) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    fail(`${command} command failed`);
  }
}

function fail(message) {
  console.error(`MANIFEST REFUSED | ${message}`);
  process.exit(1);
}
