#!/usr/bin/env node
// Reservoir quote signer — the underwriting desk as an HTTP service.
//
// Replaces the copy-paste envelope flow: the app asks this service for a
// seller-bound firm quote and receives a signed envelope it can fill directly.
//
// Security posture (deliberate, documented):
//   * binds 127.0.0.1 only; public exposure is a tunnel/proxy in front —
//     a non-loopback HOST is refused at startup unless ALLOW_NONLOCAL_BIND=1
//   * shared-secret header, constant-time compared
//   * HARD ceiling (MAX_QUOTE_WEI) independent of measured reserve capacity —
//     a signing key can never authorize more than this per quote
//   * single-flight: one outstanding unexpired quote at a time, so concurrent
//     requests cannot oversubscribe the reserve and hand a user a quote that
//     reverts at fill time. Reservations persist in SQLite across restarts
//     and are released when the kernel reports the nonce consumed on-chain.
//   * short expiry (default 120s) well inside the kernel's 15-minute bound
//   * refuses retired / mismatched deployments as a first-class readiness
//     state; fails closed on paused settlement, paused/bunker Lido, thin
//     capacity, or a chain-id mismatch
//   * every signature is appended to a structured JSONL audit log
//   * /health reports readiness, chain id, addresses, pause state, and
//     capacity — and is asserted free of secret material before it is sent
//
// The factor key lives only in this process's env. It is never returned, never
// logged, and never sent to the browser. Pricing is a fixed operator spread —
// never presented as a market or oracle price.

