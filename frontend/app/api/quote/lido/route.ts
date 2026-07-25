import { isAddress } from "viem";

import { MAX_LIDO_REQUEST } from "../../../../lib/ethereum";
import { MIN_LIVE_LIDO_QUOTE } from "../../../../lib/lido-quote";

export const dynamic = "force-dynamic";

function json(error: string, status: number) {
  return Response.json(
    { error },
    {
      status,
      headers: {
        "cache-control": "no-store, max-age=0",
      },
    },
  );
}

/// @notice Automated public firm-quote issuance is deliberately disabled:
///         operator-signed quotes are generated offline and pasted into the
///         app for execution (operator-assisted beta). The mainnet Aqua
///         intent proof and factoring settlement are complete.
/// @dev This endpoint performs no market-routing or signing integration.
export async function POST(request: Request) {
  try {
    const body = (await request.json()) as {
      seller?: unknown;
      requestedStEth?: unknown;
    };
    if (typeof body.seller !== "string" || !isAddress(body.seller)) {
      return json("Connect a valid Ethereum wallet", 400);
    }
    if (
      typeof body.requestedStEth !== "string" ||
      !/^\d+$/.test(body.requestedStEth)
    ) {
      return json("Enter a valid stETH amount", 400);
    }
    const amount = BigInt(body.requestedStEth);
    if (amount < MIN_LIVE_LIDO_QUOTE || amount > MAX_LIDO_REQUEST) {
      return json("Firm quotes support 0.001 to 1,000 stETH", 400);
    }
  } catch {
    return json("Enter a valid quote request", 400);
  }

  return json(
    "Automated firm-quote issuance is disabled; paste an operator-signed quote to execute",
    503,
  );
}
