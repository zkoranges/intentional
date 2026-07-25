import {
  createPublicClient,
  createWalletClient,
  custom,
  decodeAbiParameters,
  decodeEventLog,
  encodeFunctionData,
  formatEther,
  getAddress,
  hashTypedData,
  isAddress,
  keccak256,
  parseAbi,
  parseAbiItem,
  verifyTypedData,
  type Address,
  type EIP1193Provider,
  type Hash,
  type Hex,
} from "viem";
import { mainnet } from "viem/chains";

export const MAINNET_CHAIN_ID = 1;
export const MIN_LIDO_REQUEST = 100n;
export const MAX_LIDO_REQUEST = 1_000n * 10n ** 18n;

export const ADDRESSES = {
  aqua: getAddress("0x499943e74fb0ce105688beee8ef2abec5d936d31"),
  swapVm: getAddress("0x8fdd04dbf6111437b44bbca99c28882434e0958f"),
  stEth: getAddress("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"),
  weth: getAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
  lidoQueue: getAddress("0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1"),
  stataWeth: getAddress("0x0bfc9d54Fc184518A81162F8fB99c2eACa081202"),
} as const;

function configuredAddress(value: string | undefined): Address | null {
  return value && isAddress(value) ? getAddress(value) : null;
}

const configuredKernel = configuredAddress(
  process.env.NEXT_PUBLIC_RESERVOIR_KERNEL,
);
const configuredLidoAdapter = configuredAddress(
  process.env.NEXT_PUBLIC_RESERVOIR_LIDO_ADAPTER,
);
const configuredLidoUnstETHAdapter = configuredAddress(
  process.env.NEXT_PUBLIC_RESERVOIR_LIDO_UNSTETH_ADAPTER,
);

export const RESERVOIR_DEPLOYMENT =
  configuredKernel && configuredLidoAdapter && configuredLidoUnstETHAdapter
    ? {
        kernel: configuredKernel,
        lidoAdapter: configuredLidoAdapter,
        lidoUnstETHAdapter: configuredLidoUnstETHAdapter,
      }
    : null;

export const erc20Abi = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

export const lidoQueueAbi = parseAbi([
  "function requestWithdrawals(uint256[] amounts, address owner) returns (uint256[] requestIds)",
  "function getWithdrawalRequests(address owner) view returns (uint256[] requestIds)",
  "function getWithdrawalStatus(uint256[] requestIds) view returns ((uint256 amountOfStETH,uint256 amountOfShares,address owner,uint256 timestamp,bool isFinalized,bool isClaimed)[] statuses)",
  "function claimWithdrawal(uint256 requestId)",
  "function isPaused() view returns (bool)",
  "function isBunkerModeActive() view returns (bool)",
  "function getLastRequestId() view returns (uint256)",
  "function getLastFinalizedRequestId() view returns (uint256)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner,address operator) view returns (bool)",
  "function approve(address to,uint256 tokenId)",
]);

export const settlementAbi = parseAbi([
  "function fill((address factor,address seller,address adapter,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 claimDataHash,bytes32 boundsHash,uint256 nonce,uint256 deadline) quote,bytes claimData,bytes boundsData,bytes factorSignature) returns ((bytes32 positionKey,uint256 claimId,uint256 pendingUnits,uint256 pendingReceived,uint256 claimableUnits,uint256 assetsReceived) acquisition)",
  "function factorSigner() view returns (address)",
  "function fundingAccount() view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool)",
  "function isSealed() view returns (bool)",
  "function isPaused() view returns (bool)",
  "function nonceUsed(uint256 nonce) view returns (bool)",
  "function nonceFloor() view returns (uint256)",
]);

export const fundingAccountAbi = parseAbi([
  "function paymentAsset() view returns (address)",
  "function availableFor(uint256 wanted) view returns (uint256)",
  "function isSealed() view returns (bool)",
]);

export const lidoAdapterAbi = parseAbi([
  "function settlement() view returns (address)",
  "function stETH() view returns (address)",
  "function queue() view returns (address)",
]);

const erc1271Abi = parseAbi([
  "function isValidSignature(bytes32 hash, bytes signature) view returns (bytes4 magicValue)",
]);

export const claimSettledEvent = parseAbiItem(
  "event ClaimSettled(bytes32 indexed quoteHash,address indexed adapter,address indexed seller,address factor,address claimController,address claimReceiver,address paymentAsset,uint256 paymentAmount,bytes32 positionKey,uint256 claimId,uint256 pendingUnits,uint256 pendingReceived,uint256 claimableUnits,uint256 assetsReceived)",
);