import { appendFile } from "node:fs/promises";
import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import {
  createPublicClient,
  encodeAbiParameters,
  getAddress,
  http as viemHttp,
  isAddress,
  keccak256,
  parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

import { assertBindSafe, assertNoSecretMaterial, verifyDeploymentConfig } from "./guards.mjs";
import { buildHealthPayload } from "./health.mjs";
import { ReservationStore } from "./reservations.mjs";

const STETH = getAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84");
const WETH = getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
const QUEUE = getAddress("0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1");

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

const HOST = process.env.HOST?.trim() || "127.0.0.1";
const PORT = Number(process.env.PORT?.trim() || "8791");

// Bind safety comes before anything else: refusing a non-loopback bind must
// not depend on the rest of the configuration being present.
for (const warning of assertBindSafe(HOST, process.env.ALLOW_NONLOCAL_BIND?.trim())) {
  console.error(warning);
}

const RPC_URL = required("ETH_RPC_URL");
const FACTOR_PRIVATE_KEY = required("FACTOR_PRIVATE_KEY");
const KERNEL = getAddress(required("KERNEL_ADDRESS"));
const LIDO_ADAPTER = getAddress(required("LIDO_ADAPTER_ADDRESS"));
const SIGNER_SECRET = required("SIGNER_SECRET");
const MAX_QUOTE_WEI = BigInt(required("MAX_QUOTE_WEI"));
const MIN_QUOTE_WEI = BigInt(process.env.MIN_QUOTE_WEI?.trim() || "1000000000000000"); // 0.001
const SPREAD_BPS = BigInt(process.env.SPREAD_BPS?.trim() || "25");
const MAX_SPREAD_BPS = BigInt(process.env.MAX_SPREAD_BPS?.trim() || "100");
const QUOTE_TTL_SECONDS = BigInt(process.env.QUOTE_TTL_SECONDS?.trim() || "120");
const MAX_STETH_SHORTFALL = BigInt(process.env.MAX_STETH_SHORTFALL_WEI?.trim() || "2");
const AUDIT_LOG = process.env.AUDIT_LOG?.trim() || "./quote-audit.jsonl";
const AQUA_PROOF_TX = process.env.AQUA_INTENT_PROOF_TX?.trim() || "";
const EXPECTED_CHAIN_ID = Number(process.env.EXPECTED_CHAIN_ID?.trim() || "1");
const DEPLOYMENT_MANIFEST = process.env.DEPLOYMENT_MANIFEST?.trim() || "";
// The reservation store defaults to living beside the audit log: both are the
// desk's durable operating record and belong in the same operator-owned dir.
const RESERVATIONS_DB =
  process.env.RESERVATIONS_DB?.trim() ||
  join(dirname(resolve(AUDIT_LOG)), "quote-reservations.sqlite");

if (SIGNER_SECRET.length < 32) throw new Error("SIGNER_SECRET must be at least 32 characters");
if (SPREAD_BPS > MAX_SPREAD_BPS) throw new Error("SPREAD_BPS exceeds MAX_SPREAD_BPS");
if (QUOTE_TTL_SECONDS > 840n) throw new Error("QUOTE_TTL_SECONDS must stay inside the kernel's 15-minute bound");
if (!Number.isInteger(EXPECTED_CHAIN_ID) || EXPECTED_CHAIN_ID <= 0) {
  throw new Error("EXPECTED_CHAIN_ID must be a positive integer");
}

const account = privateKeyToAccount(FACTOR_PRIVATE_KEY);
const client = createPublicClient({ chain: mainnet, transport: viemHttp(RPC_URL) });

// Config-level deployment verification — computed once (the inputs are process
// configuration and cannot change until restart), enforced on every request,
// and reported as the "refused" readiness state on /health.
const { refusals: configRefusals } = verifyDeploymentConfig({
  expectedChainId: EXPECTED_CHAIN_ID,
  kernel: KERNEL,
  lidoAdapter: LIDO_ADAPTER,
  rpcUrl: RPC_URL,
  manifestPath: DEPLOYMENT_MANIFEST,
});

const reservations = new ReservationStore(RESERVATIONS_DB);

const kernelAbi = parseAbi([
  "function factorSigner() view returns (address)",
  "function fundingAccount() view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool)",
  "function isSealed() view returns (bool)",
  "function isPaused() view returns (bool)",
  "function nonceUsed(uint256 nonce) view returns (bool)",
  "function nonceFloor() view returns (uint256)",
]);
const fundingAbi = parseAbi([
  "function paymentAsset() view returns (address)",
  "function availableFor(uint256 wanted) view returns (uint256)",
  "function isSealed() view returns (bool)",
]);
const stEthAbi = parseAbi([
  "function getSharesByPooledEth(uint256 amount) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
]);
const queueAbi = parseAbi([
  "function isPaused() view returns (bool)",
  "function isBunkerModeActive() view returns (bool)",
  "function unfinalizedStETH() view returns (uint256)",
  "function unfinalizedRequestNumber() view returns (uint256)",
]);

const MAX_PAYMENT_WEI = MAX_QUOTE_WEI - (MAX_QUOTE_WEI * SPREAD_BPS) / 10_000n;

const healthConfig = {
  expectedChainId: EXPECTED_CHAIN_ID,
  kernel: KERNEL,
  lidoAdapter: LIDO_ADAPTER,
  weth: WETH,
  stETH: STETH,
  queue: QUEUE,
  manifestPath: DEPLOYMENT_MANIFEST,
  factorAddress: account.address,
  spreadBps: SPREAD_BPS,
  minQuoteWei: MIN_QUOTE_WEI,
  maxQuoteWei: MAX_QUOTE_WEI,
  maxPaymentWei: MAX_PAYMENT_WEI,
  quoteTtlSeconds: QUOTE_TTL_SECONDS,
};

function redactRpc(text) {
  return typeof text === "string" ? text.split(RPC_URL).join("<rpc>") : String(text);
}

// ---- chain snapshot for /health ------------------------------------------
// /health never blocks on the RPC: it serves the latest snapshot and kicks a
// background refresh when the snapshot is stale. Quote requests always make
// their own authoritative reads.
const SNAPSHOT_TTL_MS = 5_000;
let chainSnapshot = null;
let snapshotRefresh = null;

function snapshotStale() {
  return chainSnapshot === null || Date.now() - chainSnapshot.fetchedAtMs > SNAPSHOT_TTL_MS;
}

function refreshChainSnapshot() {
  if (snapshotRefresh) return snapshotRefresh;
  snapshotRefresh = (async () => {
    const fetchedAtUnix = Math.floor(Date.now() / 1000);
    try {
      const [observedChainId, factorSigner, fundingAccount, adapterAllowed, kernelSealed, kernelPaused] =
        await Promise.all([
          client.getChainId(),
          client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "factorSigner" }),
          client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "fundingAccount" }),
          client.readContract({
            address: KERNEL,
            abi: kernelAbi,
            functionName: "isAdapterAllowed",
            args: [LIDO_ADAPTER],
          }),
          client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "isSealed" }),
          client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "isPaused" }),
        ]);
      const funding = getAddress(fundingAccount);
      const [paymentAsset, fundingSealed, capacity, queuePaused, bunkerMode] = await Promise.all([
        client.readContract({ address: funding, abi: fundingAbi, functionName: "paymentAsset" }),
        client.readContract({ address: funding, abi: fundingAbi, functionName: "isSealed" }),
        client.readContract({
          address: funding,
          abi: fundingAbi,
          functionName: "availableFor",
          args: [MAX_PAYMENT_WEI],
        }),
        client.readContract({ address: QUEUE, abi: queueAbi, functionName: "isPaused" }),
        client.readContract({ address: QUEUE, abi: queueAbi, functionName: "isBunkerModeActive" }),
      ]);
      chainSnapshot = {
        fetchedAtUnix,
        fetchedAtMs: Date.now(),
        error: false,
        observedChainId,
        factorSignerMatches: getAddress(factorSigner) === account.address,
        fundingAccount: funding,
        adapterAllowed,
        kernelSealed,
        kernelPaused,
        paymentAssetOk: getAddress(paymentAsset) === WETH,
        fundingSealed,
        capacityWei: capacity,
        queuePaused,
        bunkerMode,
      };
    } catch (error) {
      console.error(
        JSON.stringify({
          at: new Date().toISOString(),
          event: "chain_snapshot_failed",
          reason: redactRpc(error?.message ?? "unknown"),
        }),
      );
      chainSnapshot = { fetchedAtUnix, fetchedAtMs: Date.now(), error: true };
    } finally {
      snapshotRefresh = null;
    }
  })();
  return snapshotRefresh;
}

