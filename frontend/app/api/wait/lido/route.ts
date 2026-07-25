export const dynamic = "force-dynamic";

const LIDO_WAIT_URL =
  "https://wq-api.lido.fi/v2/request-time/calculate?amount=1";
const MAX_WAIT_MS = 365 * 24 * 60 * 60 * 1_000;

type LidoWaitResponse = {
  status?: unknown;
  requestInfo?: {
    finalizationIn?: unknown;
    finalizationAt?: unknown;
  };
};

export async function GET() {
  try {
    const response = await fetch(LIDO_WAIT_URL, {
      headers: { accept: "application/json" },
      next: { revalidate: 60 },
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) throw new Error("Lido wait service unavailable");

    const result = (await response.json()) as LidoWaitResponse;
    const estimatedWaitMs = result.requestInfo?.finalizationIn;
    const finalizationAt = result.requestInfo?.finalizationAt;
    if (
      result.status !== "calculated" ||
      typeof estimatedWaitMs !== "number" ||
      !Number.isSafeInteger(estimatedWaitMs) ||
      estimatedWaitMs < 0 ||
      estimatedWaitMs > MAX_WAIT_MS ||
      typeof finalizationAt !== "string" ||
      !Number.isFinite(Date.parse(finalizationAt))
    ) {
      throw new Error("Invalid Lido wait estimate");
    }

    return Response.json(
      {
        market: "lido",
        amountStEth: "1",
        estimatedWaitMs,
        finalizationAt,
        source: "lido-withdrawals-api",
        observedAt: new Date().toISOString(),
      },
      {
        headers: {
          "cache-control":
            "public, s-maxage=60, stale-while-revalidate=300",
        },
      },
    );
  } catch {
    return Response.json(
      { error: "Live Lido queue estimate unavailable" },
      {
        status: 503,
        headers: { "cache-control": "no-store" },
      },
    );
  }
}