const transferEvent = parseAbiItem(
  "event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)",
);
const withdrawalClaimedEvent = parseAbiItem(
  "event WithdrawalClaimed(uint256 indexed requestId,address indexed owner,address indexed receiver,uint256 amountOfETH)",
);

export type InjectedEthereum = EIP1193Provider & {
  on?: (event: string, listener: (...args: unknown[]) => void) => void;
  removeListener?: (
    event: string,
    listener: (...args: unknown[]) => void,
  ) => void;
};

declare global {
  interface Window {
    ethereum?: InjectedEthereum;
  }
}

export type WithdrawalStatus = {
  requestId: bigint;
  amountOfStETH: bigint;
  amountOfShares: bigint;
  owner: Address;
  timestamp: bigint;
  isFinalized: boolean;
  isClaimed: boolean;
};

export type LiveWalletSnapshot = {
  account: Address;
  chainId: number;
  ethBalance: bigint;
  stEthBalance: bigint;
  wethBalance: bigint;
  queueAllowance: bigint;
  queuePaused: boolean;
  bunkerMode: boolean;
  lastRequestId: bigint;
  lastFinalizedRequestId: bigint;
  requests: WithdrawalStatus[];
  productionCodeVerified: boolean;
};

export type ClaimQuote = {
  factor: Address;
  seller: Address;
  adapter: Address;
  claimController: Address;
  claimReceiver: Address;
  paymentAsset: Address;
  paymentAmount: string;
  claimDataHash: Hex;
  boundsHash: Hex;
  nonce: string;
  deadline: string;
};

export type SignedLidoQuoteEnvelope = {
  version: "reservoir-v2-lido-1";
  mode: "originate" | "existing-unsteth";
  chainId: 1;
  kernel: Address;
  quote: ClaimQuote;
  claimData: Hex;
  boundsData: Hex;
  factorSignature: Hex;
};

export type ReservoirQuoteCheck = {
  envelope: SignedLidoQuoteEnvelope;
  requestedStEth: bigint;
  requestId: bigint | null;
  amountOfShares: bigint;
  capacity: bigint;
  approvalSatisfied: boolean;
  fundingAccount: Address;
  quoteHash: Hex;
};

export class MinedTransactionVerificationError extends Error {
  readonly transactionHash: Hash;

  constructor(message: string, transactionHash: Hash) {
    super(message);
    this.name = "MinedTransactionVerificationError";
    this.transactionHash = transactionHash;
  }
}

export function hasExactAllowance(allowance: bigint, requested: bigint) {
  return requested > 0n && allowance === requested;
}

export function getInjectedProvider(): InjectedEthereum | null {
  return typeof window === "undefined" ? null : (window.ethereum ?? null);
}

export function clients(provider: InjectedEthereum, account?: Address) {
  const transport = custom(provider);
  return {
    publicClient: createPublicClient({ chain: mainnet, transport }),
    walletClient: account
      ? createWalletClient({ account, chain: mainnet, transport })
      : null,
  };
}

export async function ensureMainnet(provider: InjectedEthereum) {
  const chainHex = (await provider.request({
    method: "eth_chainId",
  })) as Hex;
  if (Number.parseInt(chainHex, 16) === MAINNET_CHAIN_ID) return;

  await provider.request({
    method: "wallet_switchEthereumChain",
    params: [{ chainId: "0x1" }],
  });
}

export async function connectInjectedWallet(provider: InjectedEthereum) {
  await ensureMainnet(provider);
  const accounts = (await provider.request({
    method: "eth_requestAccounts",
  })) as Address[];
  if (!accounts[0]) throw new Error("The wallet returned no account");
  return getAddress(accounts[0]);
}

