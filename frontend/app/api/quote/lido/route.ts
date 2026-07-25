import { formatEther, isAddress } from "viem";

import { ADDRESSES, MAX_LIDO_REQUEST } from "../../../../lib/ethereum";
import {
  MIN_LIVE_LIDO_QUOTE,
  type LidoQuoteResponse,
} from "../../../../lib/lido-quote";
import {
  underwriteLidoExit,
  type QuotePolicy,
} from "../../../../lib/quote-policy";

export const dynamic = "force-dynamic";

const COW_QUOTE_URL = "https://api.cow.fi/mainnet/api/v1/quote";
const LIDO_WAIT_URL = "https://wq-api.lido.fi/v2/request-time/calculate";
const MAX_WAIT_MS = 365 * 24 * 60 * 60 * 1_000;

type CowResponse = {
  quote?: {
    buyAmount?: unknown;
    gasPrice?: unknown;
    validTo?: unknown;
  };
  expiration?: unknown;
};

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

function readUnsignedPolicy(name: string, fallback: number, maximum: number) {
  const raw = process.env[name]?.trim() || String(fallback);
  if (!/^\d+$/.test(raw)) throw new Error("invalid quote policy");
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
    throw new Error("invalid quote policy");
  }
  return value;
}

function quotePolicy(): QuotePolicy {
  return {
    fundingAprBps: readUnsignedPolicy(
      "LIDO_FUNDING_APR_BPS",
      1_000,
      10_000,
    ),
    riskBps: readUnsignedPolicy("LIDO_RISK_BPS", 15, 10_000),
    userEdgeShareBps: readUnsignedPolicy(
      "LIDO_USER_EDGE_SHARE_BPS",
      5_000,
      10_000,
    ),
    claimGasUnits: readUnsignedPolicy(
      "LIDO_CLAIM_GAS_UNITS",
      120_000,
      1_000_000,
    ),
  };
}

function unsigned(value: unknown, name: string) {
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    throw new Error(`invalid ${name}`);
  }
  return BigInt(value);
}

async function fetchLiveMarket(
  seller: string,
  requestedStEth: bigint,
  signal: AbortSignal,
) {
  const [cowResponse, lidoResponse] = await Promise.all([
    fetch(COW_QUOTE_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        kind: "sell",
        sellToken: ADDRESSES.stEth,
        buyToken: ADDRESSES.weth,
        sellAmountBeforeFee: requestedStEth.toString(),
        from: seller,
        receiver: seller,
        validFor: 300,
        signingScheme: "eip712",
        priceQuality: "optimal",
      }),
      cache: "no-store",
      signal,
    }),
    fetch(`${LIDO_WAIT_URL}?amount=${formatEther(requestedStEth)}`, {
      cache: "no-store",
      signal,
    }),
  ]);
  if (!cowResponse.ok || !lidoResponse.ok) {
    throw new Error("live market source unavailable");
  }

  const cow = (await cowResponse.json()) as CowResponse;
  const lido = (await lidoResponse.json()) as LidoWaitResponse;
  const cowBuyAmount = unsigned(cow.quote?.buyAmount, "CoW buy amount");
  const gasPriceWei = unsigned(cow.quote?.gasPrice, "CoW gas price");
  const estimatedWaitMs = lido.requestInfo?.finalizationIn;
  if (
    lido.status !== "calculated" ||
    typeof estimatedWaitMs !== "number" ||
    !Number.isSafeInteger(estimatedWaitMs) ||
    estimatedWaitMs < 0 ||
    estimatedWaitMs > MAX_WAIT_MS
  ) {
    throw new Error("invalid Lido wait estimate");
  }
  const expiration = Date.parse(String(cow.expiration));
  if (!Number.isFinite(expiration)) {
    throw new Error("invalid CoW quote expiration");
  }
  return {
    cowBuyAmount,
    gasPriceWei,
    estimatedWaitMs,
    expiresAt: Math.floor(expiration / 1_000),
  };
}

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as {
      seller?: unknown;
      requestedStEth?: unknown;
    };
    if (typeof body.seller !== "string" || !isAddress(body.seller)) {
      return json({ error: "Connect a valid Ethereum wallet" }, 400);
    }
    if (
      typeof body.requestedStEth !== "string" ||
      !/^\d+$/.test(body.requestedStEth)
    ) {
      return json({ error: "Enter a valid stETH amount" }, 400);
    }

    const requestedStEth = BigInt(body.requestedStEth);
    if (
      requestedStEth < MIN_LIVE_LIDO_QUOTE ||
      requestedStEth > MAX_LIDO_REQUEST
    ) {
      return json(
        { error: "Live quotes support 0.001 to 1,000 stETH" },
        400,
      );
    }

    const market = await fetchLiveMarket(
      body.seller,
      requestedStEth,
      AbortSignal.timeout(10_000),
    );
    const underwritten = underwriteLidoExit({
      requestedStEth,
      cowBuyAmount: market.cowBuyAmount,
      estimatedWaitMs: BigInt(market.estimatedWaitMs),
      gasPriceWei: market.gasPriceWei,
      policy: quotePolicy(),
    });
    const recommendedRoute = underwritten.reservoirAvailable
      ? "reservoir"
      : "cow";
    const paymentAmount =
      underwritten.reservoirPaymentAmount ?? market.cowBuyAmount;
    const discountBps =
      paymentAmount >= requestedStEth
        ? 0
        : Number(
            ((requestedStEth - paymentAmount) * 10_000n) / requestedStEth,
          );

    return json({
      kind: "market",
      market: "lido",
      requestedStEth: requestedStEth.toString(),
      paymentAmount: paymentAmount.toString(),
      paymentAsset: "WETH",
      discountBps,
      recommendedRoute,
      cowPaymentAmount: market.cowBuyAmount.toString(),
      reservoirPaymentAmount:
        underwritten.reservoirPaymentAmount?.toString() ?? null,
      underwritingCap: underwritten.underwritingCap.toString(),
      estimatedWaitMs: market.estimatedWaitMs,
      fundingCost: underwritten.fundingCost.toString(),
      riskCost: underwritten.riskCost.toString(),
      claimGasCost: underwritten.claimGasCost.toString(),
      userImprovement: underwritten.userImprovement.toString(),
      source: "cow-live+lido-live",
      sourceTimestamp: new Date().toISOString(),
      expiresAt: market.expiresAt,
      envelope: null,
    });
  } catch {
    // Never expose infrastructure details, upstream URLs, or internal error
    // messages through this public endpoint.
    return json({ error: "Live CoW/Lido pricing is temporarily unavailable" }, 503);
  }
}
