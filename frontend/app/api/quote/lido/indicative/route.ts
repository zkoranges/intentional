import { formatEther } from "viem";

import { MAX_LIDO_REQUEST } from "../../../../../lib/ethereum";
import {
  MIN_LIVE_LIDO_QUOTE,
  type LidoQuoteResponse,
  type LidoQuoteSource,
} from "../../../../../lib/lido-quote";

export const dynamic = "force-dynamic";

const LIDO_WAIT_URL = "https://wq-api.lido.fi/v2/request-time/calculate";
const DEFAULT_WAIT_MS = 7 * 24 * 60 * 60 * 1_000;
const MAX_WAIT_MS = 365 * 24 * 60 * 60 * 1_000;
const YEAR_MS = 365 * 24 * 60 * 60 * 1_000;

// Fixed operator policy, never a market price: a 10% APR funding assumption,
// a 20 bps risk-and-operations fee, and a 500 bps overall cap.
const FUNDING_APR_BPS = 1_000;
const RISK_AND_OPERATIONS_BPS = 20;
const MAX_DISCOUNT_BPS = 500;

// The estimate quotes WETH against stETH one-for-one. No depeg is priced.
const PEG_ASSUMPTION =
  "stETH:WETH is assumed 1:1; no depeg risk is priced into this estimate";

type LidoWaitResponse = {
  status?: unknown;
  requestInfo?: {
    finalizationIn?: unknown;
  };
};

function json(body: LidoQuoteResponse | { error: string }, status = 200) {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store, max-age=0",
    },
  });
}

async function waitEstimate(requestedStEth: bigint) {
  try {
    const response = await fetch(
      `${LIDO_WAIT_URL}?amount=${formatEther(requestedStEth)}`,
      {
        headers: { accept: "application/json" },
        cache: "no-store",
        signal: AbortSignal.timeout(5_000),
      },
    );
    if (!response.ok) throw new Error("Lido wait estimate unavailable");

    const result = (await response.json()) as LidoWaitResponse;
    const estimatedWaitMs = result.requestInfo?.finalizationIn;
    if (
      result.status !== "calculated" ||
      typeof estimatedWaitMs !== "number" ||
      !Number.isSafeInteger(estimatedWaitMs) ||
      estimatedWaitMs < 0 ||
      estimatedWaitMs > MAX_WAIT_MS
    ) {
      throw new Error("Invalid Lido wait estimate");
    }
    return {
      estimatedWaitMs,
      source: "reservoir-indicative+lido-live" as LidoQuoteSource,
    };
  } catch {
    return {
      estimatedWaitMs: DEFAULT_WAIT_MS,
      source: "reservoir-indicative+lido-fallback" as LidoQuoteSource,
    };
  }
}

export async function POST(request: Request) {
  let requestedStEth: bigint;
  try {
    const body = (await request.json()) as {
      requestedStEth?: unknown;
    };
    if (
      typeof body.requestedStEth !== "string" ||
      !/^\d+$/.test(body.requestedStEth)
    ) {
      return json({ error: "Enter a valid stETH amount" }, 400);
    }
    requestedStEth = BigInt(body.requestedStEth);
    if (
      requestedStEth < MIN_LIVE_LIDO_QUOTE ||
      requestedStEth > MAX_LIDO_REQUEST
    ) {
      return json(
        { error: "Indicative quotes support 0.001 to 1,000 stETH" },
        400,
      );
    }
  } catch {
    return json({ error: "Enter a valid quote request" }, 400);
  }

  const { estimatedWaitMs, source } = await waitEstimate(requestedStEth);
  const fundingBps = Math.ceil(
    (FUNDING_APR_BPS * estimatedWaitMs) / YEAR_MS,
  );
  const discountBps = Math.min(
    MAX_DISCOUNT_BPS,
    Math.max(RISK_AND_OPERATIONS_BPS, fundingBps + RISK_AND_OPERATIONS_BPS),
  );
  const paymentAmount =
    (requestedStEth * BigInt(10_000 - discountBps)) / 10_000n;
  const fundingCost = (requestedStEth * BigInt(fundingBps)) / 10_000n;
  const riskCost =
    (requestedStEth * BigInt(RISK_AND_OPERATIONS_BPS)) / 10_000n;

  // Firm quotes require the operator desk. Derived server-side: with no
  // SIGNER_URL configured, the firm proxy fails closed, so report the firm
  // path unavailable rather than implying a fillable market.
  const firmQuoteAvailability =
    process.env.SIGNER_URL?.trim() && process.env.SIGNER_SECRET?.trim()
      ? ("available" as const)
      : ("unavailable" as const);

  return json({
    kind: "market",
    market: "lido",
    requestedStEth: requestedStEth.toString(),
    paymentAmount: paymentAmount.toString(),
    paymentAsset: "WETH",
    discountBps,
    estimatedWaitMs,
    fundingCost: fundingCost.toString(),
    riskCost: riskCost.toString(),
    policy: {
      label: "fixed-policy",
      fundingAprBps: FUNDING_APR_BPS,
      riskAndOperationsBps: RISK_AND_OPERATIONS_BPS,
      maxDiscountBps: MAX_DISCOUNT_BPS,
    },
    pegAssumption: PEG_ASSUMPTION,
    firmQuoteAvailability,
    source,
    sourceTimestamp: new Date().toISOString(),
  });
}
