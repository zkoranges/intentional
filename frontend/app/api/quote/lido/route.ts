import {
  createPublicClient,
  encodeAbiParameters,
  getAddress,
  http,
  isAddress,
  keccak256,
  parseAbi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";

import {
  ADDRESSES,
  MAX_LIDO_REQUEST,
  MIN_LIDO_REQUEST,
} from "../../../../lib/ethereum";
import {
  calculatePaymentAmount,
  type LidoQuoteResponse,
} from "../../../../lib/lido-quote";

export const dynamic = "force-dynamic";

const kernelAbi = parseAbi([
  "function factorSigner() view returns (address)",
  "function fundingAccount() view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool)",
  "function isSealed() view returns (bool)",
  "function isPaused() view returns (bool)",
  "function nonceUsed(uint256 nonce) view returns (bool)",
  "function nonceFloor() view returns (uint256)",
]);
const adapterAbi = parseAbi([
  "function settlement() view returns (address)",
  "function stETH() view returns (address)",
  "function queue() view returns (address)",
]);
const fundingAbi = parseAbi([
  "function paymentAsset() view returns (address)",
  "function availableFor(uint256 wanted) view returns (uint256)",
  "function isSealed() view returns (bool)",
]);
const stEthAbi = parseAbi([
  "function getSharesByPooledEth(uint256 amount) view returns (uint256)",
]);
const queueAbi = parseAbi(["function isPaused() view returns (bool)"]);

const quoteTypes = {
  ClaimQuote: [
    { name: "factor", type: "address" },
    { name: "seller", type: "address" },
    { name: "adapter", type: "address" },
    { name: "claimController", type: "address" },
    { name: "claimReceiver", type: "address" },
    { name: "paymentAsset", type: "address" },
    { name: "paymentAmount", type: "uint256" },
    { name: "claimDataHash", type: "bytes32" },
    { name: "boundsHash", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

function json(body: LidoQuoteResponse | { error: string }, status = 200) {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store, max-age=0",
    },
  });
}

function readDiscountBps() {
  const raw = process.env.LIDO_QUOTE_DISCOUNT_BPS?.trim() || "50";
  if (!/^\d+$/.test(raw)) {
    throw new Error("LIDO_QUOTE_DISCOUNT_BPS must be an unsigned integer");
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0 || value > 2_000) {
    throw new Error("LIDO_QUOTE_DISCOUNT_BPS must be between 0 and 2,000");
  }
  return value;
}

function configuredAddress(name: string) {
  const value = process.env[name]?.trim();
  return value && isAddress(value) ? getAddress(value) : null;
}

function firmConfiguration() {
  const rpcUrl = process.env.ETH_RPC_URL?.trim();
  const signerKey = process.env.LIDO_QUOTE_SIGNER_PRIVATE_KEY?.trim();
  const factor = configuredAddress("FACTOR_ADDRESS");
  const kernel =
    configuredAddress("RESERVOIR_KERNEL") ??
    configuredAddress("NEXT_PUBLIC_RESERVOIR_KERNEL");
  const adapter =
    configuredAddress("RESERVOIR_LIDO_ADAPTER") ??
    configuredAddress("NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER");
  const configured = [rpcUrl, signerKey, kernel, adapter];
  if (configured.every(Boolean)) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(signerKey!)) {
      throw new Error("LIDO_QUOTE_SIGNER_PRIVATE_KEY must be 32-byte hex");
    }
    return {
      rpcUrl: rpcUrl!,
      signerKey: signerKey! as Hex,
      factor,
      kernel: kernel!,
      adapter: adapter!,
    };
  }
  if (configured.some(Boolean)) {
    throw new Error("The firm Lido quote service is only partially configured");
  }
  return null;
}

function makeIndicativeQuote(
  requestedStEth: bigint,
  discountBps: number,
): LidoQuoteResponse {
  return {
    kind: "indicative",
    market: "lido",
    requestedStEth: requestedStEth.toString(),
    paymentAmount: calculatePaymentAmount(
      requestedStEth,
      discountBps,
    ).toString(),
    paymentAsset: "WETH",
    discountBps,
    expiresAt: null,
    envelope: null,
  };
}

