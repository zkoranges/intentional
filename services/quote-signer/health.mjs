// Readiness derivation and the /health payload — pure functions so the shape
// is testable without a chain or a running server.
//
// Readiness is first-class and explicit:
//   refused    config-level: retired / mismatched deployment or signer — will
//              not clear until the operator fixes configuration and restarts
//   paused     settlement is paused on the kernel — clears when unpaused
//   not-ready  a live precondition fails (unsealed contracts, Lido paused or
//              in bunker mode, no reserve capacity)
//   pending    chain state not yet observed since startup
//   error      the chain could not be read
//   ready      everything above passed as of the snapshot
//
// The payload carries NO secret material: addresses, booleans, and amounts
// only. The server additionally asserts that before responding.

export const READY = "ready";
export const REFUSED = "refused";
export const PAUSED = "paused";
export const NOT_READY = "not-ready";
export const PENDING = "pending";
export const ERROR = "error";

/**
 * Derive the readiness state from startup refusals and the latest chain
 * snapshot. `refusals` is the (sticky) list from verifyDeploymentConfig;
 * `snapshot` is the latest observation of on-chain state, or null before the
 * first read completes.
 */
export function deriveReadiness({ refusals, snapshot, expectedChainId }) {
  if (refusals.length > 0) return { state: REFUSED, reasons: [...refusals] };
  if (snapshot === null) {
    return { state: PENDING, reasons: ["chain state has not been observed yet"] };
  }
  if (snapshot.error) {
    return { state: ERROR, reasons: ["the chain could not be read; see server logs"] };
  }

  const refusedReasons = [];
  if (Number(snapshot.observedChainId) !== Number(expectedChainId)) {
    refusedReasons.push(
      `RPC chain id ${snapshot.observedChainId} does not match the configured chain id ${expectedChainId}`,
    );
  }
  if (!snapshot.factorSignerMatches) {
    refusedReasons.push("the configured key is not the kernel's factor signer");
  }
  if (refusedReasons.length > 0) return { state: REFUSED, reasons: refusedReasons };

  if (snapshot.kernelPaused) {
    return { state: PAUSED, reasons: ["settlement is paused on the kernel"] };
  }

  const notReadyReasons = [];
  if (!snapshot.kernelSealed) notReadyReasons.push("the kernel is not sealed");
  if (!snapshot.adapterAllowed) notReadyReasons.push("the configured adapter is not allowlisted");
  if (!snapshot.fundingSealed) notReadyReasons.push("the funding account is not sealed");
  if (!snapshot.paymentAssetOk) {
    notReadyReasons.push("the funding account's payment asset is not the reviewed WETH reserve");
  }
  if (snapshot.queuePaused) notReadyReasons.push("canonical Lido withdrawals are paused");
  if (snapshot.bunkerMode) notReadyReasons.push("Lido bunker mode is active");
  if (snapshot.capacityWei === 0n) {
    notReadyReasons.push("the reserve reports no available capacity");
  }
  if (notReadyReasons.length > 0) return { state: NOT_READY, reasons: notReadyReasons };

  return { state: READY, reasons: [] };
}

/**
 * Build the /health response body. Everything here is public: contract
 * addresses, pause flags, capacity, and the desk's fixed pricing policy —
 * which is an operator-set spread, never a market or oracle price.
 */
export function buildHealthPayload({ config, refusals, snapshot, activeReservations }) {
  const readiness = deriveReadiness({
    refusals,
    snapshot,
    expectedChainId: config.expectedChainId,
  });

  return {
    ok: readiness.state === READY,
    service: "reservoir-quote-signer",
    readiness: {
      state: readiness.state,
      reasons: readiness.reasons,
      checkedAtUnix: snapshot?.fetchedAtUnix ?? null,
    },
    chain: {
      expectedChainId: config.expectedChainId,
      observedChainId: snapshot?.observedChainId ?? null,
    },
    contracts: {
      kernel: config.kernel,
      lidoAdapter: config.lidoAdapter,
      fundingAccount: snapshot?.fundingAccount ?? null,
      weth: config.weth,
      stETH: config.stETH,
      lidoWithdrawalQueue: config.queue,
      deploymentManifest: config.manifestPath || null,
    },
    factor: config.factorAddress,
    settlement: {
      kernelPaused: snapshot?.kernelPaused ?? null,
      kernelSealed: snapshot?.kernelSealed ?? null,
      adapterAllowed: snapshot?.adapterAllowed ?? null,
      fundingSealed: snapshot?.fundingSealed ?? null,
      lidoQueuePaused: snapshot?.queuePaused ?? null,
      lidoBunkerMode: snapshot?.bunkerMode ?? null,
    },
    capacity: {
      probePaymentWei: config.maxPaymentWei,
      availableWei: snapshot?.capacityWei ?? null,
      coversMaxQuote:
        snapshot && !snapshot.error ? snapshot.capacityWei === config.maxPaymentWei : null,
    },
    pricing: {
      mode: "operator-priced-firm-quote",
      basis: "fixed operator spread; not a market or oracle price",
      spreadBps: config.spreadBps,
      minQuoteWei: config.minQuoteWei,
      maxQuoteWei: config.maxQuoteWei,
      quoteTtlSeconds: config.quoteTtlSeconds,
    },
    reservations: {
      backend: "sqlite",
      active: activeReservations,
    },
    // Legacy top-level fields, kept for existing consumers of /health.
    kernel: config.kernel,
    adapter: config.lidoAdapter,
    maxQuoteWei: config.maxQuoteWei,
    spreadBps: config.spreadBps,
    quoteTtlSeconds: config.quoteTtlSeconds,
    outstanding: activeReservations > 0,
  };
}