function secretMatches(supplied) {
  if (typeof supplied !== "string") return false;
  const a = Buffer.from(supplied);
  const b = Buffer.from(SIGNER_SECRET);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function audit(event) {
  const line = JSON.stringify({ at: new Date().toISOString(), ...event });
  try {
    await appendFile(AUDIT_LOG, `${line}\n`);
  } catch (error) {
    console.error("audit log write failed", error.message);
  }
  console.log(line);
}

function stringifyBody(body) {
  return JSON.stringify(body, (_, value) => (typeof value === "bigint" ? value.toString() : value));
}

function json(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store, max-age=0",
  });
  response.end(stringifyBody(body));
}

async function readJsonBody(request, limitBytes = 8192) {
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limitBytes) throw new Error("request body too large");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
}

async function buildQuote({ seller, requestedStEth }) {
  const nowSeconds = Math.floor(Date.now() / 1000);

  // First-class refusal: a retired or mismatched deployment never gets as far
  // as pricing, reads, or signing.
  if (configRefusals.length > 0) {
    const error = new Error("this deployment is refused; see /health readiness for the reasons");
    error.status = 503;
    error.code = "REFUSED_DEPLOYMENT";
    throw error;
  }

  // Sweep the reservation store before deciding single-flight: expired
  // reservations fall away, and a reservation whose nonce the kernel reports
  // consumed (the fill landed) is released instead of blocking until TTL.
  const swept = await reservations.sweep({
    nowUnix: nowSeconds,
    isNonceConsumed: (nonce) =>
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "nonceUsed", args: [nonce] }),
  });
  for (const releasedReservation of swept.released) {
    await audit({
      event: "reservation_released",
      nonce: releasedReservation.nonce.toString(),
      reason: releasedReservation.reason,
    });
  }
  if (swept.active.length > 0) {
    const error = new Error("another quote is currently outstanding; retry shortly");
    error.status = 409;
    error.code = "SINGLE_FLIGHT";
    throw error;
  }

  // Hard, config-level ceiling — independent of anything measured on chain.
  if (requestedStEth < MIN_QUOTE_WEI || requestedStEth > MAX_QUOTE_WEI) {
    const error = new Error(
      `amount must be between ${MIN_QUOTE_WEI} and ${MAX_QUOTE_WEI} wei stETH`,
    );
    error.status = 400;
    error.code = "AMOUNT_OUT_OF_BOUNDS";
    throw error;
  }
  if (seller === account.address) {
    const error = new Error("seller must differ from the factor");
    error.status = 400;
    error.code = "SELLER_IS_FACTOR";
    throw error;
  }

  const paymentAmount = requestedStEth - (requestedStEth * SPREAD_BPS) / 10_000n;
  if (paymentAmount === 0n || paymentAmount >= requestedStEth) {
    const error = new Error("computed payment is out of range");
    error.status = 500;
    error.code = "PRICING";
    throw error;
  }

  const [observedChainId, factorSigner, fundingAccount, adapterAllowed, kernelSealed, kernelPaused, nonceFloor] =
    await Promise.all([
      client.getChainId(),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "factorSigner" }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "fundingAccount" }),
      client.readContract({
        address: KERNEL,
        abi: kernelAbi,
        functionName: "isAdapterAllowed",
        args: [LIDO_ADAPTER],
      }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "isSealed" }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "isPaused" }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "nonceFloor" }),
    ]);

  if (Number(observedChainId) !== EXPECTED_CHAIN_ID) {
    const error = new Error(
      `RPC chain id ${observedChainId} does not match the configured chain id ${EXPECTED_CHAIN_ID}`,
    );
    error.status = 503;
    error.code = "CHAIN_MISMATCH";
    throw error;
  }
  if (getAddress(factorSigner) !== account.address) {
    const error = new Error("configured key is not the kernel's factor signer");
    error.status = 500;
    error.code = "SIGNER_MISMATCH";
    throw error;
  }
  if (!adapterAllowed || !kernelSealed) {
    const error = new Error("kernel is not configured for this adapter");
    error.status = 503;
    error.code = "KERNEL_NOT_READY";
    throw error;
  }
  if (kernelPaused) {
    const error = new Error("settlement is paused");
    error.status = 503;
    error.code = "SETTLEMENT_PAUSED";
    throw error;
  }

  const funding = getAddress(fundingAccount);
  const [paymentAsset, fundingSealed, capacity, queuePaused, bunkerMode, unfinalizedStEth, unfinalizedRequests] =
    await Promise.all([
      client.readContract({ address: funding, abi: fundingAbi, functionName: "paymentAsset" }),
      client.readContract({ address: funding, abi: fundingAbi, functionName: "isSealed" }),
      client.readContract({
        address: funding,
        abi: fundingAbi,
        functionName: "availableFor",
        args: [paymentAmount],
      }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "isPaused" }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "isBunkerModeActive" }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "unfinalizedStETH" }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "unfinalizedRequestNumber" }),
    ]);

  if (getAddress(paymentAsset) !== WETH || !fundingSealed) {
    const error = new Error("funding account is not the reviewed WETH reserve");
    error.status = 500;
    error.code = "FUNDING_MISCONFIGURED";
    throw error;
  }
  if (capacity !== paymentAmount) {
    const error = new Error("the productive reserve cannot currently cover this payment");
    error.status = 503;
    error.code = "INSUFFICIENT_CAPACITY";
    throw error;
  }
  if (queuePaused) {
    const error = new Error("canonical Lido withdrawals are currently paused");
    error.status = 503;
    error.code = "LIDO_PAUSED";
    throw error;
  }
  if (bunkerMode) {
    const error = new Error("firm quotes are disabled while Lido bunker mode is active");
    error.status = 503;
    error.code = "LIDO_BUNKER";
    throw error;
  }

  // Seller-side preflight, so the app never presents a quote the seller
  // provably cannot fill.
  const sellerStEth = await client.readContract({
    address: STETH,
    abi: stEthAbi,
    functionName: "balanceOf",
    args: [seller],
  });
  if (sellerStEth + MAX_STETH_SHORTFALL < requestedStEth) {
    const error = new Error("seller stETH balance is below the requested amount");
    error.status = 400;
    error.code = "SELLER_BALANCE";
    throw error;
  }

  const minAmountOfShares = await client.readContract({
    address: STETH,
    abi: stEthAbi,
    functionName: "getSharesByPooledEth",
    args: [requestedStEth - MAX_STETH_SHORTFALL],
  });

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
    [{ maxStETHShortfall: MAX_STETH_SHORTFALL, minAmountOfShares }],
  );

  const latestBlock = await client.getBlock({ blockTag: "latest" });
  const deadline = latestBlock.timestamp + QUOTE_TTL_SECONDS;
  let nonce = BigInt(`0x${randomBytes(16).toString("hex")}`);
  if (nonce < nonceFloor) nonce += nonceFloor;
  const nonceConsumed = await client.readContract({
    address: KERNEL,
    abi: kernelAbi,
    functionName: "nonceUsed",
    args: [nonce],
  });
  if (nonceConsumed) {
    const error = new Error("nonce collision; retry");
    error.status = 503;
    error.code = "NONCE_COLLISION";
    throw error;
  }

  const quote = {
    factor: account.address,
    seller,
    adapter: LIDO_ADAPTER,
    claimController: account.address,
    claimReceiver: account.address,
    paymentAsset: WETH,
    paymentAmount,
    claimDataHash: keccak256(claimData),
    boundsHash: keccak256(boundsData),
    nonce,
    deadline,
  };

  const factorSignature = await account.signTypedData({
    domain: {
      name: "Reservoir v2",
      version: "1",
      chainId: EXPECTED_CHAIN_ID,
      verifyingContract: KERNEL,
    },
    types: {
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
    },
    primaryType: "ClaimQuote",
    message: quote,
  });

  // Durable single-flight: the reservation must survive a restart, so it is
  // recorded before the envelope leaves the process.
  reservations.reserve({
    nonce,
    seller,
    requestedStEthWei: requestedStEth,
    paymentWei: paymentAmount,
    deadlineUnix: deadline,
    nowUnix: nowSeconds,
  });

  await audit({
    event: "quote_signed",
    seller,
    requestedStEth: requestedStEth.toString(),
    paymentAmount: paymentAmount.toString(),
    spreadBps: SPREAD_BPS.toString(),
    nonce: nonce.toString(),
    deadline: deadline.toString(),
    queueUnfinalizedStEthWei: unfinalizedStEth.toString(),
    queueUnfinalizedRequests: unfinalizedRequests.toString(),
  });

  return {
    version: "reservoir-v2-lido-1",
    chainId: EXPECTED_CHAIN_ID,
    kernel: KERNEL,
    quote,
    claimData,
    boundsData,
    factorSignature,
    pricing: {
      mode: "operator-priced-firm-quote",
      basis: "fixed operator spread; not a market or oracle price",
      evidenceNote:
        "informational metadata; only the EIP-712 ClaimQuote fields are factor-signed",
      grossSpreadBps: SPREAD_BPS.toString(),
      signedAtUnix: String(nowSeconds),
      queueUnfinalizedStEthWei: unfinalizedStEth.toString(),
      queueUnfinalizedRequests: unfinalizedRequests.toString(),
      ...(AQUA_PROOF_TX ? { aquaIntentProofTx: AQUA_PROOF_TX } : {}),
    },
  };
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);

  if (request.method === "GET" && url.pathname === "/health") {
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (snapshotStale()) void refreshChainSnapshot();
    const payload = buildHealthPayload({
      config: healthConfig,
      refusals: configRefusals,
      snapshot: chainSnapshot,
      activeReservations: reservations.active(nowSeconds).length,
    });
    const body = stringifyBody(payload);
    // Nothing from the environment may leak through /health: assert the exact
    // bytes about to be sent contain no secret material.
    try {
      assertNoSecretMaterial(body, [SIGNER_SECRET, FACTOR_PRIVATE_KEY, RPC_URL]);
    } catch {
      return json(response, 500, { error: "health payload failed the secret-hygiene assertion" });
    }
    response.writeHead(200, {
      "content-type": "application/json",
      "cache-control": "no-store, max-age=0",
    });
    return response.end(body);
  }

  if (request.method !== "POST" || url.pathname !== "/quote") {
    return json(response, 404, { error: "not found" });
  }

  if (!secretMatches(request.headers["x-signer-secret"])) {
    await audit({ event: "auth_rejected", path: url.pathname });
    return json(response, 401, { error: "unauthorized" });
  }

  let body;
  try {
    body = await readJsonBody(request);
  } catch {
    return json(response, 400, { error: "invalid request body" });
  }

  if (typeof body.seller !== "string" || !isAddress(body.seller)) {
    return json(response, 400, { error: "seller must be a valid address" });
  }
  if (typeof body.requestedStEth !== "string" || !/^\d+$/.test(body.requestedStEth)) {
    return json(response, 400, { error: "requestedStEth must be an unsigned integer string" });
  }

  try {
    const envelope = await buildQuote({
      seller: getAddress(body.seller),
      requestedStEth: BigInt(body.requestedStEth),
    });
    return json(response, 200, envelope);
  } catch (error) {
    const status = error.status ?? 500;
    await audit({
      event: "quote_rejected",
      code: error.code ?? "INTERNAL",
      status,
      seller: body.seller,
      requestedStEth: body.requestedStEth,
      reason: redactRpc(error.message),
    });
    // Internal errors never leak their message to the caller.
    return json(response, status, {
      error: status === 500 ? "quote service error" : error.message,
      code: error.code ?? "INTERNAL",
    });
  }
});