async function makeFirmQuote(
  seller: Address,
  requestedStEth: bigint,
  discountBps: number,
  config: NonNullable<ReturnType<typeof firmConfiguration>>,
): Promise<LidoQuoteResponse> {
  const signer = privateKeyToAccount(config.signerKey);
  const factor = config.factor ?? signer.address;
  if (seller === factor) {
    throw new Error("The seller must differ from the factor claim destination");
  }
  const client = createPublicClient({
    chain: mainnet,
    transport: http(config.rpcUrl),
  });
  if ((await client.getChainId()) !== 1) {
    throw new Error("The quote RPC is not connected to Ethereum mainnet");
  }

  const latestBlock = await client.getBlock({ blockTag: "latest" });
  const deadline = latestBlock.timestamp + 10n * 60n;
  const nonceBytes = crypto.getRandomValues(new Uint8Array(32));
  const nonce = BigInt(
    `0x${Array.from(nonceBytes, (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("")}`,
  );
  const paymentAmount = calculatePaymentAmount(requestedStEth, discountBps);
  const maxStEthShortfall = 2n;

  const [
    factorSigner,
    fundingAccount,
    adapterAllowed,
    settlementSealed,
    settlementPaused,
    nonceFloor,
    adapterSettlement,
    adapterStEth,
    adapterQueue,
  ] = await Promise.all([
    client.readContract({
      address: config.kernel,
      abi: kernelAbi,
      functionName: "factorSigner",
    }),
    client.readContract({
      address: config.kernel,
      abi: kernelAbi,
      functionName: "fundingAccount",
    }),
    client.readContract({
      address: config.kernel,
      abi: kernelAbi,
      functionName: "isAdapterAllowed",
      args: [config.adapter],
    }),
    client.readContract({
      address: config.kernel,
      abi: kernelAbi,
      functionName: "isSealed",
    }),
    client.readContract({
      address: config.kernel,
      abi: kernelAbi,
      functionName: "isPaused",
    }),
    client.readContract({
      address: config.kernel,
      abi: kernelAbi,
      functionName: "nonceFloor",
    }),
    client.readContract({
      address: config.adapter,
      abi: adapterAbi,
      functionName: "settlement",
    }),
    client.readContract({
      address: config.adapter,
      abi: adapterAbi,
      functionName: "stETH",
    }),
    client.readContract({
      address: config.adapter,
      abi: adapterAbi,
      functionName: "queue",
    }),
  ]);
  if (
    factorSigner !== factor ||
    adapterSettlement !== config.kernel ||
    adapterStEth !== ADDRESSES.stEth ||
    adapterQueue !== ADDRESSES.lidoQueue ||
    !adapterAllowed ||
    !settlementSealed ||
    settlementPaused ||
    nonce < nonceFloor
  ) {
    throw new Error("The active Lido settlement deployment is not healthy");
  }

  const [fundingSealed, capacity, minAmountOfShares, queuePaused] =
    await Promise.all([
      client.readContract({
        address: fundingAccount,
        abi: fundingAbi,
        functionName: "isSealed",
      }),
      client.readContract({
        address: fundingAccount,
        abi: fundingAbi,
        functionName: "availableFor",
        args: [paymentAmount],
      }),
      client.readContract({
        address: ADDRESSES.stEth,
        abi: stEthAbi,
        functionName: "getSharesByPooledEth",
        args: [requestedStEth - maxStEthShortfall],
      }),
      client.readContract({
        address: ADDRESSES.lidoQueue,
        abi: queueAbi,
        functionName: "isPaused",
      }),
    ]);
  const paymentAsset = await client.readContract({
    address: fundingAccount,
    abi: fundingAbi,
    functionName: "paymentAsset",
  });
  if (
    paymentAsset !== ADDRESSES.weth ||
    !fundingSealed ||
    capacity !== paymentAmount
  ) {
    throw new Error("The factor reserve cannot cover this Lido quote");
  }
  if (queuePaused) {
    throw new Error("Lido withdrawals are currently paused");
  }

  const claimData = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "queue", type: "address" },
          { name: "stETH", type: "address" },
          { name: "requestedStETH", type: "uint256" },
        ],
      },
    ],
    [
      {
        queue: ADDRESSES.lidoQueue,
        stETH: ADDRESSES.stEth,
        requestedStETH: requestedStEth,
      },
    ],
  );
  const boundsData = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "maxStETHShortfall", type: "uint256" },
          { name: "minAmountOfShares", type: "uint256" },
        ],
      },
    ],
    [{ maxStETHShortfall: maxStEthShortfall, minAmountOfShares }],
  );
  const quote = {
    factor,
    seller,
    adapter: config.adapter,
    claimController: factor,
    claimReceiver: factor,
    paymentAsset: ADDRESSES.weth,
    paymentAmount,
    claimDataHash: keccak256(claimData),
    boundsHash: keccak256(boundsData),
    nonce,
    deadline,
  };
  const factorSignature = await signer.signTypedData({
    domain: {
      name: "Reservoir v2",
      version: "1",
      chainId: 1,
      verifyingContract: config.kernel,
    },
    types: quoteTypes,
    primaryType: "ClaimQuote",
    message: quote,
  });
  const envelope = {
    version: "reservoir-v2-lido-1",
    chainId: 1,
    kernel: config.kernel,
    quote: {
      ...quote,
      paymentAmount: paymentAmount.toString(),
      nonce: nonce.toString(),
      deadline: deadline.toString(),
    },
    claimData,
    boundsData,
    factorSignature,
  };
  return {
    kind: "firm",
    market: "lido",
    requestedStEth: requestedStEth.toString(),
    paymentAmount: paymentAmount.toString(),
    paymentAsset: "WETH",
    discountBps,
    expiresAt: Number(deadline),
    envelope,
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
      requestedStEth < MIN_LIDO_REQUEST ||
      requestedStEth > MAX_LIDO_REQUEST
    ) {
      return json({ error: "The amount is outside Lido withdrawal limits" }, 400);
    }

    const discountBps = readDiscountBps();
    const config = firmConfiguration();
    if (
      !config ||
      getAddress(body.seller) ===
        "0x0000000000000000000000000000000000000000"
    ) {
      return json(makeIndicativeQuote(requestedStEth, discountBps));
    }
    return json(
      await makeFirmQuote(
        getAddress(body.seller),
        requestedStEth,
        discountBps,
        config,
      ),
    );
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "The Lido quote service failed";
    return json({ error: message }, 503);
  }
}
