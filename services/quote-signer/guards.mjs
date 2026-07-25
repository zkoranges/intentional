// Startup and per-request guards for the quote signer:
//   - bind safety: the desk's posture is loopback-only behind a reverse proxy; a
//     non-loopback HOST is always refused at startup;
//   - deployment refusal: retired / mismatched deployments are refused as a
//     first-class readiness state, not discovered as a late runtime error;
//   - secret hygiene: outbound health payloads are asserted free of secret
//     material before they leave the process.

import { readFileSync } from "node:fs";
import { getAddress } from "viem";

// Deployments that must never be quoted against again. The v2 kernel is
// retired: its factor key was exposed and the deployment is paused for good.
// A fork rehearsal must deploy a fresh local kernel instead of weakening this
// guard. Checksummed for exact comparison.
export const RETIRED_KERNELS = new Set([
  getAddress("0x50b619295e00990feB28E79fA939B5f42aF6AF53"), // Reservoir v2 — retired-paused, key exposed
]);

export function isLoopbackHost(host) {
  if (typeof host !== "string" || host.length === 0) return false;
  const bare = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (bare === "localhost" || bare === "::1" || bare === "0:0:0:0:0:0:0:1") return true;
  if (/^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(bare)) return true;
  if (bare.startsWith("::ffff:127.")) return true;
  return false;
}

export function isLoopbackUrl(url) {
  try {
    return isLoopbackHost(new URL(url).hostname);
  } catch {
    return false;
  }
}

function manifestAddressMatches(value, configured) {
  try {
    return typeof value === "string" && getAddress(value) === getAddress(configured);
  } catch {
    return false;
  }
}

/** The desk binds loopback only; public exposure is a reverse proxy in front. */
export function assertBindSafe(host) {
  if (isLoopbackHost(host)) return [];
  throw new Error(
    `refusing to bind non-loopback host ${host}: the quote desk's posture is ` +
      "loopback-only behind an authenticated reverse proxy; there is no configuration override",
  );
}

/**
 * Config-level deployment verification, computed once at startup (the inputs
 * are process configuration, so the result cannot change until restart) and
 * enforced on every request. Returns { refusals, manifest }; a non-empty
 * refusal list is the "refused" readiness state.
 */
export function verifyDeploymentConfig({
  expectedChainId,
  kernel,
  lidoAdapter,
  lidoUnstETHAdapter,
  manifestPath,
}) {
  const refusals = [];
  let manifest = null;

  if (RETIRED_KERNELS.has(getAddress(kernel))) {
    refusals.push(
      `kernel ${kernel} is a retired deployment and must never be targeted again; ` +
        "fork rehearsals must deploy a fresh local kernel",
    );
  }

  if (!manifestPath) {
    refusals.push("DEPLOYMENT_MANIFEST is required; unsigned address-only configuration is refused");
  } else {
    try {
      manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    } catch (error) {
      refusals.push(`deployment manifest ${manifestPath} is unreadable: ${error.message}`);
      return { refusals, manifest: null };
    }

    if (manifest.releaseState !== "active") {
      refusals.push(
        `deployment manifest releaseState is "${manifest.releaseState}" — ` +
          'only an "active" deployment may be quoted against',
      );
    }
    if (Number(manifest.chainId) !== Number(expectedChainId)) {
      refusals.push(
        `deployment manifest chainId ${manifest.chainId} does not match the ` +
          `configured chain id ${expectedChainId}`,
      );
    }
    const manifestKernel = manifest.contracts?.kernel?.address;
    if (!manifestAddressMatches(manifestKernel, kernel)) {
      refusals.push(
        `configured KERNEL_ADDRESS ${kernel} does not match the manifest kernel ` +
          `${manifestKernel ?? "<missing>"}`,
      );
    }
    const manifestAdapter = manifest.contracts?.lidoAdapter?.address;
    if (!manifestAddressMatches(manifestAdapter, lidoAdapter)) {
      refusals.push(
        `configured LIDO_ADAPTER_ADDRESS ${lidoAdapter} does not match the ` +
          `manifest lidoAdapter ${manifestAdapter ?? "<missing>"}`,
      );
    }
    const manifestUnstETHAdapter = manifest.contracts?.lidoUnstETHExitAdapter?.address;
    if (
      !manifestAddressMatches(manifestUnstETHAdapter, lidoUnstETHAdapter)
    ) {
      refusals.push(
        `configured LIDO_UNSTETH_ADAPTER_ADDRESS ${lidoUnstETHAdapter} does not match the ` +
          `manifest lidoUnstETHExitAdapter ${manifestUnstETHAdapter ?? "<missing>"}`,
      );
    }
  }

  return { refusals, manifest };
}

/**
 * Assert that an outbound payload carries none of the given secret values in
 * any obvious encoding (verbatim, lowercased, or hex without its 0x prefix).
 * Throws a generic error — the message never includes the secret itself.
 */
export function assertNoSecretMaterial(payload, secrets) {
  const haystackLower = payload.toLowerCase();
  for (const secret of secrets) {
    if (typeof secret !== "string" || secret.length < 8) continue;
    const variants = new Set([secret.toLowerCase()]);
    if (secret.toLowerCase().startsWith("0x") && secret.length > 10) {
      variants.add(secret.slice(2).toLowerCase());
    }
    for (const variant of variants) {
      if (haystackLower.includes(variant)) {
        throw new Error("outbound payload contains secret material; refusing to send it");
      }
    }
  }
}
