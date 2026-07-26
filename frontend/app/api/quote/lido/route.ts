import { isAddress } from "viem";

import {
  MAX_LIDO_REQUEST,
  MIN_LIDO_REQUEST,
} from "../../../../lib/ethereum";

export const dynamic = "force-dynamic";

const LIDO_REQUEST_RANGE = "Lido's canonical request bounds";

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
///         ceiling, aggregate-liability admission, and short expiry, and returns a signed
///         envelope the wallet can fill directly.
/// @dev SIGNER_URL / SIGNER_SECRET are server-only Vercel environment
///      variables and must never be prefixed NEXT_PUBLIC — the signer's
///      hostname and secret must not reach the client bundle. Absent
///      configuration the route fails closed with 503.
export async function POST(request: Request) {
  let seller: string;
  let upstreamBody:
    | {
        mode: "originate";
        seller: string;
        requestedStEth: string;
        authorization: object;
        authorizationSignature: string;
        replaceNonce?: string;
      }
    | {
        mode: "existing-unsteth";
        seller: string;
        requestId: string;
        authorization: object;
        authorizationSignature: string;
        replaceNonce?: string;
      };

  try {
    const body = (await request.json()) as {
      mode?: unknown;
      seller?: unknown;
      requestedStEth?: unknown;
      requestId?: unknown;
      authorization?: unknown;
      authorizationSignature?: unknown;
      replaceNonce?: unknown;
    };
    if (typeof body.seller !== "string" || !isAddress(body.seller)) {
      return error("Connect a valid Ethereum wallet", 400);
    }
    seller = body.seller;
    if (
      typeof body.authorization !== "object" ||
      body.authorization === null ||
      Array.isArray(body.authorization) ||
      typeof body.authorizationSignature !== "string" ||
      !/^0x[0-9a-fA-F]{130}$/.test(body.authorizationSignature)
    ) {
      return error("Confirm this firm quote request with your wallet", 401);
    }
    if (
      body.replaceNonce !== undefined &&
      (typeof body.replaceNonce !== "string" ||
        !/^\d+$/.test(body.replaceNonce))
    ) {
      return error("Choose a valid active quote to replace", 400);
    }
    if (body.mode === "originate") {
      if (
        typeof body.requestedStEth !== "string" ||
        !/^\d+$/.test(body.requestedStEth)
      ) {
        return error("Enter a valid stETH amount", 400);
      }
      const amount = BigInt(body.requestedStEth);
      if (amount < MIN_LIDO_REQUEST || amount > MAX_LIDO_REQUEST) {
        return error(`Firm quotes follow ${LIDO_REQUEST_RANGE}`, 400);
      }
      upstreamBody = {
        mode: "originate",
        seller,
        requestedStEth: body.requestedStEth,
        authorization: body.authorization,
        authorizationSignature: body.authorizationSignature,
        ...(body.replaceNonce === undefined
          ? {}
          : { replaceNonce: body.replaceNonce }),
      };
    } else if (body.mode === "existing-unsteth") {
      if (
        typeof body.requestId !== "string" ||
        !/^[1-9]\d*$/.test(body.requestId)
      ) {
        return error("Choose a valid unstETH position", 400);
      }
      upstreamBody = {
        mode: "existing-unsteth",
        seller,
        requestId: body.requestId,
        authorization: body.authorization,
        authorizationSignature: body.authorizationSignature,
        ...(body.replaceNonce === undefined
          ? {}
          : { replaceNonce: body.replaceNonce }),
      };
    } else {
      return error("Choose a supported Lido exit mode", 400);
    }
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
      body: JSON.stringify(upstreamBody),
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
    // Surface the desk's own reason (authorization, capacity, paused Lido)
    // without leaking transport details.
    const upstreamCode =
      typeof payload === "object" &&
      payload !== null &&
      typeof (payload as { code?: unknown }).code === "string"
        ? (payload as { code: string }).code
        : "";
    const reason =
      upstreamCode === "AMOUNT_OUT_OF_BOUNDS"
        ? `Firm quotes follow ${LIDO_REQUEST_RANGE}`
        : typeof payload === "object" &&
            payload !== null &&
            typeof (payload as { error?: unknown }).error === "string"
          ? (payload as { error: string }).error
          : "Firm quotes are unavailable right now";
    const retryAfterSeconds =
      typeof payload === "object" &&
      payload !== null &&
      typeof (payload as { retryAfterSeconds?: unknown })
        .retryAfterSeconds === "number" &&
      Number.isSafeInteger(
        (payload as { retryAfterSeconds: number }).retryAfterSeconds,
      ) &&
      (payload as { retryAfterSeconds: number }).retryAfterSeconds >= 0
        ? (payload as { retryAfterSeconds: number }).retryAfterSeconds
        : undefined;
    const activeDeadlineUnix =
      typeof payload === "object" &&
      payload !== null &&
      typeof (payload as { activeDeadlineUnix?: unknown })
        .activeDeadlineUnix === "string" &&
      /^\d+$/.test(
        (payload as { activeDeadlineUnix: string }).activeDeadlineUnix,
      )
        ? (payload as { activeDeadlineUnix: string }).activeDeadlineUnix
        : undefined;
    const canReplace =
      typeof payload === "object" &&
      payload !== null &&
      typeof (payload as { canReplace?: unknown }).canReplace === "boolean"
        ? (payload as { canReplace: boolean }).canReplace
        : undefined;
    const responseStatus =
      upstream.status === 401 && !upstreamCode.includes("QUOTE_AUTH")
        ? 503
        : upstream.status;
    return json(
      {
        error: reason,
        ...(upstreamCode ? { code: upstreamCode } : {}),
        ...(retryAfterSeconds === undefined ? {} : { retryAfterSeconds }),
        ...(activeDeadlineUnix === undefined ? {} : { activeDeadlineUnix }),
        ...(canReplace === undefined ? {} : { canReplace }),
      },
      responseStatus,
    );
  }

  return json(payload, 200);
}