export async function readLiveWallet(
  provider: InjectedEthereum,
  account: Address,
): Promise<LiveWalletSnapshot> {
  const { publicClient } = clients(provider);
  const chainId = await publicClient.getChainId();
  if (chainId !== MAINNET_CHAIN_ID) {
    throw new Error(`Switch to Ethereum mainnet. Connected chain: ${chainId}`);
  }

  const codeAddresses = [
    ADDRESSES.aqua,
    ADDRESSES.swapVm,
    ADDRESSES.stEth,
    ADDRESSES.weth,
    ADDRESSES.lidoQueue,
    ADDRESSES.stataWeth,
  ];
  const [
    ethBalance,
    stEthBalance,
    wethBalance,
    queueAllowance,
    queuePaused,
    bunkerMode,
    lastRequestId,
    lastFinalizedRequestId,
    requestIds,
    ...codes
  ] = await Promise.all([
    publicClient.getBalance({ address: account }),
    publicClient.readContract({
      address: ADDRESSES.stEth,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    }),
    publicClient.readContract({
      address: ADDRESSES.weth,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    }),
    publicClient.readContract({
      address: ADDRESSES.stEth,
      abi: erc20Abi,
      functionName: "allowance",
      args: [account, ADDRESSES.lidoQueue],
    }),
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "isPaused",
    }),
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "isBunkerModeActive",
    }),
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "getLastRequestId",
    }),
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "getLastFinalizedRequestId",
    }),
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "getWithdrawalRequests",
      args: [account],
    }),
    ...codeAddresses.map((address) => publicClient.getCode({ address })),
  ]);

  // Keep the browser read bounded while still surfacing a realistic wallet's
  // recent claim inventory. The production demo position is never hidden
  // behind an arbitrary four-item cap.
  const recentIds = requestIds.slice(-20).reverse();
  const rawStatuses =
    recentIds.length === 0
      ? []
      : await publicClient.readContract({
          address: ADDRESSES.lidoQueue,
          abi: lidoQueueAbi,
          functionName: "getWithdrawalStatus",
          args: [recentIds],
        });
  const requests = rawStatuses.map((status, index) => ({
    requestId: recentIds[index],
    ...status,
  }));

  return {
    account,
    chainId,
    ethBalance,
    stEthBalance,
    wethBalance,
    queueAllowance,
    queuePaused,
    bunkerMode,
    lastRequestId,
    lastFinalizedRequestId,
    requests,
    productionCodeVerified: codes.every(
      (code) => code !== undefined && code !== "0x",
    ),
  };
}

export async function approveExact(
  provider: InjectedEthereum,
  account: Address,
  spender: Address,
  amount: bigint,
) {
  const { publicClient, walletClient } = clients(provider, account);
  if (!walletClient) throw new Error("Wallet client unavailable");
  const { request } = await publicClient.simulateContract({
    account,
    address: ADDRESSES.stEth,
    abi: erc20Abi,
    functionName: "approve",
    args: [spender, amount],
  });
  const hash = await walletClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new MinedTransactionVerificationError(
      "The approval transaction mined but reverted",
      hash,
    );
  }
  return receipt;
}

export async function approveUnstETH(
  provider: InjectedEthereum,
  account: Address,
  adapter: Address,
  requestId: bigint,
) {
  const { publicClient, walletClient } = clients(provider, account);
  if (!walletClient) throw new Error("Wallet client unavailable");
  const owner = await publicClient.readContract({
    address: ADDRESSES.lidoQueue,
    abi: lidoQueueAbi,
    functionName: "ownerOf",
    args: [requestId],
  });
  if (owner !== account) {
    throw new Error("The connected wallet no longer owns this unstETH");
  }
  const { request } = await publicClient.simulateContract({
    account,
    address: ADDRESSES.lidoQueue,
    abi: lidoQueueAbi,
    functionName: "approve",
    args: [adapter, requestId],
  });
  const hash = await walletClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new MinedTransactionVerificationError(
      "The unstETH approval transaction mined but reverted",
      hash,
    );
  }
  const approved = await publicClient.readContract({
    address: ADDRESSES.lidoQueue,
    abi: lidoQueueAbi,
    functionName: "getApproved",
    args: [requestId],
  });
  if (approved !== adapter) {
    throw new MinedTransactionVerificationError(
      "Ethereum did not record the expected unstETH approval",
      hash,
    );
  }
  return receipt;
}

export async function requestLidoWithdrawal(
  provider: InjectedEthereum,
  account: Address,
  amount: bigint,
) {
  const { publicClient, walletClient } = clients(provider, account);
  if (!walletClient) throw new Error("Wallet client unavailable");
  const currentAllowance = await publicClient.readContract({
    address: ADDRESSES.stEth,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account, ADDRESSES.lidoQueue],
  });
  if (!hasExactAllowance(currentAllowance, amount)) {
    throw new Error(
      "The queue allowance changed; approve the exact stETH amount again",
    );
  }
  const { request } = await publicClient.simulateContract({
    account,
    address: ADDRESSES.lidoQueue,
    abi: lidoQueueAbi,
    functionName: "requestWithdrawals",
    args: [[amount], account],
  });
  const hash = await walletClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new MinedTransactionVerificationError(
      "The Lido request transaction mined but reverted",
      hash,
    );
  }
  const mint = receipt.logs
    .filter(
      (log) => log.address.toLowerCase() === ADDRESSES.lidoQueue.toLowerCase(),
    )
    .map((log) => {
      try {
        return decodeEventLog({
          abi: [transferEvent],
          data: log.data,
          topics: log.topics,
        });
      } catch {
        return null;
      }
    })
    .find(
      (decoded) =>
        decoded?.eventName === "Transfer" &&
        decoded.args.from === "0x0000000000000000000000000000000000000000" &&
        decoded.args.to.toLowerCase() === account.toLowerCase(),
    );
  if (!mint || mint.eventName !== "Transfer") {
    throw new MinedTransactionVerificationError(
      "The Lido receipt did not contain the expected unstETH mint",
      hash,
    );
  }
  return { hash, requestId: mint.args.tokenId, receipt };
}

