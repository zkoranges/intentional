"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  formatEther,
  getAddress,
  parseEther,
  type Address,
  type Hash,
} from "viem";

import {
  ADDRESSES,
  MAX_LIVE_LIDO_QUOTE,
  MAX_LIDO_REQUEST,
  MIN_LIVE_LIDO_QUOTE,
  MIN_LIDO_REQUEST,
  MinedTransactionVerificationError,
  RESERVOIR_DEPLOYMENT,
  approveExact,
  approveUnstETH,
  claimLidoWithdrawal,
  connectInjectedWallet,
  ensureMainnet,
  etherscanToken,
  etherscanTx,
  fillReservoirQuote,
  formatMainnetAmount,
  getInjectedProvider,
  readLiveWallet,
  requestLidoWithdrawal,
  verifyReservoirQuote,
  type LiveWalletSnapshot,
  type ReservoirQuoteCheck,
  type WithdrawalStatus,
} from "../lib/ethereum";
type ActionState = "idle" | "connecting" | "reading" | "signing" | "mining";
type ExitMode = "claim" | "queue";
type NavSection = "markets" | "positions" | "faq";

type CompletedAction = {
  label: string;
  hash: Hash;
};

type LidoWaitEstimate = {
  market: "lido";
  amountStEth: "1";
  estimatedWaitMs: number;
  source: "lido-withdrawals-api";
};

type MarketState = "Live" | "Standby" | "Retired" | "Unavailable";

type MarketStatusResponse = {
  state: MarketState;
  capacityWei: string;
  firmQuoteConfigured: boolean;
  firmQuotesEnabled: boolean;
  detail: string;
  observedAt: string;
};

const GITHUB_URL = "https://github.com/zkoranges/intentional";
const DOCS_URL = "/docs";
const CONTRACTS_URL = `${GITHUB_URL}/tree/main/src/claims`;
const WALLET_DISCONNECTED_KEY = "intentional.wallet-disconnected";

const MARKETS = [
  {
    name: "Lido",
    asset: "stETH",
    claim: "Withdrawal claim",
    payout: "ETH",
    queueTime: null,
    queueDetail: "Live Lido estimate for a representative 1 stETH withdrawal",
    status: "Checking",
    active: false,
    icon: "/icons/steth.png",
    iconAlt: "stETH",
    iconClass: "stethIcon",
  },
  {
    name: "Ether.fi",
    asset: "eETH",
    claim: "Withdrawal request",
    payout: "ETH",
    queueTime: "~10 days",
    queueDetail:
      "Typical queued withdrawal; instant redemption may be available when Ether.fi has sufficient liquidity",
    status: "Next",
    active: false,
    icon: "/icons/etherfi.png",
    iconAlt: "Ether.fi",
    iconClass: "etherfiIcon",
  },
  {
    name: "Async vaults",
    asset: "ERC-7540",
    claim: "Redemption request",
    payout: "Vault asset",
    queueTime: "Vault-specific",
    queueDetail: "Each asynchronous vault defines its own settlement schedule",
    status: "Planned",
    active: false,
    icon: "/icons/vault.svg",
    iconAlt: "Vault",
    iconClass: "vaultIcon",
  },
] as const;

const FAQS = [
  {
    question: "What is onchain factoring?",
    answer:
      "Traditional factoring turns future receivables into cash today. Intentional applies the same idea to onchain withdrawals: a liquidity provider buys your future protocol payout and pays you now.",
  },
  {
    question: "Is this a loan?",
    answer:
      "No. You sell the withdrawal claim outright. There is no debt, repayment schedule or liquidation risk for you. The buyer takes over the wait and receives the eventual protocol payout.",
  },
  {
    question: "How do I get paid now?",
    answer:
      "You accept a short-lived firm quote. The withdrawal claim moves to the liquidity provider and the exact payment moves to you in one transaction. If either side fails, everything reverts.",
  },
  {
    question: "What am I selling?",
    answer:
      "You are selling the right to receive assets from a delayed withdrawal. For Lido, stETH enters the official queue and the resulting unstETH claim belongs to the buyer.",
  },
  {
    question: "Can I choose to wait instead?",
    answer:
      "Yes. The Wait for Lido route creates an unstETH withdrawal claim in your wallet. You keep the claim and redeem it after Lido finalizes the request.",
  },
] as const;

