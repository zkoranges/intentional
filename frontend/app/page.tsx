"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getAddress, parseEther, type Address, type Hash } from "viem";

import {
  ADDRESSES,
  MAX_LIDO_REQUEST,
  MIN_LIDO_REQUEST,
  MinedTransactionVerificationError,
  RESERVOIR_DEPLOYMENT,
  approveExact,
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
} from "../lib/ethereum";

type ActionState = "idle" | "connecting" | "reading" | "signing" | "mining";
type ExitMode = "instant" | "queue";

type CompletedAction = {
  label: string;
  hash: Hash;
};

const GITHUB_URL = "https://github.com/zkoranges/reservoir-v2-eth-lisbon";
const DOCS_URL = `${GITHUB_URL}#readme`;
const CONTRACTS_URL = `${GITHUB_URL}/tree/main/src/claims`;

const FAQS = [
  {
    question: "What is Reservoir?",
    answer:
      "Reservoir is an instant-liquidity layer for delayed withdrawals. A factor acquires your future withdrawal claim and pays you from productive reserves in the same transaction.",
  },
  {
    question: "How does an instant exit work?",
    answer:
      "You accept a short-lived firm quote. Reservoir verifies the claim, reserve capacity and signed terms, acquires the withdrawal claim, then releases the exact payment. If any step fails, the whole transaction reverts.",
  },
  {
    question: "What is the Lido queue option?",
    answer:
      "The standard route sends stETH directly to Lido and mints an unstETH withdrawal NFT to your wallet. You keep the claim and redeem it for ETH after Lido finalizes it.",
  },
  {
    question: "What risks should I understand?",
    answer:
      "Queue timing, final redemption value and protocol conditions can change. Reservoir quotes include a discount for that uncertainty. Always review the amount, route, contract addresses and wallet simulation before signing.",
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

export default function Home() {
  const [account, setAccount] = useState<Address | null>(null);
  const [snapshot, setSnapshot] = useState<LiveWalletSnapshot | null>(null);
  const [action, setAction] = useState<ActionState>("idle");
  const [status, setStatus] = useState(
    "Connect your wallet to start an exit.",
  );
  const [mode, setMode] = useState<ExitMode>("instant");
  const [amountInput, setAmountInput] = useState("0.10");
  const [actions, setActions] = useState<CompletedAction[]>([]);
  const [lastMintedRequest, setLastMintedRequest] = useState<bigint | null>(
    null,
  );
  const [quoteInput, setQuoteInput] = useState("");
  const [quoteCheck, setQuoteCheck] = useState<ReservoirQuoteCheck | null>(null);
  const [quoteModalOpen, setQuoteModalOpen] = useState(false);

  const provider = getInjectedProvider();
  const busy = action !== "idle";
  const amount = useMemo(() => {
    try {
      return parseEther(amountInput || "0");
    } catch {
      return 0n;
    }
  }, [amountInput]);
  const amountValid =
    amount >= MIN_LIDO_REQUEST &&
    amount <= MAX_LIDO_REQUEST &&
    Boolean(snapshot && amount <= snapshot.stEthBalance);
  const queueApproved = Boolean(
    snapshot && amount > 0n && snapshot.queueAllowance === amount,
  );

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
        setStatus("Wallet disconnected.");
        return;
      }
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
    if (!quoteModalOpen) return;

    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setQuoteModalOpen(false);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [quoteModalOpen]);

  async function connect() {
    const injected = getInjectedProvider();
    if (!injected) {
      setStatus("Open Reservoir in a browser with an Ethereum wallet.");
      return;
    }
    setAction("connecting");
    try {
      const next = await connectInjectedWallet(injected);
      setAccount(next);
      await refresh(next);
    } catch (error) {
      setStatus(errorMessage(error));
    } finally {
      setAction("idle");
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
      if (clearQuote) setQuoteCheck(null);
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

  async function inspectQuote() {
    const injected = getInjectedProvider();
    if (
      !injected ||
      !account ||
      !quoteInput.trim() ||
      !RESERVOIR_DEPLOYMENT
    )
      return;
    setAction("reading");
    setQuoteCheck(null);
    setStatus("Checking quote terms and available liquidity.");
    try {
      const checked = await verifyReservoirQuote(
        injected,
        account,
        quoteInput,
      );
      setQuoteCheck(checked);
      setQuoteModalOpen(false);
      setStatus(
        `Firm quote ready: ${formatMainnetAmount(BigInt(checked.envelope.quote.paymentAmount))} WETH.`,
      );
    } catch (error) {
      setStatus(errorMessage(error));
      setAction("idle");
    }
  }

  async function approveReservoir() {
    const injected = getInjectedProvider();
    if (!injected || !account || !quoteCheck) return;
    setAction("signing");
    setStatus("Confirm the exact stETH approval for this exit.");
    try {
      const receipt = await approveExact(
        injected,
        account,
        quoteCheck.envelope.quote.adapter,
        quoteCheck.requestedStEth,
      );
      setActions((current) => [
        ...current,
        { label: "stETH approved for Reservoir", hash: receipt.transactionHash },
      ]);
      setStatus("Approval confirmed. Re-check the quote before exiting.");
      setQuoteCheck(null);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Reservoir approval confirmed with a verification warning",
        true,
      );
    } finally {
      setAction("idle");
    }
  }

  async function fillQuote() {
    const injected = getInjectedProvider();
    if (!injected || !account || !quoteCheck) return;
    setAction("signing");
    setStatus("Confirm your instant exit.");
    try {
      const result = await fillReservoirQuote(injected, account, quoteCheck);
      setActions((current) => [
        ...current,
        {
          label: `${formatMainnetAmount(result.paymentAmount)} WETH received`,
          hash: result.hash,
        },
      ]);
      setLastMintedRequest(result.requestId);
      setStatus(
        `Exit complete. ${formatMainnetAmount(result.paymentAmount)} WETH reached your wallet.`,
      );
      setQuoteCheck(null);
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Reservoir exit confirmed with a verification warning",
        true,
      );
    }
  }

  function selectMode(nextMode: ExitMode) {
    setMode(nextMode);
    setStatus(
      nextMode === "instant"
        ? RESERVOIR_DEPLOYMENT
          ? "Import a firm quote to continue."
          : "Instant exits are not active yet. The Lido queue remains available."
        : "Use Lido directly and keep the withdrawal claim in your wallet.",
    );
  }

  const instantPayment = quoteCheck
    ? formatMainnetAmount(BigInt(quoteCheck.envelope.quote.paymentAmount))
    : "—";

  return (
    <>
      <header className="appHeader">
        <a className="brand" href="#top" aria-label="Reservoir home">
          <span className="brandMark">R</span>
          <strong>Reservoir</strong>
        </a>
        <nav className="navLinks" aria-label="Primary navigation">
          <a className="active" href="#exit">
            Exit
          </a>
          <a href="#positions">Positions</a>
          <a href="#faq">Learn</a>
        </nav>
        <div className="navActions">
          <span
            className={`networkPill ${snapshot?.productionCodeVerified ? "verified" : ""}`}
          >
            <i />
            Ethereum
          </span>
          <button className="walletButton" onClick={connect} disabled={busy}>
            {account ? short(account) : "Connect"}
          </button>
        </div>
      </header>

      <main id="top">
        <section className="appIntro">
          <p>Liquidity for delayed withdrawals</p>
          <h1>Exit when you want.</h1>
        </section>

        <section className="exitCard" id="exit" aria-label="Withdrawal interface">
          <div className="cardHeader">
            <div className="modeTabs" role="tablist" aria-label="Exit route">
              <button
                role="tab"
                aria-selected={mode === "instant"}
                className={mode === "instant" ? "selected" : ""}
                onClick={() => selectMode("instant")}
              >
                Instant exit
              </button>
              <button
                role="tab"
                aria-selected={mode === "queue"}
                className={mode === "queue" ? "selected" : ""}
                onClick={() => selectMode("queue")}
              >
                Lido queue
              </button>
            </div>
            <a className="helpLink" href="#faq" aria-label="Learn about exit routes">
              ?
            </a>
          </div>

          <div className="tokenPanel">
            <div className="tokenPanelLabel">
              <span>You send</span>
              <span>
                Balance:{" "}
                {snapshot
                  ? formatMainnetAmount(snapshot.stEthBalance)
                  : "—"}
              </span>
            </div>
            <div className="tokenRow">
              <input
                inputMode="decimal"
                value={amountInput}
                onChange={(event) => {
                  setAmountInput(event.target.value);
                  setQuoteCheck(null);
                }}
                aria-label="stETH amount"
                placeholder="0"
              />
              <button className="tokenSelect" type="button" tabIndex={-1}>
                <span className="tokenIcon stethIcon">S</span>
                stETH
              </button>
            </div>
            {snapshot && (
              <button
                className="maxButton"
                type="button"
                onClick={() =>
                  setAmountInput(formatMainnetAmount(snapshot.stEthBalance))
                }
              >
                Max
              </button>
            )}
          </div>

          <div className="routeArrow" aria-hidden="true">
            ↓
          </div>

          <div className="tokenPanel outputPanel">
            <div className="tokenPanelLabel">
              <span>{mode === "instant" ? "You receive" : "You receive"}</span>
              <span>{mode === "instant" ? "Firm quote" : "After request"}</span>
            </div>
            <div className="tokenRow">
              <output>
                {mode === "instant"
                  ? instantPayment
                  : amountValid
                    ? "1"
                    : "—"}
              </output>
              <div className="tokenSelect static">
                <span
                  className={`tokenIcon ${mode === "instant" ? "wethIcon" : "nftIcon"}`}
                >
                  {mode === "instant" ? "W" : "N"}
                </span>
                {mode === "instant" ? "WETH" : "unstETH"}
              </div>
            </div>
          </div>

          <div className="routeSummary">
            <div>
              <span>Route</span>
              <strong>{mode === "instant" ? "Reservoir" : "Lido"}</strong>
            </div>
            <div>
              <span>Timing</span>
              <strong>{mode === "instant" ? "Immediate" : "Protocol queue"}</strong>
            </div>
            <div>
              <span>Claim owner</span>
              <strong>{mode === "instant" ? "Factor" : "You"}</strong>
            </div>
          </div>

          {!provider && (
            <div className="inlineNotice">
              No browser wallet detected. Open Reservoir with MetaMask, Rabby,
              Frame, or another Ethereum wallet.
            </div>
          )}

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
            ) : mode === "instant" ? (
              !RESERVOIR_DEPLOYMENT ? (
                <button className="actionButton" disabled>
                  Instant exits coming soon
                </button>
              ) : !quoteCheck ? (
                <button
                  className="actionButton"
                  onClick={() => setQuoteModalOpen(true)}
                  disabled={busy || !amountValid}
                >
                  Import firm quote
                </button>
              ) : quoteCheck.allowance !== quoteCheck.requestedStEth ? (
                <button
                  className="actionButton"
                  onClick={approveReservoir}
                  disabled={busy}
                >
                  Approve stETH
                </button>
              ) : (
                <button
                  className="actionButton"
                  onClick={fillQuote}
                  disabled={busy}
                >
                  Exit for {instantPayment} WETH
                </button>
              )
            ) : !queueApproved ? (
              <button
                className="actionButton"
                onClick={approveQueue}
                disabled={!amountValid || snapshot.queuePaused || busy}
              >
                Approve stETH
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

          <div className="statusBar" aria-live="polite">
            <span className={busy ? "statusSpinner" : "statusDot"} />
            <p>{status}</p>
            {account && (
              <button onClick={() => refresh()} disabled={busy}>
                Refresh
              </button>
            )}
          </div>

          {mode === "instant" && !RESERVOIR_DEPLOYMENT && (
            <button
              className="fallbackLink"
              onClick={() => selectMode("queue")}
            >
              Continue with the Lido queue instead →
            </button>
          )}
        </section>

        <section className="positionsSection" id="positions">
          <div className="sectionHeading">
            <div>
              <p>Your wallet</p>
              <h2>Withdrawal positions</h2>
            </div>
            {account && <span>{short(account)}</span>}
          </div>

          {snapshot?.requests.length ? (
            <div className="positionList">
              {snapshot.requests.map((request) => (
                <article key={request.requestId.toString()}>
                  <div className="positionIdentity">
                    <span className="tokenIcon nftIcon">N</span>
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
                    {request.isFinalized && !request.isClaimed ? (
                      <button
                        onClick={() => claimRequest(request.requestId)}
                        disabled={busy}
                      >
                        Claim ETH
                      </button>
                    ) : (
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
                    )}
                  </div>
                </article>
              ))}
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
                  : "Reservoir reads your Lido withdrawals directly from Ethereum."}
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
              <p>Learn</p>
              <h2>Frequently asked questions</h2>
            </div>
            <a href={DOCS_URL} target="_blank" rel="noreferrer">
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
            <span>Documentation</span>
            <strong>Understand the protocol before using it.</strong>
          </div>
          <div className="docsLinks">
            <a href={DOCS_URL} target="_blank" rel="noreferrer">
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

      <footer>
        <a className="brand" href="#top" aria-label="Reservoir home">
          <span className="brandMark">R</span>
          <strong>Reservoir</strong>
        </a>
        <p>Non-custodial beta · Review every wallet request before signing.</p>
      </footer>

      {quoteModalOpen && (
        <div
          className="modalBackdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.currentTarget === event.target) setQuoteModalOpen(false);
          }}
        >
          <section
            className="quoteModal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="quote-modal-title"
          >
            <div className="modalHeader">
              <div>
                <span>Instant exit</span>
                <h2 id="quote-modal-title">Import your firm quote</h2>
              </div>
              <button
                className="closeButton"
                onClick={() => setQuoteModalOpen(false)}
                aria-label="Close quote dialog"
              >
                ×
              </button>
            </div>
            <p>
              Paste the signed quote supplied by your factor. Reservoir checks
              the seller, amount, expiry, contracts and available liquidity
              before requesting approval.
            </p>
            <textarea
              value={quoteInput}
              onChange={(event) => {
                setQuoteInput(event.target.value);
                setQuoteCheck(null);
              }}
              placeholder="Paste signed quote JSON"
              aria-label="Signed Reservoir quote"
              spellCheck={false}
              autoFocus
            />
            <button
              className="actionButton"
              onClick={inspectQuote}
              disabled={busy || !quoteInput.trim()}
            >
              Verify quote
            </button>
            <small>
              Quotes are short-lived and bound to this wallet. Reservoir never
              stores your wallet key.
            </small>
          </section>
        </div>
      )}
    </>
  );
}