export async function claimLidoWithdrawal(
  provider: InjectedEthereum,
  account: Address,
  requestId: bigint,
) {
  const { publicClient, walletClient } = clients(provider, account);
  if (!walletClient) throw new Error("Wallet client unavailable");
  const { request } = await publicClient.simulateContract({
    account,
    address: ADDRESSES.lidoQueue,
    abi: lidoQueueAbi,
    functionName: "claimWithdrawal",
    args: [requestId],
  });
  const hash = await walletClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new MinedTransactionVerificationError(
      "The Lido claim transaction mined but reverted",
      hash,
    );
  }
  const claim = receipt.logs
    .filter(
      (log) => log.address.toLowerCase() === ADDRESSES.lidoQueue.toLowerCase(),
    )
    .map((log) => {
      try {
        return decodeEventLog({
          abi: [withdrawalClaimedEvent],
          data: log.data,
          topics: log.topics,
        });
      } catch {
        return null;
      }
    })
    .find(
      (decoded) =>
        decoded?.eventName === "WithdrawalClaimed" &&
        decoded.args.requestId === requestId &&
        decoded.args.owner.toLowerCase() === account.toLowerCase() &&
        decoded.args.receiver.toLowerCase() === account.toLowerCase() &&
        decoded.args.amountOfETH > 0n,
    );
  if (!claim || claim.eventName !== "WithdrawalClaimed") {
    throw new MinedTransactionVerificationError(
      "The Lido receipt did not prove the expected ETH claim",
      hash,
    );
  }
  const [status] = await publicClient.readContract({
    address: ADDRESSES.lidoQueue,
    abi: lidoQueueAbi,
    functionName: "getWithdrawalStatus",
    args: [[requestId]],
  });
  if (!status?.isClaimed) {
    throw new MinedTransactionVerificationError(
      "Canonical Lido state does not mark the request claimed",
      hash,
    );
  }
  return { hash, amountOfEth: claim.args.amountOfETH };
}

function parseAddress(value: unknown, name: string): Address {
  if (typeof value !== "string" || !isAddress(value)) {
    throw new Error(`${name} is not a valid address`);
  }
  return getAddress(value);
}

function parseHex(value: unknown, name: string): Hex {
  if (
    typeof value !== "string" ||
    !value.startsWith("0x") ||
    !/^[0-9a-fA-F]*$/.test(value.slice(2))
  ) {
    throw new Error(`${name} is not valid hex`);
  }
  return value as Hex;
}

function parseUintString(value: unknown, name: string) {
  if (
    (typeof value !== "string" && typeof value !== "number") ||
    !/^\d+$/.test(String(value))
  ) {
    throw new Error(`${name} must be an unsigned integer string`);
  }
  return String(value);
}

export function parseSignedQuoteEnvelope(
  input: string,
): SignedLidoQuoteEnvelope {
  const value = JSON.parse(input) as Record<string, unknown>;
  if (value.version !== "reservoir-v2-lido-1" || value.chainId !== 1) {
    throw new Error("Unsupported quote version or chain");
  }
  if (value.mode !== "originate" && value.mode !== "existing-unsteth") {
    throw new Error("Unsupported Lido quote mode");
  }
  const rawQuote = value.quote as Record<string, unknown>;
  if (!rawQuote) throw new Error("Quote body missing");

  return {
    version: "reservoir-v2-lido-1",
    mode: value.mode,
    chainId: 1,
    kernel: parseAddress(value.kernel, "kernel"),
    quote: {
      factor: parseAddress(rawQuote.factor, "factor"),
      seller: parseAddress(rawQuote.seller, "seller"),
      adapter: parseAddress(rawQuote.adapter, "adapter"),
      claimController: parseAddress(
        rawQuote.claimController,
        "claimController",
      ),
      claimReceiver: parseAddress(rawQuote.claimReceiver, "claimReceiver"),
      paymentAsset: parseAddress(rawQuote.paymentAsset, "paymentAsset"),
      paymentAmount: parseUintString(
        rawQuote.paymentAmount,
        "paymentAmount",
      ),
      claimDataHash: parseHex(rawQuote.claimDataHash, "claimDataHash"),
      boundsHash: parseHex(rawQuote.boundsHash, "boundsHash"),
      nonce: parseUintString(rawQuote.nonce, "nonce"),
      deadline: parseUintString(rawQuote.deadline, "deadline"),
    },
    claimData: parseHex(value.claimData, "claimData"),
    boundsData: parseHex(value.boundsData, "boundsData"),
    factorSignature: parseHex(value.factorSignature, "factorSignature"),
  };
}

