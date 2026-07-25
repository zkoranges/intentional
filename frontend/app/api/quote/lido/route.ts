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

/// @notice Firm Lido pricing is deliberately paused while the Aqua/SwapVM
///         intent is being promoted from a canonical fork proof to a
///         recoverable mainnet demo.
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
    "Firm Lido quotes are paused while the Aqua mainnet intent demo is finalized",
    503,
  );
}