server.listen(PORT, HOST, async () => {
  const bound = server.address();
  console.log(
    JSON.stringify({
      at: new Date().toISOString(),
      event: "listening",
      host: HOST,
      port: bound?.port ?? PORT,
      factor: account.address,
      kernel: KERNEL,
      expectedChainId: EXPECTED_CHAIN_ID,
      deploymentManifest: DEPLOYMENT_MANIFEST || null,
      reservationsDb: RESERVATIONS_DB,
      maxQuoteWei: MAX_QUOTE_WEI.toString(),
      spreadBps: SPREAD_BPS.toString(),
      quoteTtlSeconds: QUOTE_TTL_SECONDS.toString(),
      readiness: configRefusals.length > 0 ? "refused" : "pending",
    }),
  );
  if (configRefusals.length > 0) {
    for (const refusal of configRefusals) console.error(`DEPLOYMENT REFUSED: ${refusal}`);
    await audit({ event: "deployment_refused", reasons: configRefusals });
  } else {
    // Warm the /health snapshot; quote requests do their own reads.
    void refreshChainSnapshot();
  }
});

function shutdown(signal) {
  console.log(JSON.stringify({ at: new Date().toISOString(), event: "shutdown", signal }));
  try {
    reservations.close();
  } catch {
    // the store is already closed or the process is being torn down
  }
  server.close(() => process.exit(0));
  // A reservation-holding fill in flight is on-chain state, not ours: nothing
  // here needs a grace period beyond closing the listener.
  setTimeout(() => process.exit(0), 1_000).unref();
}
process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