export async function verifyReservoirQuote(
  provider: InjectedEthereum,
  account: Address,
  rawEnvelope: string,
): Promise<ReservoirQuoteCheck> {
  const envelope = parseSignedQuoteEnvelope(rawEnvelope);
  if (!RESERVOIR_DEPLOYMENT) {
    throw new Error("Firm quotes are disabled until the reviewed deployment is pinned");
  }
  const expectedAdapter =
    envelope.mode === "originate"
      ? RESERVOIR_DEPLOYMENT.lidoAdapter
      : RESERVOIR_DEPLOYMENT.lidoUnstETHAdapter;
  if (
    envelope.kernel !== RESERVOIR_DEPLOYMENT.kernel ||
    envelope.quote.adapter !== expectedAdapter
  ) {
    throw new Error("This quote does not use the reviewed deployment");
  }
  if (envelope.quote.seller.toLowerCase() !== account.toLowerCase()) {
    throw new Error("This quote is signed for a different seller");
  }
  if (
    envelope.quote.claimController.toLowerCase() ===
      envelope.quote.seller.toLowerCase() ||
    envelope.quote.claimReceiver.toLowerCase() ===
      envelope.quote.seller.toLowerCase()
  ) {
    throw new Error("The seller cannot remain the claim controller or receiver");
  }
  if (envelope.quote.paymentAsset !== ADDRESSES.weth) {
    throw new Error("The live Lido route only accepts WETH payment quotes");
  }
  if (
    keccak256(envelope.claimData) !== envelope.quote.claimDataHash ||
    keccak256(envelope.boundsData) !== envelope.quote.boundsHash
  ) {
    throw new Error("The signed claim or bounds hash does not match its payload");
  }

  const { publicClient } = clients(provider);
  const latestBlock = await publicClient.getBlock({ blockTag: "latest" });
  if (BigInt(envelope.quote.deadline) < latestBlock.timestamp) {
    throw new Error("This quote has expired on the target chain");
  }
  if (BigInt(envelope.quote.deadline) > latestBlock.timestamp + 15n * 60n) {
    throw new Error("This quote exceeds the kernel's 15-minute lifetime");
  }
  const kernelCode = await publicClient.getCode({ address: envelope.kernel });
  const adapterCode = await publicClient.getCode({
    address: envelope.quote.adapter,
  });
  if (!kernelCode || kernelCode === "0x" || !adapterCode || adapterCode === "0x") {
    throw new Error("The quote references an undeployed kernel or adapter");
  }

  const [
    factorSigner,
    fundingAccount,
    adapterAllowed,
    settlementSealed,
    settlementPaused,
    nonceUsed,
    nonceFloor,
    adapterSettlement,
    adapterStEth,
    adapterQueue,
  ] = await Promise.all([
    publicClient.readContract({
      address: envelope.kernel,
      abi: settlementAbi,
      functionName: "factorSigner",
    }),
    publicClient.readContract({
      address: envelope.kernel,
      abi: settlementAbi,
      functionName: "fundingAccount",
    }),
    publicClient.readContract({
      address: envelope.kernel,
      abi: settlementAbi,
      functionName: "isAdapterAllowed",
      args: [envelope.quote.adapter],
    }),
    publicClient.readContract({
      address: envelope.kernel,
      abi: settlementAbi,
      functionName: "isSealed",
    }),
    publicClient.readContract({
      address: envelope.kernel,
      abi: settlementAbi,
      functionName: "isPaused",
    }),
    publicClient.readContract({
      address: envelope.kernel,
      abi: settlementAbi,
      functionName: "nonceUsed",
      args: [BigInt(envelope.quote.nonce)],
    }),
    publicClient.readContract({
      address: envelope.kernel,
      abi: settlementAbi,
      functionName: "nonceFloor",
    }),
    publicClient.readContract({
      address: envelope.quote.adapter,
      abi: lidoAdapterAbi,
      functionName: "settlement",
    }),
    publicClient.readContract({
      address: envelope.quote.adapter,
      abi: lidoAdapterAbi,
      functionName: "stETH",
    }),
    publicClient.readContract({
      address: envelope.quote.adapter,
      abi: lidoAdapterAbi,
      functionName: "queue",
    }),
  ]);
  if (
    factorSigner !== envelope.quote.factor ||
    adapterSettlement !== envelope.kernel ||
    adapterStEth !== ADDRESSES.stEth ||
    adapterQueue !== ADDRESSES.lidoQueue ||
    !adapterAllowed ||
    !settlementSealed ||
    settlementPaused ||
    nonceUsed ||
    BigInt(envelope.quote.nonce) < nonceFloor
  ) {
    throw new Error("Quote deployment bindings or nonce state are invalid");
  }
  const domain = {
    name: "Reservoir v2",
    version: "1",
    chainId: MAINNET_CHAIN_ID,
    verifyingContract: envelope.kernel,
  } as const;
  const types = {
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
  const message = {
    ...envelope.quote,
    paymentAmount: BigInt(envelope.quote.paymentAmount),
    nonce: BigInt(envelope.quote.nonce),
    deadline: BigInt(envelope.quote.deadline),
  };
  const quoteHash = hashTypedData({
    domain,
    types,
    primaryType: "ClaimQuote",
    message,
  });
  const factorCode = await publicClient.getCode({ address: factorSigner });
  let signatureValid: boolean;
  if (!factorCode || factorCode === "0x") {
    signatureValid = await verifyTypedData({
      address: factorSigner,
      domain,
      types,
      primaryType: "ClaimQuote",
      message,
      signature: envelope.factorSignature,
    });
  } else {
    const magicValue = await publicClient.readContract({
      address: factorSigner,
      abi: erc1271Abi,
      functionName: "isValidSignature",
      args: [quoteHash, envelope.factorSignature],
    });
    signatureValid = magicValue.toLowerCase() === "0x1626ba7e";
  }
  if (!signatureValid) {
    throw new Error("The factor signature is invalid");
  }

  const [paymentAsset, fundingSealed, capacity] = await Promise.all([
    publicClient.readContract({
      address: fundingAccount,
      abi: fundingAccountAbi,
      functionName: "paymentAsset",
    }),
    publicClient.readContract({
      address: fundingAccount,
      abi: fundingAccountAbi,
      functionName: "isSealed",
    }),
    publicClient.readContract({
      address: fundingAccount,
      abi: fundingAccountAbi,
      functionName: "availableFor",
      args: [BigInt(envelope.quote.paymentAmount)],
    }),
  ]);
  if (
    paymentAsset !== ADDRESSES.weth ||
    !fundingSealed ||
    capacity !== BigInt(envelope.quote.paymentAmount)
  ) {
    throw new Error("The factor reserve cannot currently deliver this quote");
  }

  let requestedStEth: bigint;
  let requestId: bigint | null = null;
  let amountOfShares: bigint;
  let approvalSatisfied: boolean;

  if (envelope.mode === "originate") {
    const [claim] = decodeAbiParameters(
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
      envelope.claimData,
    );
    const [bounds] = decodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "maxStETHShortfall", type: "uint256" },
            { name: "minAmountOfShares", type: "uint256" },
          ],
        },
      ],
      envelope.boundsData,
    );
    if (claim.queue !== ADDRESSES.lidoQueue || claim.stETH !== ADDRESSES.stEth) {
      throw new Error("Quote claim data is not bound to canonical Lido");
    }
    requestedStEth = claim.requestedStETH;
    amountOfShares = bounds.minAmountOfShares;
    if (
      requestedStEth < MIN_LIDO_REQUEST ||
      requestedStEth > MAX_LIDO_REQUEST
    ) {
      throw new Error("The signed stETH amount is outside canonical Lido bounds");
    }
    const [sellerBalance, allowance] = await Promise.all([
      publicClient.readContract({
        address: ADDRESSES.stEth,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [account],
      }),
      publicClient.readContract({
        address: ADDRESSES.stEth,
        abi: erc20Abi,
        functionName: "allowance",
        args: [account, envelope.quote.adapter],
      }),
    ]);
    if (sellerBalance < requestedStEth) {
      throw new Error("The connected wallet has insufficient stETH for this quote");
    }
    approvalSatisfied = hasExactAllowance(allowance, requestedStEth);
  } else {
    const [claim] = decodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "queue", type: "address" },
            { name: "stETH", type: "address" },
            { name: "requestId", type: "uint256" },
          ],
        },
      ],
      envelope.claimData,
    );
    const [bounds] = decodeAbiParameters(
      [
        {
          type: "tuple",
          components: [
            { name: "minAmountOfStETH", type: "uint256" },
            { name: "maxAmountOfStETH", type: "uint256" },
            { name: "minAmountOfShares", type: "uint256" },
            { name: "maxAmountOfShares", type: "uint256" },
          ],
        },
      ],
      envelope.boundsData,
    );
    if (
      claim.queue !== ADDRESSES.lidoQueue ||
      claim.stETH !== ADDRESSES.stEth ||
      claim.requestId === 0n
    ) {
      throw new Error("Quote claim data is not bound to a canonical unstETH request");
    }
    if (
      bounds.minAmountOfStETH !== bounds.maxAmountOfStETH ||
      bounds.minAmountOfShares !== bounds.maxAmountOfShares ||
      bounds.minAmountOfShares === 0n
    ) {
      throw new Error("The existing-claim quote does not bind exact economics");
    }
    requestId = claim.requestId;
    requestedStEth = bounds.minAmountOfStETH;
    amountOfShares = bounds.minAmountOfShares;
    const [statuses, owner, approved, approvedForAll] = await Promise.all([
      publicClient.readContract({
        address: ADDRESSES.lidoQueue,
        abi: lidoQueueAbi,
        functionName: "getWithdrawalStatus",
        args: [[requestId]],
      }),
      publicClient.readContract({
        address: ADDRESSES.lidoQueue,
        abi: lidoQueueAbi,
        functionName: "ownerOf",
        args: [requestId],
      }),
      publicClient.readContract({
        address: ADDRESSES.lidoQueue,
        abi: lidoQueueAbi,
        functionName: "getApproved",
        args: [requestId],
      }),
      publicClient.readContract({
        address: ADDRESSES.lidoQueue,
        abi: lidoQueueAbi,
        functionName: "isApprovedForAll",
        args: [account, envelope.quote.adapter],
      }),
    ]);
    const status = statuses[0];
    if (
      statuses.length !== 1 ||
      !status ||
      status.isClaimed ||
      status.owner !== account ||
      owner !== account ||
      status.amountOfStETH !== requestedStEth ||
      status.amountOfShares !== amountOfShares
    ) {
      throw new Error("The owned unstETH position no longer matches the signed quote");
    }
    approvalSatisfied = approved === envelope.quote.adapter || approvedForAll;
  }
  const [queuePaused, bunkerMode] = await Promise.all([
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "isPaused",
    }),
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "isBunkerModeActive",
    }),
  ]);
  if (queuePaused) {
    throw new Error("Canonical Lido withdrawals are currently paused");
  }
  if (bunkerMode) {
    throw new Error("Firm quotes are disabled while Lido bunker mode is active");
  }

  return {
    envelope,
    requestedStEth,
    requestId,
    amountOfShares,
    capacity,
    approvalSatisfied,
    fundingAccount,
    quoteHash,
  };
}