function short(value: string) {
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function unixDate(value: bigint) {
  return new Intl.DateTimeFormat("en", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(new Date(Number(value) * 1_000));
}

function errorMessage(error: unknown) {
  if (error instanceof Error) {
    const message = error.message
      .replace(/^.*execution reverted:?\s*/i, "")
      .replace(/\s*\(action=.*$/s, "");
    return message.length > 220 ? `${message.slice(0, 217)}…` : message;
  }
  return "The wallet action failed";
}

function quoteDiscount(check: ReservoirQuoteCheck | null) {
  if (!check || check.requestedStEth === 0n) return "—";
  const payment = BigInt(check.envelope.quote.paymentAmount);
  if (payment >= check.requestedStEth) return "0.00%";
  const basisPoints =
    ((check.requestedStEth - payment) * 10_000n) / check.requestedStEth;
  return `${(Number(basisPoints) / 100).toFixed(2)}%`;
}

function formatMarketWait(milliseconds: number) {
  const hours = milliseconds / (60 * 60 * 1_000);
  if (hours < 48) return `~${Math.max(1, Math.round(hours))} hours`;
  const days = hours / 24;
  return `~${days < 10 ? days.toFixed(1) : Math.round(days)} days`;
}

export default function Home() {
  const [account, setAccount] = useState<Address | null>(null);
  const [snapshot, setSnapshot] = useState<LiveWalletSnapshot | null>(null);
  const [action, setAction] = useState<ActionState>("idle");
  const [status, setStatus] = useState(
    "Connect your wallet to start an exit.",
  );
  const [mode, setMode] = useState<ExitMode>("claim");
  const [selectedClaimId, setSelectedClaimId] = useState<bigint | null>(null);
  const [amountInput, setAmountInput] = useState("0.00");
  const [actions, setActions] = useState<CompletedAction[]>([]);
  const [lastMintedRequest, setLastMintedRequest] = useState<bigint | null>(
    null,
  );
  const [claimQuoteCheck, setClaimQuoteCheck] =
    useState<ReservoirQuoteCheck | null>(null);
  const [walletMenuOpen, setWalletMenuOpen] = useState(false);
  const [activeSection, setActiveSection] =
    useState<NavSection>("markets");
  const [lidoWaitEstimate, setLidoWaitEstimate] =
    useState<LidoWaitEstimate | null>(null);
  const [marketStatus, setMarketStatus] = useState<MarketStatusResponse>({
    state: "Unavailable",
    capacityWei: "0",
    firmQuoteConfigured: false,
    firmQuotesEnabled: false,
    detail: "Checking live Ethereum deployment state",
    observedAt: "",
  });
  const walletMenuRef = useRef<HTMLDivElement>(null);

  const busy = action !== "idle";
  const marketLive = marketStatus.firmQuotesEnabled;
  const sellableClaims = useMemo(
    () => snapshot?.requests.filter((request) => !request.isClaimed) ?? [],
    [snapshot],
  );
  const selectedClaim =
    sellableClaims.find((request) => request.requestId === selectedClaimId) ??
    sellableClaims[0] ??
    null;
  const selectedClaimOffer =
    claimQuoteCheck?.requestId === selectedClaim?.requestId
      ? claimQuoteCheck
      : null;
  const selectedClaimWithinFirmLimits = Boolean(
    selectedClaim &&
      selectedClaim.amountOfStETH >= MIN_LIVE_LIDO_QUOTE &&
      selectedClaim.amountOfStETH <= MAX_LIVE_LIDO_QUOTE,
  );
  const amount = useMemo(() => {
    try {
      return parseEther(amountInput || "0");
    } catch {
      return 0n;
    }
  }, [amountInput]);
  const amountWithinLidoLimits =
    amount >= MIN_LIDO_REQUEST && amount <= MAX_LIDO_REQUEST;
  const amountValid =
    amountWithinLidoLimits &&
    Boolean(snapshot && amount <= snapshot.stEthBalance);
  const queueApproved = Boolean(
    snapshot && amount > 0n && snapshot.queueAllowance === amount,
  );
  const amountIssue =
    amount === 0n
      ? "Enter an amount"
      : amount < MIN_LIDO_REQUEST
        ? "Amount below minimum"
        : amount > MAX_LIDO_REQUEST
          ? "Amount above maximum"
          : snapshot && amount > snapshot.stEthBalance
            ? "Insufficient stETH balance"
            : null;

  const refresh = useCallback(
    async (connectedAccount = account) => {
      const injected = getInjectedProvider();
      if (!injected || !connectedAccount) return;
      setAction("reading");
      try {
        const next = await readLiveWallet(injected, connectedAccount);
        setSnapshot(next);
        setStatus(
          next.productionCodeVerified
            ? "Ethereum contracts verified. Choose an exit route."
            : "A required Ethereum contract could not be verified.",
        );
      } catch (error) {
        setSnapshot(null);
        setStatus(errorMessage(error));
      } finally {
        setAction("idle");
      }
    },
    [account],
  );

  useEffect(() => {
    const injected = getInjectedProvider();
    if (!injected) return;

    const onAccounts = (...args: unknown[]) => {
      const values = args[0] as string[] | undefined;
      if (!values?.[0]) {
        setAccount(null);
        setSnapshot(null);
        setWalletMenuOpen(false);
        setStatus("Wallet disconnected.");
        return;
      }
      if (sessionStorage.getItem(WALLET_DISCONNECTED_KEY) === "1") return;
      const next = getAddress(values[0]);
      setAccount(next);
      void refresh(next);
    };
    const onChain = () => {
      setSnapshot(null);
      if (account) void refresh(account);
    };

    injected.on?.("accountsChanged", onAccounts);
    injected.on?.("chainChanged", onChain);
    if (sessionStorage.getItem(WALLET_DISCONNECTED_KEY) === "1") {
      return () => {
        injected.removeListener?.("accountsChanged", onAccounts);
        injected.removeListener?.("chainChanged", onChain);
      };
    }
    void injected
      .request({ method: "eth_accounts" })
      .then((values) => {
        const accounts = values as string[];
        if (accounts[0]) {
          const next = getAddress(accounts[0]);
          setAccount(next);
          void refresh(next);
        }
      })
      .catch(() => undefined);

    return () => {
      injected.removeListener?.("accountsChanged", onAccounts);
      injected.removeListener?.("chainChanged", onChain);
    };
  }, [account, refresh]);

  useEffect(() => {
    const controller = new AbortController();
    void fetch("/api/status", {
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) throw new Error("Market status unavailable");
        const result = (await response.json()) as Partial<MarketStatusResponse>;
        if (
          !["Live", "Standby", "Retired", "Unavailable"].includes(
            result.state ?? "",
          ) ||
          typeof result.capacityWei !== "string" ||
          !/^\d+$/.test(result.capacityWei) ||
          typeof result.firmQuoteConfigured !== "boolean" ||
          typeof result.firmQuotesEnabled !== "boolean" ||
          typeof result.detail !== "string" ||
          typeof result.observedAt !== "string"
        ) {
          throw new Error("Invalid market status");
        }
        if (!controller.signal.aborted) {
          setMarketStatus(result as MarketStatusResponse);
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setMarketStatus({
            state: "Unavailable",
            capacityWei: "0",
            firmQuoteConfigured: false,
            firmQuotesEnabled: false,
            detail: "Live Ethereum status could not be verified",
            observedAt: "",
          });
        }
      });
    return () => controller.abort();
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    void fetch("/api/wait/lido", {
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) throw new Error("Lido wait estimate unavailable");
        const result = (await response.json()) as Partial<LidoWaitEstimate>;
        if (
          result.market !== "lido" ||
          result.amountStEth !== "1" ||
          result.source !== "lido-withdrawals-api" ||
          typeof result.estimatedWaitMs !== "number" ||
          !Number.isSafeInteger(result.estimatedWaitMs) ||
          result.estimatedWaitMs < 0
        ) {
          throw new Error("Invalid Lido wait estimate");
        }
        if (!controller.signal.aborted) {
          setLidoWaitEstimate(result as LidoWaitEstimate);
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) setLidoWaitEstimate(null);
      });
    return () => controller.abort();
  }, []);

  useEffect(() => {
    if (!walletMenuOpen) return;

    const closeOnOutsideClick = (event: PointerEvent) => {
      if (
        walletMenuRef.current &&
        !walletMenuRef.current.contains(event.target as Node)
      ) {
        setWalletMenuOpen(false);
      }
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setWalletMenuOpen(false);
    };
    document.addEventListener("pointerdown", closeOnOutsideClick);
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsideClick);
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [walletMenuOpen]);

  async function connect() {
    const injected = getInjectedProvider();
    if (!injected) {
      setStatus("Open Intentional in a browser with an Ethereum wallet.");
      return;
    }
    setAction("connecting");
    try {
      sessionStorage.removeItem(WALLET_DISCONNECTED_KEY);
      const next = await connectInjectedWallet(injected);
      setAccount(next);
      await refresh(next);
    } catch (error) {
      setStatus(errorMessage(error));
    } finally {
      setAction("idle");
    }
  }

  async function disconnect() {
    const injected = getInjectedProvider();
    sessionStorage.setItem(WALLET_DISCONNECTED_KEY, "1");
    setWalletMenuOpen(false);
    setAccount(null);
    setSnapshot(null);
    setClaimQuoteCheck(null);
    setActions([]);
    setLastMintedRequest(null);
    setStatus("Wallet disconnected. Your funds remain in your wallet.");

    if (!injected) return;
    try {
      await injected.request({
        method: "wallet_revokePermissions",
        params: [{ eth_accounts: {} }],
      });
    } catch {
      // Not every injected wallet implements permission revocation. The app
      // session remains disconnected and an explicit Connect removes the flag.
    }
  }

  async function switchToMainnet() {
    const injected = getInjectedProvider();
    if (!injected) return;
    setAction("connecting");
    try {
      await ensureMainnet(injected);
      await refresh(account);
    } catch (error) {
      setStatus(errorMessage(error));
    } finally {
      setAction("idle");
    }
  }

  async function handleMinedActionError(
    error: unknown,
    label: string,
    clearQuote = false,
  ) {
    if (error instanceof MinedTransactionVerificationError) {
      setActions((current) => [
        ...current,
        { label, hash: error.transactionHash },
      ]);
      if (clearQuote) setClaimQuoteCheck(null);
      if (account) await refresh(account);
    }
    setStatus(errorMessage(error));
    setAction("idle");
  }

  async function approveQueue() {
    const injected = getInjectedProvider();
    if (!injected || !account || !amountValid) return;
    setAction("signing");
    setStatus(
      `Approve exactly ${formatMainnetAmount(amount)} stETH for Lido.`,
    );
    try {
      const receipt = await approveExact(
        injected,
        account,
        ADDRESSES.lidoQueue,
        amount,
      );
      setActions((current) => [
        ...current,
        { label: "stETH approved for Lido", hash: receipt.transactionHash },
      ]);
      setStatus("Approval confirmed. Your withdrawal is ready.");
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Lido approval confirmed with a verification warning",
      );
    }
  }

  async function requestWithdrawal() {
    const injected = getInjectedProvider();
    if (!injected || !account || !amountValid || !queueApproved) return;
    setAction("signing");
    setStatus("Confirm the Lido withdrawal request in your wallet.");
    try {
      const result = await requestLidoWithdrawal(injected, account, amount);
      setAction("mining");
      setLastMintedRequest(result.requestId);
      setActions((current) => [
        ...current,
        { label: `unstETH #${result.requestId} created`, hash: result.hash },
      ]);
      setStatus(`Withdrawal #${result.requestId} is now in your wallet.`);
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Lido withdrawal confirmed with a verification warning",
      );
    }
  }

  async function claimRequest(requestId: bigint) {
    const injected = getInjectedProvider();
    if (!injected || !account) return;
    setAction("signing");
    setStatus(`Confirm the claim for unstETH #${requestId}.`);
    try {
      const result = await claimLidoWithdrawal(injected, account, requestId);
      setActions((current) => [
        ...current,
        { label: `unstETH #${requestId} claimed`, hash: result.hash },
      ]);
      setStatus(
        `${formatMainnetAmount(result.amountOfEth)} ETH was sent to your wallet.`,
      );
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        `Lido claim #${requestId} confirmed with a verification warning`,
      );
    }
  }

  async function approveReservoir(
    selectedCheck: ReservoirQuoteCheck | null = claimQuoteCheck,
  ) {
    const injected = getInjectedProvider();
    if (!injected || !account || !selectedCheck) return;
    setAction("signing");
    setStatus(
      selectedCheck.envelope.mode === "existing-unsteth"
        ? `Approve unstETH #${selectedCheck.requestId} for this sale.`
        : "Confirm the exact stETH approval for this exit.",
    );
    try {
      const receipt =
        selectedCheck.envelope.mode === "existing-unsteth" &&
        selectedCheck.requestId !== null
          ? await approveUnstETH(
              injected,
              account,
              selectedCheck.envelope.quote.adapter,
              selectedCheck.requestId,
            )
          : await approveExact(
              injected,
              account,
              selectedCheck.envelope.quote.adapter,
              selectedCheck.requestedStEth,
            );
      setActions((current) => [
        ...current,
        {
          label:
            selectedCheck.envelope.mode === "existing-unsteth"
              ? `unstETH #${selectedCheck.requestId} approved`
              : "stETH approved for Intentional",
          hash: receipt.transactionHash,
        },
      ]);
      const checked = await verifyReservoirQuote(
        injected,
        account,
        JSON.stringify(selectedCheck.envelope),
      );
      setClaimQuoteCheck(checked);
      setStatus("Approval confirmed. The same firm quote is ready to fill.");
    } catch (error) {
      await handleMinedActionError(
        error,
        "Intentional approval confirmed with a verification warning",
        selectedCheck.envelope.mode === "originate",
      );
      if (selectedCheck.envelope.mode === "existing-unsteth") {
        setClaimQuoteCheck(null);
      }
    } finally {
      setAction("idle");
    }
  }

  async function requestExistingClaimQuote(request: WithdrawalStatus) {
    const injected = getInjectedProvider();
    if (!injected || !account || request.isClaimed) return;
    if (!marketLive) {
      setStatus(marketStatus.detail);
      return;
    }
    if (!RESERVOIR_DEPLOYMENT) {
      setStatus("The firm quote deployment is not pinned in this app build");
      return;
    }

    setSelectedClaimId(request.requestId);
    setAction("reading");
    setClaimQuoteCheck(null);
    setStatus(`Requesting a firm offer for unstETH #${request.requestId}.`);
    try {
      const response = await fetch("/api/quote/lido", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          mode: "existing-unsteth",
          seller: account,
          requestId: request.requestId.toString(),
        }),
      });
      const payload: unknown = await response.json();
      if (!response.ok) {
        const message =
          typeof payload === "object" &&
          payload !== null &&
          typeof (payload as { error?: unknown }).error === "string"
            ? (payload as { error: string }).error
            : "Firm offers are unavailable right now";
        throw new Error(message);
      }
      const checked = await verifyReservoirQuote(
        injected,
        account,
        JSON.stringify(payload),
      );
      if (
        checked.envelope.mode !== "existing-unsteth" ||
        checked.requestId !== request.requestId ||
        checked.requestedStEth !== request.amountOfStETH ||
        checked.amountOfShares !== request.amountOfShares
      ) {
        throw new Error("The firm offer does not match this unstETH position");
      }
      setClaimQuoteCheck(checked);
      setStatus(
        `Firm offer ready: ${formatMainnetAmount(BigInt(checked.envelope.quote.paymentAmount))} WETH for unstETH #${request.requestId}.`,
      );
    } catch (error) {
      setStatus(errorMessage(error));
    } finally {
      setAction("idle");
    }
  }

  async function fillQuote(
    selectedCheck: ReservoirQuoteCheck | null = claimQuoteCheck,
  ) {
    const injected = getInjectedProvider();
    if (!injected || !account || !selectedCheck) return;
    setAction("signing");
    setStatus("Confirm the atomic claim sale.");
    try {
      const result = await fillReservoirQuote(injected, account, selectedCheck);
      setActions((current) => [
        ...current,
        {
          label: `${formatMainnetAmount(result.paymentAmount)} WETH received`,
          hash: result.hash,
        },
      ]);
      if (selectedCheck.envelope.mode === "originate") {
        setLastMintedRequest(result.requestId);
      }
      setStatus(
        selectedCheck.envelope.mode === "existing-unsteth"
          ? `Sale complete. unstETH #${result.requestId} moved to the buyer and ${formatMainnetAmount(result.paymentAmount)} WETH reached your wallet.`
          : `Exit complete. ${formatMainnetAmount(result.paymentAmount)} WETH reached your wallet.`,
      );
      setClaimQuoteCheck(null);
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Instant exit confirmed with a verification warning",
        selectedCheck.envelope.mode === "originate",
      );
      if (selectedCheck.envelope.mode === "existing-unsteth") {
        setClaimQuoteCheck(null);
      }
    }
  }

  function selectMode(nextMode: ExitMode) {
    setMode(nextMode);
    setStatus(
      nextMode === "claim"
        ? marketLive
          ? "Choose an owned unstETH claim to request a firm offer."
          : "Connect to inspect claims; public firm offers are not active."
        : "Use Lido directly and keep the withdrawal claim in your wallet.",
    );
  }

  function setBalancePercent(percent: 25 | 50 | 100) {
    if (!snapshot) return;
    const nextAmount = (snapshot.stEthBalance * BigInt(percent)) / 100n;
    setAmountInput(formatEther(nextAmount));
  }

  return (
    <>
      <div className="gavelBackdrop" aria-hidden="true" />
      <header className="appHeader">
        <a className="brand" href="#top" aria-label="Intentional home">
          <strong className="brandWordmark">
            intentional<span className="wordmarkDot">.</span>
            <span className="wordmarkTld">so</span>
          </strong>
        </a>
        <nav className="navLinks" aria-label="Primary navigation">
          <a
            className={activeSection === "markets" ? "active" : ""}
            href="#markets"
            aria-current={activeSection === "markets" ? "page" : undefined}
            onClick={() => setActiveSection("markets")}
          >
            Markets
          </a>
          <a
            className={activeSection === "positions" ? "active" : ""}
            href="#positions"
            aria-current={activeSection === "positions" ? "page" : undefined}
            onClick={() => setActiveSection("positions")}
          >
            Claims
          </a>
          <a
            className={activeSection === "faq" ? "active" : ""}
            href="#faq"
            aria-current={activeSection === "faq" ? "page" : undefined}
            onClick={() => setActiveSection("faq")}
          >
            About
          </a>
        </nav>
        <div className="navActions">
          <span
            className={`networkPill ${snapshot?.productionCodeVerified ? "verified" : ""}`}
          >
            <img
              src="/icons/eth.svg"
              alt=""
              width={18}
              height={18}
              aria-hidden="true"
            />
            Ethereum
          </span>
          {account ? (
            <div className="walletMenu" ref={walletMenuRef}>
              <button
                className="walletButton connected"
                onClick={() => setWalletMenuOpen((open) => !open)}
                disabled={busy}
                aria-haspopup="menu"
                aria-expanded={walletMenuOpen}
                aria-label={`Wallet ${short(account)}`}
              >
                <span className="walletAddress">{short(account)}</span>
                <svg
                  className="walletChevron"
                  width="14"
                  height="14"
                  viewBox="0 0 14 14"
                  fill="none"
                  aria-hidden="true"
                >
                  <path
                    d="M3.5 5.25 7 8.75l3.5-3.5"
                    stroke="currentColor"
                    strokeWidth="1.4"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </button>
              {walletMenuOpen && (
                <div className="walletPopover" role="menu">
                  <div className="walletPopoverAccount">
                    <span className="tokenIcon wethIcon">
                      <img
                        src="/icons/eth.svg"
                        alt=""
                        width={18}
                        height={18}
                      />
                    </span>
                    <div>
                      <small>Connected on Ethereum</small>
                      <strong>{short(account)}</strong>
                    </div>
                  </div>
                  <a
                    href={`https://etherscan.io/address/${account}`}
                    target="_blank"
                    rel="noreferrer"
                    role="menuitem"
                  >
                    View on Etherscan <span>↗</span>
                  </a>
                  <button type="button" onClick={disconnect} role="menuitem">
                    Disconnect wallet
                  </button>
                </div>
              )}
            </div>
          ) : (
            <button className="walletButton" onClick={connect} disabled={busy}>
              Connect wallet
            </button>
          )}
        </div>
      </header>

      <main id="top">
        <section className="appIntro">
          <p>Onchain factoring</p>
          <h1>
            Sell future payouts.
            <br />
            Get paid now.
          </h1>
          <span>
            Turn pending withdrawals and redemptions into liquidity.
            <br />
            A buyer takes the claim. Someone else waits.
          </span>
        </section>

        <section className="exitCard" id="exit" aria-label="Withdrawal interface">
          <div className="cardHeader">
            <div>
              <span className="cardEyebrow">
                {mode === "claim"
                  ? "Lido · unstETH → WETH"
                  : "Lido · stETH → unstETH"}
              </span>
              <h2>
                {mode === "claim"
                  ? "Sell an unstETH claim"
                  : "Withdraw through Lido"}
              </h2>
              <p>
                {mode === "claim"
                  ? "Transfer an owned withdrawal NFT and get paid now."
                  : "Keep the withdrawal claim in your wallet."}
              </p>
            </div>
            <a className="helpLink" href="#faq" aria-label="Learn about exits">
              ?
            </a>
          </div>

          <div className="modeTabs" role="tablist" aria-label="Exit route">
            <button
              role="tab"
              aria-selected={mode === "claim"}
              className={mode === "claim" ? "selected" : ""}
              onClick={() => selectMode("claim")}
            >
              Sell claim
            </button>
            <button
              role="tab"
              aria-selected={mode === "queue"}
              className={mode === "queue" ? "selected" : ""}
              onClick={() => selectMode("queue")}
            >
              Wait & claim
            </button>
          </div>

          <p className="modeNote">
            {mode === "claim"
              ? "Choose an unstETH NFT you own. The claim and WETH payment move atomically. Pre-alpha firm offers are capped to claims from 0.0005 to 0.0015 stETH."
              : "Join the official Lido queue and claim ETH after finalization."}
          </p>

          {mode === "claim" ? (
            <>
              <div className="tokenPanel inputPanel">
                <div className="tokenPanelLabel">
                  <span>You sell</span>
                  <span>
                    {snapshot
                      ? `${sellableClaims.length} owned claim${sellableClaims.length === 1 ? "" : "s"}`
                      : "Connect wallet"}
                  </span>
                </div>
                <div className="tokenRow">
                  <select
                    className="claimSelect"
                    aria-label="Owned unstETH claim"
                    disabled={!selectedClaim || busy}
                    value={selectedClaim?.requestId.toString() ?? ""}
                    onChange={(event) => {
                      const requestId = BigInt(event.target.value);
                      setSelectedClaimId(requestId);
                      setClaimQuoteCheck(null);
                      setStatus(`Selected unstETH #${requestId}.`);
                    }}
                  >
                    {selectedClaim ? (
                      sellableClaims.map((request) => (
                        <option
                          key={request.requestId.toString()}
                          value={request.requestId.toString()}
                        >
                          #{request.requestId} ·{" "}
                          {formatMainnetAmount(request.amountOfStETH, 6)} stETH
                        </option>
                      ))
                    ) : (
                      <option value="">No unstETH claim found</option>
                    )}
                  </select>
                  <div className="tokenSelect static">
                    <span className="tokenIcon nftIcon">
                      <img
                        src="/icons/unsteth.svg"
                        alt="unstETH"
                        width={18}
                        height={18}
                      />
                    </span>
                    unstETH
                  </div>
                </div>
              </div>

              <div className="routeArrow" aria-hidden="true">
                ↓
              </div>

              <div className="tokenPanel outputPanel">
                <div className="tokenPanelLabel">
                  <span>You receive</span>
                  <span>{selectedClaimOffer ? "Signed firm offer" : "No estimate shown"}</span>
                </div>
                <div className="tokenRow">
                  <output>
                    {selectedClaimOffer
                      ? formatMainnetAmount(
                          BigInt(
                            selectedClaimOffer.envelope.quote.paymentAmount,
                          ),
                          6,
                        )
                      : "—"}
                  </output>
                  <div className="tokenSelect static">
                    <span className="tokenIcon wethIcon">
                      <img
                        src="/icons/weth.svg"
                        alt="WETH"
                        width={18}
                        height={18}
                      />
                    </span>
                    WETH
                  </div>
                </div>
              </div>

              <div className="routeSummary">
                <div>
                  <span>Claim</span>
                  <strong>
                    <i className="instantRoute" />
                    {selectedClaim
                      ? `unstETH #${selectedClaim.requestId}`
                      : "Connect to inspect"}
                  </strong>
                </div>
                <div>
                  <span>Claim notional</span>
                  <strong>
                    {selectedClaim
                      ? `${formatMainnetAmount(selectedClaim.amountOfStETH, 6)} stETH`
                      : "—"}
                  </strong>
                </div>
                <div>
                  <span>Claim state</span>
                  <strong>
                    {selectedClaim
                      ? selectedClaim.isFinalized
                        ? "Finalized"
                        : "Pending"
                      : "—"}
                  </strong>
                </div>
                <div>
                  <span>Factoring discount</span>
                  <strong>
                    {selectedClaimOffer
                      ? quoteDiscount(selectedClaimOffer)
                      : "Set by signed offer"}
                  </strong>
                </div>
                <div>
                  <span>Who waits</span>
                  <strong>Liquidity provider</strong>
                </div>
              </div>

              <div className="primaryAction">
                {!account ? (
                  <button className="actionButton" onClick={connect} disabled={busy}>
                    Connect wallet
                  </button>
                ) : !snapshot ? (
                  <button
                    className="actionButton"
                    onClick={switchToMainnet}
                    disabled={busy}
                  >
                    Switch to Ethereum
                  </button>
                ) : !marketLive ? (
                  <button className="actionButton" disabled>
                    {marketStatus.state === "Retired"
                      ? "Firm offers paused · deployment retired"
                      : "Firm offers unavailable"}
                  </button>
                ) : !selectedClaim ? (
                  <button
                    className="actionButton"
                    onClick={() => selectMode("queue")}
                    disabled={busy}
                  >
                    Create a Lido claim first
                  </button>
                ) : !selectedClaimWithinFirmLimits ? (
                  <button className="actionButton" disabled>
                    Claim outside 0.0005–0.0015 stETH pilot
                  </button>
                ) : !selectedClaimOffer ? (
                  <button
                    className="actionButton"
                    onClick={() => requestExistingClaimQuote(selectedClaim)}
                    disabled={busy}
                  >
                    {action === "reading" ? "Getting firm offer…" : "Get firm offer"}
                  </button>
                ) : !selectedClaimOffer.approvalSatisfied ? (
                  <button
                    className="actionButton"
                    onClick={() => approveReservoir(selectedClaimOffer)}
                    disabled={busy}
                  >
                    Approve unstETH #{selectedClaim.requestId}
                  </button>
                ) : (
                  <button
                    className="actionButton"
                    onClick={() => fillQuote(selectedClaimOffer)}
                    disabled={busy}
                  >
                    Sell for{" "}
                    {formatMainnetAmount(
                      BigInt(selectedClaimOffer.envelope.quote.paymentAmount),
                      6,
                    )}{" "}
                    WETH
                  </button>
                )}
              </div>
            </>
          ) : (
            <>
              <div className="tokenPanel inputPanel">
                <div className="tokenPanelLabel">
                  <span>You deposit</span>
                  <span>
                    Balance:{" "}
                    {snapshot
                      ? formatMainnetAmount(snapshot.stEthBalance, 6)
                      : "—"}
                  </span>
                </div>
                <div className="tokenRow">
                  <input
                    inputMode="decimal"
                    value={amountInput}
                    onChange={(event) => setAmountInput(event.target.value)}
                    aria-label="stETH amount"
                    placeholder="0.00"
                  />
                  <div className="tokenSelect">
                    <span className="tokenIcon stethIcon">
                      <img
                        src="/icons/steth.png"
                        alt="stETH"
                        width={18}
                        height={18}
                      />
                    </span>
                    stETH
                  </div>
                </div>
                <div className="amountActions" aria-label="Amount shortcuts">
                  <button
                    type="button"
                    onClick={() => setBalancePercent(25)}
                    disabled={!snapshot || busy}
                  >
                    25%
                  </button>
                  <button
                    type="button"
                    onClick={() => setBalancePercent(50)}
                    disabled={!snapshot || busy}
                  >
                    50%
                  </button>
                  <button
                    className="maxButton"
                    type="button"
                    onClick={() => setBalancePercent(100)}
                    disabled={!snapshot || busy}
                  >
                    Max
                  </button>
                </div>
                {amountIssue && amount > 0n && (
                  <p className="amountError">{amountIssue}</p>
                )}
              </div>

              <div className="routeArrow" aria-hidden="true">
                ↓
              </div>

              <div className="tokenPanel outputPanel">
                <div className="tokenPanelLabel">
                  <span>You receive</span>
                  <span>Canonical Lido claim</span>
                </div>
                <div className="tokenRow">
                  <output>
                    {amountValid ? formatMainnetAmount(amount, 6) : "—"}
                  </output>
                  <div className="tokenSelect static">
                    <span className="tokenIcon nftIcon">
                      <img
                        src="/icons/unsteth.svg"
                        alt="unstETH"
                        width={18}
                        height={18}
                      />
                    </span>
                    ETH claim
                  </div>
                </div>
              </div>

              <div className="routeSummary">
                <div>
                  <span>Claim token</span>
                  <strong>
                    <i className="lidoRoute" />1 unstETH NFT
                  </strong>
                </div>
                <div>
                  <span>Claim notional</span>
                  <strong>
                    {amountValid
                      ? `~${formatMainnetAmount(amount, 6)} ETH`
                      : "—"}
                  </strong>
                </div>
                <div>
                  <span>Liquidity fee</span>
                  <strong>None</strong>
                </div>
                <div>
                  <span>Who waits</span>
                  <strong>You</strong>
                </div>
              </div>

              <div className="primaryAction">
                {!account ? (
                  <button className="actionButton" onClick={connect} disabled={busy}>
                    Connect wallet
                  </button>
                ) : !snapshot ? (
                  <button
                    className="actionButton"
                    onClick={switchToMainnet}
                    disabled={busy}
                  >
                    Switch to Ethereum
                  </button>
                ) : !queueApproved ? (
                  <button
                    className="actionButton"
                    onClick={approveQueue}
                    disabled={!amountValid || snapshot.queuePaused || busy}
                  >
                    {snapshot.queuePaused
                      ? "Lido withdrawals paused"
                      : amountIssue ?? "Approve stETH"}
                  </button>
                ) : (
                  <button
                    className="actionButton"
                    onClick={requestWithdrawal}
                    disabled={!amountValid || snapshot.queuePaused || busy}
                  >
                    Request withdrawal
                  </button>
                )}
              </div>
            </>
          )}

          <div className="statusBar" aria-live="polite">
            <span
              className={
                busy
                  ? "statusSpinner"
                  : snapshot?.productionCodeVerified
                    ? "statusDot ready"
                    : "statusDot"
              }
            />
            <p>{status}</p>
            {account && (
              <button onClick={() => refresh()} disabled={busy}>
                Refresh
              </button>
            )}
          </div>
        </section>

        <section className="marketsSection" id="markets" aria-label="Factoring markets">
          <div className="marketHeader">
            <span>Factoring markets</span>
            <small>
              Lido: {marketStatus.state}
              {marketStatus.state === "Live"
                ? ` · ${formatMainnetAmount(BigInt(marketStatus.capacityWei), 4)} WETH capacity`
                : " · More adapters under development"}
            </small>
          </div>
          <div className="marketGrid">
            {MARKETS.map((market) => {
              const isLido = market.name === "Lido";
              const isActive = isLido ? marketLive : market.active;
              const displayedStatus = isLido
                ? marketStatus.state
                : market.status;
              return (
                <a
                  className={`marketCard ${isActive ? "active" : ""}`}
                  href={isActive ? "#exit" : "#markets"}
                  aria-label={`${market.name} ${market.asset} market — ${displayedStatus}`}
                  key={market.name}
                >
                <div className="marketIdentity">
                  <span className={`tokenIcon ${market.iconClass}`}>
                    <img src={market.icon} alt={market.iconAlt} width={18} height={18} />
                  </span>
                  <div>
                    <strong>{market.name}</strong>
                    <small>{market.asset}</small>
                  </div>
                </div>
                <dl>
                  <div>
                    <dt>Claim</dt>
                    <dd>{market.claim}</dd>
                  </div>
                  <div>
                    <dt>Payout</dt>
                    <dd>{market.payout}</dd>
                  </div>
                  <div>
                    <dt>Queue time</dt>
                    <dd
                      className={
                        market.name === "Lido" && lidoWaitEstimate
                          ? "queueTime live"
                          : "queueTime"
                      }
                      title={market.queueDetail}
                    >
                      {isLido
                        ? lidoWaitEstimate
                          ? formatMarketWait(lidoWaitEstimate.estimatedWaitMs)
                          : "Checking live…"
                        : market.queueTime}
                    </dd>
                  </div>
                </dl>
                <span className={`marketStatus ${isActive ? "open" : ""}`}>
                  {displayedStatus}
                </span>
              </a>
              );
            })}
          </div>
        </section>

        <section className="positionsSection" id="positions">
          <div className="sectionHeading">
            <div>
              <p>Your receivables</p>
              <h2>Onchain claims</h2>
            </div>
            {account && <span>{short(account)}</span>}
          </div>

          {snapshot?.requests.length ? (
            <div className="positionList">
                  {snapshot.requests.map((request) => {
                    const activeOffer =
                      claimQuoteCheck?.envelope.mode === "existing-unsteth" &&
                      claimQuoteCheck.requestId === request.requestId
                        ? claimQuoteCheck
                        : null;
                    return (
                    <article
                      className={activeOffer ? "positionWithOffer" : ""}
                      key={request.requestId.toString()}
                    >
                  <div className="positionIdentity">
                    <span className="tokenIcon nftIcon">
                      <img src="/icons/unsteth.svg" alt="unstETH" width={18} height={18} />
                    </span>
                    <div>
                      <strong>unstETH #{request.requestId}</strong>
                      <small>{unixDate(request.timestamp)}</small>
                    </div>
                  </div>
                  <div>
                    <span>Amount</span>
                    <strong>
                      {formatMainnetAmount(request.amountOfStETH)} stETH
                    </strong>
                  </div>
                  <div>
                    <span>Status</span>
                    <strong
                      className={`positionStatus ${
                        request.isClaimed
                          ? "claimed"
                          : request.isFinalized
                            ? "claimable"
                            : "pending"
                      }`}
                    >
                      {request.isClaimed
                        ? "Claimed"
                        : request.isFinalized
                          ? "Claimable"
                          : "Pending"}
                    </strong>
                  </div>
                      <div className="positionAction">
                        {request.isClaimed ? (
                          <a
                        href={etherscanToken(
                          ADDRESSES.lidoQueue,
                          request.requestId,
                        )}
                        target="_blank"
                        rel="noreferrer"
                      >
                            View ↗
                          </a>
                        ) : activeOffer ? (
                          !activeOffer.approvalSatisfied ? (
                            <button
                              onClick={() => approveReservoir(activeOffer)}
                              disabled={busy}
                            >
                              Approve claim
                            </button>
                          ) : (
                            <button
                              onClick={() => fillQuote(activeOffer)}
                              disabled={busy}
                            >
                              Sell for{" "}
                              {formatMainnetAmount(
                                BigInt(activeOffer.envelope.quote.paymentAmount),
                                6,
                              )}{" "}
                              WETH
                            </button>
                          )
                        ) : (
                          <>
                            <button
                              onClick={() => requestExistingClaimQuote(request)}
                              disabled={busy || !marketLive}
                            >
                              {marketLive ? "Get firm offer" : "Offers paused"}
                            </button>
                            {request.isFinalized && (
                              <button
                                onClick={() => claimRequest(request.requestId)}
                                disabled={busy}
                              >
                                Claim ETH
                              </button>
                            )}
                          </>
                        )}
                      </div>
                    </article>
                    );
                  })}
            </div>
          ) : (
            <div className="emptyPositions">
              <span className="emptyIcon">≈</span>
              <strong>
                {snapshot ? "No withdrawals yet" : "Connect to view positions"}
              </strong>
              <p>
                {snapshot
                  ? "New Lido withdrawal requests will appear here."
                  : "Intentional reads your Lido withdrawals directly from Ethereum."}
              </p>
            </div>
          )}
        </section>

        {actions.length > 0 && (
          <section className="activitySection" aria-label="Recent activity">
            <div className="sectionHeading compact">
              <div>
                <p>Recent activity</p>
                <h2>Transactions</h2>
              </div>
              {lastMintedRequest !== null && (
                <a
                  href={etherscanToken(
                    ADDRESSES.lidoQueue,
                    lastMintedRequest,
                  )}
                  target="_blank"
                  rel="noreferrer"
                >
                  View latest position ↗
                </a>
              )}
            </div>
            <ol>
              {actions.map((item) => (
                <li key={`${item.hash}-${item.label}`}>
                  <span>{item.label}</span>
                  <a
                    href={etherscanTx(item.hash)}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {short(item.hash)} ↗
                  </a>
                </li>
              ))}
            </ol>
          </section>
        )}

        <section className="faqSection" id="faq">
          <div className="sectionHeading">
            <div>
              <p>The factoring model</p>
              <h2>Future value, liquid today.</h2>
            </div>
            <a href={DOCS_URL}>
              Read the docs ↗
            </a>
          </div>
          <div className="faqList">
            {FAQS.map((item) => (
              <details key={item.question}>
                <summary>
                  {item.question}
                  <span>+</span>
                </summary>
                <p>{item.answer}</p>
              </details>
            ))}
          </div>
        </section>

        <section className="docsStrip" aria-label="Documentation links">
          <div>
            <span>Technical documentation</span>
            <strong>Settlement infrastructure for onchain factoring.</strong>
          </div>
          <div className="docsLinks">
            <a href={DOCS_URL}>
              Docs ↗
            </a>
            <a href={CONTRACTS_URL} target="_blank" rel="noreferrer">
              Contracts ↗
            </a>
            <a href={GITHUB_URL} target="_blank" rel="noreferrer">
              GitHub ↗
            </a>
          </div>
        </section>
      </main>

      <footer className="siteFooter">
        <div className="siteFooterInner">
          <div className="footerIdentity">
            <a className="brand" href="#top" aria-label="Intentional home">
              <strong className="brandWordmark">
                intentional<span className="wordmarkDot">.</span>
                <span className="wordmarkTld">so</span>
              </strong>
            </a>
            <p>Onchain factoring for delayed claims.</p>
          </div>
          <nav className="footerNav" aria-label="Footer navigation">
            <a href="#markets">Markets</a>
            <a href="#positions">Claims</a>
            <a href={DOCS_URL}>Docs</a>
            <a href={GITHUB_URL} target="_blank" rel="noreferrer">
              GitHub <span aria-hidden="true">↗</span>
            </a>
          </nav>
        </div>
      </footer>

    </>
  );
}
