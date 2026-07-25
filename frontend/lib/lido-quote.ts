import { formatEther, isAddress, parseEther } from "viem";

export const MIN_LIVE_LIDO_QUOTE = parseEther("0.001");

export type LidoQuoteKind = "market" | "firm";

export type LidoQuoteResponse = {
  kind: LidoQuoteKind;
  market: "lido";
  requestedStEth: string;
  paymentAmount: string;
  paymentAsset: "WETH";
  discountBps: number;
  recommendedRoute: "cow" | "reservoir";
  cowPaymentAmount: string;
  reservoirPaymentAmount: string | null;
  underwritingCap: string;
  estimatedWaitMs: number;
  fundingCost: string;
  riskCost: string;
  claimGasCost: string;
  userImprovement: string;
  source: "cow-live+lido-live";
  sourceTimestamp: string;
  expiresAt: number | null;
  envelope: Record<string, unknown> | null;
};

export type LidoQuoteError = {
  error: string;
};

export function formatQuoteAmount(value: string) {
  const amount = Number(formatEther(BigInt(value)));
  if (!Number.isFinite(amount)) return "0.00";
  return amount.toLocaleString("en", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 6,
  });
}

export async function requestLidoQuote(
  seller: string,
  amount: string,
  signal?: AbortSignal,
): Promise<LidoQuoteResponse> {
  if (!isAddress(seller)) throw new Error("Connect a valid Ethereum wallet");

  let requestedStEth: bigint;
  try {
    requestedStEth = parseEther(amount || "0");
  } catch {
    throw new Error("Enter a valid stETH amount");
  }

  const response = await fetch("/api/quote/lido", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      seller,
      requestedStEth: requestedStEth.toString(),
    }),
    cache: "no-store",
    signal,
  });
  const result = (await response.json()) as LidoQuoteResponse | LidoQuoteError;
  if (!response.ok || "error" in result) {
    throw new Error(
      "error" in result ? result.error : "The Lido quote service is unavailable",
    );
  }
  if (
    result.market !== "lido" ||
    result.requestedStEth !== requestedStEth.toString() ||
    !/^\d+$/.test(result.paymentAmount) ||
    !/^\d+$/.test(result.cowPaymentAmount) ||
    !["cow", "reservoir"].includes(result.recommendedRoute) ||
    result.source !== "cow-live+lido-live"
  ) {
    throw new Error("The quote service returned an invalid Lido quote");
  }
  return result;
}
