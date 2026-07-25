import { isAddress } from "viem";

import { MAX_LIDO_REQUEST } from "../../../../lib/ethereum";
import { MIN_LIVE_LIDO_QUOTE } from "../../../../lib/lido-quote";

export const dynamic = "force-dynamic";

function json(body: unknown, status: number) {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store, max-age=0",
    },
  });
}

function error(message: string, status: number) {
  return json({ error: message }, status);
}

/// @notice Public edge for firm quote issuance. This route holds NO signing
///         key: it validates the request and proxies to the operator's quote
///         signer, which holds the factor key, enforces a hard per-quote
///         ceiling, single-flight, and short expiry, and returns a signed
///         envelope the wallet can fill directly.
/// @dev SIGNER_URL / SIGNER_SECRET are server-only Vercel environment
///      variables and must never be prefixed NEXT_PUBLIC — the signer's
///      hostname and secret must not reach the client bundle. Absent
///      configuration the route fails closed with 503.
export async function POST(request: Request) {
  let seller: string;
  let requestedStEth: string;

  try {
    const body = (await request.json()) as {
      seller?: unknown;
      requestedStEth?: unknown;
    };
    if (typeof body.seller !== "string" || !isAddress(body.seller)) {
      return error("Connect a valid Ethereum wallet", 400);
    }
    if (
      typeof body.requestedStEth !== "string" ||
      !/^\d+$/.test(body.requestedStEth)
    ) {
      return error("Enter a valid stETH amount", 400);
    }
    const amount = BigInt(body.requestedStEth);
    if (amount < MIN_LIVE_LIDO_QUOTE || amount > MAX_LIDO_REQUEST) {
      return error("Firm quotes support 0.001 to 1,000 stETH", 400);
    }
    seller = body.seller;
    requestedStEth = body.requestedStEth;
  } catch {
    return error("Enter a valid quote request", 400);
  }

  const signerUrl = process.env.SIGNER_URL?.trim();
  const signerSecret = process.env.SIGNER_SECRET?.trim();
  if (!signerUrl || !signerSecret) {
    return error(
      "Firm quote issuance is not configured in this deployment",
      503,
    );
  }

  let upstream: Response;
  try {
    upstream = await fetch(`${signerUrl.replace(/\/+$/, "")}/quote`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-signer-secret": signerSecret,
      },
      body: JSON.stringify({ seller, requestedStEth }),
      signal: AbortSignal.timeout(15_000),
      cache: "no-store",
    });
  } catch {
    return error("The quote desk is unreachable right now", 503);
  }

  let payload: unknown;
  try {
    payload = await upstream.json();
  } catch {
    return error("The quote desk returned an unreadable response", 502);
  }

  if (!upstream.ok) {
    // Surface the desk's own reason (capacity, paused Lido, single-flight)
    // without leaking transport details.
    const reason =
      typeof payload === "object" &&
      payload !== null &&
      typeof (payload as { error?: unknown }).error === "string"
        ? (payload as { error: string }).error
        : "Firm quotes are unavailable right now";
    return error(reason, upstream.status === 401 ? 503 : upstream.status);
  }

  return json(payload, 200);
}
