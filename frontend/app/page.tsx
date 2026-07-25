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

type CompletedAction = {
  label: string;
  hash: Hash;
};

const GITHUB_URL = "https://github.com/zkoranges/reservoir-v2-eth-lisbon";
const PRODUCTION_PROOF_URL =
  "https://github.com/zkoranges/reservoir-v2-eth-lisbon/actions/runs/30156722744";

const JURY_METRICS = [
  {
    label: "Aave NAV / fixed shares",
    value: "5.000000 → 5.006285 WETH",
    note: "30-day timestamp advance",
  },
  {
    label: "Seller input",
    value: "0.900000 stETH",
    note: "exact approval",
  },
  {
    label: "Claim acquired",
    value: "0.725747813572212141",
    note: "Lido share units",
  },
  {
    label: "Seller payment",
    value: "0.897750 WETH",
    note: "exact post-acquisition delta",
  },
  {
    label: "Productive NAV left",
    value: "4.102250019398133931",
    note: "WETH in StataWETH",
  },
  {
    label: "Release result",
    value: "PASS",
    note: "canonical Lido + Aave",
  },
] as const;

const JURY_STEPS = [
  "Companion Aqua/SwapVM reserve swap passed in a separate fork proof.",
  "Seller approved exactly 0.9 stETH.",
  "Canonical unstETH #130835 minted directly to the factor.",
  "0.725747813572212141 Lido share units were acquired.",
  "Seller received exactly 0.89775 WETH after acquisition.",
  "4.102250019398133931 WETH of productive reserve NAV remained.",
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
    "Connect a wallet to read canonical Ethereum contracts.",
  );
  const [amountInput, setAmountInput] = useState("0.10");
  const [actions, setActions] = useState<CompletedAction[]>([]);
  const [lastMintedRequest, setLastMintedRequest] = useState<bigint | null>(
    null,
  );
  const [quoteInput, setQuoteInput] = useState("");
  const [quoteCheck, setQuoteCheck] = useState<ReservoirQuoteCheck | null>(null);
  const [juryRun, setJuryRun] = useState(0);
  const [juryStep, setJuryStep] = useState(-1);

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

  useEffect(() => {
    if (juryRun === 0) return;

    setJuryStep(0);
    const timers = JURY_STEPS.slice(1).map((_, index) =>
      window.setTimeout(() => setJuryStep(index + 1), (index + 1) * 520),
    );
    return () => timers.forEach((timer) => window.clearTimeout(timer));
  }, [juryRun]);

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
            ? "Canonical Aqua, SwapVM, Lido, WETH and Aave bindings verified."
            : "A canonical mainnet contract failed code verification.",
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

  async function connect() {
    const injected = getInjectedProvider();
    if (!injected) {
      setStatus("Install or open an injected Ethereum wallet to continue.");
      return;
    }
    setAction("connecting");
    try {
      const next = await connectInjectedWallet(injected);
      setAccount(next);
      await refresh(next);
    } catch (error) {
      setStatus(errorMessage(error));
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
      `Approve exactly ${formatMainnetAmount(amount)} stETH for the canonical Lido queue.`,
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
        { label: "Exact queue approval", hash: receipt.transactionHash },
      ]);
      setStatus("Approval mined. The withdrawal request is ready.");
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Queue approval mined; verification warning",
      );
    }
  }

  async function requestWithdrawal() {
    const injected = getInjectedProvider();
    if (!injected || !account || !amountValid || !queueApproved) return;
    setAction("signing");
    setStatus(
      "Your wallet will simulate and then submit one canonical Lido withdrawal request.",
    );
    try {
      const result = await requestLidoWithdrawal(injected, account, amount);
      setAction("mining");
      setLastMintedRequest(result.requestId);
      setActions((current) => [
        ...current,
        { label: `unstETH #${result.requestId} minted`, hash: result.hash },
      ]);
      setStatus(
        `Withdrawal request #${result.requestId} is owned by your wallet.`,
      );
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Lido request mined; verification warning",
      );
    }
  }

  async function claimRequest(requestId: bigint) {
    const injected = getInjectedProvider();
    if (!injected || !account) return;
    setAction("signing");
    setStatus(`Simulating claim for unstETH #${requestId}.`);
    try {
      const result = await claimLidoWithdrawal(injected, account, requestId);
      setActions((current) => [
        ...current,
        { label: `unstETH #${requestId} claimed`, hash: result.hash },
      ]);
      setStatus(
        `Claim #${requestId} paid ${formatMainnetAmount(result.amountOfEth)} ETH to your wallet.`,
      );
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        `Lido claim #${requestId} mined; verification warning`,
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
    setStatus("Verifying the signed quote, deployment bindings and reserve.");
    try {
      const checked = await verifyReservoirQuote(
        injected,
        account,
        quoteInput,
      );
      setQuoteCheck(checked);
      setStatus(
        `Firm quote verified: ${formatMainnetAmount(BigInt(checked.envelope.quote.paymentAmount))} WETH available.`,
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
    setStatus("Approve only the signed stETH amount for this Lido adapter.");
    try {
      const receipt = await approveExact(
        injected,
        account,
        quoteCheck.envelope.quote.adapter,
        quoteCheck.requestedStEth,
      );
      setActions((current) => [
        ...current,
        { label: "Exact Reservoir approval", hash: receipt.transactionHash },
      ]);
      setStatus("Adapter approval mined. Re-verify before filling.");
      setQuoteCheck(null);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Reservoir approval mined; verification warning",
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
    setStatus(
      "Simulating atomic claim acquisition and exact reserve-backed payment.",
    );
    try {
      const result = await fillReservoirQuote(injected, account, quoteCheck);
      setActions((current) => [
        ...current,
        {
          label: `Reservoir paid ${formatMainnetAmount(result.paymentAmount)} WETH`,
          hash: result.hash,
        },
      ]);
      setLastMintedRequest(result.requestId);
      setStatus(
        `Settled. Claim #${result.requestId} was acquired before ${formatMainnetAmount(result.paymentAmount)} WETH reached your wallet.`,
      );
      setQuoteCheck(null);
      await refresh(account);
    } catch (error) {
      await handleMinedActionError(
        error,
        "Reservoir transaction mined; verification warning",
        true,
      );
    }
  }

  return (
    <main>
      <nav>
        <a className="brand" href="#top" aria-label="Reservoir home">
          <span>R</span>
          <strong>Reservoir</strong>
          <em>v2</em>
        </a>
        <div className="navActions">
          <a
            className="repoLink"
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
          >
            GitHub
          </a>
          <span className={`network ${snapshot?.productionCodeVerified ? "ok" : ""}`}>
            <i />
            Ethereum
          </span>
          <button className="walletButton" onClick={connect} disabled={busy}>
            {account ? short(account) : "Connect wallet"}
          </button>
        </div>
      </nav>

      <section className="hero" id="top">
        <div>
          <p className="eyebrow">Future cash flow → liquidity now</p>
          <h1>
            Exit the queue.
            <span> Keep the claim intact.</span>
          </h1>
          <p className="lede">
            Reservoir acquires a Lido withdrawal claim before productive Aave
            reserves pay the seller. The canonical queue remains available as
            the always-honest fallback.
          </p>
          <div className="heroActions">
            <a className="primaryLink" href="#jury-proof">
              Run the jury proof
            </a>
            <a href={PRODUCTION_PROOF_URL} target="_blank" rel="noreferrer">
              Inspect green CI
            </a>
          </div>
        </div>
        <div className="heroProof" aria-label="Atomic settlement order">
          <span>01</span>
          <p>Acquire unstETH</p>
          <b>→</b>
          <span>02</span>
          <p>Withdraw exact WETH</p>
          <b>→</b>
          <span>03</span>
          <p>Pay seller</p>
        </div>
      </section>

      <section className="juryDemo" id="jury-proof" aria-labelledby="jury-title">
        <header>
          <div>
            <p className="eyebrow">ETHGlobal jury mode</p>
            <h2 id="jury-title">The claim moves before the money does.</h2>
          </div>
          <div className="proofControls">
            <span>Ethereum block 25,604,561</span>
            <button
              className="primary"
              onClick={() => setJuryRun((current) => current + 1)}
            >
              {juryRun === 0 ? "Run verified fork replay" : "Replay proof"}
            </button>
          </div>
        </header>
        <p className="juryBoundary">
          This replays the exact release output from production Lido and Aave
          contracts on a disposable chain-1 fork. It is not a persistent
          mainnet fill. The companion Aqua/SwapVM swap is a separate gated fork
          proof, as required by the 1inch track.
        </p>
        <div className="juryMetrics" aria-label="Verified release measurements">
          {JURY_METRICS.map((metric) => (
            <article key={metric.label}>
              <span>{metric.label}</span>
              <strong>{metric.value}</strong>
              <small>{metric.note}</small>
            </article>
          ))}
        </div>
        <ol className="jurySteps" aria-live="polite">
          {JURY_STEPS.map((step, index) => {
            const revealed = juryStep >= index;
            return (
              <li
                key={step}
                className={revealed ? "revealed" : ""}
                aria-current={juryStep === index ? "step" : undefined}
              >
                <span>{String(index + 1).padStart(2, "0")}</span>
                <p>{step}</p>
                <b>{revealed ? "PASS" : "—"}</b>
              </li>
            );
          })}
        </ol>
        <div className="juryEvidence">
          <p>
            186 deterministic tests · 9 production-contract fork tests · 0
            failures · 0 skips
          </p>
          <a href={PRODUCTION_PROOF_URL} target="_blank" rel="noreferrer">
            Open reproducible GitHub Actions proof
          </a>
        </div>
      </section>

      <section className="terminal" aria-live="polite">
        <div>
          <span className="terminalDot" />
          <p>{status}</p>
        </div>
        {account && (
          <button className="textButton" onClick={() => refresh()} disabled={busy}>
            Refresh
          </button>
        )}
      </section>

      {!provider && (
        <section className="notice">
          <strong>No injected wallet detected.</strong>
          <p>
            Open this page in a browser with MetaMask, Rabby, Frame, or another
            EIP-1193 wallet. No key is stored by Reservoir.
          </p>
        </section>
      )}

      <section className="walletGrid" aria-label="Connected account">
        <article>
          <span>Account</span>
          <strong>{account ? short(account) : "Not connected"}</strong>
          <small>{snapshot ? "chain 1 verified" : "wallet required"}</small>
        </article>
        <article>
          <span>stETH available</span>
          <strong>
            {snapshot
              ? `${formatMainnetAmount(snapshot.stEthBalance)} stETH`
              : "—"}
          </strong>
          <small>canonical rebasing token</small>
        </article>
        <article>
          <span>WETH balance</span>
          <strong>
            {snapshot
              ? `${formatMainnetAmount(snapshot.wethBalance)} WETH`
              : "—"}
          </strong>
          <small>instant-exit settlement asset</small>
        </article>
        <article>
          <span>Lido queue</span>
          <strong>
            {snapshot
              ? snapshot.queuePaused
                ? "Paused"
                : snapshot.bunkerMode
                ? "Bunker mode"
                : "Turbo mode"
              : "—"}
          </strong>
          <small>
            {snapshot
              ? `${snapshot.lastFinalizedRequestId}/${snapshot.lastRequestId} finalized`
              : "live state after connect"}
          </small>
        </article>
      </section>

      <section className="routes" id="exit">
        <header className="sectionHeader">
          <div>
            <p className="eyebrow">Choose the honest route</p>
            <h2>One interface, two outcomes.</h2>
          </div>
          <label className="amountField">
            <span>stETH amount</span>
            <div>
              <input
                inputMode="decimal"
                value={amountInput}
                onChange={(event) => setAmountInput(event.target.value)}
                aria-label="stETH amount"
              />
              <b>stETH</b>
            </div>
          </label>
        </header>

        <div className="routeGrid">
          <article className="route reservoirRoute">
            <div className="routeTop">
              <span className="routeType">Instant / firm quote</span>
              <i>Reservoir</i>
            </div>
            <h3>Acquire the claim. Pay exact WETH.</h3>
            <p>
              {RESERVOIR_DEPLOYMENT
                ? "Paste a factor-signed quote. The app requires the build-pinned kernel and Lido adapter, then verifies its nonce, canonical bindings and full Aave-backed capacity before asking for approval."
                : "The live Lido route is available now. Reservoir instant fills remain disabled until the reviewed kernel and Lido adapter are deployed and pinned into this build."}
            </p>
            {RESERVOIR_DEPLOYMENT && (
              <dl className="deploymentPins" aria-label="Pinned deployment">
                <div>
                  <dt>Pinned kernel</dt>
                  <dd>
                    <a
                      href={`https://etherscan.io/address/${RESERVOIR_DEPLOYMENT.kernel}`}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {RESERVOIR_DEPLOYMENT.kernel}
                    </a>
                  </dd>
                </div>
                <div>
                  <dt>Pinned Lido adapter</dt>
                  <dd>
                    <a
                      href={`https://etherscan.io/address/${RESERVOIR_DEPLOYMENT.lidoAdapter}`}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {RESERVOIR_DEPLOYMENT.lidoAdapter}
                    </a>
                  </dd>
                </div>
              </dl>
            )}
            <textarea
              value={quoteInput}
              onChange={(event) => {
                setQuoteInput(event.target.value);
                setQuoteCheck(null);
              }}
              placeholder="Paste Reservoir signed quote JSON"
              aria-label="Signed Reservoir quote"
              spellCheck={false}
              disabled={!RESERVOIR_DEPLOYMENT}
            />
            {quoteCheck && (
              <dl className="quoteFacts">
                <div>
                  <dt>You deliver</dt>
                  <dd>
                    {formatMainnetAmount(quoteCheck.requestedStEth)} stETH
                  </dd>
                </div>
                <div>
                  <dt>You receive</dt>
                  <dd>
                    {formatMainnetAmount(
                      BigInt(quoteCheck.envelope.quote.paymentAmount),
                    )}{" "}
                    WETH
                  </dd>
                </div>
                <div>
                  <dt>Reserve</dt>
                  <dd>fully available</dd>
                </div>
                <div>
                  <dt>Approval</dt>
                  <dd>
                    {quoteCheck.allowance === quoteCheck.requestedStEth
                      ? "exact amount ready"
                      : "required"}
                  </dd>
                </div>
              </dl>
            )}
            <div className="routeActions">
              {!quoteCheck ? (
                <button
                  className="primary"
                  onClick={inspectQuote}
                  disabled={
                    !RESERVOIR_DEPLOYMENT ||
                    !account ||
                    busy ||
                    !quoteInput.trim()
                  }
                >
                  {RESERVOIR_DEPLOYMENT
                    ? "Verify firm quote"
                    : "Awaiting reviewed deployment"}
                </button>
              ) : (
                quoteCheck.allowance !== quoteCheck.requestedStEth ? (
                  <button
                    className="secondary"
                    onClick={approveReservoir}
                    disabled={busy}
                  >
                    Approve exact stETH
                  </button>
                ) : (
                  <button className="primary" onClick={fillQuote} disabled={busy}>
                    Fill atomically
                  </button>
                )
              )}
            </div>
            <small className="finePrint">
              {RESERVOIR_DEPLOYMENT
                ? "No quote service or key is embedded. The app accepts only the pinned deployment, simulates onchain, then independently checks canonical WETH payment and unstETH ownership."
                : "No arbitrary pasted contract can request approval. Redeploy this frontend only after pinning the reviewed public kernel and adapter addresses."}
            </small>
          </article>

          <article className="route canonicalRoute">
            <div className="routeTop">
              <span className="routeType">Delayed / protocol-native</span>
              <i>Canonical Lido</i>
            </div>
            <h3>Enter the withdrawal queue directly.</h3>
            <p>
              This production route creates an unstETH NFT in your wallet. It
              offers no instant payment and its eventual ETH amount and timing
              follow Lido protocol state.
            </p>
            <dl className="routeFacts">
              <div>
                <dt>Recipient</dt>
                <dd>{account ? short(account) : "connect wallet"}</dd>
              </div>
              <div>
                <dt>Approval</dt>
                <dd>{queueApproved ? "exact amount ready" : "required"}</dd>
              </div>
              <div>
                <dt>Output</dt>
                <dd>one transferable unstETH</dd>
              </div>
            </dl>
            <div className="routeActions">
              {!snapshot ? (
                <button className="primary" onClick={connect} disabled={busy}>
                  Connect to continue
                </button>
              ) : snapshot.chainId !== 1 ? (
                <button
                  className="primary"
                  onClick={switchToMainnet}
                  disabled={busy}
                >
                  Switch to Ethereum
                </button>
              ) : !queueApproved ? (
                <button
                  className="secondary"
                  onClick={approveQueue}
                  disabled={!amountValid || snapshot.queuePaused || busy}
                >
                  Approve exact stETH
                </button>
              ) : (
                <button
                  className="primary"
                  onClick={requestWithdrawal}
                  disabled={!amountValid || snapshot.queuePaused || busy}
                >
                  Request withdrawal
                </button>
              )}
            </div>
            <small className="finePrint">
              The app simulates every write first. You remain the NFT owner and
              can transfer or claim it through any compatible interface.
              Bunker mode changes timing and underwriting risk; only a paused
              queue disables this action.
            </small>
          </article>
        </div>
      </section>

      {(lastMintedRequest !== null || actions.length > 0) && (
        <section className="activity">
          <header className="sectionHeader">
            <div>
              <p className="eyebrow">Receipt-backed activity</p>
              <h2>What actually happened.</h2>
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
                View unstETH #{lastMintedRequest}
              </a>
            )}
          </header>
          <ol>
            {actions.map((item) => (
              <li key={`${item.hash}-${item.label}`}>
                <span>{item.label}</span>
                <a href={etherscanTx(item.hash)} target="_blank" rel="noreferrer">
                  {short(item.hash)}
                </a>
              </li>
            ))}
          </ol>
        </section>
      )}

      <section className="requests" aria-label="Recent Lido requests">
        <header className="sectionHeader">
          <div>
            <p className="eyebrow">Your canonical claims</p>
            <h2>Recent unstETH positions.</h2>
          </div>
          <span>
            {snapshot ? `${snapshot.requests.length} loaded` : "connect to load"}
          </span>
        </header>
        {snapshot?.requests.length ? (
          <div className="requestList">
            {snapshot.requests.map((request) => (
              <article key={request.requestId.toString()}>
                <div>
                  <span>unstETH #{request.requestId}</span>
                  <strong>
                    {formatMainnetAmount(request.amountOfStETH)} stETH
                  </strong>
                </div>
                <div>
                  <span>Created</span>
                  <strong>{unixDate(request.timestamp)}</strong>
                </div>
                <div>
                  <span>Status</span>
                  <strong>
                    {request.isClaimed
                      ? "Claimed"
                      : request.isFinalized
                        ? "Claimable"
                        : "Pending"}
                  </strong>
                </div>
                <div className="requestAction">
                  {request.isFinalized && !request.isClaimed ? (
                    <button
                      className="primary small"
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
                      Inspect
                    </a>
                  )}
                </div>
              </article>
            ))}
          </div>
        ) : (
          <div className="emptyState">
            <p>
              {snapshot
                ? "No Lido withdrawal NFTs were found for this wallet."
                : "Connect a wallet to read its canonical Lido positions."}
            </p>
          </div>
        )}
      </section>

      <section className="proof">
        <div className="proofCopy">
          <p className="eyebrow">Jury-grade evidence</p>
          <h2>Production contracts. Disposable capital.</h2>
          <p>
            The release gate executes Lido origination and Aave StataWETH
            materialization against pinned historical Ethereum state. A
            separate companion proof executes the modified SwapVM router
            through official Aqua. No external protocol is replaced by a test
            double in the fork suite.
          </p>
        </div>
        <div className="proofGrid">
          <article>
            <span>01 / Rest</span>
            <strong>5.000000 WETH NAV</strong>
            <small>zero idle underlying</small>
          </article>
          <article>
            <span>02 / Earn</span>
            <strong>5.006285 WETH NAV</strong>
            <small>same StataWETH shares</small>
          </article>
          <article>
            <span>03 / Acquire</span>
            <strong>0.725747813572 shares</strong>
            <small>canonical unstETH</small>
          </article>
          <article>
            <span>04 / Pay</span>
            <strong>0.89775 WETH</strong>
            <small>after claim acquisition</small>
          </article>
        </div>
        <div className="bindings">
          {[
            ["Aqua", ADDRESSES.aqua],
            ["SwapVM", ADDRESSES.swapVm],
            ["Lido queue", ADDRESSES.lidoQueue],
            ["StataWETH", ADDRESSES.stataWeth],
          ].map(([name, address]) => (
            <a
              key={address}
              href={etherscanToken(address as Address)}
              target="_blank"
              rel="noreferrer"
            >
              <span>{name}</span>
              <strong>{short(address)}</strong>
            </a>
          ))}
        </div>
      </section>

      <section className="safety">
        <p className="eyebrow">Transaction boundary</p>
        <div>
          <h2>The page is convenience. The contracts are authority.</h2>
          <ul>
            <li>Exact approvals only—never unlimited.</li>
            <li>Ethereum mainnet and canonical endpoints are checked.</li>
            <li>Every write is simulated before the wallet sends it.</li>
            <li>A Reservoir payment follows measured claim acquisition.</li>
            <li>Canonical queue timing and redemption value can change.</li>
          </ul>
        </div>
      </section>

      <footer>
        <div className="brand">
          <span>R</span>
          <strong>Reservoir</strong>
          <em>ETH Lisbon</em>
        </div>
        <div className="footerLinks">
          <a href={GITHUB_URL} target="_blank" rel="noreferrer">
            Source
          </a>
          <a href={PRODUCTION_PROOF_URL} target="_blank" rel="noreferrer">
            Fork proof
          </a>
          <p>
            Mainnet wallet beta · Review contract addresses and wallet prompts
            before signing.
          </p>
        </div>
      </footer>
    </main>
  );
}
