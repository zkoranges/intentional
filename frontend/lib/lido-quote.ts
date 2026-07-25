import { formatEther, parseEther } from "viem";

export const MIN_LIVE_LIDO_QUOTE = parseEther("0.001");

export type LidoQuoteSource =
  | "reservoir-indicative+lido-live"
  | "reservoir-indicative+lido-fallback";

export type LidoQuotePolicy = {
  label: "fixed-policy";
  fundingAprBps: number;
  riskAndOperationsBps: number;
  maxDiscountBps: number;
};

export type LidoQuoteResponse = {
  kind: "market";
  market: "lido";
  requestedStEth: string;
  paymentAmount: string;
  paymentAsset: "WETH";
  discountBps: number;
  estimatedWaitMs: number;
  fundingCost: string;
  riskCost: string;
  policy: LidoQuotePolicy;
  pegAssumption: string;
  firmQuoteAvailability: "available" | "unavailable";
  source: LidoQuoteSource;
  sourceTimestamp: string;
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
  amount: string,
  signal?: AbortSignal,
): Promise<LidoQuoteResponse> {
  let requestedStEth: bigint;
  try {
    requestedStEth = parseEther(amount || "0");
  } catch {
    throw new Error("Enter a valid stETH amount");
  }

  const response = await fetch("/api/quote/lido/indicative", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
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
    result.kind !== "market" ||
    result.market !== "lido" ||
    result.requestedStEth !== requestedStEth.toString() ||
    !/^\d+$/.test(result.paymentAmount) ||
    typeof result.discountBps !== "number" ||
    typeof result.estimatedWaitMs !== "number" ||
    !["available", "unavailable"].includes(result.firmQuoteAvailability) ||
    ![
      "reservoir-indicative+lido-live",
      "reservoir-indicative+lido-fallback",
    ].includes(result.source)
  ) {
    throw new Error("The quote service returned an invalid Lido quote");
  }
  return result;
}
