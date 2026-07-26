#!/usr/bin/env node
// Reservoir quote signer — the underwriting desk as an HTTP service.
//
// Replaces the copy-paste envelope flow: the app asks this service for a
// seller-bound firm quote and receives a signed envelope it can fill directly.
//
// Security posture (deliberate, documented):
//   * binds 127.0.0.1 only; public exposure is a reverse proxy in front —
//     a non-loopback HOST is always refused at startup
//   * shared-secret header, constant-time compared
//   * every public request carries a short-lived seller signature bound to its
//     exact mode and amount/claim; public chain data alone cannot reserve funds
//   * HARD ceiling (MAX_QUOTE_WEI) independent of measured reserve capacity —
//     a signing key can never authorize more than this per quote
//   * aggregate reservations: simultaneous wallet quotes are admitted only
//     while their total payment liability fits authoritative reserve capacity.
//     A seller can explicitly replace its active envelope while preserving
//     that nonce: old and new envelopes remain mutually exclusive onchain.
//     Versioned SQLite admission prevents cross-process overcommit; rows
//     persist across restarts and release when their nonce is consumed.
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
import {
  QuoteRequestReplayGuard,
  verifyQuoteRequestAuthorization,
} from "./request-authorization.mjs";
import { ReservationStore } from "./reservations.mjs";
import { SerialExecutor } from "./serial-executor.mjs";

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
for (const warning of assertBindSafe(HOST)) {
  console.error(warning);
}

const RPC_URL = required("ETH_RPC_URL");
const FACTOR_PRIVATE_KEY = required("FACTOR_PRIVATE_KEY");
const KERNEL = getAddress(required("KERNEL_ADDRESS"));
const LIDO_ADAPTER = getAddress(required("LIDO_ADAPTER_ADDRESS"));
const LIDO_UNSTETH_ADAPTER = getAddress(required("LIDO_UNSTETH_ADAPTER_ADDRESS"));
const SIGNER_SECRET = required("SIGNER_SECRET");
const MAX_QUOTE_WEI = BigInt(required("MAX_QUOTE_WEI"));
const MIN_QUOTE_WEI = BigInt(process.env.MIN_QUOTE_WEI?.trim() || "500000000000000"); // 0.0005
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
if (MAX_SPREAD_BPS > 10_000n || SPREAD_BPS === 0n || SPREAD_BPS > MAX_SPREAD_BPS) {
  throw new Error("SPREAD_BPS must be positive, bounded, and no greater than 10,000");
}
if (MIN_QUOTE_WEI <= MAX_STETH_SHORTFALL || MAX_QUOTE_WEI < MIN_QUOTE_WEI) {
  throw new Error("quote amount bounds are invalid");
}
if (QUOTE_TTL_SECONDS === 0n || QUOTE_TTL_SECONDS > 840n) {
  throw new Error("QUOTE_TTL_SECONDS must be positive and stay inside the kernel's 15-minute bound");
}
if (!Number.isInteger(EXPECTED_CHAIN_ID) || EXPECTED_CHAIN_ID <= 0) {
  throw new Error("EXPECTED_CHAIN_ID must be a positive integer");
}
if (LIDO_ADAPTER === LIDO_UNSTETH_ADAPTER || KERNEL === LIDO_ADAPTER || KERNEL === LIDO_UNSTETH_ADAPTER) {
  throw new Error("kernel and adapter addresses must be distinct");
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
  lidoUnstETHAdapter: LIDO_UNSTETH_ADAPTER,
  manifestPath: DEPLOYMENT_MANIFEST,
});

const reservations = new ReservationStore(RESERVATIONS_DB);
const quoteExecutor = new SerialExecutor();
const quoteRequestReplayGuard = new QuoteRequestReplayGuard();

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
  "function getLastRequestId() view returns (uint256)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner, address operator) view returns (bool)",
  "function getWithdrawalStatus(uint256[] requestIds) view returns ((uint256 amountOfStETH, uint256 amountOfShares, address owner, uint256 timestamp, bool isFinalized, bool isClaimed)[] statuses)",
]);

const MAX_PAYMENT_WEI = MAX_QUOTE_WEI - (MAX_QUOTE_WEI * SPREAD_BPS) / 10_000n;