export async function fillReservoirQuote(
  provider: InjectedEthereum,
  account: Address,
  check: ReservoirQuoteCheck,
) {
  const { envelope } = check;
  const { publicClient, walletClient } = clients(provider, account);
  if (!walletClient) throw new Error("Wallet client unavailable");
  const sellerWethBefore = await publicClient.readContract({
    address: ADDRESSES.weth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account],
  });
  if (envelope.mode === "originate") {
    const fillAllowance = await publicClient.readContract({
      address: ADDRESSES.stEth,
      abi: erc20Abi,
      functionName: "allowance",
      args: [account, envelope.quote.adapter],
    });
    if (!hasExactAllowance(fillAllowance, check.requestedStEth)) {
      throw new Error(
        "The adapter allowance changed; approve the exact signed stETH amount again",
      );
    }
  } else {
    if (check.requestId === null) throw new Error("The signed unstETH request is missing");
    const [owner, approved, approvedForAll] = await Promise.all([
      publicClient.readContract({
        address: ADDRESSES.lidoQueue,
        abi: lidoQueueAbi,
        functionName: "ownerOf",
        args: [check.requestId],
      }),
      publicClient.readContract({
        address: ADDRESSES.lidoQueue,
        abi: lidoQueueAbi,
        functionName: "getApproved",
        args: [check.requestId],
      }),
      publicClient.readContract({
        address: ADDRESSES.lidoQueue,
        abi: lidoQueueAbi,
        functionName: "isApprovedForAll",
        args: [account, envelope.quote.adapter],
      }),
    ]);
    if (
      owner !== account ||
      (approved !== envelope.quote.adapter && !approvedForAll)
    ) {
      throw new Error("The unstETH ownership or approval changed; approve this claim again");
    }
  }
  const quote = {
    ...envelope.quote,
    paymentAmount: BigInt(envelope.quote.paymentAmount),
    nonce: BigInt(envelope.quote.nonce),
    deadline: BigInt(envelope.quote.deadline),
  };
  const { request } = await publicClient.simulateContract({
    account,
    address: envelope.kernel,
    abi: settlementAbi,
    functionName: "fill",
    args: [
      quote,
      envelope.claimData,
      envelope.boundsData,
      envelope.factorSignature,
    ],
  });
  const estimatedGas = await publicClient.estimateContractGas({
    account,
    address: envelope.kernel,
    abi: settlementAbi,
    functionName: "fill",
    args: [
      quote,
      envelope.claimData,
      envelope.boundsData,
      envelope.factorSignature,
    ],
  });
  const hash = await walletClient.writeContract({
    ...request,
    gas: (estimatedGas * 15n) / 10n,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new MinedTransactionVerificationError(
      "The settlement transaction mined but reverted",
      hash,
    );
  }
  const settled = receipt.logs
    .filter(
      (log) => log.address.toLowerCase() === envelope.kernel.toLowerCase(),
    )
    .map((log) => {
      try {
        return decodeEventLog({
          abi: [claimSettledEvent],
          data: log.data,
          topics: log.topics,
        });
      } catch {
        return null;
      }
    })
    .find((log) => log?.eventName === "ClaimSettled");
  if (!settled || settled.eventName !== "ClaimSettled") {
    throw new MinedTransactionVerificationError(
      "Settlement receipt is missing ClaimSettled",
      hash,
    );
  }
  if (
    settled.args.quoteHash !== check.quoteHash ||
    settled.args.adapter !== envelope.quote.adapter ||
    settled.args.seller.toLowerCase() !== account.toLowerCase() ||
    settled.args.factor !== envelope.quote.factor ||
    settled.args.claimController !== envelope.quote.claimController ||
    settled.args.claimReceiver !== envelope.quote.claimReceiver ||
    settled.args.paymentAsset !== ADDRESSES.weth ||
    settled.args.paymentAmount !== BigInt(envelope.quote.paymentAmount)
  ) {
    throw new MinedTransactionVerificationError(
      "ClaimSettled does not match the pinned signed quote",
      hash,
    );
  }
  const [sellerWethAfter, statuses] = await Promise.all([
    publicClient.readContract({
      address: ADDRESSES.weth,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    }),
    publicClient.readContract({
      address: ADDRESSES.lidoQueue,
      abi: lidoQueueAbi,
      functionName: "getWithdrawalStatus",
      args: [[settled.args.claimId]],
    }),
  ]);
  const approvalCleared =
    envelope.mode === "originate"
      ? (await publicClient.readContract({
          address: ADDRESSES.stEth,
          abi: erc20Abi,
          functionName: "allowance",
          args: [account, envelope.quote.adapter],
        })) === 0n
      : (await publicClient.readContract({
          address: ADDRESSES.lidoQueue,
          abi: lidoQueueAbi,
          functionName: "getApproved",
          args: [settled.args.claimId],
        })) === "0x0000000000000000000000000000000000000000";
  const acquiredUnits = settled.args.pendingUnits + settled.args.claimableUnits;
  if (
    sellerWethAfter - sellerWethBefore !== settled.args.paymentAmount ||
    statuses.length !== 1 ||
    statuses[0].owner !== envelope.quote.claimReceiver ||
    statuses[0].amountOfShares !== acquiredUnits ||
    statuses[0].isClaimed ||
    !approvalCleared
  ) {
    throw new MinedTransactionVerificationError(
      "Settlement receipt failed canonical payment or claim checks",
      hash,
    );
  }
  return {
    hash,
    requestId: settled.args.claimId,
    paymentAmount: settled.args.paymentAmount,
    pendingReceived: settled.args.pendingReceived,
  };
}

export function requestWithdrawalCalldata(amount: bigint, owner: Address) {
  return encodeFunctionData({
    abi: lidoQueueAbi,
    functionName: "requestWithdrawals",
    args: [[amount], owner],
  });
}

export function formatMainnetAmount(value: bigint, places = 4) {
  const formatted = formatEther(value);
  const [whole, fraction = ""] = formatted.split(".");
  return fraction.length === 0
    ? whole
    : `${whole}.${fraction.slice(0, places).replace(/0+$/, "") || "0"}`;
}

export function etherscanTx(hash: Hash | string) {
  return `https://etherscan.io/tx/${hash}`;
}

export function etherscanToken(address: Address, tokenId?: bigint) {
  return tokenId === undefined
    ? `https://etherscan.io/address/${address}`
    : `https://etherscan.io/nft/${address}/${tokenId}`;
}
