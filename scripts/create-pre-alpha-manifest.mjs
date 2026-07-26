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
const etherscanApiKey = required("ETHERSCAN_API_KEY");
const factor = checksum(required("FACTOR_ADDRESS"));

const contracts = [
  [
    "fundingAccount",
    "ProductiveFundingAccount",
    "out/ProductiveFundingAccount.sol/ProductiveFundingAccount.json",
  ],
  [
    "reserveAdapter",
    "ERC4626ReserveAdapter",
    "out/ERC4626ReserveAdapter.sol/ERC4626ReserveAdapter.json",
  ],
  [
    "kernel",
    "AsyncClaimSettlement",
    "out/AsyncClaimSettlement.sol/AsyncClaimSettlement.json",
  ],
  [
    "lidoAdapter",
    "LidoWithdrawalClaimAdapter",
    "out/LidoWithdrawalClaimAdapter.sol/LidoWithdrawalClaimAdapter.json",
  ],
  [
    "lidoUnstETHExitAdapter",
    "LidoUnstETHExitAdapter",
    "out/LidoUnstETHExitAdapter.sol/LidoUnstETHExitAdapter.json",
  ],
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
const gitCommit = run("git", ["rev-parse", "HEAD"]).trim();
if (
  typeof broadcast.commit !== "string" ||
  broadcast.commit.length < 7 ||
  !gitCommit.toLowerCase().startsWith(broadcast.commit.toLowerCase())
) {
  fail(
    `broadcast commit ${String(broadcast.commit)} does not match reviewed commit ${gitCommit}`,
  );
}

const manifestContracts = {};
const creationsByName = {};
for (const [manifestName, contractName, artifactPath] of contracts) {
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
  creationsByName[contractName] = creation;
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

  const chainTransaction = JSON.parse(
    run("cast", ["tx", creation.hash, "--rpc-url", rpcUrl, "--json"]),
  );
  if (
    checksum(chainTransaction.from).toLowerCase() !== factor.toLowerCase() ||
    chainTransaction.to !== null
  ) {
    fail(`${contractName} mainnet transaction is not a creation by the reviewed factor`);
  }
  const broadcastInput = creation.transaction?.input?.toLowerCase();
  const chainInput = chainTransaction.input?.toLowerCase();
  if (
    typeof broadcastInput !== "string" ||
    typeof chainInput !== "string" ||
    broadcastInput !== chainInput
  ) {
    fail(`${contractName} broadcast creation input does not match mainnet`);
  }
  if (!existsSync(artifactPath)) {
    fail(`${contractName} local artifact is missing: ${artifactPath}`);
  }
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  const localInitCode = artifact.bytecode?.object?.toLowerCase();
  if (
    typeof localInitCode !== "string" ||
    localInitCode === "0x" ||
    !chainInput.startsWith(localInitCode)
  ) {
    fail(`${contractName} mainnet creation bytecode does not match the reviewed local artifact`);
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
  await requireVerifiedSource(address, contractName);

  manifestContracts[manifestName] = {
    address,
    runtimeCodeHash,
    deploymentTxHash: creation.hash,
    blockNumber: Number(BigInt(receipt.blockNumber)),
    sourceVerified: true,
    sourceVerificationUrl: `https://etherscan.io/address/${address}#code`,
  };
}

assertArguments("ProductiveFundingAccount", [factor]);
assertArguments("ERC4626ReserveAdapter", [
  manifestContracts.fundingAccount.address,
  "0x0bfc9d54Fc184518A81162F8fB99c2eACa081202",
  "0",
  "0",
]);
assertArguments("AsyncClaimSettlement", [
  factor,
  manifestContracts.fundingAccount.address,
]);
assertArguments("LidoWithdrawalClaimAdapter", [
  manifestContracts.kernel.address,
  "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
  "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
]);
assertArguments("LidoUnstETHExitAdapter", [
  manifestContracts.kernel.address,
  "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
  "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1",
]);

const manifest = {
  schemaVersion: 2,
  network: "ethereum-mainnet",
  chainId: 1,
  gitCommit,
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
    reserveFundingWei: "6000000000000000",
    activationMinimumCapacityWei: "5000000000000000",
    operationalMinimumPaymentWei: "498750000000000",
    minimumClaimWei: "500000000000000",
    maximumClaimWei: "5000000000000000",
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

function assertArguments(contractName, expected) {
  const creation = creationsByName[contractName];
  if (
    !creation ||
    !Array.isArray(creation.arguments) ||
    creation.arguments.length !== expected.length
  ) {
    fail(`${contractName} constructor arguments are missing or malformed`);
  }
  for (let index = 0; index < expected.length; index += 1) {
    const actualValue = String(creation.arguments[index]);
    const expectedValue = String(expected[index]);
    const actual = /^0x[0-9a-fA-F]{40}$/.test(actualValue)
      ? checksum(actualValue).toLowerCase()
      : actualValue;
    const wanted = /^0x[0-9a-fA-F]{40}$/.test(expectedValue)
      ? checksum(expectedValue).toLowerCase()
      : expectedValue;
    if (actual !== wanted) {
      fail(`${contractName} constructor argument ${index} does not match the reviewed topology`);
    }
  }
}

async function requireVerifiedSource(address, contractName) {
  const url = new URL("https://api.etherscan.io/v2/api");
  url.searchParams.set("chainid", "1");
  url.searchParams.set("module", "contract");
  url.searchParams.set("action", "getsourcecode");
  url.searchParams.set("address", address);
  url.searchParams.set("apikey", etherscanApiKey);

  let response;
  try {
    response = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  } catch {
    fail(`Etherscan source verification lookup failed for ${contractName}`);
  }
  if (!response.ok) {
    fail(`Etherscan source verification lookup returned HTTP ${response.status} for ${contractName}`);
  }
  let payload;
  try {
    payload = await response.json();
  } catch {
    fail(`Etherscan returned unreadable source metadata for ${contractName}`);
  }
  const source = payload?.result?.[0];
  if (
    payload?.status !== "1" ||
    typeof source?.SourceCode !== "string" ||
    source.SourceCode.trim() === "" ||
    typeof source?.ContractName !== "string" ||
    !source.ContractName.endsWith(contractName)
  ) {
    fail(`${contractName} is not source-verified on Etherscan`);
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
