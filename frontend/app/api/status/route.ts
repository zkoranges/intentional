import {
  createPublicClient,
  getAddress,
  http,
  isAddress,
  parseAbi,
  type Address,
} from "viem";
import { mainnet } from "viem/chains";

export const dynamic = "force-dynamic";

const CAPACITY_PROBE = 1n * 10n ** 18n;

const kernelAbi = parseAbi([
  "function fundingAccount() view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool)",
  "function isPaused() view returns (bool)",
  "function isSealed() view returns (bool)",
]);

const fundingAbi = parseAbi([
  "function availableFor(uint256 wanted) view returns (uint256)",
  "function isPaused() view returns (bool)",
  "function isSealed() view returns (bool)",
]);

type MarketState = "Live" | "Standby" | "Retired" | "Unavailable";

function response(
  state: MarketState,
  capacityWei: bigint,
  firmQuoteConfigured: boolean,
  detail: string,
) {
  return Response.json(
    {
      state,
      capacityWei: capacityWei.toString(),
      firmQuoteConfigured,
      firmQuotesEnabled: state === "Live" && firmQuoteConfigured,
      detail,
      observedAt: new Date().toISOString(),
    },
    {
      headers: {
        "cache-control": "no-store, max-age=0",
      },
    },
  );
}

function configuredAddress(value: string | undefined): Address | null {
  return value && isAddress(value) ? getAddress(value) : null;
}

/// Server-only chain status for the public market surface. ETH_RPC_URL and
/// signer configuration are never returned. The UI derives its status and CTA
/// from these live reads instead of a hardcoded availability label.
export async function GET() {
  const rpcUrl = process.env.ETH_RPC_URL?.trim();
  const kernel = configuredAddress(process.env.NEXT_PUBLIC_RESERVOIR_KERNEL);
  const expectedAdapter = configuredAddress(
    process.env.NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER,
  );
  const expectedUnstETHAdapter = configuredAddress(
    process.env.NEXT_PUBLIC_RESERVOIR_LIDO_UNSTETH_ADAPTER,
  );
  const firmQuoteConfigured = Boolean(
    process.env.SIGNER_URL?.trim() && process.env.SIGNER_SECRET?.trim(),
  );

  if (!rpcUrl || !kernel || !expectedAdapter || !expectedUnstETHAdapter) {
    return response(
      "Unavailable",
      0n,
      false,
      "Deployment status is not configured",
    );
  }

  try {
    const client = createPublicClient({
      chain: mainnet,
      transport: http(rpcUrl, { timeout: 8_000 }),
    });
    const [
      chainId,
      kernelCode,
      adapterCode,
      unstETHAdapterCode,
      kernelPaused,
      kernelSealed,
      adapterAllowed,
      unstETHAdapterAllowed,
      funding,
    ] = await Promise.all([
        client.getChainId(),
        client.getCode({ address: kernel }),
        client.getCode({ address: expectedAdapter }),
        client.getCode({ address: expectedUnstETHAdapter }),
        client.readContract({
          address: kernel,
          abi: kernelAbi,
          functionName: "isPaused",
        }),
        client.readContract({
          address: kernel,
          abi: kernelAbi,
          functionName: "isSealed",
        }),
        client.readContract({
          address: kernel,
          abi: kernelAbi,
          functionName: "isAdapterAllowed",
          args: [expectedAdapter],
        }),
        client.readContract({
          address: kernel,
          abi: kernelAbi,
          functionName: "isAdapterAllowed",
          args: [expectedUnstETHAdapter],
        }),
        client.readContract({
          address: kernel,
          abi: kernelAbi,
          functionName: "fundingAccount",
        }),
      ]);

    if (
      chainId !== 1 ||
      !kernelCode ||
      kernelCode === "0x" ||
      !adapterCode ||
      adapterCode === "0x" ||
      !unstETHAdapterCode ||
      unstETHAdapterCode === "0x" ||
      !adapterAllowed ||
      !unstETHAdapterAllowed
    ) {
      return response(
        "Unavailable",
        0n,
        false,
        "Reviewed mainnet contracts are unavailable",
      );
    }

    const [fundingCode, fundingPaused, fundingSealed, capacity] =
      await Promise.all([
        client.getCode({ address: funding }),
        client.readContract({
          address: funding,
          abi: fundingAbi,
          functionName: "isPaused",
        }),
        client.readContract({
          address: funding,
          abi: fundingAbi,
          functionName: "isSealed",
        }),
        client.readContract({
          address: funding,
          abi: fundingAbi,
          functionName: "availableFor",
          args: [CAPACITY_PROBE],
        }),
      ]);

    if (
      !fundingCode ||
      fundingCode === "0x" ||
      !kernelSealed ||
      !fundingSealed
    ) {
      return response(
        "Unavailable",
        0n,
        false,
        "Deployment bindings are incomplete",
      );
    }

    if (kernelPaused && fundingPaused) {
      return response(
        "Retired",
        capacity,
        false,
        "Mainnet proof completed; this deployment is permanently retired",
      );
    }

    if (!kernelPaused && !fundingPaused && capacity > 0n) {
      return response(
        "Live",
        capacity,
        firmQuoteConfigured,
        firmQuoteConfigured
          ? "Onchain settlement and the operator quote desk are ready"
          : "Onchain settlement is funded, but public firm quotes are unavailable",
      );
    }

    return response(
      "Standby",
      capacity,
      false,
      "Deployment is not accepting public firm quotes",
    );
  } catch {
    return response(
      "Unavailable",
      0n,
      false,
      "Live Ethereum status could not be verified",
    );
  }
}