const healthConfig = {
  expectedChainId: EXPECTED_CHAIN_ID,
  kernel: KERNEL,
  lidoAdapter: LIDO_ADAPTER,
  lidoUnstETHAdapter: LIDO_UNSTETH_ADAPTER,
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
      const [
        observedChainId,
        latestBlock,
        factorSigner,
        fundingAccount,
        originationAdapterAllowed,
        unstETHAdapterAllowed,
        kernelSealed,
        kernelPaused,
      ] =
        await Promise.all([
          client.getChainId(),
          client.getBlock({ blockTag: "latest" }),
          client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "factorSigner" }),
          client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "fundingAccount" }),
          client.readContract({
            address: KERNEL,
            abi: kernelAbi,
            functionName: "isAdapterAllowed",
            args: [LIDO_ADAPTER],
          }),
          client.readContract({
            address: KERNEL,
            abi: kernelAbi,
            functionName: "isAdapterAllowed",
            args: [LIDO_UNSTETH_ADAPTER],
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
        chainTimeUnix: Number(latestBlock.timestamp),
        factorSignerMatches: getAddress(factorSigner) === account.address,
        fundingAccount: funding,
        originationAdapterAllowed,
        unstETHAdapterAllowed,
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

// Authentication failures originate at the public edge and are untrusted
// volume. Never append one durable audit record per rejected request: doing so
// would let an unauthenticated scanner consume the service disk. Summarize at
// most once per minute to journald, whose own retention is bounded. Signed
// quotes and authenticated quote refusals remain durably audited.
const AUTH_REJECTION_WINDOW_MS = 60_000;
let authRejectionWindowStartedAt = Date.now();
let authRejectionCount = 0;

function recordAuthRejection() {
  authRejectionCount += 1;
  const now = Date.now();
  if (now - authRejectionWindowStartedAt < AUTH_REJECTION_WINDOW_MS) return;

  console.warn(
    JSON.stringify({
      at: new Date(now).toISOString(),
      event: "auth_rejected_summary",
      count: authRejectionCount,
      windowMs: now - authRejectionWindowStartedAt,
    }),
  );
  authRejectionWindowStartedAt = now;
  authRejectionCount = 0;
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

function quoteError(message, status, code, details = {}) {
  const error = new Error(message);
  error.status = status;
  error.code = code;
  error.details = details;
  return error;
}

function requireAmountBounds(amount) {
  if (amount < MIN_QUOTE_WEI || amount > MAX_QUOTE_WEI) {
    throw quoteError(
      `claim amount must be between ${MIN_QUOTE_WEI} and ${MAX_QUOTE_WEI} wei stETH`,
      400,
      "AMOUNT_OUT_OF_BOUNDS",
    );
  }
}

function retryMetadata(active, nowSeconds) {
  if (active.length === 0) return {};
  const earliest = active.reduce((left, right) =>
    left.deadlineUnix <= right.deadlineUnix ? left : right,
  );
  return {
    retryAfterSeconds: Number(
      earliest.deadlineUnix > BigInt(nowSeconds)
        ? earliest.deadlineUnix - BigInt(nowSeconds)
        : 0n,
    ),
    activeDeadlineUnix: earliest.deadlineUnix.toString(),
  };
}

async function buildQuote(
  { seller, mode, requestedStEth, requestId, replaceNonce },
  reservationAttempt = 0,
) {
  // First-class refusal: a retired or mismatched deployment never gets as far
  // as pricing, reads, or signing.
  if (configRefusals.length > 0) {
    throw quoteError(
      "this deployment is refused; see /health readiness for the reasons",
      503,
      "REFUSED_DEPLOYMENT",
    );
  }
  // Quote validity is defined by block.timestamp, so reservation expiry must
  // use the same clock. This also keeps fork rehearsals honest when the forked
  // block is older than the host's wall clock.
  const latestBlock = await client.getBlock({ blockTag: "latest" });
  const nowSeconds = Number(latestBlock.timestamp);

  // Sweep before capacity accounting: expired rows fall away, and a
  // reservation whose nonce the kernel reports consumed is no longer a live
  // liability.
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
  let activeReservations = swept.active;
  let reservationVersion = swept.version;
  let replacement = null;
  if (activeReservations.length > 0) {
    const recovered = reservations.recover({
      nowUnix: nowSeconds,
      seller,
      mode,
      requestId: requestId ?? null,
      claimAmountWei: requestedStEth ?? null,
    });
    if (recovered !== null && replaceNonce === undefined) {
      const recoveredNonce = BigInt(recovered.quote.nonce);
      const active = activeReservations.find((row) => row.nonce === recoveredNonce);
      await audit({
        event: "quote_reused",
        mode,
        seller,
        requestId: requestId?.toString() ?? null,
        nonce: recoveredNonce.toString(),
        deadline: active?.deadlineUnix.toString() ?? recovered.quote.deadline.toString(),
      });
      return recovered;
    }

  }
  if (replaceNonce !== undefined) {
    replacement = activeReservations.find((row) => row.nonce === replaceNonce) ?? null;
    const staleOwnedReplacement =
      replacement === null &&
      reservations.isReleasedForSeller(replaceNonce, seller);
    if (
      (replacement !== null && replacement.seller !== seller) ||
      (replacement === null && !staleOwnedReplacement)
    ) {
      throw quoteError(
        "the active quote does not match this seller and replacement nonce",
        409,
        "REPLACEMENT_MISMATCH",
        retryMetadata(activeReservations, nowSeconds),
      );
    }
  }

  if (seller === account.address) {
    throw quoteError("seller must differ from the factor", 400, "SELLER_IS_FACTOR");
  }

  if (mode !== "originate" && mode !== "existing-unsteth") {
    throw quoteError("mode must be originate or existing-unsteth", 400, "INVALID_MODE");
  }
  const adapter = mode === "originate" ? LIDO_ADAPTER : LIDO_UNSTETH_ADAPTER;

  const [observedChainId, factorSigner, fundingAccount, adapterAllowed, kernelSealed, kernelPaused, nonceFloor] =
    await Promise.all([
      client.getChainId(),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "factorSigner" }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "fundingAccount" }),
      client.readContract({
        address: KERNEL,
        abi: kernelAbi,
        functionName: "isAdapterAllowed",
        args: [adapter],
      }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "isSealed" }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "isPaused" }),
      client.readContract({ address: KERNEL, abi: kernelAbi, functionName: "nonceFloor" }),
    ]);

  if (Number(observedChainId) !== EXPECTED_CHAIN_ID) {
    throw quoteError(
      `RPC chain id ${observedChainId} does not match the configured chain id ${EXPECTED_CHAIN_ID}`,
      503,
      "CHAIN_MISMATCH",
    );
  }
  if (getAddress(factorSigner) !== account.address) {
    throw quoteError("configured key is not the kernel's factor signer", 500, "SIGNER_MISMATCH");
  }
  if (!adapterAllowed || !kernelSealed) {
    throw quoteError("kernel is not configured for this adapter", 503, "KERNEL_NOT_READY");
  }
  if (kernelPaused) {
    throw quoteError("settlement is paused", 503, "SETTLEMENT_PAUSED");
  }

  let claimAmount;
  let claimData;
  let boundsData;
  let approval;
  let claimMetadata;

  if (mode === "originate") {
    if (typeof requestedStEth !== "bigint") {
      throw quoteError("requestedStEth is required for originate mode", 400, "INVALID_AMOUNT");
    }
    requireAmountBounds(requestedStEth);
    claimAmount = requestedStEth;

    const sellerStEth = await client.readContract({
      address: STETH,
      abi: stEthAbi,
      functionName: "balanceOf",
      args: [seller],
    });
    if (sellerStEth + MAX_STETH_SHORTFALL < requestedStEth) {
      throw quoteError(
        "seller stETH balance is below the requested amount",
        400,
        "SELLER_BALANCE",
      );
    }

    const minAmountOfShares = await client.readContract({
      address: STETH,
      abi: stEthAbi,
      functionName: "getSharesByPooledEth",
      args: [requestedStEth - MAX_STETH_SHORTFALL],
    });

    claimData = encodeAbiParameters(
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
    boundsData = encodeAbiParameters(
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
    approval = {
      kind: "erc20",
      token: STETH,
      spender: adapter,
      amountWei: requestedStEth.toString(),
    };
    claimMetadata = {
      requestedStEthWei: requestedStEth.toString(),
      minAmountOfShares: minAmountOfShares.toString(),
    };
  } else {
    if (typeof requestId !== "bigint" || requestId <= 0n) {
      throw quoteError(
        "requestId must be a non-zero unsigned integer for existing-unsteth mode",
        400,
        "INVALID_REQUEST_ID",
      );
    }
    const lastRequestId = await client.readContract({
      address: QUEUE,
      abi: queueAbi,
      functionName: "getLastRequestId",
    });
    if (requestId > lastRequestId) {
      throw quoteError("the Lido request does not exist", 400, "INVALID_REQUEST_ID");
    }

    const statuses = await client.readContract({
      address: QUEUE,
      abi: queueAbi,
      functionName: "getWithdrawalStatus",
      args: [[requestId]],
    });
    if (statuses.length !== 1) {
      throw quoteError("Lido returned an invalid request status", 503, "INVALID_LIDO_STATUS");
    }
    const status = statuses[0];
    if (status.isClaimed) {
      throw quoteError("the Lido request has already been claimed", 400, "CLAIM_ALREADY_CLAIMED");
    }
    if (status.amountOfShares === 0n) {
      throw quoteError("the Lido request has no claim shares", 400, "EMPTY_CLAIM");
    }
    if (getAddress(status.owner) !== seller) {
      throw quoteError("the connected seller does not own this Lido request", 400, "CLAIM_NOT_OWNED");
    }
    const erc721Owner = getAddress(
      await client.readContract({
        address: QUEUE,
        abi: queueAbi,
        functionName: "ownerOf",
        args: [requestId],
      }),
    );
    if (erc721Owner !== seller) {
      throw quoteError("the connected seller does not own this unstETH NFT", 400, "CLAIM_NOT_OWNED");
    }

    requireAmountBounds(status.amountOfStETH);
    claimAmount = status.amountOfStETH;
    const [approved, approvedForAll] = await Promise.all([
      client.readContract({
        address: QUEUE,
        abi: queueAbi,
        functionName: "getApproved",
        args: [requestId],
      }),
      client.readContract({
        address: QUEUE,
        abi: queueAbi,
        functionName: "isApprovedForAll",
        args: [seller, adapter],
      }),
    ]);

    claimData = encodeAbiParameters(
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
      [{ queue: QUEUE, stETH: STETH, requestId }],
    );
    boundsData = encodeAbiParameters(
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
      [
        {
          minAmountOfStETH: status.amountOfStETH,
          maxAmountOfStETH: status.amountOfStETH,
          minAmountOfShares: status.amountOfShares,
          maxAmountOfShares: status.amountOfShares,
        },
      ],
    );
    approval = {
      kind: "erc721",
      token: QUEUE,
      spender: adapter,
      tokenId: requestId.toString(),
      alreadyApproved: getAddress(approved) === adapter || approvedForAll,
    };
    claimMetadata = {
      requestId: requestId.toString(),
      amountOfStEthWei: status.amountOfStETH.toString(),
      amountOfShares: status.amountOfShares.toString(),
      isFinalizedAtSigning: status.isFinalized,
      stateBinding:
        "finalization state is informational and not signed; the exact amount/share bounds survive pending-to-finalized maturation",
    };
  }

  const paymentAmount = claimAmount - (claimAmount * SPREAD_BPS) / 10_000n;
  if (paymentAmount === 0n || paymentAmount >= claimAmount) {
    throw quoteError("computed payment is out of range", 500, "PRICING");
  }

  const activeReservedWei = activeReservations.reduce(
    (total, row) =>
      replacement !== null && row.nonce === replacement.nonce
        ? total
        : total + row.paymentWei,
    0n,
  );
  const totalLiabilityWei = activeReservedWei + paymentAmount;
  const funding = getAddress(fundingAccount);
  const [paymentAsset, fundingSealed, capacity, queuePaused, bunkerMode, unfinalizedStEth, unfinalizedRequests] =
    await Promise.all([
      client.readContract({ address: funding, abi: fundingAbi, functionName: "paymentAsset" }),
      client.readContract({ address: funding, abi: fundingAbi, functionName: "isSealed" }),
      client.readContract({
        address: funding,
        abi: fundingAbi,
        functionName: "availableFor",
        args: [totalLiabilityWei],
      }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "isPaused" }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "isBunkerModeActive" }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "unfinalizedStETH" }),
      client.readContract({ address: QUEUE, abi: queueAbi, functionName: "unfinalizedRequestNumber" }),
    ]);

  if (getAddress(paymentAsset) !== WETH || !fundingSealed) {
    throw quoteError(
      "funding account is not the reviewed WETH reserve",
      500,
      "FUNDING_MISCONFIGURED",
    );
  }
  if (capacity !== totalLiabilityWei) {
    const details = {
      ...retryMetadata(activeReservations, nowSeconds),
      canReplace: activeReservations.some((row) => row.seller === seller),
      availableCapacityWei: capacity.toString(),
      activeReservedWei: activeReservedWei.toString(),
      requestedPaymentWei: paymentAmount.toString(),
      totalLiabilityWei: totalLiabilityWei.toString(),
    };
    if (capacity >= paymentAmount && activeReservedWei > 0n) {
      throw quoteError(
        "productive reserve capacity is reserved by other live quotes",
        409,
        "RESERVE_CAPACITY_RESERVED",
        details,
      );
    }
    throw quoteError(
      "the productive reserve cannot currently cover this payment",
      503,
      "INSUFFICIENT_CAPACITY",
      details,
    );
  }
  if (queuePaused) {
    throw quoteError("canonical Lido withdrawals are currently paused", 503, "LIDO_PAUSED");
  }
  if (bunkerMode) {
    throw quoteError(
      "firm quotes are disabled while Lido bunker mode is active",
      503,
      "LIDO_BUNKER",
    );
  }

  if (replacement !== null && replacement.nonce < nonceFloor) {
    // Raising the factor's nonce floor already invalidated every old envelope
    // sharing this nonce. Release the stale row and create an independent
    // fresh nonce instead of preserving a nonce the kernel will reject.
    reservations.release(replacement.nonce, "below-nonce-floor", nowSeconds);
    await audit({
      event: "reservation_released",
      nonce: replacement.nonce.toString(),
      reason: "below-nonce-floor",
    });
    replacement = null;
    activeReservations = activeReservations.filter(
      (row) => row.nonce !== replaceNonce,
    );
    reservationVersion = reservations.version();
  }

  const deadline = latestBlock.timestamp + QUOTE_TTL_SECONDS;
  let nonce;
  if (replacement !== null) {
    nonce = replacement.nonce;
  } else {
    nonce = BigInt(`0x${randomBytes(16).toString("hex")}`);
    if (nonce < nonceFloor) nonce += nonceFloor;
    const nonceConsumed = await client.readContract({
      address: KERNEL,
      abi: kernelAbi,
      functionName: "nonceUsed",
      args: [nonce],
    });
    if (nonceConsumed) {
      throw quoteError("nonce collision; retry", 503, "NONCE_COLLISION");
    }
  }

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

  const envelope = {
    version: "reservoir-v2-lido-1",
    mode,
    chainId: EXPECTED_CHAIN_ID,
    kernel: KERNEL,
    quote,
    claimData,
    boundsData,
    factorSignature,
    approval,
    claim: claimMetadata,
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

  // Durable aggregate reservation: the signed response survives a restart,
  // and the versioned SQLite commit prevents a second signer process from
  // admitting liability against the same capacity snapshot.
  const reservation = {
    nonce,
    seller,
    mode,
    requestId: requestId ?? null,
    claimAmountWei: claimAmount,
    paymentWei: paymentAmount,
    envelope,
    deadlineUnix: deadline,
    nowUnix: nowSeconds,
  };
  const admission = reservations.reserveWithinCapacity({
    reservation,
    expectedVersion: reservationVersion,
    capacityWei: capacity,
    nowUnix: nowSeconds,
    replaceNonce: replacement?.nonce ?? null,
  });
  if (admission.status === "race" && reservationAttempt < 2) {
    // A separate signer process changed durable liabilities during our chain
    // reads. Discard this unreturned signature and recompute from fresh chain
    // and SQLite state.
    return buildQuote(
      { seller, mode, requestedStEth, requestId, replaceNonce },
      reservationAttempt + 1,
    );
  }
  if (admission.status === "capacity") {
    throw quoteError(
      "productive reserve capacity changed while quoting; retry",
      409,
      "RESERVE_CAPACITY_RESERVED",
      {
        ...retryMetadata(reservations.active(nowSeconds), nowSeconds),
        canReplace: reservations
          .active(nowSeconds)
          .some((row) => row.seller === seller),
        availableCapacityWei: capacity.toString(),
        activeReservedWei: admission.activeReservedWei.toString(),
        requestedPaymentWei: paymentAmount.toString(),
        totalLiabilityWei: admission.totalLiabilityWei.toString(),
      },
    );
  }
  if (admission.status !== "reserved") {
    throw quoteError(
      "the active quote changed while it was being replaced; retry",
      409,
      admission.status === "replacement-mismatch"
        ? "REPLACEMENT_MISMATCH"
        : "RESERVATION_RACE",
    );
  }

  await audit({
    event: replacement === null ? "quote_signed" : "quote_replaced",
    mode,
    seller,
    requestId: requestId?.toString() ?? null,
    claimAmountWei: claimAmount.toString(),
    paymentAmount: paymentAmount.toString(),
    spreadBps: SPREAD_BPS.toString(),
    nonce: nonce.toString(),
    deadline: deadline.toString(),
    previousDeadline: replacement?.deadlineUnix.toString() ?? null,
    queueUnfinalizedStEthWei: unfinalizedStEth.toString(),
    queueUnfinalizedRequests: unfinalizedRequests.toString(),
  });

  return envelope;
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);

  if (request.method === "GET" && url.pathname === "/health") {
    const nowSeconds = chainSnapshot?.chainTimeUnix ?? Math.floor(Date.now() / 1000);
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
    recordAuthRejection();
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
  if (body.mode !== "originate" && body.mode !== "existing-unsteth") {
    return json(response, 400, { error: "mode must be originate or existing-unsteth" });
  }
  if (
    body.mode === "originate"
    && (typeof body.requestedStEth !== "string" || !/^\d+$/.test(body.requestedStEth))
  ) {
    return json(response, 400, { error: "requestedStEth must be an unsigned integer string" });
  }
  if (
    body.mode === "existing-unsteth"
    && (typeof body.requestId !== "string" || !/^[1-9]\d*$/.test(body.requestId))
  ) {
    return json(response, 400, { error: "requestId must be a non-zero unsigned integer string" });
  }
  if (
    body.replaceNonce !== undefined
    && (typeof body.replaceNonce !== "string" || !/^\d+$/.test(body.replaceNonce))
  ) {
    return json(response, 400, {
      error: "replaceNonce must be an unsigned integer string",
      code: "INVALID_REPLACEMENT_NONCE",
    });
  }

  try {
    if (configRefusals.length > 0) {
      throw quoteError(
        "this deployment is refused; see /health readiness for the reasons",
        503,
        "REFUSED_DEPLOYMENT",
      );
    }
    await verifyQuoteRequestAuthorization({
      authorization: body.authorization,
      authorizationSignature: body.authorizationSignature,
      request: {
        seller: body.seller,
        mode: body.mode,
        ...(body.mode === "originate"
          ? { requestedStEth: body.requestedStEth }
          : { requestId: body.requestId }),
      },
      nowSeconds: Math.floor(Date.now() / 1_000),
      replayGuard: quoteRequestReplayGuard,
    });
    // Serialize the complete sweep -> validate -> sign -> durable-reserve
    // sequence. Node may accept several requests concurrently; without this
    // critical section, two requests could both observe an empty reservation
    // set before either inserted its row.
    const envelope = await quoteExecutor.run(() =>
      buildQuote({
        seller: getAddress(body.seller),
        mode: body.mode,
        requestedStEth: body.mode === "originate" ? BigInt(body.requestedStEth) : undefined,
        requestId: body.mode === "existing-unsteth" ? BigInt(body.requestId) : undefined,
        replaceNonce: body.replaceNonce === undefined ? undefined : BigInt(body.replaceNonce),
      }),
    );
    return json(response, 200, envelope);
  } catch (error) {
    const status = error.status ?? 500;
    await audit({
      event: "quote_rejected",
      code: error.code ?? "INTERNAL",
      status,
      mode: body.mode,
      seller: body.seller,
      requestedStEth: body.requestedStEth ?? null,
      requestId: body.requestId ?? null,
      reason: redactRpc(error.message),
    });
    // Internal errors never leak their message to the caller.
    return json(response, status, {
      error: status === 500 ? "quote service error" : error.message,
      code: error.code ?? "INTERNAL",
      ...(status === 500 ? {} : error.details),
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
